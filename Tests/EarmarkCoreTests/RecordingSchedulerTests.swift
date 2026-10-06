import EarmarkCore
import Foundation
import Testing

// Фиксированный пояс и фиксированные даты: решения считаются абсолютным временем от now, и тест не
// должен зависеть от пояса машины. Москва — чтобы местная полночь не совпадала с полночью UTC.
private let zone = TimeZone(identifier: "Europe/Moscow") ?? .gmt

private let work = CalendarInfo(id: "cal-work", title: "Work", account: "Local")
private let personal = CalendarInfo(id: "cal-personal", title: "Personal", account: "Local")
private let other = CalendarInfo(id: "cal-other", title: "Other", account: "Local")

/// "10:00:00" — 2 октября 2026, или полная дата "2026-10-03 00:00:30", в фиксированном поясе.
/// Опечатка в литерале роняет тест, а не даёт тихую дату.
private func at(_ text: String) -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = zone
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    guard let date = formatter.date(from: text.count == 8 ? "2026-10-02 " + text : text) else {
        preconditionFailure("дата в тесте: \(text)")
    }
    return date
}

/// "HH:mm:ss" в том же поясе — для журналов прогона.
private func clock(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = zone
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: date)
}

/// Событие календаря. Ключ по умолчанию: серия = title, occurrence = start.
private func meeting(
    _ title: String, _ start: String, _ end: String, in calendar: CalendarInfo = work,
    allDay: Bool = false, canceled: Bool = false, participation: Participation = .accepted,
    series: String? = nil, occurrence: String? = nil
) -> Meeting {
    let startDate = at(start)
    let seriesId = series ?? title
    return Meeting(
        key: OccurrenceKey(seriesId: seriesId, occurrence: at(occurrence ?? start), start: startDate),
        eventId: "\(title)@\(calendar.id)", externalId: seriesId, title: title, calendar: calendar,
        start: startDate, end: at(end), isAllDay: allDay, isCanceled: canceled, participation: participation)
}

/// Включены Work и Personal (в этом порядке), lead 60 с, авто-запись включена.
private func makeConfig(
    calendars: [String] = [work.id, personal.id], autoRecord: Bool = true, extra: [String: ConfigValue] = [:]
) -> Config {
    var values: [String: ConfigValue] = [
        "auto_record": .bool(autoRecord), "calendars": .stringList(calendars), "lead_seconds": .int(60),
    ]
    values.merge(extra) { _, new in new }
    return Config(values: values)
}

private func decide(
    _ now: String, _ meetings: [Meeting], config: Config = makeConfig(), handled: Set<OccurrenceKey> = [],
    rearmable: Set<OccurrenceKey> = [], callActive: Bool = false, current: ActiveRecording? = nil
) -> SchedulerDecision {
    RecordingScheduler.decide(
        now: at(now), meetings: meetings, config: config, handled: handled, rearmable: rearmable,
        callActive: callActive, current: current)
}

@Suite("RecordingScheduler: когда начинать авто-запись")
struct RecordingSchedulerTests {
    /// Встреча 10:00–10:30 в Work, lead 60 с.
    static let standup = meeting("Standup", "10:00:00", "10:30:00")

