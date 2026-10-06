import EarmarkCore
import Foundation
import os

/// Очередь транскрипции (§8.4): по одной задаче, старые первыми, каждая — отдельный процесс
/// `earmark transcribe <id> --now`. В процессе app whisper не крутится никогда: ggml на любом
/// assert делает abort(), а после whisper_free остаётся ~233 MB (§3.1).
///
/// Источник правды — папки записей и meta.json, а не память: после перезапуска очередь
/// восстанавливается сканом `pendingTranscription()`. meta во всех случаях пишет сам воркер
/// (Task 22); очередь трогает её только в revert.
@MainActor
final class TranscriptionQueue {
    private struct Job {
        let id: String
        let force: Bool
        let folder: URL
        /// meta до запуска — для revert, если воркер убит сигналом и не вернул её сам.
        let before: RecordingMeta
        let process: Process
        /// Когда воркеру послан SIGTERM (вытеснение); nil — не вытеснялся.
        var preemptedAt: Date?
    }

    private struct Request {
        let id: String
        var force: Bool
    }

    /// SIGTERM → SIGKILL. VAD внутри whisper_full (b5130) abort-хука не имеет: ~6 с на час канала,
    /// ~30 с на 5 ч (M3 Pro), холодная компиляция Metal — ещё до 20 с. Раньше этого SIGKILL убил бы
    /// воркер, который и так выходит; запас — на Mac медленнее.
    private static let killGrace: TimeInterval = 90
    /// Пауза для задачи, которую сейчас трогать не надо, и период фонового скана.
    private static let pause: TimeInterval = 60

    private(set) var progress: TranscribeProgress?
    private(set) var pendingCount = 0
    var runningID: String? { running?.id }

    private let store: () -> RecordingStore
    private let config: () -> Config
    private let isRecording: () -> Bool
    private let provisioner: ModelProvisioner
    private let worker: URL?
    private var running: Job?
    /// Явные запросы (`earmark transcribe <id>`) идут раньше бэклога, в порядке поступления.
    private var requests: [Request] = []
    /// Бэклог с диска перечитывается по поводу (старт, конец записи, конец задачи, модель) и раз
    /// в минуту: так находятся задачи, чей lock освободил чужой процесс (воркер, переживший
    /// выход app, ручной `earmark transcribe --now`).
    private var needsScan = true
    private var nextScan = Date.distantPast
    /// Есть работа, а модели нет: каждый тик зовём ensure(), он сам держит паузу после неудачи.
    private var waitingForModel = false
    /// Задачи, которые сейчас не надо трогать: lock занят чужим воркером, воркер упал.
    private var cooldown: [String: Date] = [:]
    private var lastWorkerError: String?
    private var ticker: Task<Void, Never>?
    private let logger = Logger(subsystem: EarmarkPaths.bundleID, category: "transcription")

    init(
        store: @escaping () -> RecordingStore, config: @escaping () -> Config,
        isRecording: @escaping () -> Bool, provisioner: ModelProvisioner, worker: URL?
    ) {
        self.store = store
        self.config = config
        self.isRecording = isRecording
        self.provisioner = provisioner
        self.worker = worker
    }

