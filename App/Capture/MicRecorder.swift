// Copyright (c) 2026 Andrew Jones
// Copyright (c) 2026 Samat Galimov
// SPDX-License-Identifier: MIT
// Портировано из gsamat/amanu@fbccc13: Sources/amanu/Audio/MicRecorder.swift (MIT) — ядро рестартов
// (start L283-311, слушатель default input L687-720, рестарт L725-823, паддинг L855-873) и привязка
// к микрофону звонилки (bindInputDevice L633-655): без voice processing и storm-guard.
@preconcurrency import AVFoundation
import Accelerate
import CoreAudio
import EarmarkAudio
import EarmarkCore
import Foundation
import Synchronization
import os

/// Микрофон (я): AVAudioEngine.inputNode → CAFWriter (синхронно, со своей очереди).
///
/// Voice processing (VPIO) не включаем никогда: он приглушает чужой звук, может заглушить микрофон в
/// Teams и Chrome и дестабилизирует aggregate с tap.
///
/// Пишем микрофон звонилки, а не системный default: микрофон выбирают в настройках звонилки (Teams,
/// Jitsi), и default об этом не знает. Какие входы держит звонилка, раз в секунду сообщает
/// CallActivityMonitor (`follow`), выбирает MicRoute. Без звонилки — default.
///
/// Формат входа не фиксирован (BT-гарнитура в HFP — 1 ch 16 kHz, замер S1), а формат файла задан
/// первой записью: каждый буфер приводим к `writer.clientFormat`.
///
/// Перезапуск — по AVAudioEngineConfigurationChange (звонилка перенастроила устройство, AirPods сменили
/// профиль) и по смене default input: на неё AVAudioEngine не реагирует вовсе, остаётся на старом
/// устройстве и ничего не постит (замер amanu). Дыру после рестарта закрывает тишиной первый буфер
/// нового движка — только он знает, сколько устройство поднималось.
final class MicRecorder: @unchecked Sendable {
    /// Пачка уведомлений при переключении устройства — один рестарт.
    static let restartDebounce: TimeInterval = 0.5
    static let retryDelay: TimeInterval = 2

    private static let log = Logger(subsystem: EarmarkPaths.bundleID, category: "mic")

    private let control = DispatchQueue(label: "com.konayre.earmark.mic")
    private let writeQueue = DispatchQueue(label: "com.konayre.earmark.mic.write", qos: .userInitiated)
    private let level = Atomic<Float>(0)
    private let firstHostTime = Atomic<UInt64>(0)
    /// Host time последнего вызова тапа: живой ли движок, который уверяет, что работает.
    private let lastTapHostTime = Atomic<UInt64>(0)
    private let running = Atomic<Bool>(false)
    private let ticksPerSecond = AudioGetHostClockFrequency()

    // Только на `control`.
    private var writer: CAFWriter?
    private var engine: AVAudioEngine?
    /// Устройство и формат, на которых поднят `engine`.
    private var device: AudioObjectID?
    private var inputFormat: AVAudioFormat?
    private var generation = 0
    private var configObserver: (any NSObjectProtocol)?
    private var defaultInputListener: AudioObjectPropertyListenerBlock?
    private var pendingRestart: DispatchWorkItem?
    /// Микрофоны звонилок с последнего опроса — хранятся и на простое: старт посреди созвона сразу берёт
    /// микрофон звонилки.
    private var callInputs: [AudioObjectID] = []
    /// Микрофон звонилки, на котором держим запись; nil — системный default.
    private var wanted: AudioObjectID?
    private var settle = MicRoute.Settle()
    /// Не поднялись в этой записи: до следующей к ним не возвращаемся.
    private var refused: Set<AudioObjectID> = []
    /// Последний attach привязал движок к `wanted` явно, мимо default. Отказ default в `refused` не идёт.
    private var boundWanted = false

    // Только на `writeQueue`.
    /// Открыт от start до stop: буфер, который тап отдал уже после stop, в закрытый writer не идёт.
    private var accepting = false
    private var writtenGeneration = 0
    private var windowSum: Float = 0
    private var windowFrames: Int = 0
    private var reportedWriteError = false

