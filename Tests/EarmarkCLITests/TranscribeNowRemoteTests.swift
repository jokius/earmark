import EarmarkCore
import Foundation
import Synchronization
import Testing

@testable import EarmarkCLI

/// Своя support-папка процесса (EARMARK_HOME): config.json, remote-token и пустой models/.
/// Настоящий ~/Library/Application Support/earmark тест не видит.
private struct Home {
    enum Token { case valid, missing, insecure }

    let dir: URL

    init(token: Token) throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "earmark-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        let file = dir.appending(path: "remote-token")
        switch token {
        case .valid, .insecure:
            try Data("\(FakeWhisper.token)\n".utf8).write(to: file)
            try FileManager.default.setAttributes(
                [.posixPermissions: token == .valid ? 0o600 : 0o644], ofItemAtPath: file.path)
        case .missing: break
        }
    }

    var models: URL { dir.appending(path: "models") }
    var configStore: ConfigStore { ConfigStore(url: dir.appending(path: "config.json")) }

    /// VAD вне бандла приложения ищется по EARMARK_VAD_MODEL; здесь его нет.
    var environment: [String: String] {
        ["EARMARK_HOME": dir.path, "EARMARK_VAD_MODEL": dir.appending(path: "no-vad.bin").path]
    }

    /// Удалённый режим на `url` (remote: false — режим выключен); записи — в recordings_dir фикстуры.
    func configure(_ fixture: RecordingFixture, url: String, remote: Bool = true) throws {
        var values: [String: ConfigValue] = [
            "recordings_dir": .string(fixture.root.path), "transcription.language": .string("ru"),
        ]
        if remote {
            values["transcription.remote.enabled"] = .bool(true)
            values["transcription.remote.url"] = .string(url)
        }
        try configStore.save(Config(values: values))
    }

    /// Окружение подхвачено: иначе тест пошёл бы в настоящий supportDir пользователя.
    func requireActive() throws {
        try #require(
            EarmarkPaths.supportDir.resolvingSymlinksInPath().path == dir.resolvingSymlinksInPath().path,
            "EARMARK_HOME не подхвачен")
    }

    var modelsIsEmpty: Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: models.path))?.isEmpty == true
    }
}

/// Переменные окружения общие для процесса: ставим на время тела и возвращаем прежние значения.
/// Сьют поэтому .serialized — два теста с разными EARMARK_HOME не пересекаются.
private func withEnvironment<T>(_ values: [String: String], _ body: () async throws -> T) async throws -> T {
    let saved = values.keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
    for (key, value) in values { setenv(key, value, 1) }
    defer {
        for (key, value) in saved {
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
        }
    }
    return try await body()
}

/// Запуск `earmark transcribe <id> --now [флаги]` в окружении `home`; nil — успех.
private func transcribe(_ home: Home, _ flags: [String] = []) async throws -> EarmarkError? {
    let parsed = try CommandTable.parse(["transcribe", "20261002-1400-a1b2", "--now"] + flags)
    return try await withEnvironment(home.environment) {
        try home.requireActive()
        do {
            _ = try await TranscribeNowCommand.run(parsed, CLIContext(configStore: home.configStore))
            return nil
        } catch {
            return error as? EarmarkError
        }
    }
}

/// Что CLI сделал при запуске из шелла: запуски app и строки stderr.
private final class Shell: Sendable {
    let launches = Mutex(0)
    let stderr = Mutex<[String]>([])

    /// Контекст как у шелла, но app не поднимается: сокета нет, launchApp падает и считается.
    func context(_ home: Home) -> CLIContext {
        CLIContext(
            ipc: IPCClient(
                socket: home.dir.appending(path: "s.sock"),
                launchApp: { [self] in
                    launches.withLock { $0 += 1 }
                    throw CocoaError(.featureUnsupported)
                }),
            configStore: home.configStore,
            output: Output(
                stdout: { _ in /* stdout здесь не проверяем */ },
                stderr: { [self] line in stderr.withLock { $0.append(line) } }, prettyStdout: false))
    }
}

private func tone(_ frame: Int) -> Float { sin(Float(frame) * 0.05) * 0.2 }

@Suite("CLI: earmark transcribe --now в удалённом режиме (EARMARK_HOME)", .serialized)
struct TranscribeNowRemoteTests {
    @Test("токен в EARMARK_HOME, models/ пуст, VAD нет — расшифровано сервером: локальная модель не нужна")
    func remoteWithoutLocalModel() async throws {
        let fixture = try RecordingFixture(left: tone, right: tone)
        let server = try FakeJobServer {
            $0.result = [[FakeSegment(startMs: 0, endMs: 800, text: "с сервера")], []]
        }
        defer { server.stop() }
        let home = try Home(token: .valid)
        try home.configure(fixture, url: server.baseURL.absoluteString)

        let error = try await transcribe(home)

        #expect(error == nil, "\(String(describing: error))")
        let meta = try fixture.meta
        #expect(meta.status == .transcribed)
        let transcript = try EarmarkJSON.decoder.decode(
            Transcript.self, from: Data(contentsOf: fixture.file(RecordingFiles.transcript)))
        #expect(transcript.segments.map(\.text) == ["с сервера"])
        #expect(server.submits.map(\.languages) == ["ru"])
        #expect(server.calls.last == "delete")
        #expect(home.modelsIsEmpty)
    }