    /// Секундный опрос вместо подписок: вытеснение должно сработать, откуда бы ни стартовала
    /// запись (меню, IPC, календарь), а почти бесплатная проверка раз в секунду проще трёх хуков.
    /// Нагрев читается так же — подписка на thermalStateDidChangeNotification ничего бы не добавила.
    func start() {
        guard worker != nil else {
            logger.error("earmark CLI is missing from Contents/Helpers; transcription is idle")
            return
        }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func requestScan() {
        needsScan = true
    }

    /// `{queued: true, position}`; position — сколько задач впереди (0 — следующая или уже идёт).
    func enqueue(id: String, force: Bool) throws(EarmarkError) -> JSONValue {
        guard worker != nil else {
            throw EarmarkError.unavailable("earmark CLI is missing from Earmark.app/Contents/Helpers")
        }
        let folder: RecordingFolder?
        do {
            folder = try store().find(id: id)
        } catch {
            throw EarmarkError.operationFailed("cannot read recordings: \(error.localizedDescription)")
        }
        guard let folder else { throw EarmarkError.notFound("no recording with id \(id)") }
        // Пока есть manifest, запись идёт (D7): финализация пишет meta.json раньше, чем удаляет его.
        guard !folder.isRecording, let meta = folder.meta else {
            throw EarmarkError.busy("recording \(id) is still in progress")
        }
        if meta.status == .transcribed && !force {
            throw EarmarkError.invalidArguments(
                "recording \(id) is already transcribed; pass force to redo it")
        }
        // transcription_failed скан очереди не берёт (D36): без --force отвечаем ошибкой, а не молчим.
        if meta.status == .transcriptionFailed && !force {
            throw EarmarkError.invalidArguments(
                "recording \(id) failed transcription (\(meta.transcription.error ?? "no details")); "
                    + "pass force to retry")
        }
        if running?.id == id { return Self.queued(position: 0) }
        if let index = requests.firstIndex(where: { $0.id == id }) {
            requests[index].force = requests[index].force || force
        } else {
            requests.append(Request(id: id, force: force))
        }
        let ahead = requests.firstIndex { $0.id == id } ?? 0
        return Self.queued(position: ahead + (running == nil ? 0 : 1))
    }

    /// Выход из app. Без SIGTERM воркер умер бы от SIGPIPE на первом же прогрессе в закрытый pipe —
    /// и попытка была бы засчитана. Ждём его до 2 с, пока pipe ещё открыт: на SIGTERM он сам
    /// возвращает meta и выходит с 75 (Task 22). Не успел (VAD без abort-хука) — после SIGTERM он
    /// прогресс не пишет, дойдёт до проверки флага и вернёт meta уже без нас; SIGPIPE настигнет его
    /// только на конверте ошибки, когда meta уже возвращена. Исключение — отладочный
    /// EARMARK_WHISPER_LOG: лог whisper в закрытый pipe убьёт воркер раньше. revert здесь не нужен:
    /// за 2 с сигналом умирает только воркер, не успевший поставить обработчик, а он meta не трогал.
    func shutdown() {
        ticker?.cancel()
        guard let job = running else { return }
        job.process.terminate()
        let deadline = Date().addingTimeInterval(2)
        while job.process.isRunning && Date() < deadline { usleep(20_000) }
    }

    // MARK: - внутреннее

    private func tick(now: Date = .now) {
        let blocked = isRecording() || !config().transcriptionEnabled
        if let job = running {
            if let preemptedAt = job.preemptedAt {
                if now.timeIntervalSince(preemptedAt) >= Self.killGrace && job.process.isRunning {
                    logger.error("worker for \(job.id, privacy: .public) ignored SIGTERM, killing it")
                    kill(job.process.processIdentifier, SIGKILL)
                }
            } else if blocked {
                // Вытеснение (§8.4): запись важнее, и 2 ГБ воркера ей ни к чему. SIGSTOP не годится —
                // процесс держал бы память всю запись. Выключенная транскрипция вытесняет так же.
                running?.preemptedAt = now
                job.process.terminate()
            }
            return
        }
        // Нагрев (§8.4): при .serious и выше новые задачи не стартуют.
        let hot = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        guard !blocked, !hot else { return }
        if waitingForModel {
            // Работа могла исчезнуть (записи удалили): раз в минуту сверяемся, иначе после неудачной
            // загрузки 1.6 ГБ качались бы впустую — модель нужна, только когда есть что расшифровать (§8.2).
            if now >= nextScan, nextRequest(now: now) == nil {
                waitingForModel = false
                return
            }
            // Готовая модель → onReady → requestScan; неудача → ensure() сам выждет 10 минут.
            provisioner.ensure(now: now)
            guard provisioner.isReady else { return }
            waitingForModel = false
        }
        guard let next = nextRequest(now: now) else { return }
        guard provisioner.isReady else {
            // Пока модели нет, записи ждут в recorded и попыток не тратят (§8.2).
            waitingForModel = true
            return
        }
        launch(next, now: now)
    }

    private func nextRequest(now: Date) -> Request? {
        if cooldown.values.contains(where: { $0 <= now }) {
            cooldown = cooldown.filter { $0.value > now }
            needsScan = true
        }
        if let request = requests.first(where: { cooldown[$0.id] == nil }) { return request }
        guard needsScan || now >= nextScan else { return nil }
        nextScan = now.addingTimeInterval(Self.pause)
        let pending: [RecordingFolder]
        do {
            pending = try store().pendingTranscription()
        } catch {
            logger.error("scan failed: \(error.localizedDescription, privacy: .public)")
            needsScan = false
            return nil
        }
        pendingCount = pending.count
        guard let id = pending.compactMap(\.id).first(where: { cooldown[$0] == nil }) else {
            needsScan = false
            return nil
        }
        return Request(id: id, force: false)
    }

    private func launch(_ request: Request, now: Date) {
        guard let worker else { return }
        let found: RecordingFolder?
        do {
            found = try store().find(id: request.id)
        } catch {
            cooldown[request.id] = now.addingTimeInterval(Self.pause)
            return
        }
        // Записи нет (удалили) или она ещё пишется: явный запрос снимаем, скан её не вернёт.
        guard let folder = found, let meta = folder.meta, !folder.isRecording else {
            requests.removeAll { $0.id == request.id }
            return
        }
        let process = Process()
        process.executableURL = worker
        process.arguments = ["transcribe", request.id, "--now"] + (request.force ? ["--force"] : [])
        // .utility, а не .background: на .background загрузка модели и VAD медленнее вчетверо
        // (замер, §8.4). Выставляется строго до run(): после запуска свойство только для чтения.
        process.qualityOfService = .utility
        // stderr — в тот же pipe. Два FileHandle.bytes в одном процессе читаются по очереди (общий
        // ридер Foundation с блокирующим read(2)): stderr, молчащий до выхода, держал бы весь прогресс,
        // а лог whisper (EARMARK_WHISPER_LOG) забил бы непрочитанный pipe и остановил воркер (замер).
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let id = request.id
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            let reason = finished.terminationReason
            Task { @MainActor in self?.finished(id: id, status: status, reason: reason) }
        }
        do {
            try process.run()
        } catch {
            logger.error("cannot launch worker: \(error.localizedDescription, privacy: .public)")
            cooldown[request.id] = now.addingTimeInterval(Self.pause)
            return
        }
        requests.removeAll { $0.id == request.id }
        running = Job(id: id, force: request.force, folder: folder.url, before: meta, process: process)
        progress = nil
        lastWorkerError = nil
        pendingCount = max(0, pendingCount - 1)
        read(output.fileHandleForReading, id: id)
    }