    struct WindowCase: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let now: String
        let starts: Bool
    }

    @Test(
        "окно start − lead ≤ now < end",
        arguments: [
            WindowCase(testDescription: "за секунду до start − lead — рано", now: "09:58:59", starts: false),
            WindowCase(testDescription: "ровно start − lead — пре-ролл", now: "09:59:00", starts: true),
            WindowCase(testDescription: "ровно start", now: "10:00:00", starts: true),
            WindowCase(
                testDescription: "проснулся или запустился посреди встречи", now: "10:17:00", starts: true),
            WindowCase(testDescription: "за секунду до end", now: "10:29:59", starts: true),
            WindowCase(testDescription: "ровно end — поздно", now: "10:30:00", starts: false),
            WindowCase(testDescription: "после end", now: "11:00:00", starts: false),
        ])
    func window(_ testCase: WindowCase) {
        let expected: SchedulerDecision = testCase.starts ? .start(Self.standup) : .none
        #expect(decide(testCase.now, [Self.standup]) == expected)
    }

    @Test("граница суток: окно считается от now, отсечки «сегодня» нет")
    func midnight() {
        // В Call Reminder выборка кончалась в полночь, и встреча в 00:00:30 при lead 60 с
        // срабатывала поздно или никогда (воспроизведено).
        let night = meeting("Night sync", "2026-10-03 00:00:30", "2026-10-03 00:30:00")
        #expect(decide("2026-10-02 23:59:31", [night]) == .start(night))
        #expect(decide("2026-10-02 23:59:29", [night]) == .none)
    }

    @Test("lead календаря переопределяет общий")
    func perCalendarLead() {
        let config = makeConfig(extra: ["calendar.cal-personal.lead_seconds": .int(300)])
        let gym = meeting("Gym", "10:00:00", "11:00:00", in: personal)
        #expect(decide("09:55:00", [gym, Self.standup], config: config) == .start(gym))
        #expect(decide("09:54:59", [gym, Self.standup], config: config) == .none)
        // У Work переопределения нет — общий lead 60 с.
        #expect(decide("09:55:00", [Self.standup], config: config) == .none)
    }

    @Test("событие невключённого календаря не пишем")
    func disabledCalendar() {
        let foreign = meeting("Foreign", "10:00:00", "10:30:00", in: other)
        #expect(decide("10:00:00", [foreign]) == .none)
    }

    struct FilterCase: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let meeting: Meeting
        let starts: Bool
    }

    @Test(
        "весь день, отменённые и отклонённые — мимо; tentative и прочие ответы — пишем",
        arguments: [
            FilterCase(
                testDescription: "на весь день",
                meeting: meeting("Holiday", "10:00:00", "10:30:00", allDay: true), starts: false),
            FilterCase(
                testDescription: "отменено",
                meeting: meeting("Canceled", "10:00:00", "10:30:00", canceled: true), starts: false),
            FilterCase(
                testDescription: "я отклонил",
                meeting: meeting("Nope", "10:00:00", "10:30:00", participation: .declined), starts: false),
            FilterCase(
                testDescription: "tentative",
                meeting: meeting("Maybe", "10:00:00", "10:30:00", participation: .tentative), starts: true),
            FilterCase(
                testDescription: "без ответа",
                meeting: meeting("Pending", "10:00:00", "10:30:00", participation: .pending), starts: true),
            FilterCase(
                testDescription: "я организатор",
                meeting: meeting("Mine", "10:00:00", "10:30:00", participation: .organizer), starts: true),
            FilterCase(
                testDescription: "своё событие без участников",
                meeting: meeting("Solo", "10:00:00", "10:30:00", participation: .none), starts: true),
            FilterCase(
                testDescription: "меня не нашли среди участников",
                meeting: meeting("List", "10:00:00", "10:30:00", participation: .unknown), starts: true),
        ])
    func eventFilter(_ testCase: FilterCase) {
        let expected: SchedulerDecision = testCase.starts ? .start(testCase.meeting) : .none
        #expect(decide("10:00:00", [testCase.meeting]) == expected)
    }

    @Test("handled второй раз не стартует")
    func handledOnce() {
        #expect(decide("10:05:00", [Self.standup], handled: [Self.standup.key]) == .none)
    }

    @Test("rearmable стартует снова, но только при активном созвоне")
    func rearm() {
        let key = Self.standup.key
        #expect(decide("10:15:00", [Self.standup], rearmable: [key], callActive: false) == .none)
        #expect(
            decide("10:15:00", [Self.standup], rearmable: [key], callActive: true) == .start(Self.standup))
    }

    @Test("перекрытие: раньше start, при равенстве — календарь раньше в списке")
    func overlap() {
        let early = meeting("Early", "10:00:00", "11:00:00", in: personal)
        let late = meeting("Late", "10:05:00", "10:35:00", in: work)
        #expect(decide("10:06:00", [late, early]) == .start(early))

        let team = meeting("Team", "10:00:00", "10:30:00", in: work)
        let dentist = meeting("Dentist", "10:00:00", "10:30:00", in: personal)
        #expect(decide("09:59:00", [dentist, team]) == .start(team))
        let personalFirst = makeConfig(calendars: [personal.id, work.id])
        #expect(decide("09:59:00", [team, dentist], config: personalFirst) == .start(dentist))
    }

    @Test("одно событие в двух календарях — одна запись, побеждает календарь раньше в списке")
    func dedupeAcrossCalendars() {
        let inPersonal = meeting("Sync", "10:00:00", "10:30:00", in: personal, series: "series-1")
        let inWork = meeting("Sync", "10:00:00", "10:30:00", in: work, series: "series-1")
        let inOther = meeting("Sync", "10:00:00", "10:30:00", in: other, series: "series-1")
        let order = [work.id, personal.id]
        #expect(RecordingScheduler.dedupe([inOther, inPersonal, inWork], calendarOrder: order) == [inWork])
        // Перенесённое вхождение — уже другое: start входит в ключ.
        let moved = meeting(
            "Sync", "15:00:00", "15:30:00", in: personal, series: "series-1", occurrence: "10:00:00")
        #expect(RecordingScheduler.dedupe([inWork, moved], calendarOrder: order) == [inWork, moved])
        // Проигравшая копия не стартует раньше со своим lead: у Personal 300 с, у Work 60 с.
        let config = makeConfig(extra: ["calendar.cal-personal.lead_seconds": .int(300)])
        #expect(decide("09:55:00", [inPersonal, inWork], config: config) == .none)
        #expect(decide("09:59:00", [inPersonal, inWork], config: config) == .start(inWork))
    }

    @Test("auto_record выключен — авто-записи нет")
    func autoRecordOff() {
        #expect(decide("10:00:00", [Self.standup], config: makeConfig(autoRecord: false)) == .none)
    }
}

