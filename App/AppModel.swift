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
    /// Временно, до Task 16: монитор созвона на app один, и Task 16 переносит его в SchedulerDriver.
    @ObservationIgnored private lazy var callMonitor = CallActivityMonitor(levels: session.levels)
    /// Предупреждения записи (`capture_failed:…`, `far_end_digital_silence`, `start_failed:…`,
    /// `finalize_failed:…`) — в status.warnings. Сбрасываются на каждом старте записи.
    private(set) var recordingWarnings: [String] = []

    var isRecording: Bool { session.isRecording }

    /// Запись и детект созвона. Последняя строка start(): AppDelegate зовёт его только после проверки
    /// TestEnvironment, так что под тестами ни захвата, ни восстановления нет.
    func startRecordingServices() {
        session.onStarted = { [weak self] in self?.recordingWarnings = [] }
        session.onWarning = { [weak self] warning in
            guard let self, !self.recordingWarnings.contains(warning) else { return }
            self.recordingWarnings.append(warning)
        }
        callMonitor.start { [weak self] sample in self?.session.ingest(sample) }  // убирает Task 16
        Task { await session.recoverInterrupted() }  // Task 23 переносит за создание очереди
    }

    /// Ручная запись из меню, CLI и агента. Идемпотентна: идёт запись — вернёт её. Отказ старта виден в
    /// status.warnings (`start_failed:…`), а не только в логе: из меню иначе «ничего не произошло».
    func startManual(title: String?) throws(EarmarkError) -> CurrentRecordingInfo {
        if let current = session.current { return current }
        let request = RecordingSession.StartRequest(
            trigger: .manual, title: title ?? "Manual recording", meeting: nil, calendarFolder: nil)
        recordingWarnings = []
        do throws(EarmarkError) {
            return try session.start(request)
        } catch {
            recordingWarnings = ["start_failed:\(error.message)"]
            throw error
        }
    }

    /// Стоп из меню, CLI и агента; ответ — после финализации. nil — писать было нечего или запись отброшена.
    func stopRecording() async throws(EarmarkError) -> RecordingMeta? {
        try await session.stop(reason: .manual)
    }
    let permissions = Permissions()

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
    }

    func shutdown() {
        ticker?.cancel()
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
        return data
    }

    // MARK: - права

    func requestPermissions() async -> PermissionsInfo {
        let result = await permissions.request()
        refreshSnapshot()
        return result
    }

    /// Тон слышно в динамиках, и во время записи он попал бы в канал собеседников — отсюда busy.
    func audioTest() async throws(EarmarkError) -> DoctorCheck {
        guard status().state != "recording" else {
            throw EarmarkError.busy("audio test would be heard in the recording in progress")
        }
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
