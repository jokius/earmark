// Тикающая часть ReminderEngine из Call Reminder (MIT, тот же автор): тик 1 с, перечитывание
// календаря раз в 60 с, didWake, EKEventStoreChanged, handled только после успешного действия.
import AppKit
import EarmarkCore
import os

/// Ведёт авто-запись по календарю (§5): раз в секунду спрашивает чистый RecordingScheduler
/// (EarmarkCore) и исполняет решение через RecordingSession. Сам ничего не решает, кроме
/// «какая запись к какому событию относится» — это нужно для re-arm и ручной записи.
///
/// Фильтр включённых календарей и дедуп — внутри RecordingScheduler: ему отдаётся сырая выборка.
@MainActor
final class SchedulerDriver {
    private let calendar: CalendarService
    private let session: RecordingSession
    private let config: () -> Config
    private let handledStore: HandledStore
    private var state: HandledState
    /// События всех календарей за [now − 24 h, now + 24 h]. Включённые отбирает планировщик на каждом
    /// тике: список календарей в конфиге может поменяться между перечитываниями.
    private var meetings: [Meeting] = []
    private(set) var calendars: [CalendarInfo] = []
    private var lastReload = Date.distantPast
    private var lastSample: ActivitySample?
    /// Записи, начатые (или привязанные) к событию: id записи → ключ события. Словарь, а не одна
    /// пара: сведение A идёт в фоне, и если за это время стартует B, поздний onFinalized A всё равно
    /// найдёт своё событие — иначе re-arm A после no_call или sleep терялся бы.
    private var eventKeys: [String: OccurrenceKey] = [:]
    private var lastFailure: (key: OccurrenceKey, at: Date)?
    private var acting = false
    /// Между willSleep и didWake: стоп `.sleep` сразу делает событие rearmable (короткая запись
    /// отбрасывается за миллисекунды), и тик до засыпания начал бы новую запись, которая переживёт сон.
    private var asleep = false
    private var ticker: Task<Void, Never>?
    private var sleepObservers: [any NSObjectProtocol] = []
    private var monitor: CallActivityMonitor?
    private let logger = Logger(subsystem: EarmarkPaths.bundleID, category: "scheduler")
    /// `start_failed:…` и `finalize_failed:…` для status.warnings — тот же канал, что у сеанса.
    var onWarning: ((String) -> Void)?

    init(
        calendar: CalendarService, session: RecordingSession, config: @escaping () -> Config,
        handledStore: HandledStore = HandledStore()
    ) {
        self.calendar = calendar
        self.session = session
        self.config = config
        self.handledStore = handledStore
        state = handledStore.load()
    }