@Suite("RecordingScheduler: пока идёт запись")
struct SchedulerTimelineTests {
    /// Гоняет decide раз в секунду и применяет решения так, как SchedulerDriver: после старта —
    /// handled, текущая запись — новая. Стоп-правила не моделируются: запись идёт, пока её не сменит
    /// следующее событие. Журнал — «start|switch <title> [<календарь>] @HH:mm:ss».
    private func run(from: String, to: String, _ meetings: [Meeting]) -> [String] {
        let config = makeConfig()
        let end = at(to)
        var handled: Set<OccurrenceKey> = []
        var current: ActiveRecording?
        var log: [String] = []
        var now = at(from)
        while now <= end {
            let decision = RecordingScheduler.decide(
                now: now, meetings: meetings, config: config, handled: handled, rearmable: [],
                callActive: true, current: current)
            switch decision {
            case .none:
                break
            case .start(let meeting), .switchTo(let meeting):
                let verb = decision == .start(meeting) ? "start" : "switch"
                log.append("\(verb) \(meeting.title) [\(meeting.calendar.title)] @\(clock(now))")
                handled.insert(meeting.key)
                current = ActiveRecording(trigger: .calendar, key: meeting.key, startedAt: now)
            }
            now += 1
        }
        return log
    }

    @Test("ручную запись авто-логика не прерывает")
    func manualBlocks() {
        let standup = meeting("Standup", "10:00:00", "10:30:00")
        let planning = meeting("Planning", "10:30:00", "11:00:00")
        let manual = ActiveRecording(trigger: .manual, key: nil, startedAt: at("09:30:00"))
        #expect(decide("10:00:00", [standup], current: manual) == .none)
        // Ручная, привязанная к текущему событию, — тоже: следующая встреча её не сменит.
        let bound = ActiveRecording(trigger: .manual, key: standup.key, startedAt: at("10:05:00"))
        #expect(decide("10:30:00", [standup, planning], current: bound) == .none)
    }

    @Test("встречи впритык: пре-ролл первой, переключение ровно в начале второй, без дублей")
    func backToBack() {
        let log = run(
            from: "09:58:00", to: "10:31:00",
            [meeting("Standup", "10:00:00", "10:30:00"), meeting("Planning", "10:30:00", "11:00:00")])
        #expect(log == ["start Standup [Work] @09:59:00", "switch Planning [Work] @10:30:00"])
    }