    /// RMS последней полной секунды, 0…1. Пока рекордер не пишет — 0: монитор созвона на простое
    /// должен видеть тишину, а не уровень прошлой записи. Буферов нет дольше 2 с (рестарт движка,
    /// устройство ещё не поднялось) — тоже 0, а не застывший уровень последней живой секунды.
    var levelRMS: Float {
        guard isRunning else { return 0 }
        let last = lastTapHostTime.load(ordering: .relaxed)
        let now = AudioGetCurrentHostTime()
        guard now >= last, Double(now - last) < 2 * ticksPerSecond else { return 0 }
        return level.load(ordering: .relaxed)
    }
    /// Host time первого сэмпла трека; nil до первого буфера.
    var startHostTime: UInt64? {
        let first = firstHostTime.load(ordering: .acquiring)
        return first == 0 ? nil : first
    }
    var isRunning: Bool { running.load(ordering: .relaxed) }

    func start(writer: CAFWriter) throws(EarmarkError) {
        try control.sync { () -> Result<Void, EarmarkError> in
            guard self.writer == nil else { return .success(()) }
            level.store(0, ordering: .relaxed)
            firstHostTime.store(0, ordering: .relaxed)
            writeQueue.sync {
                accepting = true
                windowSum = 0
                windowFrames = 0
                reportedWriteError = false
            }
            self.writer = writer
            refused = []
            settle = MicRoute.Settle()
            wanted = route(current: nil)
            do throws(EarmarkError) {
                try attachWithFallback()
            } catch {
                self.writer = nil
                return .failure(error)
            }
            listenForDefaultInput()
            running.store(true, ordering: .relaxed)
            return .success(())
        }.get()
    }

    /// Останавливает движок и дожидается записи уже пришедших буферов: после возврата writer можно закрывать.
    func stop() {
        control.sync {
            guard writer != nil else { return }
            pendingRestart?.cancel()
            pendingRestart = nil
            stopListeningForDefaultInput()
            detach()
            writer = nil
            running.store(false, ordering: .relaxed)
        }
        // Барьер: всё, что тап отдал до этой точки, уже в файле; опоздавшие буферы отбросит `accepting`.
        writeQueue.sync { accepting = false }
    }

    /// Входы звонилок с опроса CallActivityMonitor, с любого потока. Во время записи — переезд на микрофон
    /// звонилки, когда новый выбор устоялся (MicRoute.Settle).
    func follow(callInputs inputs: [AudioObjectID]) {
        control.async { [self] in
            callInputs = inputs
            guard writer != nil else { return }
            // nil — звонилка отпустила вход: остаёмся, где есть. Переключение внутри звонилки даёт пустой
            // опрос, и прыжок на default стоил бы двух рестартов.
            let choice = route(current: device)
            // Звонилка на том микрофоне, который уже пишем: закрепляем его, иначе смена default увела бы запись.
            if let choice, choice == device { wanted = choice }
            guard settle.observe(choice, current: device), let target = choice else { return }
            wanted = target
            scheduleRestart(reason: "call app moved to \(Self.describe(target))")
        }
    }

    // MARK: - Движок

    /// Какой микрофон писать по последнему опросу, без отказавших; nil — звонилка не держит входов.
    private func route(current: AudioObjectID?) -> AudioObjectID? {
        MicRoute.choose(
            callInputs: callInputs.filter { !refused.contains($0) }, current: current,
            systemDefault: AudioProcessList.defaultInputDevice())
    }

    /// attach, а не поднялся микрофон звонилки — ещё попытка на default. Не поднялся сам default (звонилка
    /// на нём же) — запасного нет: ошибка уходит наверх, на ретрай рестарта.
    private func attachWithFallback() throws(EarmarkError) {
        do throws(EarmarkError) {
            try attach()
        } catch {
            guard boundWanted, let wanted else { throw error }
            refuse(wanted, because: error.message)
            try attach()
        }
    }

