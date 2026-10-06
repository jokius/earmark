// Copyright (c) 2026 Andrew Jones
// Copyright (c) 2026 Samat Galimov
// Портировано из gsamat/amanu@fbccc13: Sources/amanu/Audio/SystemAudioRecorder.swift (MIT).
// Глобальный mono-tap без себя и порядок разборки — insidegui/AudioCap@6f609e8
// AudioCap/ProcessTap/ProcessTap.swift (BSD-2, Copyright (c) 2024 Guilherme Rambo). Запись из IOProc
// через ExtAudioFileWriteAsync — Apple sample «Capturing system audio with Core Audio taps»
// (Copyright © 2024 Apple Inc.).
@preconcurrency import AVFoundation
import Accelerate
import AudioToolbox
import CoreAudio
import EarmarkAudio
import EarmarkCore
import Foundation
import Synchronization
import os

/// Собеседники: Core Audio process tap → приватный aggregate только из tap → IOProc → CAFWriter.
///
/// Tap глобальный (всё, что звучит, кроме самого earmark): per-app tap тихо промахивается мимо
/// helper'ов браузеров, а час тишины на канале собеседников хуже уведомлений в нём.
///
/// Watchdog раз в 5 с: колбэков нет 45 с — пересобираем tap и aggregate и пишем дальше в тот же файл,
/// дыру закрываем тишиной по host time. То же — по kAudioHardwarePropertyServiceRestarted: после
/// перезапуска coreaudiod все наши объекты недействительны.
///
/// Keep-alive output не нужен: по замеру S1 tap-only aggregate с tapautostart = 0 зовёт IOProc
/// непрерывно и в тишине. Не мерили случай «выход простаивает, микрофон на другом устройстве»: если
/// system.caf в бою выйдет короче mic.caf — вернуть тихий выход на время захвата.
final class SystemAudioRecorder: @unchecked Sendable {
    static let stallTimeout: TimeInterval = 45
    static let watchdogInterval: TimeInterval = 5

    private static let log = Logger(subsystem: "com.konayre.earmark", category: "system-audio")

    private let control = DispatchQueue(label: "com.konayre.earmark.system-audio")
    private let ioQueue = DispatchQueue(label: "com.konayre.earmark.system-audio.io", qos: .userInteractive)
    private let running = Atomic<Bool>(false)
    /// Читаются с любого потока без control.sync: пересборка может держать control секунды (тишина).
    private let meters = Meters()

    // Только на `control`.
    private var io: IOState?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    /// Когда IO последний раз (пере)запускался — отсчёт для watchdog, пока колбэков ещё не было.
    private var ioStartedAt: UInt64 = 0
    private var watchdog: DispatchSourceTimer?
    private var serviceRestartListener: AudioObjectPropertyListenerBlock?

    /// RMS последней полной секунды, 0…1. Пока рекордер не пишет — 0: монитор созвона на простое
    /// должен видеть тишину, а не уровень прошлой записи. Колбэков нет дольше 2 с (stall, пересборка не
    /// удалась) — тоже 0: в файл идёт тишина паддинга, и стоп-правила с far_end_digital_silence должны
    /// видеть её, а не застывший уровень последней живой секунды.
    var levelRMS: Float {
        guard isRunning else { return 0 }
        let last = meters.lastHostTime.load(ordering: .relaxed)
        let now = AudioGetCurrentHostTime()
        guard now >= last, Double(now - last) < 2 * Double(AudioGetHostClockFrequency()) else { return 0 }
        return meters.level.load(ordering: .relaxed)
    }
    /// Host time первого сэмпла трека; nil, пока IOProc ни разу не вызывался.
    var startHostTime: UInt64? {
        let first = meters.firstHostTime.load(ordering: .acquiring)
        return first == 0 ? nil : first
    }
    var isRunning: Bool { running.load(ordering: .relaxed) }

