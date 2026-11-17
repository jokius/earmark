import EarmarkCore
import Foundation
import Synchronization
import Testing

/// Канал, у которого отправляемый срез начинается не с нуля: тело обязано быть ровно этим срезом.
private let channel: [Float] = [9, -9, 0.5, Float(123.456), -0.25, Float(1e-7), 1, -1, 7]
private let slice = channel[2..<7]

private func seconds(since start: Date) -> TimeInterval { Date().timeIntervalSince(start) }

/// Ошибка удалённого сервера по контракту: remote_failed, exit 69.
private func expectRemoteFailed(
    _ error: EarmarkError?, containing text: String? = nil, sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(error?.code == "remote_failed", "\(String(describing: error))", sourceLocation: sourceLocation)
    #expect(error?.exitCode == 69, sourceLocation: sourceLocation)
    if let text {
        #expect(
            error?.message.contains(text) == true, "в \(String(describing: error?.message)) нет «\(text)»",
            sourceLocation: sourceLocation)
    }
}

/// Каждый запрос, кроме рукопожатия /v1/health, несёт токен клиента.
private func expectBearer(_ server: FakeWhisperServer, sourceLocation: SourceLocation = #_sourceLocation) {
    let requests = server.requests.filter { $0.path != "/v1/health" }
    #expect(!requests.isEmpty, sourceLocation: sourceLocation)
    for request in requests {
        #expect(
            request.headers["authorization"] == "Bearer \(FakeWhisper.token)", "\(request.path)",
            sourceLocation: sourceLocation)
    }
}

/// Рукопожатие /v1/health: GET с nonce из 64 hex в нижнем регистре, токен не уходит никак —
/// ни заголовком, ни в query, ни в теле.
private func expectHandshake(_ request: FakeRequest, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(request.method == "GET", sourceLocation: sourceLocation)
    #expect(request.path == "/v1/health", sourceLocation: sourceLocation)
    let nonce = request.query["nonce"] ?? ""
    #expect(nonce.wholeMatch(of: /[0-9a-f]{64}/) != nil, "nonce «\(nonce)»", sourceLocation: sourceLocation)
    #expect(request.headers["authorization"] == nil, sourceLocation: sourceLocation)
    let token = FakeWhisper.token
    #expect(
        !request.headers.values.contains { $0.contains(token) }
            && !request.query.values.contains { $0.contains(token) }
            && request.body.range(of: Data(token.utf8)) == nil,
        "токен ушёл в рукопожатии: \(request.headers) \(request.query)", sourceLocation: sourceLocation)
}

private let notProven = "server did not prove it knows the token"

/// Обычный /v1/full на `language`, с которым клиент ходит по умолчанию в тестах.
private func full(
    _ client: RemoteWhisperClient, _ samples: ArraySlice<Float> = slice, language: String = "ru",
    progress: ProgressLog = ProgressLog(), abort: AbortFlag = AbortFlag()
) async throws(EarmarkError) -> [RemoteSegment] {
    try await client.full(
        samples, language: language, threads: 4, progress: { progress.append($0) },
        shouldAbort: { abort.isRaised })
}

/// Один вызов клиента на эндпоинт; shouldAbort, где он есть, опущен.
private func call(_ endpoint: RemoteWhisperClientFailureTests.Endpoint, _ client: RemoteWhisperClient)
    async throws(EarmarkError)
{
    switch endpoint {
    case .health: _ = try await client.health()
    case .vad: _ = try await client.vad(slice, threads: 4)
    case .language: _ = try await client.language(slice, threads: 4)
    case .full: _ = try await full(client)
    }
}