    /// Новый AVAudioEngine на микрофоне звонилки или текущем default input: старый после смены устройства
    /// на нём и остался бы.
    private func attach() throws(EarmarkError) {
        guard let writer else { return }
        let fallback = AudioProcessList.defaultInputDevice()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        boundWanted = false
        // Default движок берёт сам; другое устройство — только явно и до чтения формата.
        if let wanted, wanted != fallback {
            do {
                try input.auAudioUnit.setDeviceID(wanted)
                boundWanted = true
            } catch {
                refuse(wanted, because: error.localizedDescription)
            }
        }
        let device = wanted ?? fallback
        guard let format = Self.deviceFormat(of: input), format.sampleRate > 0 else {
            throw .unavailable("no input device")
        }
        try installTap(on: input, format: format, writer: writer)
        // Подписка до start: только что привязанный движок встаёт сразу после старта, и уведомление, пришедшее до
        // подписки, потерялось бы. Рестарт отложен и уйдёт в `control` уже после этого attach.
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.control.async { self.scheduleRestart(reason: "AVAudioEngineConfigurationChange") }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            NotificationCenter.default.removeObserver(observer)
            input.removeTap(onBus: 0)
            throw .operationFailed("the microphone did not start: \(error.localizedDescription)")
        }
        configObserver = observer
        self.engine = engine
        self.device = device
        inputFormat = format
        let name = device.map(Self.describe) ?? "none"
        let source = wanted == nil ? "default" : "call app"
        Self.log.info(
            """
            mic: device \(name, privacy: .public) (\(source, privacy: .public)), \
            \(format.sampleRate, privacy: .public) Hz × \(format.channelCount, privacy: .public)
            """)
    }

    /// Формат, который отдаёт устройство. outputFormat узла после setDeviceID остаётся от прежнего устройства
    /// (замер 10.10.2026: 48 kHz от MacBook на входе 16 kHz), и тап на нём не получает ни одного буфера:
    /// частота тапа обязана совпадать с аппаратной. Канал один: трек моно, и из многоканального входа тап
    /// берёт канал 0, основной у микрофона, — без микса (стандартный формат больше двух каналов и не умеет).
    /// nil — входа нет.
    private static func deviceFormat(of input: AVAudioInputNode) -> AVAudioFormat? {
        let hardware = input.inputFormat(forBus: 0)
        guard hardware.channelCount > 0 else { return nil }
        return AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate, channels: 1)
    }

    /// Тап нового поколения: по поколению очередь записи узнаёт первый буфер после рестарта и закрывает дыру.
    private func installTap(on input: AVAudioInputNode, format: AVAudioFormat, writer: CAFWriter)
        throws(EarmarkError)
    {
        let target = writer.clientFormat
        let converter: AVAudioConverter?
        if format == target {
            converter = nil
        } else {
            // Файл держит формат первой записи; новое устройство (48k колонки, 16k HFP) приводим к нему.
            guard let made = AVAudioConverter(from: format, to: target) else {
                throw .operationFailed("no converter from \(format) to \(target)")
            }
            converter = made
        }
        generation += 1
        let tap = TapContext(generation: generation, writer: writer, converter: converter, target: target)
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak self] buffer, when in
            guard let self else { return }
            self.lastTapHostTime.store(AudioGetCurrentHostTime(), ordering: .relaxed)
            // Буфер приводим и копируем здесь, на потоке тапа: в свою очередь уходит наш собственный буфер.
            guard let owned = tap.own(buffer) else { return }
            let host = when.isHostTimeValid ? when.hostTime : nil
            self.writeQueue.async { self.write(owned, hostTime: host, tap: tap) }
        }
    }

    /// Движок сам встал на смене конфигурации, а устройство и формат прежние: запускаем его же. Новый движок на
    /// только что выбранном устройстве ловил ту же смену и тоже вставал (замер 10.10.2026: лишний рестарт на
    /// каждый переезд, под нагрузкой — шторм рестартов). false — не завёлся, нужна пересборка.
    private func restartInPlace(_ engine: AVAudioEngine) -> Bool {
        guard let writer, let inputFormat else { return false }
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        do throws(EarmarkError) {
            try installTap(on: input, format: inputFormat, writer: writer)
        } catch {
            return false
        }
        do {
            try engine.start()
        } catch {
            Self.log.error(
                "mic: the engine did not start again: \(error.localizedDescription, privacy: .public)")
            return false
        }
        return true
    }

    /// Микрофон звонилки не поднялся: пишем default и к этому устройству до конца записи не возвращаемся.
    private func refuse(_ device: AudioObjectID, because reason: String) {
        refused.insert(device)
        wanted = nil
        Self.log.warning(
            """
            mic: cannot record \(Self.describe(device), privacy: .public) \
            (\(reason, privacy: .public)), using the default input
            """)
    }

    /// «Имя (id)» для логов.
    private static func describe(_ device: AudioObjectID) -> String {
        "\(AudioProcessList.deviceName(device) ?? "?") (\(device))"
    }

    private func detach() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
    }

    private func scheduleRestart(reason: String) {
        guard writer != nil else { return }
        pendingRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.restart(reason: reason) }
        pendingRestart = work
        control.asyncAfter(deadline: .now() + Self.restartDebounce, execute: work)
    }

    private func restart(reason: String, isRetry: Bool = false) {
        guard writer != nil else { return }
        // Уведомление ещё не значит, что движок умер: при старте системного tap оно приходит, а микрофон
        // пишет дальше (замер S1). Рестарт тогда дал бы лишь дыру в начале каждой записи. Сверяем с микрофоном
        // звонилки, а не с одним default: смена default при записи с микрофона звонилки дала бы холостой
        // рестарт.
        let running = engine?.isRunning == true
        let sameDevice = device == wanted ?? AudioProcessList.defaultInputDevice()
        let sameFormat = engine.flatMap { Self.deviceFormat(of: $0.inputNode) } == inputFormat
        let tapAlive = isTapAlive
        if running, sameDevice, sameFormat, tapAlive {
            Self.log.info("mic: \(reason, privacy: .public), the engine keeps delivering, no restart")
            return
        }
        // Привязку сверяем по самому движку: пропавшее устройство AUHAL мог подменить default.
        if let engine, !running, sameDevice, engine.inputNode.auAudioUnit.deviceID == device, sameFormat,
            restartInPlace(engine)
        {
            Self.log.info("mic: \(reason, privacy: .public), the engine stopped, started it again in place")
            return
        }
        Self.log.warning(
            """
            mic: restart (\(reason, privacy: .public)): running \(running, privacy: .public), \
            same device \(sameDevice, privacy: .public), same format \(sameFormat, privacy: .public), \
            tap alive \(tapAlive, privacy: .public)
            """)
        detach()
        do throws(EarmarkError) {
            // Сразу после уведомления устройство часто ещё поднимается (BT-гарнитура сменила профиль):
            // первая неудача — повод для ретрая на том же микрофоне, а не отказ от него до конца записи.
            if isRetry { try attachWithFallback() } else { try attach() }
        } catch {
            // Устройство могло ещё не появиться (AirPods на полпути) — пробуем снова; дыру закроет первый
            // буфер, когда движок наконец поднимется.
            Self.log.error("mic: restart failed: \(error.message, privacy: .public), retrying in 2 s")
            let work = DispatchWorkItem { [weak self] in self?.restart(reason: "retry", isRetry: true) }
            pendingRestart = work
            control.asyncAfter(deadline: .now() + Self.retryDelay, execute: work)
        }
    }

    /// Тап звался за последние `restartDebounce`, то есть уже после уведомления. Буфер тапа — до 400 мс.
    private var isTapAlive: Bool {
        let last = lastTapHostTime.load(ordering: .relaxed)
        let now = AudioGetCurrentHostTime()
        return now >= last && Double(now - last) < Self.restartDebounce * ticksPerSecond
    }

    private static let defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private func listenForDefaultInput() {
        var address = Self.defaultInputAddress
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleRestart(reason: "default input changed")
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, control, listener)
        if status == noErr {
            defaultInputListener = listener
        } else {
            Self.log.error("mic: cannot watch the default input (OSStatus \(status, privacy: .public))")
        }
    }

    private func stopListeningForDefaultInput() {
        guard let listener = defaultInputListener else { return }
        var address = Self.defaultInputAddress
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, control, listener)
        defaultInputListener = nil
    }

    // MARK: - Запись (writeQueue)

    private func write(_ buffer: AVAudioPCMBuffer, hostTime: UInt64?, tap: TapContext) {
        guard accepting else { return }
        let writer = tap.writer
        do {
            if tap.generation != writtenGeneration {
                // Первый буфер нового движка: дыра = его host time минус «где трек должен быть». У первого
                // движка сеанса firstHostTime ещё 0 — паддить нечего.
                let first = firstHostTime.load(ordering: .acquiring)
                if first != 0, let hostTime {
                    let gap = PaddingMath.gapFrames(
                        startHostTime: first, framesWritten: writer.framesWritten, actualHostTime: hostTime,
                        sampleRate: writer.clientFormat.sampleRate, hostTicksPerSecond: ticksPerSecond)
                    if gap > 0 {
                        Self.log.info("mic: gap after restart, \(gap, privacy: .public) frames of silence")
                        try writer.writeSilence(frames: AVAudioFrameCount(clamping: gap))
                    }
                }
                writtenGeneration = tap.generation
            }
            if firstHostTime.load(ordering: .relaxed) == 0 {
                firstHostTime.store(hostTime ?? AudioGetCurrentHostTime(), ordering: .releasing)
            }
            try writer.write(buffer)
            measure(buffer)
        } catch {
            // Диск полон или writer закрыт — сообщаем один раз, а не на каждый буфер.
            if !reportedWriteError {
                Self.log.error("mic.caf: \(error.localizedDescription, privacy: .public)")
            }
            reportedWriteError = true
        }
    }

    private func measure(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        var sum: Float = 0
        vDSP_svesq(data, 1, &sum, vDSP_Length(buffer.frameLength))
        windowSum += sum
        windowFrames += Int(buffer.frameLength)
        guard Double(windowFrames) >= buffer.format.sampleRate else { return }
        level.store((windowSum / Float(windowFrames)).squareRoot(), ordering: .relaxed)
        windowSum = 0
        windowFrames = 0
    }
}

