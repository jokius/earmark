import AppKit
import EarmarkCore
import Observation
import os

/// Состояние приложения и единственная точка действий для меню и IPC.
///
/// Живёт в AppDelegate, а не в сцене: content у MenuBarExtra создаётся лениво, и до первого
/// открытия меню его просто нет (Call Reminder, тот же паттерн).
@MainActor
@Observable
final class AppModel {
    /// Конфиг читается отсюда на каждом обращении, а не копируется в поля сервисов: иначе
    /// `config set` применялся бы не сразу (баг Call Reminder с lead).
    private(set) var config: Config
    /// То, что рисуют значок и меню. Обновляется раз в секунду из status(): сервисы записи,
    /// очереди и прав не обязаны быть @Observable, а время записи в меню тикает само.
    private(set) var snapshot: StatusData

    @ObservationIgnored private let configStore: ConfigStore
    @ObservationIgnored private var configProblem: String?
    @ObservationIgnored private var loginItemProblem: String?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored let logger = Logger(subsystem: EarmarkPaths.bundleID, category: "app")
    /// Сеанс записи. lazy: замыканиям нужен self, а до конца init его захватывать нельзя.
    @ObservationIgnored private(set) lazy var session = RecordingSession(
        store: { [weak self] in RecordingStore(root: (self?.config ?? Config()).recordingsDir) },
        config: { [weak self] in self?.config ?? Config() })
    /// Предупреждения записи (`capture_failed:…`, `far_end_digital_silence`, `start_failed:…`,
    /// `finalize_failed:…`) — в status.warnings. Сбрасываются на каждом старте записи.
    private(set) var recordingWarnings: [String] = []

    var isRecording: Bool { session.isRecording }

    /// Запись. Зовётся из start(): AppDelegate зовёт его только после проверки TestEnvironment, так что
    /// под тестами ни захвата, ни восстановления нет. Монитор созвона держит SchedulerDriver (D28).
    func startRecordingServices() {
        session.onStarted = { [weak self] in self?.recordingWarnings = [] }
        session.onWarning = { [weak self] warning in
            guard let self, !self.recordingWarnings.contains(warning) else { return }
            self.recordingWarnings.append(warning)
        }
    }

    /// Ручная запись из меню, CLI и агента. Идемпотентна: идёт запись — вернёт её (§9.3). Отказ старта
    /// виден в status.warnings (`start_failed:…`), а не только в логе: из меню иначе «ничего не произошло».
    func startManual(title: String?) throws(EarmarkError) -> CurrentRecordingInfo {
        if let current = session.current { return current }
        // Ровно одно текущее событие включённого календаря — запись уходит в его папку с его
        // метаданными (trigger остаётся manual) и делает его handled (§5).
        let meeting = scheduler?.currentMeeting()
        let request = RecordingSession.StartRequest(
            trigger: .manual, title: title ?? meeting?.title ?? "Manual recording", meeting: meeting,
            calendarFolder: meeting.flatMap { scheduler?.folderName(for: $0.calendar) })
        recordingWarnings = []
        let info: CurrentRecordingInfo
        do throws(EarmarkError) {
            info = try session.start(request)
        } catch {
            recordingWarnings = ["start_failed:\(error.message)"]
            throw error
        }
        if let meeting { scheduler?.attachManual(recordingId: info.id, to: meeting) }
        return info
    }

    /// Стоп из меню, CLI и агента; ответ — после финализации. nil — писать было нечего или запись отброшена.
    func stopRecording() async throws(EarmarkError) -> RecordingMeta? {
        try await session.stop(reason: .manual)
    }
    let permissions = Permissions()
    let calendarService = CalendarService()
    @ObservationIgnored private var scheduler: SchedulerDriver?
    @ObservationIgnored private var server: IPCServer?
    @ObservationIgnored private var socketProblem: String?
    let provisioner = ModelProvisioner()
    @ObservationIgnored private var queue: TranscriptionQueue?
    /// Два самотеста разом — два afplay и два tap: меню и `doctor --audio-test` не должны пересечься.
    @ObservationIgnored private var audioTestRunning = false

