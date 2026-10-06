@preconcurrency import AVFoundation
import AppKit
import EarmarkAudio
import EarmarkCore
import Foundation
import Observation
import os

/// Одна запись от старта до meta.json: папка, manifest, оба рекордера, стоп-правила, финализация,
/// восстановление прерванных, сон и выход. Файловую часть конца делает RecordingFinalizer (EarmarkAudio).
@MainActor
@Observable
final class RecordingSession {
    struct StartRequest {
        var trigger: RecordingTrigger
        var title: String
        var meeting: Meeting?
        var calendarFolder: String?
    }

    /// 5 минут ровных нулей на канале собеседников при идущем созвоне: неавторизованный tap или баг
    /// нулевых буферов. От немого созвона не отличить — поэтому только предупреждение.
    static let digitalSilenceWarning: TimeInterval = 5 * 60

    private static let log = Logger(subsystem: EarmarkPaths.bundleID, category: "session")

    /// Запись сведена и meta.json на диске — после стопа и после восстановления прерванной.
    @ObservationIgnored var onFinalized: ((URL, RecordingMeta) -> Void)?
    /// Запись отброшена (StopRules.shouldDiscard), папки уже нет: id записи и причина стопа.
    @ObservationIgnored var onDiscarded: ((String, StopReason) -> Void)?
    /// Запись началась, ручная или авто. Зовётся раньше предупреждений `capture_failed` этого старта.
    @ObservationIgnored var onStarted: (() -> Void)?
    @ObservationIgnored var onWarning: ((String) -> Void)?

    /// Уровни каналов для CallActivityMonitor: он читает их со своей очереди, без main actor.
    /// Рекордеры отдают 0, пока не пишут, поэтому при простое здесь (0, 0).
    nonisolated let levels: @Sendable () -> (mic: Float, system: Float)

    private let store: () -> RecordingStore
    private let config: () -> Config
    private let mic: MicRecorder
    private let system: SystemAudioRecorder
    /// Единственное наблюдаемое состояние: меню перерисовывается, когда запись началась или кончилась.
    private var active: Active?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    private struct Active {
        let folder: URL
        let manifest: RecordingManifest
        let micWriter: CAFWriter
        let systemWriter: CAFWriter
        let activity: any NSObjectProtocol
        var tracker: ActivityTracker
        var callActive = false
        var warnedDigitalSilence = false
    }