    @Test("две встречи в одно время: выбор на пре-ролле держится и в момент start")
    func sameStart() {
        let log = run(
            from: "09:58:00", to: "10:31:00",
            [
                meeting("Dentist", "10:00:00", "10:30:00", in: personal),
                meeting("Team", "10:00:00", "11:00:00", in: work),
            ])
        #expect(log == ["start Team [Work] @09:59:00"])
    }

    @Test("проснулся посреди встречи, она в двух календарях: одна запись")
    func wakeMidMeeting() {
        let log = run(
            from: "10:17:00", to: "10:40:00",
            [
                meeting("Standup", "10:00:00", "10:30:00", in: personal),
                meeting("Standup", "10:00:00", "10:30:00", in: work),
            ])
        #expect(log == ["start Standup [Work] @10:17:00"])
    }

    @Test("запуск посреди двух встреч: раньше начавшаяся, и не перескакиваем")
    func launchBetweenTwo() {
        let log = run(
            from: "10:20:00", to: "10:50:00",
            [meeting("Long", "10:00:00", "11:00:00"), meeting("Inner", "10:15:00", "10:45:00")])
        #expect(log == ["start Long [Work] @10:20:00"])
    }
}

@Suite("RecordingScheduler: текущее событие и ближайшие")
struct SchedulerQueriesTests {
    @Test("ручная запись привязывается только к единственному идущему событию")
    func currentMeeting() {
        let standup = meeting("Standup", "10:00:00", "10:30:00")
        let twin = meeting("Standup", "10:00:00", "10:30:00", in: personal)
        let overlap = meeting("Overlap", "10:15:00", "10:45:00", in: personal)
        let foreign = meeting("Foreign", "10:00:00", "10:30:00", in: other)
        let holiday = meeting("Holiday", "10:00:00", "10:30:00", allDay: true)
        func current(_ now: String, _ meetings: [Meeting]) -> Meeting? {
            RecordingScheduler.currentMeeting(now: at(now), meetings: meetings, config: makeConfig())
        }
        #expect(current("10:05:00", [standup, foreign, holiday]) == standup)
        #expect(current("10:05:00", [twin, standup]) == standup)  // одно событие в двух календарях
        #expect(current("10:20:00", [standup, overlap]) == nil)  // два разных — не угадываем
        #expect(current("09:59:30", [standup]) == nil)  // пре-ролл: событие ещё не идёт
        #expect(current("10:30:00", [standup]) == nil)
    }

    @Test("upcoming: что и когда начнёт писаться")
    func upcoming() {
        let config = makeConfig(extra: ["calendar.cal-personal.lead_seconds": .int(300)])
        let meetings = [
            meeting("Gym", "11:30:00", "12:30:00", in: personal),
            meeting("Standup", "11:00:00", "11:15:00", in: personal),
            meeting("Standup", "11:00:00", "11:15:00", in: work),
            meeting("Running", "09:30:00", "10:30:00"),
            meeting("Ended now", "09:00:00", "10:00:00"),
            meeting("Horizon", "12:00:00", "12:30:00"),
            meeting("Holiday", "10:00:00", "23:00:00", allDay: true),
            meeting("Foreign", "11:00:00", "12:00:00", in: other),
        ]
        let items = RecordingScheduler.upcoming(
            now: at("10:00:00"), hours: 2, meetings: meetings, config: config)
        #expect(
            items.map { "\($0.title) [\($0.calendar.title)] \(clock($0.start)) rec \(clock($0.recordAt))" }
                == [
                    "Running [Work] 09:30:00 rec 09:29:00",
                    "Standup [Work] 11:00:00 rec 10:59:00",
                    "Gym [Personal] 11:30:00 rec 11:25:00",
                ])
        #expect(
            items.first
                == UpcomingItem(
                    eventId: "Running@cal-work", title: "Running",
                    calendar: CalendarRef(id: "cal-work", title: "Work"),
                    start: at("09:30:00"), end: at("10:30:00"), recordAt: at("09:29:00")))
        // auto_record выключен — записано не будет ничего, и обещать нечего (за ним и status.next).
        #expect(
            RecordingScheduler.upcoming(
                now: at("10:00:00"), hours: 2, meetings: meetings, config: makeConfig(autoRecord: false)
            ).isEmpty)
    }
}
