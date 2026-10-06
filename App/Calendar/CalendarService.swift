// Из Call Reminder (MIT, тот же автор): Sources/CalendarService.swift.
// Отличия: окно выборки задаёт вызывающий (а не «до полуночи»), события всех календарей — фильтр
// включённых делает планировщик, ключ вхождения со start и без calendarID, наблюдение за
// EKEventStoreChanged — с init, а не после первого гранта. Статус и запрос прав — в Permissions.
import EarmarkCore
import EventKit
import Foundation

/// Единственная точка чтения EventKit (статус и запрос прав — в Permissions). Дальше этого файла
/// события не текут: планировщик живёт в EarmarkCore и тестируется без календаря и без прав.
@MainActor
final class CalendarService {
    private let store = EKEventStore()
    private var observer: (any NSObjectProtocol)?

    /// Любое изменение календаря и смена прав: заголовок EKEventStore.h обещает уведомление и тогда,
    /// когда пользователь выдал или отозвал доступ.
    var onChange: (() -> Void)?

    init() {
        // Наблюдаем сразу, а не после гранта, как было в Call Reminder: иначе доступ, выданный
        // позже в System Settings, app не замечал бы до перезапуска.
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.storeChanged() }
        }
    }

    // Обычный deinit не компилируется в Swift 6.2+: обращение к не-Sendable свойству из nonisolated deinit.
    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func storeChanged() {
        // Store, созданный до гранта, может так и остаться пустым. reset() — «как будто создали
        // новый» (EKEventStore.h); зовём, только пока календарей не видно, чтобы не терять кэш зря.
        if store.calendars(for: .event).isEmpty { store.reset() }
        onChange?()
    }

    /// Ключ — только `id`: у пользователя бывает несколько календарей с одинаковым названием.
    func calendars() -> [CalendarInfo] {
        store.calendars(for: .event)
            .map(Self.info(_:))
            .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
    }

    /// События всех календарей, пересекающие [start, end). Окно задаёт планировщик: только
    /// «сегодня» терять нельзя — встреча сразу после полуночи пропадала (воспроизведено).
    func meetings(from start: Date, to end: Date) -> [Meeting] {
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            // Предикат включает событие, закончившееся ровно в начале окна, — замерено.
            .filter { $0.endDate > start }
            .compactMap(Self.meeting(from:))
            .sorted { $0.start < $1.start }
    }

    private static func info(_ calendar: EKCalendar) -> CalendarInfo {
        CalendarInfo(
            id: calendar.calendarIdentifier, title: calendar.title, account: calendar.source?.title ?? "—")
    }

    private static func meeting(from event: EKEvent) -> Meeting? {
        guard let calendar = event.calendar else { return nil }
        // Явные типы обязательны: свойства null_unspecified, без них `??` даёт Optional.
        let start: Date = event.startDate
        let end: Date = event.endDate
        let occurrence: Date = event.occurrenceDate ?? start
        let external: String? = event.calendarItemExternalIdentifier
        let rawID: String = external ?? event.calendarItemIdentifier
        let eventID: String = event.eventIdentifier ?? event.calendarItemIdentifier
        let title: String = event.title ?? ""
        return Meeting(
            // Не eventIdentifier: он общий у всей серии и меняется (/RID=), когда повтор переносят.
            // start в ключе — чтобы перенесённое вхождение сработало снова; calendarID нет — одно
            // событие в двух календарях даёт одну запись (§5).
            key: OccurrenceKey(
                seriesId: rawID.components(separatedBy: "/RID=")[0], occurrence: occurrence, start: start),
            eventId: eventID,
            externalId: external ?? "",
            title: title.isEmpty ? "Untitled" : title,
            calendar: info(calendar),
            start: start,
            end: end,
            isAllDay: event.isAllDay,
            // EKEvent.h: единственный надёжный статус — canceled.
            isCanceled: event.status == .canceled,
            participation: participation(event))
    }

    private static func participation(_ event: EKEvent) -> Participation {
        // isCurrentUser — единственный надёжный способ найти себя: у Exchange несколько SMTP-алиасов.
        if let me = event.attendees?.first(where: \.isCurrentUser) {
            switch me.participantStatus {
            case .accepted: return .accepted
            case .declined: return .declined
            case .tentative: return .tentative
            case .pending: return .pending
            default: return .unknown
            }
        }
        if event.organizer?.isCurrentUser == true { return .organizer }
        // Без участников — своё событие. Участники есть, а меня нет — рассылка на группу.
        return (event.attendees ?? []).isEmpty ? .none : .unknown
    }
}
