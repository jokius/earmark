import EarmarkCore
import Foundation
import Testing

@Suite("HandledStore: state.json")
struct HandledStoreTests {
    /// now тестов; целые секунды, как у дат EventKit.
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    /// Ключ вхождения возрастом `age` секунд; start по умолчанию совпадает с occurrence.
    private func key(_ series: String, age: TimeInterval, startAge: TimeInterval? = nil) -> OccurrenceKey {
        OccurrenceKey(
            seriesId: series, occurrence: now.addingTimeInterval(-age),
            start: now.addingTimeInterval(-(startAge ?? age)))
    }

    /// Свой каталог на тест: Swift Testing гоняет тесты параллельно.
    private func stateURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("earmark-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }

    @Test("сохранили — прочитали то же самое")
    func roundTrip() throws {
        let url = try stateURL()
        var state = HandledState()
        state.markHandled(key("standup", age: 3600))
        state.markRearmable(key("planning", age: 600))
        try HandledStore(url: url).save(state)
        #expect(HandledStore(url: url).load() == state)
    }

    @Test("нет файла или он битый — пустое состояние, а не ошибка")
    func missingOrCorrupt() throws {
        let url = try stateURL()
        #expect(HandledStore(url: url).load() == HandledState())
        try Data("{\"handled\": [".utf8).write(to: url)
        #expect(HandledStore(url: url).load() == HandledState())
    }

    @Test("отметка переводит ключ из одного множества в другое")
    func marks() {
        let item = key("standup", age: 60)
        var state = HandledState()
        state.markRearmable(item)
        #expect(state == HandledState(rearmable: [item]))
        state.markHandled(item)
        #expect(state == HandledState(handled: [item]))
        state.markRearmable(item)
        #expect(state == HandledState(rearmable: [item]))
    }

    @Test("prune выкидывает ключи старше суток из обоих множеств")
    func prune() {
        let fresh = key("fresh", age: 23 * 3600)
        let edge = key("edge", age: 86_400)  // ровно сутки — ещё держим
        let stale = key("stale", age: 86_401)
        let staleRearm = key("stale-rearm", age: 30 * 3600)
        let freshRearm = key("fresh-rearm", age: 3600)
        // Вхождение серии перенесли на двое суток позже: occurrence старый, а встреча идёт сейчас.
        let moved = key("moved", age: 48 * 3600, startAge: 600)
        var state = HandledState(handled: [fresh, edge, stale, moved], rearmable: [staleRearm, freshRearm])
        state.prune(now: now)
        #expect(state == HandledState(handled: [fresh, edge, moved], rearmable: [freshRearm]))
    }

    @Test("prune не трогает старые ключи из keeping: событие ещё в выборке")
    func pruneKeepsAlive() {
        // Многодневная конференция со временем началась 30 ч назад и ещё идёт.
        let aliveHandled = key("conference", age: 30 * 3600)
        let aliveRearm = key("offsite", age: 50 * 3600)
        let staleHandled = key("stale", age: 30 * 3600)
        let staleRearm = key("stale-rearm", age: 50 * 3600)
        // В keeping, но не в состоянии: prune ничего не добавляет.
        let ghost = key("ghost", age: 40 * 3600)
        var state = HandledState(handled: [aliveHandled, staleHandled], rearmable: [aliveRearm, staleRearm])
        state.prune(now: now, keeping: [aliveHandled, aliveRearm, ghost])
        #expect(state == HandledState(handled: [aliveHandled], rearmable: [aliveRearm]))
    }

    @Test("save создаёт недостающие каталоги: первый запуск без ~/Library/…/earmark")
    func saveCreatesParentDirectory() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("earmark-state-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("nested/deeper", isDirectory: true)
            .appendingPathComponent("state.json")
        var state = HandledState()
        state.markHandled(key("standup", age: 600))
        try HandledStore(url: url).save(state)
        #expect(HandledStore(url: url).load() == state)
    }
}