    /// `writer` создан с форматом трека, и в него ещё ничего не записано: клиентский формат (формат tap)
    /// рекордер ставит сам. Первый старт tap показывает системный запрос на запись системного звука
    /// и блокирует поток до ответа (S1).
    func start(writer: CAFWriter) throws(EarmarkError) {
        // DispatchQueue.sync только rethrows и стирает тип ошибки — несём её наружу через Result.
        try control.sync { () -> Result<Void, EarmarkError> in
            guard io == nil else { return .success(()) }
            meters.reset()
            let state = IOState(writer: writer, meters: meters)
            do throws(EarmarkError) {
                try build(state, isFirst: true)
            } catch {
                return .failure(error)
            }
            io = state
            listenForServiceRestart()
            startWatchdog()
            running.store(true, ordering: .relaxed)
            return .success(())
        }.get()
    }

    /// Останавливает IO и ждёт, пока IO-очередь доработает: после возврата writer можно закрывать.
    /// Сам writer рекордер не закрывает.
    func stop() {
        control.sync {
            guard io != nil else { return }
            watchdog?.cancel()
            watchdog = nil
            stopListeningForServiceRestart()
            teardown()
            io = nil
            running.store(false, ordering: .relaxed)
        }
    }

    // MARK: - Сборка и разборка

