import EarmarkCore
import Foundation
import Testing

@testable import EarmarkCLI

@Suite("CLI: earmark move — ручная запись под календарь")
struct CLIMoveCommandTests {
    private let id = "20261002-1400-a1b2"

    @Test("--calendar: в app уходит recording.move с id и calendar_id, ответ app — в конверте как есть")
    func moveToCalendar() async throws {
        let harness = try CLIHarness()
        let reply: JSONValue = [
            "id": .string(id), "path": "/rec/Work/2026-10-02 14-00 Idea",
            "calendar": ["id": "cal-work", "title": "Work"],
        ]
        let app = try harness.startApp { _ in .success(reply) }

        let result = try await harness.run(["move", id, "--calendar", "cal-work"])

        #expect(result.code == 0)
        #expect(result.out?["command"] == .string("move"))
        #expect(result.data == reply)
        #expect(app.requests.map(\.method) == [IPCMethod.recordingMove])
        #expect(app.requests.first?.params == ["id": .string(id), "calendar_id": "cal-work"])
    }

    @Test("--manual: calendar_id null или нет вовсе, ответ app — как есть")
    func moveToManual() async throws {
        let harness = try CLIHarness()
        let reply: JSONValue = [
            "id": .string(id), "path": "/rec/Manual/2026-10-02 14-00 Idea", "calendar": .null,
        ]
        let app = try harness.startApp { _ in .success(reply) }

        let result = try await harness.run(["move", id, "--manual"])

        #expect(result.code == 0)
        #expect(result.data == reply)
        #expect(app.requests.map(\.method) == [IPCMethod.recordingMove])
        let params = try #require(app.requests.first?.params)
        #expect(params["id"] == .string(id))
        let calendar = params["calendar_id"]
        #expect(calendar == nil || calendar == .null, "\(String(describing: calendar))")
    }

    @Test("ошибка app доходит до stderr как есть, со своим кодом выхода")
    func appErrorPassesThrough() async throws {
        let harness = try CLIHarness()
        try harness.startApp { _ in .failure(.busy("transcription in progress")) }

        let result = try await harness.run(["move", id, "--calendar", "cal-work"])

        #expect(result.code == 75)
        #expect(result.out == nil)
        #expect(result.errorCode == "busy")
        #expect(result.err?["error"]?["message"] == .string("transcription in progress"))
    }

    @Test(
        "не ровно одно из --calendar и --manual или пустой --calendar: exit 64, в app ничего не уходит",
        arguments: [
            ["move", "20261002-1400-a1b2"],
            ["move", "20261002-1400-a1b2", "--calendar", "cal-work", "--manual"],
            ["move", "20261002-1400-a1b2", "--calendar", ""],
        ])
    func exactlyOneTarget(argv: [String]) async throws {
        let harness = try CLIHarness()
        let app = try harness.startApp { _ in .success(.null) }

        let result = try await harness.run(argv)

        #expect(result.code == 64)
        #expect(result.errorCode == "invalid_arguments")
        let message = result.err?["error"]?["message"]?.stringValue ?? ""
        // для пустого значения спека дословный текст не задаёт — только что речь о --calendar
        let fragment = argv.contains("") ? "--calendar" : "pass exactly one of --calendar <id> or --manual"
        #expect(message.contains(fragment), "\(message)")
        #expect(app.requests.isEmpty)
    }
}
