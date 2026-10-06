// Из Call Reminder (MIT, тот же автор): meetingToShow из Sources/ReminderEngine.swift,
// с правками из §5 спеки.
import Foundation

/// Что сейчас пишется — ровно то, что планировщику нужно знать о текущей записи.
public struct ActiveRecording: Equatable, Sendable {
    public var trigger: RecordingTrigger
    /// Событие записи; у ручной записи без события — nil.
    public var key: OccurrenceKey?
    public var startedAt: Date

    public init(trigger: RecordingTrigger, key: OccurrenceKey?, startedAt: Date) {
        self.trigger = trigger
        self.key = key
        self.startedAt = startedAt
    }
}

public enum SchedulerDecision: Equatable, Sendable {
    case none
    /// Начать авто-запись этого события.
    case start(Meeting)
    /// Финализировать текущую авто-запись с причиной next_event и начать эту.
    case switchTo(Meeting)
}

/// Когда начинать авто-запись. Чистые функции: события, конфиг, состояние и now — на входе, поэтому
/// решения проверяются таблицей с фиксированным now, без таймера и EventKit.
///
/// Отличия от `meetingToShow` из Call Reminder:
/// - окно `start − lead ≤ now < end`, а не `< start`: Mac проснулся или app запустили посреди
///   встречи — пишем остаток, а не теряем встречу целиком;
/// - окно считается только от now, отсечки «до конца сегодняшнего дня» нет: в Call Reminder
///   встреча в 00:00:30 при lead 60 с срабатывала поздно или никогда (воспроизведено);
/// - lead читается из конфига при каждом решении, а не копируется в поле: там новый lead
///   применялся только после клика по Settings;
/// - одно событие в нескольких календарях — одно (`dedupe`).
public enum RecordingScheduler {
    /// Одно событие в нескольких календарях → одно (по OccurrenceKey); побеждает календарь раньше
    /// в `calendarOrder`, незнакомые — последними. Порядок первых появлений сохраняется.
    ///
    /// Дело не только в двойной записи: у копии из другого календаря свой lead и своя папка, и без
    /// дедупа копия с lead побольше стартовала бы раньше победителя — и не в той папке.
    public static func dedupe(_ meetings: [Meeting], calendarOrder: [String]) -> [Meeting] {
        var winners: [OccurrenceKey: Meeting] = [:]
        var keys: [OccurrenceKey] = []
        for meeting in meetings {
            guard let held = winners[meeting.key] else {
                winners[meeting.key] = meeting
                keys.append(meeting.key)
                continue
            }
            if rank(meeting.calendar.id, in: calendarOrder) < rank(held.calendar.id, in: calendarOrder) {
                winners[meeting.key] = meeting
            }
        }
        return keys.compactMap { winners[$0] }
    }

