import Foundation

// Общие value-типы. Живут отдельно от календаря, записей и стоп-правил, чтобы эти модули
// (задачи 5–8) не зависели друг от друга и писались параллельно.

/// Календарь из EventKit. `account` нужен, чтобы различить два календаря «Work» в разных аккаунтах.
public struct CalendarInfo: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var account: String

    public init(id: String, title: String, account: String) {
        self.id = id
        self.title = title
        self.account = account
    }
}

/// Ссылка на календарь в meta.json и выводе CLI: без аккаунта, он там не нужен.
public struct CalendarRef: Codable, Equatable, Sendable {
    public var id: String
    public var title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// Событие, к которому привязана запись. `externalId` переживает пересинхронизацию календаря,
/// `id` (calendarItemIdentifier) — нет, поэтому храним оба.
public struct EventRef: Codable, Equatable, Sendable {
    public var id: String
    public var externalId: String
    public var start: Date
    public var end: Date

    public init(id: String, externalId: String, start: Date, end: Date) {
        self.id = id
        self.externalId = externalId
        self.start = start
        self.end = end
    }
}

public enum RecordingTrigger: String, Codable, Sendable { case calendar, manual }

/// Причина остановки — в meta.json. `recovered` ставит восстановление (Task 13) и после крэша,
/// и после выхода из app посреди записи: выход только закрывает CAF и оставляет manifest,
/// своей причины у него нет.
public enum StopReason: String, Codable, Sendable {
    case callEnded = "call_ended", eventOver = "event_over", noCall = "no_call", silence
    case maxDuration = "max_duration", nextEvent = "next_event", sleep, manual, recovered
}

/// Строка `earmark upcoming`: что и когда будет записано.
public struct UpcomingItem: Codable, Equatable, Sendable {
    public var eventId: String
    public var title: String
    public var calendar: CalendarRef
    public var start: Date
    public var end: Date
    /// start − lead этого календаря: момент, когда запись реально начнётся.
    public var recordAt: Date

    public init(eventId: String, title: String, calendar: CalendarRef, start: Date, end: Date, recordAt: Date)
    {
        self.eventId = eventId
        self.title = title
        self.calendar = calendar
        self.start = start
        self.end = end
        self.recordAt = recordAt
    }
}
