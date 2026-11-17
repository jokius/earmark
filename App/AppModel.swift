import AppKit
import EarmarkAudio
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
    /// Открытые вопросы «какой проект?» по ручным записям, по порядку остановки. Очередь не берёт из
    /// бэклога ни эти записи, ни их кандидатов на склейку. Только в памяти: после перезапуска запись
    /// просто расшифруется там, где лежит.
    private(set) var projectQuestions: [ProjectQuestion] = []
    /// Записи, которые сейчас склеиваются: очередь их не берёт, move и вторая склейка — busy.
    @ObservationIgnored private var merging: Set<String> = []
    @ObservationIgnored private lazy var projectPanels = ProjectPanels(model: self)

    var isRecording: Bool { session.isRecording }

    /// Запись. Зовётся из start(): AppDelegate зовёт его только после проверки TestEnvironment, так что
    /// под тестами ни захвата, ни восстановления нет. Монитор созвона держит SchedulerDriver (D28).
    func startRecordingServices() {
        session.onStarted = { [weak self] in self?.recordingWarnings = [] }
        session.onWarning = { [weak self] in self?.addRecordingWarning($0) }
    }

    /// Канал предупреждений записи один на сеанс и календарь; повтор того же текста не дублируется.
    private func addRecordingWarning(_ warning: String) {
        guard !recordingWarnings.contains(warning) else { return }
        recordingWarnings.append(warning)
    }

    /// Ручная запись из меню, CLI и агента. Идемпотентна: идёт запись — вернёт её (§9.3). Отказ старта
    /// виден в status.warnings (`start_failed:…`), а не только в логе: из меню иначе «ничего не произошло».
    func startManual(title: String?) throws(EarmarkError) -> CurrentRecordingInfo {
        if let current = session.current { return current }
        // Ровно одно текущее событие включённого календаря — запись уходит в его папку с его
        // метаданными (trigger остаётся manual) и делает его handled (§5).
        let meeting = scheduler?.currentMeeting()
        let request = RecordingSession.StartRequest(
            trigger: .manual, title: title ?? meeting?.title ?? RecordingFiles.manualTitle, meeting: meeting,
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
        // Отказ авто-старта и сбой сведения A при переключении (next_event) иначе видны только в логе.
        scheduler.onWarning = { [weak self] in self?.addRecordingWarning($0) }
        self.scheduler = scheduler
        // onChange у сервиса один: подписчиков раздаёт модель, а не тот, кто подписался последним.
        calendarService.onChange = { [weak self, weak scheduler] in
            scheduler?.calendarsChanged()
            self?.calendarStoreVersion += 1
        }
        let queue = TranscriptionQueue(
            store: { [weak self] in RecordingStore(root: (self?.config ?? Config()).recordingsDir) },
            config: { [weak self] in self?.config ?? Config() },
            isRecording: { [weak self] in self?.session.isRecording ?? false },
            // Держим, пока запись сводится или склеивается, и пока ждёт ответа «какой проект?» она
            // сама или запись, которая предлагает приклеиться к ней: иначе очередь расшифровала бы
            // предыдущую сразу после стопа, а склейка всё переделала бы или упёрлась в lock.
            isHeld: { [weak self] id in
                guard let self else { return false }
                return self.session.finalizing.contains(id) || self.merging.contains(id)
                    || self.projectQuestions.contains { $0.id == id || $0.mergeTarget?.id == id }
            },
            provisioner: provisioner, worker: Self.cliExecutable)
        self.queue = queue
        provisioner.onReady = { [weak queue] in queue?.requestScan() }
        // Колбэки сеанса — только здесь (D33). Вопрос о проекте открывается при стопе, не дожидаясь
        // сведения; ответ, данный раньше конца сведения, применяется после него. onFinalized один на
        // троих: re-arm смотрит причину стопа, отложенный ответ кладёт запись на место, очередь ставит
        // её в работу.
        session.onStopped = { [weak self] manifest, endedAt in
            self?.recordingStopped(manifest, endedAt: endedAt)
        }
        session.onFinalized = { [weak self, weak scheduler, weak queue] _, meta in
            scheduler?.recordingFinalized(meta)
            self?.applyProjectAnswers()
            queue?.requestScan()
        }
        session.onDiscarded = { [weak self, weak scheduler] id, reason in
            scheduler?.recordingDiscarded(id: id, reason: reason)
            self?.recordingGone(id)
        }
        session.onFinalizeFailed = { [weak self] id in self?.recordingGone(id) }
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

    // MARK: - проект ручной записи

    /// Ручная запись остановлена: спросить проект сразу, не дожидаясь сведения. Правило то же, что
    /// RecordingMeta.needsProject: из stopNow восстановленных записей не бывает. Нечего предложить — ни
    /// включённого календаря, ни записи для склейки — не спрашиваем.
    func recordingStopped(_ manifest: RecordingManifest, endedAt: Date) {
        guard manifest.trigger == .manual, !projectQuestions.contains(where: { $0.id == manifest.id }) else {
            return
        }
        let calendars = projectCalendars()
        var previous: RecordingFolder?
        do {
            previous = try RecordingStore(root: config.recordingsDir)
                .mergeTarget(id: manifest.id, startedAt: manifest.startedAt)
        } catch {
            logger.error(
                "merge target of \(manifest.id, privacy: .public): \(error.message, privacy: .public)")
        }
        guard !calendars.isEmpty || previous?.meta != nil else { return }
        let question = ProjectQuestion(
            id: manifest.id, title: manifest.title, startedAt: manifest.startedAt, endedAt: endedAt,
            calendar: manifest.calendar, mergeTarget: previous?.meta)
        projectQuestions.append(question)
        projectPanels.show(question, calendars: calendars)
    }

    /// Включённые календари в порядке config.calendars (это и приоритет) — кнопки вопроса о проекте.
    func projectCalendars() -> [CalendarListItem] {
        let all = calendarsList()
        return config.calendars.compactMap { id in all.first { $0.id == id } }
    }

    /// Ответ с панели. Выбор того, где запись уже лежит, просто снимает вопрос. Остальное применяется,
    /// когда запись (и цель склейки) сведена; до тех пор кнопки гаснут, а панель пишет «Saving…».
    func answerProject(id: String, _ answer: ProjectAnswer) {
        guard let question = projectQuestions.first(where: { $0.id == id }), question.pending == nil else {
            return
        }
        if answer == .move(question.calendar?.id) {
            stopAwaitingProject(id)
            return
        }
        setProjectAnswer(id, pending: answer, error: nil)
        applyProjectAnswers()
    }

    /// Крестик панели: запись остаётся, где лежит. false — выбор уже сохраняется, закрывать нельзя.
    func closeProjectQuestion(id: String) -> Bool {
        guard projectQuestions.first(where: { $0.id == id })?.pending == nil else { return false }
        stopAwaitingProject(id)
        return true
    }

    /// Отложенные ответы, чьи записи больше не сводятся. Зовётся после ответа и после каждого конца
    /// сведения: удачного, отброшенного и упавшего.
    private func applyProjectAnswers() {
        // Цикл идёт по копии: удачный ответ убирает вопрос из projectQuestions.
        for question in projectQuestions {
            guard let answer = question.pending, !session.finalizing.contains(question.id),
                !merging.contains(question.id)
            else { continue }
            switch answer {
            case .move(let calendarID):
                do {
                    _ = try moveRecording(id: question.id, calendarID: calendarID)
                } catch {
                    setProjectAnswer(question.id, pending: nil, error: error.message)
                }
            case .merge:
                guard let target = question.mergeTarget?.id, !session.finalizing.contains(target),
                    !merging.contains(target)
                else { continue }
                do {
                    // Сбой склейки снимает ответ в mergeFinished.
                    _ = try startMerge(question.id, into: target)
                } catch {
                    setProjectAnswer(question.id, pending: nil, error: error.message)
                }
            }
        }
    }

    private func setProjectAnswer(_ id: String, pending: ProjectAnswer?, error: String?) {
        guard let index = projectQuestions.firstIndex(where: { $0.id == id }) else { return }
        projectQuestions[index].pending = pending
        projectQuestions[index].error = error
        projectPanels.setSaving(id, pending != nil)
    }

    /// Запись отброшена при сведении или сведение упало: вопрос и отложенный выбор забываются.
    /// Упавшую доделает восстановление при следующем старте, а восстановленные не спрашиваем.
    private func recordingGone(_ id: String) {
        stopAwaitingProject(id)
        applyProjectAnswers()
    }

    /// Панель, CLI и агент. nil — обратно в Manual. Ответ — `{id, path, calendar}`.
    func moveRecording(id: String, calendarID: String?) throws(EarmarkError) -> JSONValue {
        var calendar: CalendarRef?
        var folder: String?
        if let calendarID {
            let all = calendarService.calendars()
            guard let info = all.first(where: { $0.id == calendarID }) else {
                throw EarmarkError.notFound("no calendar \(calendarID); take ids from `earmark calendars`")
            }
            calendar = CalendarRef(id: info.id, title: info.title)
            folder = RecordingStore.calendarFolderName(
                for: info, override: config.folderOverride(forCalendar: info.id), allCalendars: all)
        }
        // meta.json уже на диске, а сведение ещё не кончилось: следом оно удаляет CAF по старому пути,
        // и в переехавшей папке остались бы сырые дорожки. Склейка переписывает папку целиком.
        if session.finalizing.contains(id) || merging.contains(id) {
            throw EarmarkError.busy("recording \(id) is still in progress")
        }
        // Воркер этой записи держит .transcribe.lock, и store.move ответил бы тем же busy — но с
        // текстом про чужой процесс. Здесь мы знаем, что воркер наш.
        if queue?.runningID == id {
            throw EarmarkError.busy(
                "recording \(id) is being transcribed; move it when transcription finishes")
        }
        let moved = try RecordingStore(root: config.recordingsDir).move(id: id, to: calendar, folder: folder)
        stopAwaitingProject(id)
        let ref = moved.meta?.calendar
        return .object([
            "id": .string(id), "path": .string(moved.url.path),
            "calendar": ref.map { .object(["id": .string($0.id), "title": .string($0.title)]) } ?? .null,
        ])
    }

    /// CLI: приклеить запись к той, что закончилась прямо перед ней (не раньше mergeWindow до её старта).
    /// Ответ — `{id, merged, path}`: id и папка записи, которая осталась.
    func mergeRecording(id: String) async throws(EarmarkError) -> JSONValue {
        let store = RecordingStore(root: config.recordingsDir)
        let found: RecordingFolder?
        do {
            found = try store.find(id: id)
        } catch {
            throw EarmarkError.operationFailed("cannot read recordings: \(error.localizedDescription)")
        }
        guard let found else {
            throw EarmarkError.notFound("no recording \(id); take ids from `earmark recordings`")
        }
        guard !session.finalizing.contains(id), !found.isRecording, let meta = found.meta else {
            throw EarmarkError.busy("recording \(id) is still in progress")
        }
        guard let target = try store.mergeTarget(id: id, startedAt: meta.startedAt)?.id else {
            throw EarmarkError.notFound(
                "no recording ended within \(Int(RecordingStore.mergeWindow / 60)) minutes before \(id) "
                    + "to attach it to")
        }
        let merged = try await startMerge(id, into: target).value.get()
        return .object(["id": .string(target), "merged": .string(id), "path": .string(merged.url.path)])
    }

    /// Склейка вне main actor: перекодирование часового созвона — десятки секунд. Проверки и пометка
    /// merging — сразу, в этом же ходе: два ответа подряд не запустят две склейки.
    private func startMerge(_ id: String, into target: String)
        throws(EarmarkError) -> Task<Result<RecordingFolder, EarmarkError>, Never>
    {
        for recording in [id, target] {
            if session.finalizing.contains(recording) || merging.contains(recording) {
                throw EarmarkError.busy("recording \(recording) is still in progress")
            }
            // Как у move: lock держит наш воркер, а не чужой процесс.
            if queue?.runningID == recording {
                throw EarmarkError.busy(
                    "recording \(recording) is being transcribed; merge it when transcription finishes")
            }
        }
        merging.formUnion([id, target])
        let store = RecordingStore(root: config.recordingsDir)
        return Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { () throws(EarmarkError) -> RecordingFolder in
                    try RecordingMerger.merge(id, into: target, store: store)
                }
            }.value
            self?.mergeFinished(id, into: target, result)
            return result
        }
    }

    /// Ответы, отложенные, пока id и target склеивались, применяются здесь же: иначе «Saving…» навсегда.
    private func mergeFinished(
        _ id: String, into target: String, _ result: Result<RecordingFolder, EarmarkError>
    ) {
        merging.subtract([id, target])
        switch result {
        case .success(let folder):
            // Вопрос, предлагавший приклеиться к id, теперь клеит к target: id в нём растворилась.
            // Вопрос самой target остаётся: на него ещё не ответили.
            for index in projectQuestions.indices where projectQuestions[index].mergeTarget?.id == id {
                projectQuestions[index].mergeTarget = folder.meta
            }
            stopAwaitingProject(id)
        case .failure(let error):
            // В том же ходе, что снятие merging: иначе applyProjectAnswers запустил бы ту же склейку снова.
            // «Attach to previous» убираем: после сбоя на полпути повтор дописал бы вторую часть дважды.
            // Нарочно повторить можно `earmark merge`. Выбор .move, сделанный во время склейки из CLI, живёт.
            if let index = projectQuestions.firstIndex(where: { $0.id == id }) {
                projectQuestions[index].mergeTarget = nil
                let pending = projectQuestions[index].pending
                setProjectAnswer(id, pending: pending == .merge ? nil : pending, error: error.message)
            }
            queue?.requestScan()
        }
        applyProjectAnswers()
    }

    /// Любой ответ снимает вопрос: панель закрывается (и та, что открыта, когда ответили из CLI),
    /// очередь сканирует заново.
    private func stopAwaitingProject(_ id: String) {
        projectQuestions.removeAll { $0.id == id }
        projectPanels.close(id)
        queue?.requestScan()
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

    /// Растёт на каждом CalendarService.onChange. Store EventKit не @Observable, а окно Settings
    /// должно увидеть новый календарь, аккаунт или выданный доступ без переоткрытия. Счётчик
    /// меняется уже после reset() пустого store — своя подписка на EKEventStoreChanged читала бы
    /// список раньше и видела пустоту.
    private(set) var calendarStoreVersion = 0

    func calendarsList() -> [CalendarListItem] {
        // Чтение подписывает вызывающую вьюху на изменения календаря; IPC получает свежий список.
        _ = calendarStoreVersion
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

    /// Переключатель календаря в окне Settings. Путь тот же, что у CLI: проверка, атомарная запись
    /// config.json, планировщик видит новый список на следующем тике.
    func setCalendar(_ id: String, enabled: Bool) {
        let ids = CalendarSelection.toggled(config.calendars, id: id, enabled: enabled)
        // JSON-массив, а не список через запятую: id календаря — непрозрачная строка EventKit.
        // [String] кодируется всегда; запасное "[]" здесь выключило бы все календари.
        guard let data = try? JSONEncoder().encode(ids), let raw = String(bytes: data, encoding: .utf8) else {
            logger.error("calendars: cannot encode the calendar list")
            return
        }
        do {
            _ = try setConfig("calendars", raw: raw)
        } catch {
            logger.error("calendars: \(error.message, privacy: .public)")
        }
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
        if next.recordingsDir != config.recordingsDir {
            // Идущая запись осталась бы в старом каталоге: ни очередь, ни recover, ни `recordings`
            // её больше не увидят.
            guard !session.isRecording else {
                throw EarmarkError.busy(
                    "recordings_dir cannot change during a recording: stop the recording first")
            }
            try ensureRecordingsDir(next.recordingsDir)
        }
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
        if let remote = await remoteCheck() { checks.append(remote) }
        if audioTest {
            do {
                checks.append(try await self.audioTest())
            } catch {
                checks.append(DoctorCheck(name: "audio_test", ok: false, detail: error.message))
            }
        }
        // Удалённое распознавание на ready не влияет: при любом его сбое воркер распознаёт локально.
        return DoctorReport(
            ready: checks.allSatisfy { $0.ok || $0.name == Self.remoteCheckName }, checks: checks)
    }

    private static let remoteCheckName = "remote_transcription"

    /// Только при включённом transcription.remote.enabled: настроен ли, отвечает ли сервер, подошёл ли
    /// токен и те же ли у него whisper.cpp и модели. nil — режим выключен, чека нет.
    private func remoteCheck() async -> DoctorCheck? {
        guard let setup = RemoteTranscription.client(config: config, supportDir: EarmarkPaths.supportDir)
        else { return nil }
        let fallback = "; recordings are transcribed locally"
        do {
            let client = try setup.get()
            let health = try await client.checkCompatible()
            let gpu = health.gpu.isEmpty ? "" : " on \(health.gpu)"
            return DoctorCheck(
                name: Self.remoteCheckName, ok: true,
                detail: "\(client.baseURL.absoluteString): whisper \(health.whisper)\(gpu)")
        } catch {
            return DoctorCheck(name: Self.remoteCheckName, ok: false, detail: error.message + fallback)
        }
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
