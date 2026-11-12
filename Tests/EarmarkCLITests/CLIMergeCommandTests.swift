import EarmarkCore
import Foundation
import Testing

@testable import EarmarkCLI

@Suite("CLI: earmark merge — склейка с предыдущей записью")
struct CLIMergeCommandTests {
    private let id = "20261002-1432-b2c3"

    @Test("в app уходит recording.merge с {id}, ответ app — в конверте как есть")
    func merge() async throws {
        let harness = try CLIHarness()
        let reply: JSONValue = [
            "id": "20261002-1400-a1b2", "merged": .string(id),
            "path": "/rec/Work/2026-10-02 14-00 Daily sync",
        ]
        let app = try harness.startApp { _ in .success(reply) }

        let result = try await harness.run(["merge", id])

        #expect(result.code == 0)
        #expect(result.out?["command"] == .string("merge"))
        #expect(result.data == reply)
        #expect(IPCMethod.recordingMerge == "recording.merge")
        #expect(app.requests.map(\.method) == [IPCMethod.recordingMerge])
        #expect(app.requests.first?.params == ["id": .string(id)])
    }

    @Test(
        "ошибка app доходит до stderr как есть, со своим кодом выхода",
        arguments: [
            EarmarkError.notFound(
                "no recording ended within 10 minutes before 20261002-1432-b2c3 to attach it to"),
            .busy("20261002-1400-a1b2 is being transcribed; try again when it is done"),
        ])
    func appErrorPassesThrough(error: EarmarkError) async throws {
        let harness = try CLIHarness()
        try harness.startApp { _ in .failure(error) }

        let result = try await harness.run(["merge", id])

        #expect(result.code == error.exitCode)
        #expect(result.out == nil)
        #expect(result.errorCode == error.code)
        #expect(result.err?["error"]?["message"] == .string(error.message))
    }

    @Test("без id — invalid_arguments, exit 64, в app ничего не уходит")
    func missingID() async throws {
        let harness = try CLIHarness()
        let app = try harness.startApp { _ in .success(.null) }

        let result = try await harness.run(["merge"])

        #expect(result.code == 64)
        #expect(result.errorCode == "invalid_arguments")
        #expect(app.requests.isEmpty)
    }
}