    func start() {
        calendar.onChange = { [weak self] in
            self?.reload()
            Task { await self?.tick() }
        }
        reload()
        // Монитор созвона один на app и работает всегда, а не только во время записи: re-arm (§5 п.5)
        // стартует запись по появлению созвона, когда ничего не пишется. Сэмпл без записи (и поздний,
        // пришедший после стопа) сеанс просто пропускает.
        let monitor = CallActivityMonitor(levels: session.levels)
        monitor.start { [weak self] sample in self?.ingest(sample) }
        self.monitor = monitor
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await self?.tick()
            }
        }
        // До сна тики молчат (re-arm ждёт пробуждения, D31); после — перечитываем и решаем сразу.
        let center = NSWorkspace.shared.notificationCenter
        sleepObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.asleep = true }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    self?.asleep = false
                    self?.reload()
                    Task { await self?.tick() }
                }
            },
        ]
    }

    /// `now` параметром — чтобы тик можно было прогнать руками; таймер зовёт с дефолтом.
    func tick(now: Date = .now) async {
        // После переключения (next_event) тик дожидается сведения A; второй тик из wake или
        // EKEventStoreChanged в это время ничего не решает.
        guard !acting, !asleep else { return }
        acting = true
        defer { acting = false }

        if now.timeIntervalSince(lastReload) >= 60 { reload(now: now) }
        let config = config()
        let current = session.current
        if current?.trigger == .manual { markCoveredByManual(now: now, config: config) }

        let decision = RecordingScheduler.decide(
            now: now, meetings: meetings, config: config, handled: state.handled, rearmable: state.rearmable,
            callActive: callActive(now: now),
            current: current.map {
                ActiveRecording(trigger: $0.trigger, key: eventKeys[$0.id], startedAt: $0.startedAt)
            })
        switch decision {
        case .none:
            return
        case .start(let meeting):
            startRecording(meeting, now: now)
        case .switchTo(let meeting):
            // Встречи впритык (§5 п.2, D30): stopNow синхронно закрывает CAF A и освобождает сеанс,
            // B стартует сразу, в B.start. Сведение A (у часовой встречи — десятки секунд) идёт
            // в фоне; ждать его до старта B — значит потерять начало B. next_event не rearmable,
            // так что поздний onFinalized A только уберёт A из eventKeys.
            let finishing = session.stopNow(reason: .nextEvent)
            startRecording(meeting, now: now)
            do {
                _ = try await finishing?.value
            } catch {
                // Уже после старта B: его onStarted предупреждение не сотрёт.
                onWarning?("finalize_failed:\(error.localizedDescription)")
            }
        }
    }

    /// Re-arm (§5 п.5): после стопа no_call или sleep событие можно начать заново, если созвон
    /// появится до его конца. Причина стопа есть только в meta — поэтому сюда ведёт onFinalized.
    func recordingFinalized(_ meta: RecordingMeta) {
        recordingEnded(id: meta.id, reason: meta.stopReason)
    }

    /// Отброшенная авто-запись (короче min_keep_seconds) не оставляет meta, и onFinalized не зовётся —
    /// сюда ведёт onDiscarded (D31). Без этого событие осталось бы handled: крышка закрылась
    /// в пре-ролле — и после пробуждения встреча уже не перезапустится.
    func recordingDiscarded(id: String, reason: StopReason) {
        recordingEnded(id: id, reason: reason)
    }

    // MARK: - ручная запись

    /// Ровно одно текущее событие включённого календаря — для привязки ручной записи (§5).
    func currentMeeting(now: Date = .now) -> Meeting? {
        RecordingScheduler.currentMeeting(now: now, meetings: meetings, config: config())
    }

    /// Ручная запись посреди события пишется в папку этого события и делает его handled: иначе
    /// после ручного стопа сразу стартовала бы «поздняя» авто-запись того же события.
    func attachManual(recordingId: String, to meeting: Meeting) {
        eventKeys[recordingId] = meeting.key
        state.markHandled(meeting.key)
        save()
    }

    func folderName(for calendar: CalendarInfo) -> String {
        RecordingStore.calendarFolderName(
            for: calendar, override: config().folderOverride(forCalendar: calendar.id),
            allCalendars: calendars)
    }

    // MARK: - для status и CLI

    /// Ближайшее событие, которое будет записано: из кэша, без похода в EventKit (status() зовётся
    /// раз в секунду ради меню). Уже записанное (handled) не показываем.
    var next: UpcomingItem? {
        let pool = meetings.filter { !state.handled.contains($0.key) }
        return RecordingScheduler.upcoming(now: .now, hours: 24, meetings: pool, config: config()).first
    }

    /// Свежая выборка на произвольное окно: кэш покрывает только ±24 h.
    func upcoming(hours: Int, now: Date = .now) -> [UpcomingItem] {
        let fresh = calendar.meetings(from: now, to: now.addingTimeInterval(Double(hours) * 3600))
        let pool = fresh.filter { !state.handled.contains($0.key) }
        return RecordingScheduler.upcoming(now: now, hours: hours, meetings: pool, config: config())
    }

    /// Включённые ID, которых нет в EventKit: calendarIdentifier не переживает полный ресинк
    /// (EKCalendar.h). Пустой список календарей значит «нет доступа», а не «всё устарело».
    var staleCalendarIDs: [String] {
        guard !calendars.isEmpty else { return [] }
        let known = Set(calendars.map(\.id))
        return config().calendars.filter { !known.contains($0) }
    }

    // MARK: - внутреннее

    private func reload(now: Date = .now) {
        lastReload = now
        calendars = calendar.calendars()
        meetings = calendar.meetings(
            from: now.addingTimeInterval(-86_400), to: now.addingTimeInterval(86_400))
        let before = state
        // Идущие события (выборка их содержит) не теряют handled, даже если начались больше суток назад.
        state.prune(now: now, keeping: Set(meetings.map(\.key)))
        if state != before { save() }
    }

    private func ingest(_ sample: ActivitySample) {
        lastSample = sample
        session.ingest(sample)
    }

    /// Запись кончилась (meta или discard): событие возвращается в игру, если стоп rearmable.
    /// Чужие id (восстановленные после крэша, ручные без события) просто пропускаем.
    private func recordingEnded(id: String, reason: StopReason?) {
        guard let key = eventKeys.removeValue(forKey: id), let reason, StopRules.isRearmable(reason) else {
            return
        }
        state.markRearmable(key)
        save()
    }

    /// Ручная запись, перекрывшая событие, делает его handled (§5 п.4). currentMeeting по одному
    /// событию — это «включено, записываемо и идёт сейчас»: правило уже покрыто тестами
    /// RecordingScheduler, здесь его не дублируем.
    private func markCoveredByManual(now: Date, config: Config) {
        let covered = meetings.filter {
            !state.handled.contains($0.key)
                && RecordingScheduler.currentMeeting(now: now, meetings: [$0], config: config) != nil
        }
        guard !covered.isEmpty else { return }
        covered.forEach { state.markHandled($0.key) }
        save()
    }

    private func startRecording(_ meeting: Meeting, now: Date) {
        // Неудачный старт (нет прав, нет места) не повторяем каждую секунду: это поток ошибок
        // в журнале и пустых папок. Через 30 с — новая попытка.
        if let lastFailure, lastFailure.key == meeting.key, now.timeIntervalSince(lastFailure.at) < 30 {
            return
        }
        let request = RecordingSession.StartRequest(
            trigger: .calendar, title: meeting.title, meeting: meeting,
            calendarFolder: folderName(for: meeting.calendar))
        do throws(EarmarkError) {
            let info = try session.start(request)
            eventKeys[info.id] = meeting.key
            lastFailure = nil
            // handled — только после успешного старта (Call Reminder, 160e6ae): неудачный повторится.
            state.markHandled(meeting.key)
            save()
        } catch {
            lastFailure = (meeting.key, now)
            logger.error("auto start failed: \(error.message, privacy: .public)")
            onWarning?("start_failed:\(error.message)")
        }
    }

    /// Отставший сэмпл (монитор встал) — не повод стартовать запись по re-arm.
    private func callActive(now: Date) -> Bool {
        guard let lastSample, now.timeIntervalSince(lastSample.now) < 5 else { return false }
        return lastSample.callActive
    }

    private func save() {
        do {
            try handledStore.save(state)
        } catch {
            logger.error("state.json: \(error.localizedDescription, privacy: .public)")
        }
    }
}
