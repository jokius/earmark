// Из Call Reminder (MIT, тот же автор): Sources/Meeting.swift — с правками из §5 спеки.
import Foundation

/// Ключ конкретного вхождения события: по нему планировщик помнит, что уже записал.
///
/// Не `eventIdentifier`: он общий у всей серии, а у перенесённого вхождения к нему дописывается
/// `/RID=…`. В Call Reminder замерено: 712 событий дали 328 разных eventIdentifier и 712 таких ключей.
///
/// Две правки против Call Reminder:
/// - calendarID в ключ не входит: одно событие в двух включённых календарях — одна запись, а не две;
/// - start входит: occurrenceDate переживает перенос вхождения, и без start перенесённая встреча
///   считалась бы обработанной в старом слоте и не записалась бы в новом.
///
/// Даты — целые секунды, как их отдаёт EventKit: EarmarkJSON пишет ISO 8601 без долей секунды,
/// и ключ с долями после state.json перестал бы совпадать сам с собой.
public struct OccurrenceKey: Codable, Hashable, Sendable {
    /// calendarItemExternalIdentifier до "/RID=" (или calendarItemIdentifier, если внешнего нет).
    public var seriesId: String
    /// occurrenceDate ?? start — исходно запланированный слот.
    public var occurrence: Date
    public var start: Date

    public init(seriesId: String, occurrence: Date, start: Date) {
        self.seriesId = seriesId
        self.occurrence = occurrence
        self.start = start
    }
}

/// Мой ответ на приглашение. Себя CalendarService ищет через `isCurrentUser`: у Exchange несколько
/// адресов-алиасов, и сравнивать почту руками бессмысленно (замер Call Reminder).
public enum Participation: String, Codable, Sendable {
    /// `organizer` — приглашение моё; `none` — участников нет, это моё событие;
    /// `unknown` — участники есть, но меня среди них не нашли или статус непонятен.
    case accepted, tentative, declined, pending, organizer, unknown, none
}

/// Событие календаря в терминах earmark. EventKit дальше CalendarService (app) не течёт,
/// поэтому планировщик тестируется без календаря и без прав доступа.
public struct Meeting: Codable, Equatable, Sendable {
    public var key: OccurrenceKey
    /// eventIdentifier — для meta.event.id.
    public var eventId: String
    /// calendarItemExternalIdentifier целиком — для meta.event.external_id.
    public var externalId: String
    public var title: String
    public var calendar: CalendarInfo
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    /// Заголовок EKEvent.h честно пишет, что из статусов события надёжен только canceled.
    public var isCanceled: Bool
    public var participation: Participation

    public init(
        key: OccurrenceKey, eventId: String, externalId: String, title: String, calendar: CalendarInfo,
        start: Date, end: Date, isAllDay: Bool, isCanceled: Bool, participation: Participation
    ) {
        self.key = key
        self.eventId = eventId
        self.externalId = externalId
        self.title = title
        self.calendar = calendar
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.isCanceled = isCanceled
        self.participation = participation
    }

    /// Ссылка на событие для manifest и meta.json.
    public var eventRef: EventRef {
        EventRef(id: eventId, externalId: externalId, start: start, end: end)
    }
}

/// Пишем всё, кроме событий на весь день, отменённых и отклонённых мной (§5 спеки).
/// tentative пишем: лишняя запись дешевле пропущенной. По availability не фильтруем: в Call Reminder
/// правило «свободен и без приглашения» прятало настоящие личные события (f7b7e55).
public func shouldRecord(_ meeting: Meeting) -> Bool {
    !meeting.isAllDay && !meeting.isCanceled && meeting.participation != .declined
}