    /// status() начинает с него, а каждая задача, которой есть что сказать, дописывает своё
    /// перед `return data`. Версия — EarmarkVersion (Task 1): одна на app, CLI и meta.json.
    private static let idle = StatusData(
        appRunning: true, appVersion: EarmarkVersion.current, state: "idle", recording: nil, next: nil,
        queue: nil, permissions: nil, model: nil, warnings: [])

    init(configStore: ConfigStore = ConfigStore()) {
        self.configStore = configStore
        var problem: String?
        do {
            config = try configStore.load()
        } catch {
            // Битый config.json не повод не стартовать: работаем на дефолтах и говорим об этом
            // в status. Файл не трогаем, пока пользователь сам не сделает config set.
            config = Config()
            problem = error.localizedDescription
        }
        configProblem = problem
        snapshot = Self.idle
    }

    func start() {
        do {
            try setLaunchAtLogin(config.launchAtLogin)
        } catch {
            loginItemProblem = error.message
        }
        refreshSnapshot()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.refreshSnapshot()
            }
        }
        startRecordingServices()
        let scheduler = SchedulerDriver(
            calendar: calendarService, session: session, config: { [weak self] in self?.config ?? Config() })
        self.scheduler = scheduler
        let queue = TranscriptionQueue(
            store: { [weak self] in RecordingStore(root: (self?.config ?? Config()).recordingsDir) },
            config: { [weak self] in self?.config ?? Config() },
            isRecording: { [weak self] in self?.session.isRecording ?? false },
            provisioner: provisioner, worker: Self.cliExecutable)
        self.queue = queue
        provisioner.onReady = { [weak queue] in queue?.requestScan() }
        // Колбэки сеанса — только здесь (D33). onFinalized один на двоих: re-arm смотрит причину
        // стопа, очередь ставит запись в работу.
        session.onFinalized = { [weak scheduler, weak queue] _, meta in
            scheduler?.recordingFinalized(meta)
            queue?.requestScan()
        }
        session.onDiscarded = { [weak scheduler] id, reason in
            scheduler?.recordingDiscarded(id: id, reason: reason)
        }
        // Восстановленные при старте записи уходят в очередь, как только сведены (§4.3, D33).
        Task { [weak self, weak queue] in
            await self?.session.recoverInterrupted()
            queue?.requestScan()
        }
        scheduler.start()
        queue.start()
    }

    func shutdown() {
        ticker?.cancel()
        server?.stop()
        queue?.shutdown()
    }

    /// Поднимает IPC-сокет (§9.2). false — сокет уже обслуживает другой экземпляр: этот должен
    /// выйти, не тронув ни микрофон, ни state.json. Прочие сбои сокета не повод не писать по
    /// календарю: причина уходит в status, а CLI увидит app_not_running.
    func startIPC() -> Bool {
        do {
            try EarmarkPaths.ensureSupportDir()
        } catch {
            socketProblem = "support dir: \(error.localizedDescription)"
            return true
        }
        let server = IPCServer(socket: EarmarkPaths.socketFile) { [weak self] request, peer in
            guard let self else { return .failure(.unavailable("earmark is shutting down")) }
            return await IPCHandlers.handle(request, peer: peer, model: self)
        }
        do {
            try server.start()
            self.server = server
        } catch {
            if error.code == "busy" { return false }
            socketProblem = error.message
        }
        return true
    }

    func status() -> StatusData {
        var data = Self.idle
        if let configProblem { data.warnings.append("config_unreadable: \(configProblem)") }
        // Префикс `launch_at_login:` уже стоит в тексте ошибки (setLaunchAtLogin).
        if let loginItemProblem { data.warnings.append(loginItemProblem) }
        if let current = session.current {
            data.state = "recording"
            data.recording = current
        }
        data.warnings += recordingWarnings
        data.permissions = permissions.current()
        data.next = scheduler?.next
        if let stale = scheduler?.staleCalendarIDs, !stale.isEmpty {
            data.warnings.append("stale_calendars:" + stale.joined(separator: ","))
        }
        if let socketProblem { data.warnings.append("socket: \(socketProblem)") }
        // Только stat, без sha256: дёшево и раз в секунду, зато status сразу видит модель,
        // импортированную или докачанную CLI.
        provisioner.refresh()
        data.model = provisioner.info
        if let queue {
            data.queue = QueueInfo(
                running: queue.runningID, pending: queue.pendingCount,
                channel: queue.progress?.channel.rawValue, percent: queue.progress?.percent)
            if data.state == "idle" && queue.runningID != nil { data.state = "transcribing" }
        }
        if let error = provisioner.lastError {
            data.warnings.append("model_download_failed: \(error)")
        } else if config.transcriptionEnabled && provisioner.info.state == "missing" {
            data.warnings.append("model_missing")
        }
        return data
    }

    // MARK: - транскрипция

    func enqueueTranscription(id: String, force: Bool) throws(EarmarkError) -> JSONValue {
        guard config.transcriptionEnabled else {
            throw EarmarkError.unavailable(
                "transcription is disabled: earmark config set transcription.enabled true")
        }
        guard let queue else { throw EarmarkError.unavailable("transcription queue is not running") }
        return try queue.enqueue(id: id, force: force)
    }

    // MARK: - права

    func requestPermissions() async -> PermissionsInfo {
        let result = await permissions.request()
        refreshSnapshot()
        return result
    }

    /// Тон слышно в динамиках, и во время записи он попал бы в канал собеседников — отсюда busy.
    /// Пока на системный звук не ответили, первый старт tap висит на системном запросе дольше
    /// таймаута IPC (S1): такой тест не запускаем, запрос — дело `permissions request`.
    func audioTest() async throws(EarmarkError) -> DoctorCheck {
        guard status().state != "recording" else {
            throw EarmarkError.busy("audio test would be heard in the recording in progress")
        }
        guard !audioTestRunning else { throw EarmarkError.busy("an audio test is already running") }
        guard permissions.current(maxAge: 0).audioCapture != "not_determined" else {
            throw EarmarkError.permissionDenied(
                "System Audio Recording has not been granted yet: run earmark permissions request")
        }
        audioTestRunning = true
        defer { audioTestRunning = false }
        return await AudioSelfTest.run()
    }

    /// Красный значок. В DEBUG его включает аргумент `-debugRecordingIcon YES`: так отрисовку
    /// можно проверить без настоящей записи.
    var showsRecordingIcon: Bool {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "debugRecordingIcon") { return true }
        #endif
        return session.isRecording || snapshot.state == "recording"
    }

    // MARK: - календари

    func calendarsList() -> [CalendarListItem] {
        let all = calendarService.calendars()
        let enabled = Set(config.calendars)
        return all.map { calendar in
            CalendarListItem(
                id: calendar.id, title: calendar.title, account: calendar.account,
                enabled: enabled.contains(calendar.id),
                folder: RecordingStore.calendarFolderName(
                    for: calendar, override: config.folderOverride(forCalendar: calendar.id),
                    allCalendars: all))
        }
    }

    func upcoming(hours: Int) -> [UpcomingItem] {
        scheduler?.upcoming(hours: hours) ?? []
    }

    #if DEBUG
    /// Переключатель календаря из Debug-меню: проверка расписания не ждёт IPC и CLI.
    func debugSetCalendar(_ id: String, enabled: Bool) {
        var ids = config.calendars.filter { $0 != id }
        if enabled { ids.append(id) }
        let raw = (try? JSONEncoder().encode(ids)).flatMap { String(bytes: $0, encoding: .utf8) } ?? "[]"
        do {
            _ = try setConfig("calendars", raw: raw)
        } catch {
            logger.error("debug calendars: \(error.message, privacy: .public)")
        }
    }
    #endif

    // MARK: - конфиг

    /// Ответ — `{key, old, new}` с эффективными значениями (дефолт, если ключ не задан).
    func setConfig(_ key: String, raw: String) throws(EarmarkError) -> JSONValue {
        var next = config
        let change: (old: ConfigValue?, new: ConfigValue)
        do {
            change = try next.set(key, raw: raw)
        } catch {
            // Текст тот же, что у CLI для config list/get (ConfigError.description, Task 4).
            throw .invalidArguments(error.description)
        }
        try apply(next)
        return .object([
            "key": .string(key), "old": change.old?.jsonValue ?? .null, "new": change.new.jsonValue,
        ])
    }

    /// nil — сбросить всё. Ответ — `{key, old, new}` для одного ключа или `{all: true}`.
    func resetConfig(_ key: String?) throws(EarmarkError) -> JSONValue {
        var next = config
        guard let key else {
            next.resetAll()
            try apply(next)
            return .object(["all": .bool(true)])
        }
        let old = config.value(for: key)
        do {
            try next.reset(key)
        } catch {
            throw .invalidArguments(error.description)
        }
        try apply(next)
        return .object([
            "key": .string(key), "old": old?.jsonValue ?? .null,
            "new": next.value(for: key)?.jsonValue ?? .null,
        ])
    }

    /// Сначала побочные эффекты, которые могут не получиться, потом файл: иначе config.json
    /// обещал бы каталог или login item, которых в системе нет.
    private func apply(_ next: Config) throws(EarmarkError) {
        if next.recordingsDir != config.recordingsDir { try ensureRecordingsDir(next.recordingsDir) }
        if next.launchAtLogin != config.launchAtLogin {
            try setLaunchAtLogin(next.launchAtLogin)
            loginItemProblem = nil
        }
        do {
            try configStore.save(next)
        } catch {
            throw EarmarkError.operationFailed("cannot save config: \(error.localizedDescription)")
        }
        config = next
        configProblem = nil
    }

    // MARK: - doctor

    /// Всё, что должно быть готово, чтобы созвон записался и расшифровался (§10). CLI выходит
    /// с кодом 1, если ready == false.
    func doctor(audioTest: Bool) async -> DoctorReport {
        let pid = ProcessInfo.processInfo.processIdentifier
        var checks = [
            DoctorCheck(name: "app", ok: true, detail: "pid \(pid), version \(EarmarkVersion.current)"),
            DoctorCheck(
                name: "socket", ok: server != nil, detail: socketProblem ?? EarmarkPaths.socketFile.path),
        ]
        let access = permissions.current(maxAge: 0)
        for (name, value) in [
            ("microphone", access.microphone), ("audio_capture", access.audioCapture),
            ("calendars", access.calendars),
        ] {
            checks.append(DoctorCheck(name: name, ok: value == "granted", detail: value))
        }
        let stale = scheduler?.staleCalendarIDs ?? []
        checks.append(
            DoctorCheck(
                name: "enabled_calendars", ok: stale.isEmpty,
                detail: stale.isEmpty
                    ? "\(config.calendars.count) enabled"
                    : "missing in EventKit: " + stale.joined(separator: ", ")))
        checks.append(recordingsDirCheck())
        checks.append(await modelCheck())
        checks.append(vadCheck())
        let cli = Self.cliExecutable?.path
        checks.append(
            DoctorCheck(
                name: "cli", ok: cli != nil, detail: cli ?? "earmark CLI is missing from Contents/Helpers"))
        checks.append(diskCheck())
        checks.append(loginItemCheck())
        if audioTest {
            do {
                checks.append(try await self.audioTest())
            } catch {
                checks.append(DoctorCheck(name: "audio_test", ok: false, detail: error.message))
            }
        }
        return DoctorReport(ready: checks.allSatisfy(\.ok), checks: checks)
    }

    /// CLI в бандле (он же воркер транскрипции) лежит в Contents/Helpers (Task 1, D1). Не через
    /// url(forAuxiliaryExecutable:): тот ищет в Contents/MacOS, где на регистронезависимом APFS
    /// «earmark» и «Earmark» — один файл, то есть сам app.
    static var cliExecutable: URL? {
        let cli = Bundle.main.bundleURL.appending(path: "Contents/Helpers/earmark")
        return FileManager.default.isExecutableFile(atPath: cli.path) ? cli : nil
    }

    private func recordingsDirCheck() -> DoctorCheck {
        let dir = config.recordingsDir
        // Та же проверка, что у config set: защищённые TCC папки и доступность на запись (§7.1).
        do {
            _ = try ConfigSchema.parse(dir.path, for: "recordings_dir")
            return DoctorCheck(name: "recordings_dir", ok: true, detail: dir.path)
        } catch {
            return DoctorCheck(name: "recordings_dir", ok: false, detail: error.description)
        }
    }

    /// Размер и sha256 (§10, D35): обрезанную или подменённую модель видно только по хэшу.
    private func modelCheck() async -> DoctorCheck {
        // sha256 полутора гигабайт — 1–4 с CPU: не на главном акторе.
        let result = await Task.detached(priority: .userInitiated) {
            Result { try ModelStore().state(of: Models.largeV3Turbo, verify: true) }
        }.value
        let state: ModelState
        switch result {
        case .success(let value):
            state = value
        case .failure(let error):
            return DoctorCheck(name: "model", ok: false, detail: error.localizedDescription)
        }
        switch state {
        case .ready(let url):
            return DoctorCheck(name: "model", ok: true, detail: url.path)
        case .missing:
            return DoctorCheck(
                name: "model", ok: false, detail: "missing: earmark model download (or model import)")
        case .downloading(let received, let total):
            return DoctorCheck(
                name: "model", ok: false, detail: "downloading \(received * 100 / max(total, 1))%")
        case .corrupt(let url):
            return DoctorCheck(
                name: "model", ok: false, detail: "corrupt (size or sha256 mismatch): \(url.path)")
        }
    }

    /// VAD лежит в корне Resources бандла (D35); размер сверяем с манифестом — обрезанная копия
    /// не загрузится.
    private func vadCheck() -> DoctorCheck {
        let vad = Models.sileroVAD
        guard let url = Bundle.main.url(forResource: vad.fileName, withExtension: nil) else {
            return DoctorCheck(
                name: "vad", ok: false, detail: "\(vad.fileName) is missing from the app bundle")
        }
        let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        return DoctorCheck(name: "vad", ok: size.map { Int64($0) == vad.size } ?? false, detail: url.path)
    }

    /// 2 ГБ: час записи в CAF — около 0.7 ГБ, плюс итоговый m4a и временные файлы сведения.
    private func diskCheck() -> DoctorCheck {
        var probe = config.recordingsDir
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe.deleteLastPathComponent()
        }
        let free = (try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        guard let free else { return DoctorCheck(name: "disk", ok: false, detail: "cannot read free space") }
        return DoctorCheck(
            name: "disk", ok: free >= 2_000_000_000,
            detail: ByteCountFormatter.string(fromByteCount: free, countStyle: .file) + " free")
    }

    private func loginItemCheck() -> DoctorCheck {
        guard Self.isInstalled else {
            return DoctorCheck(
                name: "login_item", ok: true, detail: "not installed in /Applications (dev build)")
        }
        if LaunchAtLogin.isEnabled { return DoctorCheck(name: "login_item", ok: true, detail: "enabled") }
        if LaunchAtLogin.requiresApproval {
            return DoctorCheck(
                name: "login_item", ok: !config.launchAtLogin,
                detail: "requires approval: System Settings → General → Login Items")
        }
        return DoctorCheck(name: "login_item", ok: !config.launchAtLogin, detail: "not registered")
    }

    // MARK: - система

    /// Каталог записей создаётся с правами 0700 (§7.1): записи — чужие голоса.
    private func ensureRecordingsDir(_ url: URL) throws(EarmarkError) {
        do {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw EarmarkError.operationFailed("cannot create \(url.path): \(error.localizedDescription)")
        }
    }

    /// Login item регистрирует только установленная копия: сборка из build/ (`make run`)
    /// иначе прописалась бы в автозапуск и при входе спорила бы с /Applications за сокет.
    static var isInstalled: Bool { Bundle.main.bundleURL.path.hasPrefix("/Applications/") }

    private func setLaunchAtLogin(_ enabled: Bool) throws(EarmarkError) {
        guard Self.isInstalled else { return }
        do {
            try LaunchAtLogin.setEnabled(enabled)
        } catch {
            throw EarmarkError.operationFailed("launch_at_login: \(error.localizedDescription)")
        }
    }

    func openRecordingsFolder() {
        let url = config.recordingsDir
        do {
            try ensureRecordingsDir(url)
        } catch {
            logger.error("\(error.message, privacy: .public)")
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func refreshSnapshot() {
        let fresh = status()
        if fresh != snapshot { snapshot = fresh }
    }
}