    @Test(
        "повторный transcribe --now на расшифрованной записи — файлы каналов переиспользованы, звук не грузится; --force считает заново"
    )
    func secondRunReusesChannels() async throws {
        let fixture = try RecordingFixture(left: tone, right: tone)
        let server = try FakeJobServer {
            $0.result = [[FakeSegment(startMs: 0, endMs: 800, text: "с сервера")], []]
        }
        defer { server.stop() }
        let home = try Home(token: .valid)
        try home.configure(fixture, url: server.baseURL.absoluteString)
        let first = try await transcribe(home)
        try #require(first == nil, "\(String(describing: first))")
        try #require(server.submits.count == 1, "\(server.calls)")
        let afterFirst = server.calls.count

        let second = try await transcribe(home)

        #expect(second == nil, "\(String(describing: second))")
        let again = Array(server.calls.dropFirst(afterFirst))
        #expect(!again.contains { $0.hasPrefix("put") || $0 == "submit" }, "\(again)")
        #expect(try fixture.meta.status == .transcribed)
        let transcript = try EarmarkJSON.decoder.decode(
            Transcript.self, from: Data(contentsOf: fixture.file(RecordingFiles.transcript)))
        #expect(transcript.segments.map(\.text) == ["с сервера"])

        let afterSecond = server.calls.count
        let forced = try await transcribe(home, ["--force"])

        #expect(forced == nil, "\(String(describing: forced))")
        let third = Array(server.calls.dropFirst(afterSecond))
        #expect(third.contains { $0.hasPrefix("put") } && third.contains("submit"), "\(third)")
        #expect(server.submits.count == 2)
    }

    enum Misconfig: String, CaseIterable { case tokenMissing, tokenInsecure, urlEmpty }

    @Test(
        "удалённый режим не настроен — unavailable (69) «waiting for server: …» до захвата: meta не тронута, сервер не тронут",
        arguments: Misconfig.allCases)
    func notConfiguredWaits(_ misconfig: Misconfig) async throws {
        let fixture = try RecordingFixture()
        let server = try FakeJobServer()
        defer { server.stop() }
        let token: Home.Token =
            switch misconfig {
            case .tokenMissing: .missing
            case .tokenInsecure: .insecure
            case .urlEmpty: .valid
            }
        let home = try Home(token: token)
        try home.configure(fixture, url: misconfig == .urlEmpty ? "" : server.baseURL.absoluteString)

        let error = try await transcribe(home)

        #expect(error?.code == "unavailable", "\(String(describing: error))")
        #expect(error?.exitCode == 69)
        let message = error?.message ?? ""
        #expect(message.hasPrefix("waiting for server: "), "«\(message)»")
        let meta = try fixture.meta
        #expect(meta.status == .recorded)
        #expect(meta.transcription.attempts == 0)
        #expect(meta.transcription.error == nil && meta.transcription.errorKind == nil)
        #expect(server.requests.isEmpty, "\(server.calls)")
        #expect(!FileManager.default.fileExists(atPath: fixture.file(RecordingFiles.transcript).path))
    }

    @Test(
        "--local в удалённом режиме — локальный путь: без модели и VAD 69 не про сервер; серверу — рукопожатие и DELETE"
    )
    func localFlag() async throws {
        let fixture = try RecordingFixture(left: tone, right: tone)
        let server = try FakeJobServer()
        defer { server.stop() }
        server.seed(
            "20261002-1400-a1b2", FakeJob(state: "done", progress: 100, lengths: [1, 1], languages: "ru"))
        let home = try Home(token: .valid)
        try home.configure(fixture, url: server.baseURL.absoluteString)

        let error = try await transcribe(home, ["--local"])

        #expect(error?.exitCode == 69, "\(String(describing: error))")
        let message = error?.message ?? ""
        #expect(!message.hasPrefix("waiting for server"), "«\(message)»")
        #expect(server.calls == ["health", "delete"])
        #expect(server.job("20261002-1400-a1b2") == nil)
        let meta = try fixture.meta
        #expect(meta.status == .recorded)
        #expect(meta.transcription.attempts == 0)
    }

    @Test(
        "transcribe <id> --local без --now — в этом процессе, app не нужен: без модели 69, не app_not_running",
        arguments: [true, false])
    func localWithoutNow(remote: Bool) async throws {
        let fixture = try RecordingFixture(left: tone, right: tone)
        let server = try FakeJobServer()
        defer { server.stop() }
        server.seed(
            "20261002-1400-a1b2", FakeJob(state: "done", progress: 100, lengths: [1, 1], languages: "ru"))
        let home = try Home(token: .valid)
        try home.configure(fixture, url: server.baseURL.absoluteString, remote: remote)
        let shell = Shell()

        let code = try await withEnvironment(home.environment) {
            try home.requireActive()
            return await EarmarkCLI.run(
                ["transcribe", "20261002-1400-a1b2", "--local"], context: shell.context(home))
        }

        #expect(code == 69, "\(shell.stderr.withLock { $0 })")
        #expect(shell.launches.withLock { $0 } == 0)
        let envelope = try #require(try shell.stderr.withLock { $0.last }.map(CLIHarness.parse))
        let errorCode = envelope["error"]?["code"]?.stringValue
        #expect(errorCode != nil && errorCode != "app_not_running", "\(envelope)")
        let message = envelope["error"]?["message"]?.stringValue ?? ""
        #expect(!message.hasPrefix("waiting for server"), "«\(message)»")
        // В удалённом режиме — best-effort DELETE задачи после рукопожатия; без него сервер не трогается.
        #expect(server.calls == (remote ? ["health", "delete"] : []), "\(server.calls)")
        let meta = try fixture.meta
        #expect(meta.status == .recorded)
        #expect(meta.transcription.attempts == 0)
        #expect(home.modelsIsEmpty)
    }
}