@Suite("RemoteTranscription.client: клиент из конфига и токен-файла ходит с правильным токеном")
struct RemoteTranscriptionWiringTests {
    @Test(
        "токен — первая строка файла без пробелов по краям: им сверен proof и он же в Bearer; URL с хвостовым / ведёт на те же пути"
    )
    func tokenFromFile() async throws {
        let server = try FakeWhisper.server()
        defer { server.stop() }
        let supportDir = FileManager.default.temporaryDirectory.appending(
            path: "earmark-token-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        let file = supportDir.appending(path: "remote-token")
        try Data("  \(FakeWhisper.token) \t\nsecond-line\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        var config = Config()
        try config.set("transcription.remote.enabled", raw: "true")
        try config.set("transcription.remote.url", raw: server.baseURL.absoluteString + "/")

        let client = try #require(RemoteTranscription.client(config: config, supportDir: supportDir)).get()
        _ = try await client.health()
        _ = try await client.vad(slice, threads: 4)

        #expect(server.paths == ["/v1/health", "/v1/vad"])
        expectHandshake(try #require(server.requests.first))
        expectBearer(server)
    }
}

@Suite("RemoteWhisperClient: запросы и ответы контракта v1")
struct RemoteWhisperClientContractTests {
    @Test("стандартные таймауты 5/120/30/600 с и коммит whisper.cpp, с которым доказан паритет")
    func constants() {
        #expect(
            RemoteWhisperClient.Timeouts.standard
                == RemoteWhisperClient.Timeouts(health: 5, request: 120, idle: 30, stall: 600))
        #expect(RemoteWhisperClient.whisperCommit == "927cfce34f31707e17f2bff35c349632fb9e2c3a")
        let client = RemoteWhisperClient(
            baseURL: URL(string: "http://gpu-box.local:8178")!, token: "t")
        #expect(client.baseURL.absoluteString == "http://gpu-box.local:8178")
    }

    @Test(
        "health: GET /v1/health?nonce=<64 hex> без Authorization, proof сошёлся, snake_case-ключи разбираются"
    )
    func health() async throws {
        let server = try FakeWhisper.server(health: {
            FakeWhisper.health(for: $0, commit: "abc", model: "m1", vad: "v1")
        })
        defer { server.stop() }

        let health = try await FakeWhisper.client(server).health()

        #expect(health.whisper == "1.9.4")
        #expect(health.commit == "abc")
        #expect(health.modelSha256 == "m1")
        #expect(health.vadSha256 == "v1")
        #expect(health.gpu == "Test GPU 24 GB")
        #expect(server.paths == ["/v1/health"])
        expectHandshake(try #require(server.requests.first))
    }

    @Test("health: на каждый вызов свежий nonce — записанный чужой proof не годится дважды")
    func freshNonce() async throws {
        let server = try FakeWhisper.server()
        defer { server.stop() }
        let client = FakeWhisper.client(server)

        _ = try await client.health()
        _ = try await client.health()
        _ = try await FakeWhisper.client(server).checkCompatible()

        let nonces = server.requests.map { $0.query["nonce"] ?? "" }
        #expect(nonces.count == 3)
        #expect(Set(nonces).count == 3, "\(nonces)")
        server.requests.forEach { expectHandshake($0) }
    }

    @Test(
        "health: proof не тот, чужой, пустой или его нет — remote_failed «server did not prove it knows the token»",
        arguments: FakeWhisper.Proof.forged)
    func unprovenHealth(proof: FakeWhisper.Proof) async throws {
        let server = try FakeWhisper.server(health: { FakeWhisper.health(for: $0, proof: proof) })
        defer { server.stop() }

        let error = await #expect(throws: EarmarkError.self) { try await FakeWhisper.client(server).health() }

        expectRemoteFailed(error, containing: notProven)
        #expect(server.paths == ["/v1/health"])
    }

    @Test(
        "checkCompatible: коммит и sha256 совпали, но proof не сошёлся — remote_failed, а не health",
        arguments: FakeWhisper.Proof.forged)
    func unprovenCompatible(proof: FakeWhisper.Proof) async throws {
        let server = try FakeWhisper.server(health: { FakeWhisper.health(for: $0, proof: proof) })
        defer { server.stop() }

        let error = await #expect(throws: EarmarkError.self) {
            try await FakeWhisper.client(server).checkCompatible()
        }

        expectRemoteFailed(error, containing: notProven)
        #expect(server.paths == ["/v1/health"])
    }

    @Test("checkCompatible: коммит и оба sha256 совпали — отдаёт health")
    func compatible() async throws {
        let server = try FakeWhisper.server()
        defer { server.stop() }

        let health = try await FakeWhisper.client(server).checkCompatible()

        #expect(health.commit == RemoteWhisperClient.whisperCommit)
        #expect(health.modelSha256 == Models.largeV3Turbo.sha256)
        #expect(health.vadSha256 == Models.sileroVAD.sha256)
        #expect(health.gpu == "Test GPU 24 GB")
        #expect(server.paths == ["/v1/health"])
    }

    enum Mismatch: CaseIterable { case commit, model, vad }

    @Test(
        "checkCompatible: не тот коммит, модель или VAD — remote_failed, в тексте то, что не сошлось",
        arguments: Mismatch.allCases)
    func incompatible(mismatch: Mismatch) async throws {
        let wrong = "ffff\(mismatch)0000"
        let server = try FakeWhisper.server(health: { request in
            switch mismatch {
            case .commit: FakeWhisper.health(for: request, commit: wrong)
            case .model: FakeWhisper.health(for: request, model: wrong)
            case .vad: FakeWhisper.health(for: request, vad: wrong)
            }
        })
        defer { server.stop() }

        let error = await #expect(throws: EarmarkError.self) {
            try await FakeWhisper.client(server).checkCompatible()
        }

        expectRemoteFailed(error, containing: wrong)
    }

    @Test("vad: POST /v1/vad?threads=N, тело — ровно little-endian float32 среза, float из ответа без потерь")
    func vad() async throws {
        let raw: [(Float, Float)] = [(Float(12.34), Float(56.78)), (Float(123.456), Float(0.1) + 1000)]
        let server = try FakeWhisper.server(vad: { _ in FakeWhisper.spans(raw) })
        defer { server.stop() }

        let spans = try await FakeWhisper.client(server).vad(slice, threads: 3)

        #expect(spans.map(\.t0) == raw.map(\.0))
        #expect(spans.map(\.t1) == raw.map(\.1))
        let request = try #require(server.requests.first)
        #expect(server.paths == ["/v1/vad"])
        #expect(request.method == "POST")
        #expect(request.query["threads"] == "3")
        #expect(request.body == littleEndianBytes(slice))
        #expect(request.headers["content-type"] == "application/octet-stream")
        expectBearer(server)
    }

    @Test("language: POST /v1/language?threads=N с телом среза, вероятности — словарь из ответа")
    func language() async throws {
        let probs: [String: Float] = ["ru": Float(0.8123), "en": Float(0.12), "az": Float(3e-5)]
        let server = try FakeWhisper.server(language: { _ in FakeWhisper.probs(probs) })
        defer { server.stop() }

        let result = try await FakeWhisper.client(server).language(slice, threads: 4)

        #expect(result == probs)
        let request = try #require(server.requests.first)
        #expect(server.paths == ["/v1/language"])
        #expect(request.method == "POST")
        #expect(request.query["threads"] == "4")
        #expect(request.body == littleEndianBytes(slice))
        expectBearer(server)
    }

    @Test("language: пустой словарь вероятностей — пустой результат, не ошибка")
    func emptyProbabilities() async throws {
        let server = try FakeWhisper.server()
        defer { server.stop() }

        #expect(try await FakeWhisper.client(server).language(slice, threads: 4).isEmpty)
    }

    @Test(
        "full: POST /v1/full?language&threads, прогресс только при смене, сегменты из последней строки, текст сырой"
    )
    func fullStream() async throws {
        // Текст whisper как есть, с ведущим пробелом: обрезает его движок, а не клиент.
        let final = FakeWhisper.segments([
            (0, 150, #" Привет, "мир""#), (150, 1_800_000, " Second\nline \n"),
        ])
        let server = try FakeWhisperServer { _, connection in
            connection.startStream()
            for percent in [3, 3, 10, 10, 10, 35, 35, 80, 80] {
                connection.line(#"{"progress":\#(percent)}"#)
            }
            connection.line(final)
            connection.endStream()
        }
        defer { server.stop() }
        let progress = ProgressLog()

        let segments = try await full(FakeWhisper.client(server), progress: progress)

        #expect(progress.all == [3, 10, 35, 80])
        #expect(segments.map(\.t0) == [0, 150])
        #expect(segments.map(\.t1) == [150, 1_800_000])
        #expect(segments.map(\.text) == [#" Привет, "мир""#, " Second\nline \n"])
        let request = try #require(server.requests.first)
        #expect(server.paths == ["/v1/full"])
        #expect(request.method == "POST")
        #expect(request.query["language"] == "ru")
        #expect(request.query["threads"] == "4")
        #expect(request.body == littleEndianBytes(slice))
        #expect(request.headers["content-type"] == "application/octet-stream")
        expectBearer(server)
    }

    @Test("full: язык auto уходит в query как есть")
    func fullAuto() async throws {
        let server = try FakeWhisper.server()
        defer { server.stop() }

        #expect(try await full(FakeWhisper.client(server), language: "auto").isEmpty)
        #expect(server.requests.first?.query["language"] == "auto")
    }
}

@Suite("RemoteWhisperClient: любой сбой сервера — remote_failed")
struct RemoteWhisperClientFailureTests {
    @Test("последняя строка {\"error\":…} — remote_failed с текстом сервера")
    func errorLine() async throws {
        let server = try FakeWhisperServer { _, connection in
            connection.startStream()
            connection.line(#"{"progress":10}"#)
            connection.line(#"{"error":"whisper_full returned -6"}"#)
            connection.endStream()
        }
        defer { server.stop() }

        let error = await #expect(throws: EarmarkError.self) { try await full(FakeWhisper.client(server)) }

        expectRemoteFailed(error, containing: "whisper_full returned -6")
    }

    @Test("поток закончился без итоговой строки — remote_failed")
    func endedWithoutResult() async throws {
        let server = try FakeWhisperServer { _, connection in
            connection.startStream()
            connection.line(#"{"progress":10}"#)
            connection.line(#"{"progress":100}"#)
            connection.endStream()
        }
        defer { server.stop() }

        let error = await #expect(throws: EarmarkError.self) { try await full(FakeWhisper.client(server)) }

        expectRemoteFailed(error)
    }

    @Test("соединение оборвалось посреди строки — remote_failed")
    func droppedMidLine() async throws {
        let server = try FakeWhisperServer { _, connection in
            connection.startStream()
            connection.line(#"{"progress":40}"#)
            connection.chunk(#"{"segments":[{"t0":0,"t1":1"#)
            // Возврат из обработчика закрывает сокет без завершающего chunk.
        }
        defer { server.stop() }

        let error = await #expect(throws: EarmarkError.self) { try await full(FakeWhisper.client(server)) }

        expectRemoteFailed(error)
    }

    @Test(
        "строка не по контракту в потоке /v1/full — remote_failed",
        arguments: ["not json", #"{"segments":[{"t0":1}]}"#, #"{"segments":"none"}"#])
    func malformedStream(line: String) async throws {
        let server = try FakeWhisperServer { _, connection in
            connection.startStream()
            connection.line(#"{"progress":5}"#)
            connection.line(line)
            connection.endStream()
        }
        defer { server.stop() }

        let error = await #expect(throws: EarmarkError.self) { try await full(FakeWhisper.client(server)) }

        expectRemoteFailed(error)
    }

    enum Endpoint: String, CaseIterable { case health, vad, language, full }

    @Test(
        "код ошибки HTTP на любом эндпоинте — remote_failed",
        arguments: Endpoint.allCases, [400, 401, 404, 413, 500])
    func httpErrors(endpoint: Endpoint, status: Int) async throws {
        let server = try FakeWhisperServer { _, connection in
            connection.respond(status, status == 401 ? #"{"error":"unauthorized"}"# : #"{"error":"boom"}"#)
        }
        defer { server.stop() }

        let error = await #expect(throws: EarmarkError.self) {
            try await call(endpoint, FakeWhisper.client(server))
        }

        expectRemoteFailed(error, containing: status == 401 ? "401" : nil)
    }

    @Test(
        "ответ 200 с телом не по контракту — remote_failed",
        arguments: [
            (Endpoint.health, "not json"), (.health, #"{"whisper":"1.9.4"}"#),
            (.vad, #"{"spanz":[]}"#), (.vad, #"{"spans":[[1.5]]}"#), (.vad, "{"),
            (.language, #"{"probs":"ru"}"#), (.language, "[]"),
        ])
    func malformedBody(endpoint: Endpoint, body: String) async throws {
        let server = try FakeWhisperServer { _, connection in connection.respond(200, body) }
        defer { server.stop() }

        let error = await #expect(throws: EarmarkError.self) {
            try await call(endpoint, FakeWhisper.client(server))
        }

        expectRemoteFailed(error)
    }

    @Test("никто не слушает порт — remote_failed сразу, без ожидания таймаутов", arguments: Endpoint.allCases)
    func connectionRefused(endpoint: Endpoint) async throws {
        let client = RemoteWhisperClient(
            baseURL: try FakeWhisper.deadURL(), token: FakeWhisper.token,
            timeouts: .init(health: 30, request: 30, idle: 30, stall: 30))
        let start = Date()

        let error = await #expect(throws: EarmarkError.self) { try await call(endpoint, client) }

        expectRemoteFailed(error)
        #expect(seconds(since: start) < 5)
    }
}

@Suite("RemoteWhisperClient: таймауты и отмена")
struct RemoteWhisperClientTimeoutTests {
    /// Принял запрос и молчит: ни байта ответа.
    private func silentServer() throws -> FakeWhisperServer {
        try FakeWhisperServer { _, connection in connection.hang() }
    }

    @Test("health висит — remote_failed примерно через timeouts.health")
    func healthHangs() async throws {
        let server = try silentServer()
        defer { server.stop() }
        let start = Date()

        let error = await #expect(throws: EarmarkError.self) {
            try await FakeWhisper.client(server, timeouts: .init(health: 1, request: 30, idle: 30, stall: 30))
                .health()
        }

        expectRemoteFailed(error)
        #expect((0.5..<3.5).contains(seconds(since: start)))
    }

    @Test(
        "vad и language висят — remote_failed примерно через timeouts.request",
        arguments: ["vad", "language"])
    func requestHangs(endpoint: String) async throws {
        let server = try silentServer()
        defer { server.stop() }
        let client = FakeWhisper.client(server, timeouts: .init(health: 30, request: 1, idle: 30, stall: 30))
        let start = Date()

        let error = await #expect(throws: EarmarkError.self) {
            if endpoint == "vad" {
                _ = try await client.vad(slice, threads: 4)
            } else {
                _ = try await client.language(slice, threads: 4)
            }
        }

        expectRemoteFailed(error)
        #expect((0.5..<3.5).contains(seconds(since: start)))
    }

    @Test("full: сервер не отвечает ни байтом — remote_failed примерно через timeouts.idle")
    func fullNeverAnswers() async throws {
        let server = try silentServer()
        defer { server.stop() }
        let start = Date()

        let error = await #expect(throws: EarmarkError.self) {
            try await full(
                FakeWhisper.client(server, timeouts: .init(health: 30, request: 30, idle: 1, stall: 30)))
        }

        expectRemoteFailed(error)
        #expect((0.5..<3.5).contains(seconds(since: start)))
    }

    @Test("full: заголовки пришли, а строк нет — remote_failed примерно через timeouts.idle")
    func fullSilentAfterHeaders() async throws {
        let server = try FakeWhisperServer { _, connection in
            connection.startStream()
            connection.line(#"{"progress":0}"#)
            connection.hang()
        }
        defer { server.stop() }
        let start = Date()

        let error = await #expect(throws: EarmarkError.self) {
            try await full(
                FakeWhisper.client(server, timeouts: .init(health: 30, request: 30, idle: 1, stall: 30)))
        }

        expectRemoteFailed(error)
        #expect((0.5..<3.5).contains(seconds(since: start)))
    }

    @Test("full: heartbeat идёт, а прогресс стоит — remote_failed по timeouts.stall, не раньше idle")
    func stalled() async throws {
        let server = try FakeWhisperServer { _, connection in
            connection.startStream()
            repeat {
                guard connection.line(#"{"progress":42}"#) else { return }
            } while !connection.pause(0.2)
        }
        defer { server.stop() }
        let start = Date()

        let error = await #expect(throws: EarmarkError.self) {
            try await full(
                FakeWhisper.client(server, timeouts: .init(health: 30, request: 30, idle: 0.6, stall: 2)))
        }

        expectRemoteFailed(error, containing: "stall")
        // heartbeat чаще idle: поток жил дольше idle и упал по застою прогресса.
        #expect((1.5..<4.5).contains(seconds(since: start)))
    }

    @Test("full: heartbeat чаще idle и прогресс меняется — поток дольше idle доходит до результата")
    func heartbeatKeepsAlive() async throws {
        let server = try FakeWhisperServer { _, connection in
            connection.startStream()
            for step in 0..<10 {
                connection.line(#"{"progress":\#(step / 2 * 10 + 5)}"#)
                if connection.pause(0.2) { return }
            }
            connection.line(FakeWhisper.segments([(0, 100, "done")]))
            connection.endStream()
        }
        defer { server.stop() }
        let progress = ProgressLog()

        let segments = try await full(
            FakeWhisper.client(server, timeouts: .init(health: 30, request: 30, idle: 0.6, stall: 1.5)),
            progress: progress)

        #expect(segments.map(\.text) == ["done"])
        #expect(progress.all == [5, 15, 25, 35, 45])
    }

    @Test("full: shouldAbort посреди потока — interrupted (75) быстро, соединение закрыто, не remote_failed")
    func abortMidStream() async throws {
        let closedAt = Mutex<Date?>(nil)
        let server = try FakeWhisperServer { _, connection in
            connection.startStream()
            while connection.line(#"{"progress":10}"#), !connection.pause(0.1) { /* heartbeat */  }
            closedAt.withLock { $0 = Date() }
        }
        defer { server.stop() }
        let abort = AbortFlag.after(0.4)
        let start = Date()

        let error = await #expect(throws: EarmarkError.self) {
            try await full(
                FakeWhisper.client(server, timeouts: .init(health: 30, request: 30, idle: 30, stall: 30)),
                abort: abort)
        }

        #expect(error == .interrupted)
        #expect(error?.code == "interrupted")
        #expect(error?.exitCode == 75)
        #expect(seconds(since: start) < 2.4)
        // Сервер видит закрытое соединение: по нему он отпускает GPU.
        let deadline = Date().addingTimeInterval(2)
        while closedAt.withLock({ $0 }) == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(closedAt.withLock { $0 } != nil, "сервер не увидел закрытия соединения")
    }

    @Test("full: shouldAbort, пока сервер молчит до ответа — interrupted быстро, а не таймаут")
    func abortWhileWaiting() async throws {
        let server = try silentServer()
        defer { server.stop() }
        let abort = AbortFlag.after(0.3)
        let start = Date()

        let error = await #expect(throws: EarmarkError.self) {
            try await full(
                FakeWhisper.client(server, timeouts: .init(health: 30, request: 30, idle: 10, stall: 30)),
                abort: abort)
        }

        #expect(error == .interrupted)
        #expect(seconds(since: start) < 2.3)
    }

    @Test(
        "отмена Swift-задачи при опущенном shouldAbort — remote_failed (фолбэк), не interrupted (exit 75)",
        arguments: RemoteWhisperClientFailureTests.Endpoint.allCases)
    func taskCancelled(endpoint: RemoteWhisperClientFailureTests.Endpoint) async throws {
        let server = try silentServer()
        defer { server.stop() }
        let client = FakeWhisper.client(server, timeouts: .init(health: 10, request: 10, idle: 10, stall: 30))
        let start = Date()
        let task = Task { try await call(endpoint, client) }
        try await Task.sleep(for: .milliseconds(300))

        task.cancel()
        let result = await task.result

        guard case .failure(let failure) = result else {
            Issue.record("отменённый запрос завершился успехом")
            return
        }
        let error = failure as? EarmarkError
        #expect(error != .interrupted)
        expectRemoteFailed(error)
        // Ошибку дала сама отмена, а не таймаут в 10 с.
        #expect(seconds(since: start) < 5)
    }

    @Test("full: shouldAbort во время отправки тела (сервер не читает) — interrupted быстро")
    func abortWhileUploading() async throws {
        let server = try FakeWhisperServer(readsBody: false) { _, connection in connection.hang() }
        defer { server.stop() }
        // 32 MB — заметно больше буферов loopback-сокета: отправка упирается в нечитающий сервер.
        let big = [Float](repeating: 0.25, count: 8_000_000)
        let abort = AbortFlag.after(0.3)
        let start = Date()

        let error = await #expect(throws: EarmarkError.self) {
            try await full(
                FakeWhisper.client(server, timeouts: .init(health: 30, request: 30, idle: 10, stall: 30)),
                big[...], abort: abort)
        }

        #expect(error == .interrupted)
        #expect(seconds(since: start) < 2.5)
    }
}