    /// tap → формат → aggregate → IOProc → старт. На любой ошибке разбирает собранное.
    private func build(_ state: IOState, isFirst: Bool) throws(EarmarkError) {
        let description = CATapDescription(
            monoGlobalTapButExcludeProcesses: AudioProcessList.ownProcessObject().map { [$0] } ?? [])
        description.uuid = UUID()
        description.name = "earmark"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var newTap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &newTap)
        guard status == noErr else {
            throw .operationFailed("cannot create the process tap (OSStatus \(status))")
        }
        tapID = newTap
        do throws(EarmarkError) {
            let format = try Self.tapFormat(newTap)
            if isFirst {
                // Клиентский формат writer'а меняется только до первой записи (замер в Task 9).
                try Self.call { try state.writer.setClientFormat(format) }
                try Self.call { try state.writer.primeAsync() }
                try state.prepare(for: format)
            } else if format.sampleRate != state.sampleRate || format.channelCount != state.channels {
                // Формат tap сменился между пересборками, а клиентский формат ExtAudioFile уже не
                // поменять: писать в старом — значит испортить шкалу времени. Ждём следующего тика.
                throw EarmarkError.operationFailed(
                    "tap format changed: \(state.sampleRate) Hz/\(state.channels) ch → \(format.sampleRate) Hz/"
                        + "\(format.channelCount) ch")
            }
            // Рецепт S1: только tap, без sub-device вывода, drift compensation = 1.
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "earmark-tap",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                // Приватный aggregate не переживает процесс: после крэша в системе ничего не остаётся.
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                // 0: IO идёт с первой секунды и в тишине, иначе watchdog «45 с без колбэков» срабатывал бы
                // на любой паузе, а host time старта был бы неизвестен до первого звука.
                kAudioAggregateDeviceTapAutoStartKey: false,
                kAudioAggregateDeviceSubDeviceListKey: [] as [[String: Any]],
                kAudioAggregateDeviceTapListKey: [
                    [kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]
                ],
            ]
            var newAggregate = AudioObjectID(kAudioObjectUnknown)
            status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &newAggregate)
            guard status == noErr else {
                throw EarmarkError.operationFailed("cannot create the aggregate device (OSStatus \(status))")
            }
            aggregateID = newAggregate

            var newProc: AudioDeviceIOProcID?
            status = AudioDeviceCreateIOProcIDWithBlock(&newProc, newAggregate, ioQueue, Self.ioBlock(state))
            guard status == noErr, let newProc else {
                throw EarmarkError.operationFailed("cannot create the IOProc (OSStatus \(status))")
            }
            procID = newProc
            if !isFirst { state.meters.needsResidualPad.store(true, ordering: .releasing) }
            ioStartedAt = AudioGetCurrentHostTime()
            // Первый старт aggregate с tap и показывает системный запрос «запись системного звука».
            status = AudioDeviceStart(newAggregate, newProc)
            guard status == noErr else {
                throw EarmarkError.operationFailed("the aggregate device did not start (OSStatus \(status))")
            }
        } catch {
            teardown()
            throw error
        }
    }

    /// Обратный порядок: Stop → DestroyIOProcID → DestroyAggregateDevice → DestroyProcessTap. После
    /// перезапуска coreaudiod объекты уже мертвы — ошибки здесь безвредны и не проверяются.
    private func teardown() {
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
        // Блок, уже стоящий в IO-очереди, должен доработать до того, как writer закроют.
        ioQueue.sync { /* барьер: дожидаемся последнего колбэка */  }
    }

    // MARK: - Watchdog и пересборка

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: control)
        timer.schedule(
            deadline: .now() + Self.watchdogInterval, repeating: Self.watchdogInterval, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in self?.checkStall() }
        timer.resume()
        watchdog = timer
    }

    private func checkStall() {
        guard let io else { return }
        guard procID != nil else {
            rebuild(io, reason: "previous rebuild failed")
            return
        }
        let last = max(io.meters.lastHostTime.load(ordering: .relaxed), ioStartedAt)
        let silent = Double(AudioGetCurrentHostTime() &- last) / AudioGetHostClockFrequency()
        if silent >= Self.stallTimeout { rebuild(io, reason: "no callbacks for \(Int(silent)) s") }
        let status = io.meters.lastWriteStatus.exchange(noErr, ordering: .relaxed)
        if status != noErr { Self.log.error("system.caf: writeAsync returned \(status)") }
    }

    /// Разобрать, закрыть дыру тишиной до «сейчас», собрать заново. Остаток дыры — время старта нового
    /// IO — закрывает первый колбэк (`needsResidualPad`).
    private func rebuild(_ state: IOState, reason: String) {
        Self.log.warning("system tap: rebuilding (\(reason, privacy: .public))")
        teardown()
        let first = state.meters.firstHostTime.load(ordering: .acquiring)
        // Два прохода: тишина пишется лишь ~30x быстрее реального времени, 45 с дыры — это ~1,5 с записи
        // (замер), и на столько дыра успевает снова вырасти. Такой остаток больше секунды, и padResidual
        // отбросил бы его целиком. Второй проход дотягивает его за ~60 мс.
        for _ in 0..<2 where first != 0 {
            let gap = PaddingMath.gapFrames(
                startHostTime: first, framesWritten: state.writer.framesWritten,
                actualHostTime: AudioGetCurrentHostTime(), sampleRate: state.sampleRate,
                hostTicksPerSecond: AudioGetHostClockFrequency())
            guard gap > 0 else { break }
            do {
                try state.writer.writeSilence(frames: AVAudioFrameCount(clamping: gap))
            } catch {
                let reason = error.localizedDescription
                Self.log.error("system.caf: silence not written: \(reason, privacy: .public)")
                break
            }
        }
        do throws(EarmarkError) {
            try build(state, isFirst: false)
        } catch {
            // procID остаётся nil — следующий тик watchdog попробует снова и заодно дотянет тишину.
            Self.log.error("system tap: rebuild failed: \(error.message, privacy: .public)")
        }
    }

    private func listenForServiceRestart() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyServiceRestarted, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // Слушатель уже на `control`; пересборку — следующим блоком, не изнутри слушателя HAL.
            self?.control.async { [weak self] in
                guard let self, let io = self.io else { return }
                self.rebuild(io, reason: "coreaudiod restarted")
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, control, listener)
        if status == noErr { serviceRestartListener = listener }
    }

    private func stopListeningForServiceRestart() {
        guard let listener = serviceRestartListener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyServiceRestarted, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, control, listener)
        serviceRestartListener = nil
    }

    // MARK: - IOProc

    /// IOProc синхронный, даже с очередью (AudioHardware.h): в нём только writeAsync, атомики и арифметика.
    /// Блок строится в nonisolated static-функции: замыкание, созданное в @MainActor-контексте, Swift 6
    /// изолирует на main и в рантайме ловит trap на IO-потоке.
    private static func ioBlock(_ state: IOState) -> AudioDeviceIOBlock {
        { _, input, inputTime, _, _ in
            let frames = input.pointee.mBuffers.mDataByteSize / state.bytesPerFrame
            guard frames > 0 else { return }
            let time = inputTime.pointee
            let host = time.mFlags.contains(.hostTimeValid) ? time.mHostTime : AudioGetCurrentHostTime()
            let meters = state.meters
            let first = meters.firstHostTime.load(ordering: .relaxed)
            if first == 0 {
                meters.firstHostTime.store(host, ordering: .releasing)
            } else if meters.needsResidualPad.exchange(false, ordering: .acquiringAndReleasing) {
                state.padResidual(start: first, host: host)
            }
            meters.lastHostTime.store(host, ordering: .relaxed)
            let status = state.writer.writeAsync(input, frames: frames)
            if status != noErr { meters.lastWriteStatus.store(status, ordering: .relaxed) }
            state.measure(input, frames: frames)
        }
    }

    private static func tapFormat(_ tap: AudioObjectID) throws(EarmarkError) -> AVAudioFormat {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &description)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &description),
            format.commonFormat == .pcmFormatFloat32
        else { throw .operationFailed("the tap format is unreadable or not Float32 (OSStatus \(status))") }
        return format
    }

    private static func call(_ body: () throws -> Void) throws(EarmarkError) {
        do { try body() } catch { throw .operationFailed(error.localizedDescription) }
    }
}

