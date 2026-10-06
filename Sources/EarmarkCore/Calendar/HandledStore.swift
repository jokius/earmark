// Из Call Reminder (MIT, тот же автор): HandledStore из Sources/ReminderEngine.swift,
// файл вместо UserDefaults.
import Foundation

/// Что планировщик уже сделал с вхождениями событий.
///
/// У ключа три состояния, множества не пересекаются — каждая отметка переводит ключ:
/// - свежий (нет ни там, ни там) — можно стартовать;
/// - handled — больше не стартовать: запись состоялась, её остановили руками или стоп окончательный;
/// - rearmable — стоп no_call или sleep: стартовать снова, если созвон всё-таки пошёл (§5 п.5).
public struct HandledState: Codable, Equatable, Sendable {
    public var handled: Set<OccurrenceKey> = []
    public var rearmable: Set<OccurrenceKey> = []

    public init(handled: Set<OccurrenceKey> = [], rearmable: Set<OccurrenceKey> = []) {
        self.handled = handled
        self.rearmable = rearmable
    }

    /// Только после успешного старта, как в Call Reminder (160e6ae): старт, который не случился,
    /// не должен съесть встречу. Ещё — ручной стоп и ручная запись, перекрывшая окно события.
    public mutating func markHandled(_ key: OccurrenceKey) {
        rearmable.remove(key)
        handled.insert(key)
    }

    public mutating func markRearmable(_ key: OccurrenceKey) {
        handled.remove(key)
        rearmable.insert(key)
    }

    /// Выкидывает ключи старше суток, чтобы state.json не пух: события выбираются на сутки назад.
    ///
    /// Возраст — по более позднему из occurrence и start. Перенесённое вхождение серии хранит
    /// исходный occurrence: встречу перенесли с понедельника на среду — occurrence двухдневной
    /// давности, а сама встреча сегодня. Чистка по одному occurrence выкинула бы её handled посреди
    /// встречи, и планировщик начал бы её второй раз.
    ///
    /// `alive` — ключи событий, которые ещё в выборке драйвера. Многодневное событие со временем
    /// (конференция, поездка) началось больше суток назад, но идёт: без `alive` оно теряло бы handled,
    /// снова становилось кандидатом, и планировщик перезапускал бы запись на каждом reload до самого
    /// конца события. В Call Reminder эту защиту держал prune(keeping:).
    public mutating func prune(now: Date, keeping alive: Set<OccurrenceKey> = []) {
        let cutoff = now.addingTimeInterval(-86_400)
        let isFresh: (OccurrenceKey) -> Bool = {
            alive.contains($0) || max($0.occurrence, $0.start) >= cutoff
        }
        handled = handled.filter(isFresh)
        rearmable = rearmable.filter(isFresh)
    }
}

/// state.json в каталоге поддержки. Не UserDefaults: app — единственный writer, а CLI, doctor и тесты
/// читают обычный файл (изменения UserDefaults из чужого процесса app не видит — урок Call Reminder).
public struct HandledStore: Sendable {
    private let url: URL

    public init(url: URL = EarmarkPaths.stateFile) {
        self.url = url
    }

    /// Нет файла или он битый — пустое состояние. Худшее, что из этого выйдет, — повторный старт уже
    /// записанного события; отказ работать из-за state.json был бы хуже.
    public func load() -> HandledState {
        guard let data = try? Data(contentsOf: url),
            let state = try? EarmarkJSON.decoder.decode(HandledState.self, from: data)
        else { return HandledState() }
        return state
    }

    /// Каталог поддержки при первом сохранении может ещё не существовать, а AtomicFile его не создаёт:
    /// без этого handled не пережил бы первый перезапуск.
    public func save(_ state: HandledState) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try AtomicFile.write(EarmarkJSON.encoder.encode(state), to: url)
    }
}