/// Состояние одного движка, нужное блоку тапа. Тап вызывается последовательно на одном потоке, поэтому
/// конвертер без замков; новый движок — новый контекст.
private final class TapContext: @unchecked Sendable {
    let generation: Int
    let writer: CAFWriter
    private let converter: AVAudioConverter?
    private let target: AVAudioFormat

    init(generation: Int, writer: CAFWriter, converter: AVAudioConverter?, target: AVAudioFormat) {
        self.generation = generation
        self.writer = writer
        self.converter = converter
        self.target = target
    }

    /// Буфер в формате writer'а, принадлежащий нам: тап может переиспользовать свою память.
    func own(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter else { return copy(buffer) }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        // Блок ввода @Sendable: «уже отдали» храним в ящике, а не в локальной var.
        final class Fed: @unchecked Sendable { var done = false }
        let fed = Fed()
        var error: NSError?
        // .noDataNow, а не .endOfStream: хвост ресэмплера остаётся в конвертере и выйдет со следующим
        // буфером, а не теряется на каждом стыке.
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            guard !fed.done else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed.done = true
            inputStatus.pointee = .haveData
            return buffer
        }
        return status == .error || output.frameLength == 0 ? nil : output
    }

    private func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let output = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength)
        else {
            return nil
        }
        output.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
        for (from, to) in zip(source, destination) {
            if let src = from.mData, let dst = to.mData {
                memcpy(dst, src, Int(min(from.mDataByteSize, to.mDataByteSize)))
            }
        }
        return output
    }
}
