import EarmarkCore
import Foundation
import Testing

@testable import EarmarkCLI

@Suite("CLI: команды через app")
struct CLIAppCommandsTests {
    @Test("status без app: app_running=false, exit 0, app не поднимается")
    func statusWithoutApp() async throws {
        let harness = try CLIHarness()
        let result = try await harness.run(["status"])
        #expect(result.code == 0)
        #expect(result.out?["schema_version"] == .number(1))
        #expect(result.out?["command"] == .string("status"))
        #expect(result.data?["app_running"] == .bool(false))
        #expect(result.err == nil)
        #expect(harness.launchCount == 0)
        #expect(!harness.context().ipc.isAppRunning())
    }

    /// Поднятый app начал бы поздней авто-записью идущую встречу — «стоп» стартовал бы запись.
    @Test("stop без app: data null, exit 0, app не поднимается")
    func stopWithoutApp() async throws {
        let harness = try CLIHarness()
        let result = try await harness.run(["stop"])
        #expect(result.code == 0)
        #expect(result.out?["command"] == .string("stop"))
        #expect(result.data == .null)
        #expect(result.err == nil)
        #expect(harness.launchCount == 0)
    }

    @Test("status с app: data от app проходит как есть")
    func statusWithApp() async throws {
        let harness = try CLIHarness()
        let status: JSONValue = .object([
            "app_running": .bool(true), "state": .string("recording"), "warnings": .array([]),
        ])
        let app = try harness.startApp { _ in .success(status) }
        let result = try await harness.run(["status"])
        #expect(result.code == 0)
        #expect(result.data == status)
        #expect(app.requests.map(\.method) == [IPCMethod.status])
        #expect(harness.context().ipc.isAppRunning())
    }

    @Test("start/stop: params уходят в app, ответ возвращается в конверте")
    func startAndStop() async throws {
        let harness = try CLIHarness()
        let id: JSONValue = .string("20261002-1400-a1b2")
        let app = try harness.startApp { request in
            switch request.method {
            case IPCMethod.recordingStart:
                .success(.object(["id": id, "title": request.params["title"] ?? .null]))
            case IPCMethod.recordingStop: .success(.object(["id": id, "status": .string("recorded")]))
            default: .failure(.invalidArguments("unexpected method \(request.method)"))
            }
        }
        let started = try await harness.run(["start", "--title", "Daily sync"])
        #expect(started.code == 0)
        #expect(started.out?["command"] == .string("start"))
        #expect(started.data?["title"] == .string("Daily sync"))

        let stopped = try await harness.run(["stop"])
        #expect(stopped.code == 0)
        #expect(stopped.data?["status"] == .string("recorded"))
        #expect(app.requests.map(\.method) == [IPCMethod.recordingStart, IPCMethod.recordingStop])
    }

    @Test("ошибка app доходит до stderr со своим кодом выхода")
    func appErrorPassesThrough() async throws {
        let harness = try CLIHarness()
        try harness.startApp { _ in .failure(.busy("finalizing the recording")) }
        let result = try await harness.run(["stop"])
        #expect(result.code == 75)
        #expect(result.out == nil)
        #expect(result.errorCode == "busy")
        #expect(result.err?["error"]?["exit_code"] == .number(75))
    }

    @Test("app не поднялся: app_not_running, exit 3")
    func appNotRunningWhenLaunchFails() async throws {
        let harness = try CLIHarness()
        let result = try await harness.run(["start"])
        #expect(result.code == 3)
        #expect(result.errorCode == "app_not_running")
        #expect(harness.launchCount == 1)
    }

    @Test("автозапуск: CLI ждёт, пока app поднимет сокет")
    func autoLaunchWaitsForSocket() async throws {
        let harness = try CLIHarness()
        let result = try await harness.run(["calendars"]) {
            // Как настоящий app: сокет появляется не сразу после open, а через полсекунды.
            Thread.detachNewThread {
                Thread.sleep(forTimeInterval: 0.5)
                _ = try? harness.startApp { _ in .success(.array([])) }
            }
        }
        #expect(result.code == 0)
        #expect(result.data == .array([]))
        #expect(harness.launchCount == 1)
    }