/// Счётчики, общие для IOProc и остального приложения: только атомики, поэтому честно Sendable.
private final class Meters: Sendable {
    let level = Atomic<Float>(0)
    let firstHostTime = Atomic<UInt64>(0)
    let lastHostTime = Atomic<UInt64>(0)
    let lastWriteStatus = Atomic<Int32>(0)
    let needsResidualPad = Atomic<Bool>(false)

    func reset() {
        level.store(0, ordering: .relaxed)
        firstHostTime.store(0, ordering: .relaxed)
        lastHostTime.store(0, ordering: .relaxed)
        lastWriteStatus.store(0, ordering: .relaxed)
        needsResidualPad.store(false, ordering: .relaxed)
    }
}

/// Всё, что трогает IOProc. Отдельный объект: блок держит его, а не рекордер, и переживает пересборки.
private final class IOState: @unchecked Sendable {
    let writer: CAFWriter
    let meters: Meters
    let ticksPerSecond = AudioGetHostClockFrequency()

    // Задаются в `prepare` до старта IO и дальше не меняются.
    private(set) var sampleRate: Double = 0
    private(set) var channels: AVAudioChannelCount = 0
    private(set) var bytesPerFrame: UInt32 = 1
    /// 1 с нулей в формате tap, выделена заранее: в IOProc аллоцировать нельзя.
    private var silence: AVAudioPCMBuffer?
    private var silenceList: UnsafePointer<AudioBufferList>?

    // Только IO-поток: окно для RMS последней секунды.
    private var windowSum: Float = 0
    private var windowFrames: UInt32 = 0

    init(writer: CAFWriter, meters: Meters) {
        self.writer = writer
        self.meters = meters
    }

    func prepare(for format: AVAudioFormat) throws(EarmarkError) {
        let frames = AVAudioFrameCount(format.sampleRate)
        guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw .operationFailed("cannot allocate the silence buffer")
        }
        silence.frameLength = frames
        for buffer in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        self.silence = silence
        silenceList = silence.audioBufferList
        sampleRate = format.sampleRate
        channels = format.channelCount
        bytesPerFrame = format.streamDescription.pointee.mBytesPerFrame
    }

    /// Остаток дыры после пересборки — до секунды; больше значит, что что-то не так, и не паддим вслепую.
    func padResidual(start: UInt64, host: UInt64) {
        guard let silenceList else { return }
        let gap = PaddingMath.gapFrames(
            startHostTime: start, framesWritten: writer.framesWritten, actualHostTime: host,
            sampleRate: sampleRate, hostTicksPerSecond: ticksPerSecond)
        guard gap > 0, gap <= Int64(sampleRate) else { return }
        let status = writer.writeAsync(silenceList, frames: UInt32(gap))
        if status != noErr { meters.lastWriteStatus.store(status, ordering: .relaxed) }
    }

    /// Окно ровно в секунду: «ровно ноль» (цифровая тишина) остаётся нулём, любой звук — нет.
    func measure(_ input: UnsafePointer<AudioBufferList>, frames: UInt32) {
        guard let data = input.pointee.mBuffers.mData?.assumingMemoryBound(to: Float.self) else { return }
        var sum: Float = 0
        vDSP_svesq(data, 1, &sum, vDSP_Length(frames))
        windowSum += sum
        windowFrames += frames
        guard Double(windowFrames) >= sampleRate else { return }
        meters.level.store((windowSum / Float(windowFrames)).squareRoot(), ordering: .relaxed)
        windowSum = 0
        windowFrames = 0
    }
}