    init(store: @escaping () -> RecordingStore, config: @escaping () -> Config) {
        self.store = store
        self.config = config
        let mic = MicRecorder()
        let system = SystemAudioRecorder()
        self.mic = mic
        self.system = system
        levels = { (mic.levelRMS, system.levelRMS) }
        // На сон финализируем по-настоящему: CAF закрываются до сна, сведение доработает после пробуждения.
        observers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.stopInBackground(reason: .sleep) }
            })
        // На выходе только закрываем CAF: сведение часового созвона не успело бы до kill от системы,
        // а manifest остаётся — следующий запуск сведёт audio.m4a в recoverInterrupted.
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.closeForQuit() }
            })
    }

    isolated deinit {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Пишет ли что-то прямо сейчас — для значка и `status`.
    var isRecording: Bool { active != nil }

    var current: CurrentRecordingInfo? { active.map(Self.info) }

    /// Идемпотентно: идёт запись — возвращает её. Рекордер, который не поднялся, не валит запись, пока
    /// жив второй: созвон без одного канала лучше, чем без записи. Не поднялись оба — ошибка.
    func start(_ request: StartRequest) throws(EarmarkError) -> CurrentRecordingInfo {
        if let current { return current }
        // Пока на запрос права не ответили, первый старт tap висит на системном диалоге и держит main
        // actor (S1) — вместе с меню, IPC и тиками. Сюда сходятся меню, IPC и календарь; запрос —
        // дело `permissions request`.
        var unanswered: [String] = []
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            unanswered.append("Microphone")
        }
        if TCCPreflight.audioCapture() == .notDetermined {
            unanswered.append("System Audio Recording")
        }
        guard unanswered.isEmpty else {
            throw .permissionDenied(
                unanswered.joined(separator: " and ")
                    + " access has not been granted yet: run earmark permissions request")
        }
        // Оба трека в одном формате: клиент — Float32 48 kHz mono, файл — Int16 (CAFWriter). Рекордеры
        // приводят к нему свои устройства.
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1) else {
            throw .operationFailed("the 48 kHz mono track format is unavailable")
        }
        let store = store()
        let now = Date()
        let folder: URL
        let manifest: RecordingManifest
        let micWriter: CAFWriter
        let systemWriter: CAFWriter
        do {
            folder = try store.createRecordingFolder(
                calendarFolder: request.calendarFolder, title: request.title, startedAt: now)
            manifest = RecordingManifest(
                pid: getpid(), startedAt: now, appVersion: EarmarkVersion.current,
                id: RecordingStore.makeID(startedAt: now, random: UInt16.random(in: .min ... .max)),
                trigger: request.trigger, title: request.title,
                calendar: request.meeting.map { CalendarRef(id: $0.calendar.id, title: $0.calendar.title) },
                event: request.meeting?.eventRef)
            // manifest — до первого сэмпла: упади мы через секунду, recover найдёт папку.
            try store.writeManifest(manifest, in: folder)
            micWriter = try CAFWriter(url: folder.appendingPathComponent(RecordingFiles.mic), format: format)
            systemWriter = try CAFWriter(
                url: folder.appendingPathComponent(RecordingFiles.system), format: format)
        } catch {
            throw .operationFailed("cannot create the recording folder: \(error.localizedDescription)")
        }

        var failures: [String] = []
        do throws(EarmarkError) { try system.start(writer: systemWriter) } catch {
            failures.append("system: \(error.message)")
        }
        do throws(EarmarkError) { try mic.start(writer: micWriter) } catch {
            failures.append("mic: \(error.message)")
        }
        if failures.count == 2 {
            try? micWriter.close()
            try? systemWriter.close()
            try? FileManager.default.removeItem(at: folder)
            throw .operationFailed("capture did not start: \(failures.joined(separator: "; "))")
        }

        // Без этого Mac засыпает на простое посреди созвона, а App Nap сдвигает таймеры на секунды.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "earmark: recording")
        let recording = Active(
            folder: folder, manifest: manifest, micWriter: micWriter, systemWriter: systemWriter,
            activity: activity, tracker: ActivityTracker(startedAt: now))
        active = recording
        Self.log.info("recording \(manifest.id, privacy: .public) started: \(folder.path, privacy: .public)")
        // Сначала onStarted — он сбрасывает предупреждения прошлой записи, — потом предупреждения этой.
        onStarted?()
        for failure in failures { onWarning?("capture_failed:\(failure)") }
        return Self.info(recording)
    }

    /// Стоп, шаг 1 — синхронно: рекордеры и CAF закрыты, сеанс свободен, и следующую запись (встреча
    /// впритык) можно стартовать сразу. Шаг 2 — возвращённая detached-задача: сведение и meta.json вне
    /// main actor, в конце — onFinalized или onDiscarded. nil — ничего не писалось.
    func stopNow(reason: StopReason) -> Task<RecordingMeta?, any Error>? {
        guard let finished = active else { return nil }
        active = nil
        let micStart = mic.startHostTime
        let systemStart = system.startHostTime
        closeCapture(finished)
        let offset = Self.micOffsetMs(mic: micStart, system: systemStart)
        let config = config()
        let store = store()
        let folder = finished.folder
        let manifest = finished.manifest
        let callApps = finished.tracker.callAppsSeen
        let endedAt = Date()
        return Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result { () throws -> RecordingMeta? in
                try RecordingFinalizer.finalize(
                    folder: folder, manifest: manifest, stopReason: reason, endedAt: endedAt,
                    micOffsetMs: offset, callApps: callApps, keepRawTracks: config.keepRawTracks,
                    stop: config.stop, store: store)
            }
            await self?.finalized(result, folder: folder, id: manifest.id, reason: reason)
            return try result.get()
        }
    }

    /// stopNow и ожидание сведения: меню и CLI получают ответ после meta.json. nil — запись отброшена
    /// (StopRules.shouldDiscard) или ничего не шло.
    func stop(reason: StopReason) async throws(EarmarkError) -> RecordingMeta? {
        guard let finishing = stopNow(reason: reason) else { return nil }
        do {
            return try await finishing.value
        } catch {
            throw .operationFailed("finalization failed: \(error.localizedDescription)")
        }
    }

    /// От CallActivityMonitor раз в секунду.
    func ingest(_ sample: ActivitySample) {
        guard var recording = active else { return }
        recording.tracker.ingest(sample)
        recording.callActive = sample.callActive
        if let since = recording.tracker.digitalSilenceSince, !recording.warnedDigitalSilence,
            sample.now.timeIntervalSince(since) >= Self.digitalSilenceWarning
        {
            recording.warnedDigitalSilence = true
            onWarning?("far_end_digital_silence")
        }
        active = recording
        let manifest = recording.manifest
        // Ручную запись StopRules останавливает только по max_duration — отдельной ветки здесь не нужно.
        let decision = StopRules.evaluate(
            trigger: manifest.trigger, startedAt: manifest.startedAt, eventStart: manifest.event?.start,
            eventEnd: manifest.event?.end, signals: recording.tracker.signals, config: config().stop)
        if case .stop(let reason) = decision { stopInBackground(reason: reason) }
    }

    /// При старте app: папки с manifest, кроме идущей записи, — свести и отдать в очередь.
    func recoverInterrupted() async {
        let store = store()
        let keepRawTracks = config().keepRawTracks
        let folders: [RecordingFolder]
        do {
            // По pid живость не проверяем: второй экземпляр выходит раньше start() (single instance),
            // значит, писатель любого manifest, кроме своей записи, мёртв. А pid старого писателя после
            // перезагрузки нередко занят чужим живым процессом — такая запись не восстановилась бы никогда.
            folders = try store.interrupted { _ in false }
        } catch {
            Self.log.error("cannot list interrupted recordings: \(error, privacy: .public)")
            return
        }
        for folder in folders where folder.url != active?.folder {
            guard let manifest = folder.manifest else { continue }
            let url = folder.url
            let result = await Task.detached(priority: .utility) {
                Result {
                    try RecordingFinalizer.recover(
                        folder: url, manifest: manifest, keepRawTracks: keepRawTracks, store: store)
                }
            }.value
            switch result {
            case .success(let meta):
                Self.log.info("recovered recording \(meta.id, privacy: .public)")
                onFinalized?(url, meta)
            case .failure(let error):
                Self.log.error("recovery of \(url.path, privacy: .public) failed: \(error, privacy: .public)")
            }
        }
    }

    // MARK: -

    /// Итог финализации — уже на main actor: лог и колбэки.
    private func finalized(
        _ result: Result<RecordingMeta?, any Error>, folder: URL, id: String, reason: StopReason
    ) {
        switch result {
        case .success(let meta?):
            Self.log.info("recording \(id, privacy: .public) finalized: \(reason.rawValue, privacy: .public)")
            onFinalized?(folder, meta)
        case .success(nil):
            Self.log.info("recording \(id, privacy: .public) discarded: \(reason.rawValue, privacy: .public)")
            onDiscarded?(id, reason)
        case .failure(let error):
            // manifest остался — recoverInterrupted доделает при следующем старте.
            Self.log.error("finalization of \(id, privacy: .public) failed: \(error, privacy: .public)")
        }
    }

    /// Стоп по стоп-правилу или сну: захват закрывается сейчас же — до сна обязательно, — а сведение
    /// дорабатывает в фоне.
    private func stopInBackground(reason: StopReason) {
        guard let finishing = stopNow(reason: reason) else { return }
        Task {
            do {
                _ = try await finishing.value
            } catch {
                onWarning?("finalize_failed:\(error.localizedDescription)")
            }
        }
    }

    private func closeForQuit() {
        guard let finished = active else { return }
        active = nil
        closeCapture(finished)
    }

    /// Рекордеры, затем writer'ы: stop() рекордера дожидается своей очереди, после него в CAF никто не пишет.
    private func closeCapture(_ recording: Active) {
        mic.stop()
        system.stop()
        for writer in [recording.micWriter, recording.systemWriter] {
            do {
                try writer.close()
            } catch {
                Self.log.error("CAF did not close: \(error, privacy: .public)")
            }
        }
        ProcessInfo.processInfo.endActivity(recording.activity)
    }

    private static func info(_ recording: Active) -> CurrentRecordingInfo {
        let manifest = recording.manifest
        return CurrentRecordingInfo(
            id: manifest.id, title: manifest.title, calendar: manifest.calendar, trigger: manifest.trigger,
            startedAt: manifest.startedAt, elapsedSec: Date().timeIntervalSince(manifest.startedAt),
            callActive: recording.callActive, callApps: recording.tracker.callAppsSeen,
            folder: recording.folder.path)
    }

    /// > 0 — mic начался позже system. Нет одного из стартов — 0: сдвигать не от чего.
    static func micOffsetMs(mic: UInt64?, system: UInt64?) -> Int {
        guard let mic, let system else { return 0 }
        let ticks = Double(mic) - Double(system)
        return Int((ticks / AudioGetHostClockFrequency() * 1_000).rounded())
    }
}