    @Test(
        "неверные аргументы: exit 64, в app ничего не уходит",
        arguments: [
            ["upcoming", "--hours", "abc"], ["upcoming", "--hours", "0"], ["config", "reset"],
            ["config", "reset", "lead_seconds", "--all"], ["calendars", "enable"], ["frobnicate"],
        ])
    func invalidArguments(argv: [String]) async throws {
        let harness = try CLIHarness()
        let app = try harness.startApp { _ in .success(.null) }
        let result = try await harness.run(argv)
        #expect(result.code == 64)
        #expect(result.errorCode == "invalid_arguments")
        #expect(app.requests.isEmpty)
    }

    @Test("calendars enable/disable: список с диска, порядок сохранён, в app уходит config.set")
    func calendarsKeepOrder() async throws {
        let harness = try CLIHarness()
        try harness.setConfig(["calendars": .stringList(["cal-work", "cal-personal"])])
        let app = try harness.startApp { request in
            .success(.object(["key": .string("calendars"), "new": request.params["value"] ?? .null]))
        }
        let steps = [
            ["calendars", "enable", "cal-team"], ["calendars", "enable", "cal-work"],
            ["calendars", "disable", "cal-work"],
        ]
        for argv in steps {
            #expect(try await harness.run(argv).code == 0)
        }
        #expect(app.requests.allSatisfy { $0.method == IPCMethod.configSet })
        #expect(app.requests.allSatisfy { $0.params["key"] == .string("calendars") })
        let sent = try app.requests.map { request in
            let raw = request.params["value"]?.stringValue ?? ""
            return try JSONDecoder().decode([String].self, from: Data(raw.utf8))
        }
        // config.json пишет только app, тест его не меняет: каждый шаг считается от исходного списка.
        #expect(sent[0] == ["cal-work", "cal-personal", "cal-team"])
        #expect(sent[1] == ["cal-work", "cal-personal"])
        #expect(sent[2] == ["cal-personal"])
    }

    @Test("doctor: отчёт app + проверка whisper.framework; не готов — exit 1 и отчёт в stdout")
    func doctorNotReady() async throws {
        let harness = try CLIHarness()
        let check: JSONValue = .object([
            "name": .string("microphone"), "ok": .bool(false), "detail": .string("denied"),
        ])
        let report: JSONValue = .object(["ready": .bool(false), "checks": .array([check])])
        let app = try harness.startApp { _ in .success(report) }
        let result = try await harness.run(["doctor", "--audio-test"])
        #expect(result.code == 1)
        #expect(result.data?["ready"] == .bool(false))
        let names = result.data?["checks"]?.items.compactMap { $0["name"]?.stringValue }
        #expect(names == ["microphone", "whisper_framework"])
        #expect(app.requests.first?.params["audio_test"] == .bool(true))
    }

    @Test("whisper.framework ищется в ../Frameworks от настоящего бинаря, симлинк раскрывается")
    func whisperFrameworkNextToBinary() throws {
        let harness = try CLIHarness()
        let contents = harness.dir.appendingPathComponent("Earmark.app/Contents")
        let binary = contents.appendingPathComponent("Helpers/earmark")
        let framework = contents.appendingPathComponent("Frameworks/whisper.framework")
        try FileManager.default.createDirectory(
            at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: binary)
        let link = harness.dir.appendingPathComponent("earmark")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: binary)
        #expect(AppCommands.localChecks(executable: link).map(\.ok) == [false])

        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
        #expect(AppCommands.localChecks(executable: link).map(\.ok) == [true])
    }

    @Test("transcribe: без --now — в очередь app; с --now — никогда не в app")
    func transcribeRouting() async throws {
        let harness = try CLIHarness()
        let id = "20261002-1400-a1b2"
        let app = try harness.startApp { _ in .success(.object(["position": .number(1)])) }
        let queued = try await harness.run(["transcribe", id, "--force"])
        #expect(queued.code == 0)
        #expect(app.requests.first?.method == IPCMethod.transcriptionEnqueue)
        #expect(app.requests.first?.params == .object(["id": .string(id), "force": .bool(true)]))

        // --now — воркер в этом процессе: в сокет он не ходит. Записи нет — значит, ошибка.
        let now = try await harness.run(["transcribe", id, "--now"])
        #expect(now.code != 0)
        #expect(now.err != nil)
        #expect(app.requests.count == 1)
    }
}