    /// stdout и stderr воркера — один pipe: JSON-строки прогресса (TranscribeProgress), каждая одним
    /// write(2), и последней строкой конверт CLI (ошибка — из stderr); с EARMARK_WHISPER_LOG ещё лог
    /// whisper. Всё, что не прогресс, — кандидат в причину сбоя. Читаем до конца: непрочитанный pipe
    /// заполнился бы и остановил воркер.
    private func read(_ output: FileHandle, id: String) {
        Task { [weak self] in
            do {
                for try await line in output.bytes.lines {
                    guard let self, self.running?.id == id else { continue }
                    let data = Data(line.utf8)
                    if let progress = try? EarmarkJSON.decoder.decode(TranscribeProgress.self, from: data) {
                        self.progress = progress
                    } else {
                        self.lastWorkerError = line
                    }
                }
            } catch {
                // Обрыв pipe значит, что воркер умер; итог разберёт terminationHandler.
                self?.logger.debug("worker output closed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func finished(id: String, status: Int32, reason: Process.TerminationReason) {
        guard let job = running, job.id == id else { return }
        running = nil
        progress = nil
        needsScan = true
        let done = reason == .exit && status == 0
        if job.preemptedAt != nil && !done {
            // Вытеснение (D37): на SIGTERM воркер выходит штатно с 75 interrupted, уже вернув meta
            // (Task 22); revert — только если его убил сигнал. Cooldown не ставим.
            if reason == .uncaughtSignal { revert(job) }
            // Явный --force не теряем: со скана задача вернулась бы обычной и оставила старые каналы.
            if job.force { requests.insert(Request(id: id, force: true), at: 0) }
            return
        }
        let later = Date().addingTimeInterval(Self.pause)
        switch (reason, status) {
        case (.exit, 0):
            logger.notice("transcribed \(id, privacy: .public)")
        case (.exit, 75):
            // Lock держит другой воркер (например, `earmark transcribe --now` руками) или воркер
            // прервали не мы (SIGINT, SIGHUP): meta он вернул сам.
            cooldown[id] = later
        case (.exit, 69):
            // Модели нет или не читается config.json — environmental, попытку воркер не засчитал
            // (D36). Пауза — на случай, если файл есть, но не грузится: иначе запуск шёл бы каждую секунду.
            cooldown[id] = later
            provisioner.refresh()
        case (.exit, 65):
            // Битое аудио — permanent: обычно воркер уже записал transcription_failed (D36). Пауза
            // защитная (D37): отказ до захвата meta не трогает, и скан перезапускал бы задачу каждую секунду.
            cooldown[id] = later
            logger.error("transcription of \(id, privacy: .public) failed permanently")
        default:
            // Сбой whisper (1, retryable — D36), сигнал (abort в ggml) или неожиданный код. Попытка
            // засчитана при захвате, после третьей воркер сам поставит transcription_failed; пауза
            // не даёт крутить сбой подряд.
            cooldown[id] = later
            logger.error(
                "worker for \(id, privacy: .public) ended: reason \(reason.rawValue) status \(status) \(self.lastWorkerError ?? "", privacy: .public)"
            )
        }
    }

    /// Вытесненный воркер убит сигналом и meta сам не вернул: SIGKILL после killGrace оставил её
    /// transcribing с засчитанной попыткой, а SIGTERM до установки обработчика (чтение конфига,
    /// locate) не дал ему даже захватить задачу. Возвращаем снимок до запуска — ровно как сам воркер
    /// на interrupted. Только под .transcribe.lock и только из transcribing: занятый lock — задачу
    /// держит другой процесс, и его засчитанную попытку трогать нельзя; нетронутая meta со снимком
    /// совпадает, и возврат ничего не меняет.
    private func revert(_ job: Job) {
        do {
            guard
                let lock = try FileLock.tryAcquire(
                    at: job.folder.appending(path: RecordingFiles.transcribeLock))
            else { return }
            defer { lock.release() }
            try store().updateMeta(in: job.folder) { meta in
                guard meta.status == .transcribing else { return }
                meta.status = job.before.status
                meta.transcription = job.before.transcription
            }
        } catch {
            logger.error("cannot revert preempted job: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func queued(position: Int) -> JSONValue {
        .object(["queued": .bool(true), "position": .number(Double(position))])
    }
}