    /// Начать, переключиться или ничего не делать.
    ///
    /// Кандидаты — события включённых календарей, которые `shouldRecord`, в окне
    /// `start − lead(календаря) ≤ now < end`, не handled; rearmable — только при активном созвоне.
    /// Сырой список из EventKit можно отдавать как есть: дедуп по календарям делается здесь же.
    /// Семь параметров — цена чистоты: всё состояние на входе, поэтому решение проверяется таблицей.
    public static func decide(  // swiftlint:disable:this function_parameter_count
        now: Date, meetings: [Meeting], config: Config, handled: Set<OccurrenceKey>,
        rearmable: Set<OccurrenceKey>, callActive: Bool, current: ActiveRecording?
    ) -> SchedulerDecision {
        guard config.autoRecord else { return .none }
        let order = config.calendars
        let candidates = dedupe(meetings, calendarOrder: order).filter { meeting in
            guard isRecordable(meeting, order: order) else { return false }
            let lead = TimeInterval(config.leadSeconds(forCalendar: meeting.calendar.id))
            guard meeting.start.addingTimeInterval(-lead) <= now, now < meeting.end else { return false }
            // handled — уже записано, либо стоп был окончательным. rearmable — стоп no_call или sleep:
            // стартуем снова, только когда созвон правда пошёл, иначе это была бы та же пустая запись.
            if handled.contains(meeting.key) { return false }
            if rearmable.contains(meeting.key) { return callActive }
            return true
        }

        guard let current else {
            guard let first = candidates.min(by: { precedes($0, $1, order: order) }) else { return .none }
            return .start(first)
        }
        // Ручную запись авто-логика не прерывает никогда (§5 п.4).
        guard current.trigger == .calendar else { return .none }
        // Встречи впритык (§5 п.2): переключаемся в B.start, а не в B.start − lead — пре-ролл B
        // остаётся хвостом A, пока A ещё может идти. B должен начаться позже и самой записи (иначе
        // поздний старт посреди двух встреч тут же перескакивал бы с выбранной), и её события (иначе
        // ничья по календарям, решённая на пре-ролле, переигрывалась бы в момент start).
        let since = max(current.startedAt, current.key?.start ?? current.startedAt)
        let next = candidates.filter { $0.key != current.key && $0.start <= now && $0.start > since }
        guard let target = next.min(by: { precedes($0, $1, order: order) }) else { return .none }
        return .switchTo(target)
    }

    /// Ровно одно событие включённого календаря идёт прямо сейчас (`start ≤ now < end`) — к нему
    /// привязывается ручная запись. Ноль или несколько — nil: угадывать нельзя, запись уйдёт в Manual/.
    /// auto_record и handled не важны: это не старт, а только папка и метаданные.
    public static func currentMeeting(now: Date, meetings: [Meeting], config: Config) -> Meeting? {
        let order = config.calendars
        let live = dedupe(meetings, calendarOrder: order).filter {
            isRecordable($0, order: order) && $0.start <= now && now < $0.end
        }
        return live.count == 1 ? live.first : nil
    }

    /// Что будет записано в ближайшие `hours` часов: `end > now` и `start < now + hours`,
    /// `recordAt = start − lead(календаря)`. Уже идущие события тоже в списке: поздний старт их запишет.
    /// auto_record выключен — пусто: записано не будет ничего (`decide` тоже молчит).
    public static func upcoming(
        now: Date, hours: Int, meetings: [Meeting], config: Config
    ) -> [UpcomingItem] {
        guard config.autoRecord else { return [] }
        let order = config.calendars
        let horizon = now.addingTimeInterval(TimeInterval(hours) * 3600)
        return dedupe(meetings, calendarOrder: order)
            .filter { isRecordable($0, order: order) && $0.end > now && $0.start < horizon }
            .sorted { precedes($0, $1, order: order) }
            .map { meeting in
                let lead = TimeInterval(config.leadSeconds(forCalendar: meeting.calendar.id))
                return UpcomingItem(
                    eventId: meeting.eventId, title: meeting.title,
                    calendar: CalendarRef(id: meeting.calendar.id, title: meeting.calendar.title),
                    start: meeting.start, end: meeting.end, recordAt: meeting.start.addingTimeInterval(-lead))
            }
    }

    /// Календарь включён, и событие из тех, что пишем.
    private static func isRecordable(_ meeting: Meeting, order: [String]) -> Bool {
        order.contains(meeting.calendar.id) && shouldRecord(meeting)
    }

    /// Порядок выбора: раньше start (§5 п.3), затем календарь раньше в списке, затем eventId — чтобы
    /// решение не зависело от порядка, в котором EventKit отдал события.
    private static func precedes(_ lhs: Meeting, _ rhs: Meeting, order: [String]) -> Bool {
        (lhs.start, rank(lhs.calendar.id, in: order), lhs.eventId)
            < (rhs.start, rank(rhs.calendar.id, in: order), rhs.eventId)
    }

    /// Позиция календаря в списке; незнакомые — в конец.
    private static func rank(_ calendarId: String, in order: [String]) -> Int {
        order.firstIndex(of: calendarId) ?? Int.max
    }
}
