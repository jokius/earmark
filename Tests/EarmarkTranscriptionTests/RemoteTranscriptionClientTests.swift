import Foundation
import Testing

@testable import EarmarkCore

private let id = "20261002-1400-a1b2"

/// Канал, у которого отправляемый срез начинается не с нуля: тело PUT обязано быть ровно этим срезом.
private let channel: [Float] = [9, -9, 0.5, Float(123.456), -0.25, Float(1e-7), 1, -1, 7]
private let slice = channel[2..<7]

private func seconds(since start: Date) -> TimeInterval { Date().timeIntervalSince(start) }

/// Сбой среды: remote_failed, exit 69 — попытка не засчитывается, очередь повторит.
private func expectEnvironmental(_ error: EarmarkError?, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(error?.code == "remote_failed", "\(String(describing: error))", sourceLocation: sourceLocation)
    #expect(error?.exitCode == 69, sourceLocation: sourceLocation)
}

/// Засчитанный сбой: operation_failed, exit 1.
private func expectCounted(_ error: EarmarkError?, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(error?.code == "operation_failed", "\(String(describing: error))", sourceLocation: sourceLocation)
    #expect(error?.exitCode == 1, sourceLocation: sourceLocation)
}

/// Запрос к /v2/jobs* несёт токен клиента.
private func expectBearer(_ request: FakeRequest?, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(
        request?.headers["authorization"] == "Bearer \(FakeWhisper.token)",
        "\(String(describing: request?.path))",
        sourceLocation: sourceLocation)
}

/// Рукопожатие: GET /v2/health с nonce из 64 hex, без тела; токен не уходит никак.
private func expectHandshake(_ request: FakeRequest?, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(request?.method == "GET", sourceLocation: sourceLocation)
    #expect(request?.path == "/v2/health", sourceLocation: sourceLocation)
    let nonce = request?.query["nonce"] ?? ""
    #expect(
        nonce.wholeMatch(of: /[0-9a-fA-F]{64}/) != nil, "nonce «\(nonce)»", sourceLocation: sourceLocation)
    #expect(request?.headers["authorization"] == nil, sourceLocation: sourceLocation)
    #expect(request?.body.isEmpty == true, sourceLocation: sourceLocation)
    let token = FakeWhisper.token
    let leaked =
        request.map { request in
            request.headers.values.contains { $0.contains(token) }
                || request.query.values.contains { $0.contains(token) }
        } ?? false
    #expect(!leaked, "токен ушёл в рукопожатии", sourceLocation: sourceLocation)
}

/// Вызов клиента по имени эндпоинта — для параметризованных тестов.
enum ClientCall: String, CaseIterable, Sendable {
    case health, job, upload, submit, delete

    static let jobs: [ClientCall] = [.job, .upload, .submit, .delete]

    var endpoint: FakeJobServer.Endpoint {
        switch self {
        case .health: .health
        case .job: .job
        case .upload: .upload
        case .submit: .submit
        case .delete: .delete
        }
    }

    /// Как запрос выглядит в журнале FakeJobServer.calls.
    var logged: String {
        switch self {
        case .health: "health"
        case .job: "get"
        case .upload: "put0@0"
        case .submit: "submit"
        case .delete: "delete"
        }
    }

    var path: String {
        switch self {
        case .health: "/v2/health"
        case .job, .delete: "/v2/jobs/\(id)"
        case .upload: "/v2/jobs/\(id)/channels/0"
        case .submit: "/v2/jobs/\(id)/submit"
        }
    }

    func run(_ client: RemoteTranscriptionClient) async throws(EarmarkError) {
        switch self {
        case .health: _ = try await client.checkCompatible()
        case .job: _ = try await client.job(id)
        case .upload: _ = try await client.upload(id, channel: 0, offset: 0, samples: slice, source: .m4a)
        case .submit: _ = try await client.submit(id, languages: "ru", lengths: [5, 0])
        case .delete: try await client.delete(id)
        }
    }
}

@Suite("RemoteTranscription.client: клиент из конфига и токен-файла")
struct RemoteTranscriptionWiringTests {
    @Test(
        "токен — первая строка файла без пробелов по краям: им сверен proof; URL с хвостовым / ведёт на /v2/health"
    )
    func tokenFromFile() async throws {
        let server = try FakeJobServer()
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
        _ = try await client.checkCompatible()

        #expect(server.calls == ["health"])
        expectHandshake(server.requests.first)
    }
}

@Suite("RemoteTranscriptionClient: рукопожатие /v2/health и совместимость")
struct RemoteClientHealthTests {
    @Test("стандартные таймауты 5/120 с и коммит whisper.cpp, с которым доказан паритет")
    func constants() throws {
        #expect(
            RemoteTranscriptionClient.Timeouts.standard
                == RemoteTranscriptionClient.Timeouts(health: 5, request: 120))
        #expect(RemoteTranscriptionClient.whisperCommit == "927cfce34f31707e17f2bff35c349632fb9e2c3a")
        let url = try #require(URL(string: "http://gpu-box.local:8178"))
        #expect(RemoteTranscriptionClient(baseURL: url, token: "t").baseURL == url)
    }

    @Test(
        "checkCompatible: GET /v2/health?nonce без Authorization, proof сошёлся — поля сервера в snake_case разобраны"
    )
    func compatible() async throws {
        let server = try FakeJobServer()
        defer { server.stop() }

        let health = try await FakeWhisper.client(server).checkCompatible()

        #expect(health.whisper == "1.9.4")
        #expect(health.commit == RemoteTranscriptionClient.whisperCommit)
        #expect(health.model == "ggml-large-v3-turbo.bin")
        #expect(health.modelSha256 == Models.largeV3Turbo.sha256)
        #expect(health.vadSha256 == Models.sileroVAD.sha256)
        #expect(health.gpu == "Test GPU 24 GB")
        #expect(server.calls == ["health"])
        expectHandshake(server.requests.first)
    }

    @Test("на каждый вызов свежий nonce — записанный proof не годится дважды")
    func freshNonce() async throws {
        let server = try FakeJobServer()
        defer { server.stop() }
        let client = FakeWhisper.client(server)

        _ = try await client.checkCompatible()
        _ = try await client.checkCompatible()

        let nonces = server.requests.map { $0.query["nonce"] ?? "" }
        #expect(nonces.count == 2)
        #expect(Set(nonces).count == 2, "\(nonces)")
    }

    @Test(
        "proof чужой, от другого токена, пустой или его нет — remote_failed",
        arguments: FakeWhisper.Proof.forged)
    func forgedProof(proof: FakeWhisper.Proof) async throws {
        let server = try FakeJobServer { $0.proof = proof }
        defer { server.stop() }

        let error = await #expect(throws: EarmarkError.self) {
            try await FakeWhisper.client(server).checkCompatible()
        }

        expectEnvironmental(error)
        #expect(server.calls == ["health"])
    }

    enum Mismatch: CaseIterable { case commit, vad }

    @Test("не тот коммит whisper.cpp или не тот VAD — remote_failed", arguments: Mismatch.allCases)
    func incompatible(mismatch: Mismatch) async throws {
        let server = try FakeJobServer { settings in
            switch mismatch {
            case .commit: settings.commit = "ffff0000commit"
            case .vad: settings.vadSha256 = "ffff0000vad"
            }
        }
        defer { server.stop() }

        let error = await #expect(throws: EarmarkError.self) {
            try await FakeWhisper.client(server).checkCompatible()
        }

        expectEnvironmental(error)
    }

    @Test("модель не сверяется: сервер с другой моделью совместим, её имя и sha256 — в ответе")
    func modelNotPinned() async throws {
        let sha = String(repeating: "c0ffee", count: 10) + "abcd"
        let server = try FakeJobServer {
            $0.model = "ggml-large-v3.bin"
            $0.modelSha256 = sha
        }
        defer { server.stop() }

        let health = try await FakeWhisper.client(server).checkCompatible()

        #expect(health.model == "ggml-large-v3.bin")
        #expect(health.modelSha256 == sha)
    }

    @Test("health висит — remote_failed примерно через timeouts.health")
    func healthHangs() async throws {
        let server = try FakeJobServer()
        defer { server.stop() }
        server.script(.health, .hang)
        let start = Date()

        let error = await #expect(throws: EarmarkError.self) {
            try await FakeWhisper.client(server, timeouts: .init(health: 1, request: 30)).checkCompatible()
        }

        expectEnvironmental(error)
        #expect((0.5..<3.5).contains(seconds(since: start)))
    }
}

@Suite("RemoteTranscriptionClient: задачи /v2/jobs")
struct RemoteClientJobsTests {
    @Test("job: задачи нет (404) — nil; GET /v2/jobs/<id> с Bearer")
    func missingJob() async throws {
        let server = try FakeJobServer()
        defer { server.stop() }

        let job = try await FakeWhisper.client(server).job(id)

        #expect(job == nil)
        #expect(server.calls == ["get"])
        let request = try #require(server.requests.first)
        #expect(request.method == "GET")
        #expect(request.path == "/v2/jobs/\(id)")
        expectBearer(request)
    }

    @Test("job: done разобран целиком — модель, sha256 и сегменты обоих каналов с языком")
    func doneJob() async throws {
        let server = try FakeJobServer()
        defer { server.stop() }
        let mic = [
            FakeSegment(startMs: 0, endMs: 900, text: #"Привет, "мир""#, language: "ru"),
            FakeSegment(startMs: 1_000, endMs: 1_800_000, text: "second\nline", language: "en"),
        ]
        server.seed(
            id,
            FakeJob(
                state: "done", progress: 100, lengths: [32_000, 31_990], languages: "ru,en", error: nil,
                result: [mic, []]))

        let job = try #require(try await FakeWhisper.client(server).job(id))

        #expect(job.state == .done)
        #expect(job.progress == 100)
        #expect(job.lengths == [32_000, 31_990])
        #expect(job.languages == "ru,en")
        #expect(job.source == .m4a)
        #expect(job.error == nil)
        #expect(job.model == "ggml-large-v3-turbo.bin")
        #expect(job.modelSha256 == Models.largeV3Turbo.sha256)
        #expect(
            job.channels == [
                [
                    RemoteJobSegment(startMs: 0, endMs: 900, text: #"Привет, "мир""#, language: "ru"),
                    RemoteJobSegment(startMs: 1_000, endMs: 1_800_000, text: "second\nline", language: "en"),
                ],
                [],
            ])
    }

    @Test("job: receiving от стрима до submit — languages, error, модель и каналы пустые")
    func receivingJob() async throws {
        let server = try FakeJobServer()
        defer { server.stop() }
        server.seed(id, FakeJob(state: "receiving", lengths: [480, 0], source: "stream"))

        let job = try #require(try await FakeWhisper.client(server).job(id))

        #expect(job.state == .receiving)
        #expect(job.lengths == [480, 0])
        #expect(job.source == .stream)
        #expect(job.languages == nil)
        #expect(job.error == nil)
        #expect(job.model == nil && job.modelSha256 == nil && job.channels == nil)
    }

    @Test("job: failed — текст ошибки сервера")
    func failedJob() async throws {
        let server = try FakeJobServer()
        defer { server.stop() }
        server.seed(
            id,
            FakeJob(
                state: "failed", lengths: [10, 10], languages: "ru", error: "server crashed on this job twice"
            ))

        let job = try #require(try await FakeWhisper.client(server).job(id))

        #expect(job.state == .failed)
        #expect(job.error == "server crashed on this job twice")
    }

    @Test("upload: PUT /v2/jobs/<id>/channels/<n>?offset&source, тело — ровно little-endian float32 среза")
    func upload() async throws {
        let server = try FakeJobServer()
        defer { server.stop() }

        let result = try await FakeWhisper.client(server).upload(
            id, channel: 1, offset: 0, samples: slice, source: .m4a)

        #expect(result == .success([0, slice.count]))
        let request = try #require(server.requests.first)
        #expect(request.method == "PUT")
        #expect(request.path == "/v2/jobs/\(id)/channels/1")
        #expect(request.query["offset"] == "0")
        #expect(request.query["source"] == "m4a")
        #expect(request.body == littleEndianBytes(slice))
        expectBearer(request)
        #expect(server.job(id)?.samples == [[], Array(slice)])
    }

    @Test("upload: дозапись с длины сервера; source=stream задаётся первым куском")
    func appendAndStream() async throws {
        let server = try FakeJobServer()
        defer { server.stop() }
        let client = FakeWhisper.client(server)

        _ = try await client.upload(id, channel: 0, offset: 0, samples: channel[0..<4], source: .stream)
        let result = try await client.upload(
            id, channel: 0, offset: 4, samples: channel[4...], source: .stream)

        #expect(result == .success([channel.count, 0]))
        #expect(server.uploads(channel: 0).map { $0.query["offset"] } == ["0", "4"])
        #expect(server.job(id)?.samples[0] == channel)
        #expect(server.job(id)?.source == "stream")
    }

    @Test(
        "upload: offset не равен длине на сервере — failure(RemoteConflict) с длинами сервера, данные не пишутся"
    )
    func uploadWrongOffset() async throws {
        let server = try FakeJobServer()
        defer { server.stop() }
        server.seed(id, FakeJob(state: "receiving", lengths: [3, 0], samples: [[1, 2, 3], []]))

        let result = try await FakeWhisper.client(server).upload(
            id, channel: 0, offset: 0, samples: slice, source: .m4a)

        #expect(result == .failure(RemoteConflict(state: .receiving, lengths: [3, 0], languages: nil)))
        #expect(server.job(id)?.samples == [[1, 2, 3], []])
    }

    @Test("upload: задача уже не receiving — failure(RemoteConflict) с её состоянием")
    func uploadIntoQueued() async throws {
        let server = try FakeJobServer()
        defer { server.stop() }
        server.seed(id, FakeJob(state: "queued", lengths: [5, 5], languages: "ru"))

        let result = try await FakeWhisper.client(server).upload(
            id, channel: 0, offset: 5, samples: slice, source: .m4a)

        #expect(result == .failure(RemoteConflict(state: .queued, lengths: [5, 5], languages: "ru")))
    }

    @Test("submit: POST /v2/jobs/<id>/submit с языками и длинами — задача queued")
    func submit() async throws {
        let server = try FakeJobServer { $0.afterSubmit = [] }
        defer { server.stop() }
        server.seed(id, FakeJob(state: "receiving", lengths: [5, 0], samples: [Array(slice), []]))

        let result = try await FakeWhisper.client(server).submit(id, languages: "ru,en,az", lengths: [5, 0])

        guard case .success(let job) = result else {
            Issue.record("ожидали .success, получили \(result)")
            return
        }
        #expect(job.state == .queued)
        #expect(job.languages == "ru,en,az")
        #expect(job.lengths == [5, 0])
        let request = try #require(server.requests.first)
        #expect(request.method == "POST")
        #expect(request.path == "/v2/jobs/\(id)/submit")
        expectBearer(request)
        #expect(server.submits.map(\.languages) == ["ru,en,az"])
        #expect(server.submits.map(\.lengths) == [[5, 0]])
        #expect(server.job(id)?.state == "queued")
    }

    @Test(
        "PUT — Content-Type application/octet-stream и на теле больше 8 KiB (form-urlencoded httplib режет 413), submit — application/json"
    )
    func contentTypes() async throws {
        let server = try FakeJobServer { $0.afterSubmit = [] }
        defer { server.stop() }
        let client = FakeWhisper.client(server)
        // 4096 сэмплов — 16 KiB тела.
        let samples = [Float](repeating: 0.25, count: 4_096)

        _ = try await client.upload(id, channel: 0, offset: 0, samples: samples[...], source: .m4a)
        _ = try await client.submit(id, languages: "ru", lengths: [samples.count, 0])

        #expect(server.calls == ["put0@0", "submit"])
        let put = try #require(server.requests.first)
        #expect(put.mediaType == "application/octet-stream", "\(put.headers)")
        #expect(put.body.count == 16_384)
        let submit = try #require(server.requests.last)
        #expect(submit.mediaType == "application/json", "\(submit.headers)")
    }

    @Test("submit: длины не совпали — failure(RemoteConflict) с состоянием и длинами сервера")
    func submitConflict() async throws {
        let server = try FakeJobServer()
        defer { server.stop() }
        server.seed(id, FakeJob(state: "receiving", lengths: [5, 0], samples: [Array(slice), []]))

        let result = try await FakeWhisper.client(server).submit(id, languages: "ru", lengths: [5, 7])

        #expect(result == .failure(RemoteConflict(state: .receiving, lengths: [5, 0], languages: nil)))
        #expect(server.job(id)?.state == "receiving")
    }

    @Test(
        "delete: DELETE /v2/jobs/<id> с Bearer; есть задача (200) или нет (404) — успех",
        arguments: [true, false])
    func delete(exists: Bool) async throws {
        let server = try FakeJobServer()
        defer { server.stop() }
        if exists { server.seed(id, FakeJob(state: "done", lengths: [1, 1], languages: "ru")) }

        try await FakeWhisper.client(server).delete(id)

        #expect(server.calls == ["delete"])
        let request = try #require(server.requests.first)
        #expect(request.method == "DELETE")
        #expect(request.path == "/v2/jobs/\(id)")
        expectBearer(request)
        #expect(server.job(id) == nil)
    }
}

@Suite("RemoteTranscriptionClient: классификация ошибок")
struct RemoteClientErrorTests {
    private static let jobsAndStatuses = ClientCall.jobs.flatMap { call in
        [401, 500, 503, 507].map { (call, $0) }
    }

    @Test("401, 5xx и 507 на /v2/jobs* — remote_failed (69): ждём сервер", arguments: jobsAndStatuses)
    func environmentalStatus(call: ClientCall, status: Int) async throws {
        let server = try FakeJobServer()
        defer { server.stop() }
        server.script(call.endpoint, .status(status, #"{"error":"boom"}"#))

        let error = await #expect(throws: EarmarkError.self) {
            try await call.run(FakeWhisper.client(server))
        }

        expectEnvironmental(error)
    }

    /// Любой не-200 на /v2/health — proof нет, сервер не наш или не той версии (v1 отвечает 404): ждём, не засчитываем.
    @Test("health отвечает не 200 (401, 404, 5xx) — remote_failed (69)", arguments: [401, 404, 500, 503])
    func healthStatus(status: Int) async throws {
        let server = try FakeJobServer()
        defer { server.stop() }
        server.script(.health, .status(status, #"{"error":"boom"}"#))

        let error = await #expect(throws: EarmarkError.self) {
            try await FakeWhisper.client(server).checkCompatible()
        }

        expectEnvironmental(error)
    }

    private static let countedStatuses = ClientCall.jobs.flatMap { call in
        [400, 403, 413, 422].map { (call, $0) }
    }

    @Test("прочие 4xx на /v2/jobs* — operation_failed (1): засчитанная попытка", arguments: countedStatuses)
    func countedStatus(call: ClientCall, status: Int) async throws {
        let server = try FakeJobServer()
        defer { server.stop() }
        server.script(call.endpoint, .status(status, #"{"error":"bad request"}"#))

        let error = await #expect(throws: EarmarkError.self) {
            try await call.run(FakeWhisper.client(server))
        }

        expectCounted(error)
        #expect(server.calls == [call.logged])
    }

    @Test("submit на задачу, которой нет (404), — operation_failed: 404 там не ответ")
    func submitMissingJob() async throws {
        let server = try FakeJobServer()
        defer { server.stop() }

        let error = await #expect(throws: EarmarkError.self) {
            try await ClientCall.submit.run(FakeWhisper.client(server))
        }

        expectCounted(error)
        #expect(server.calls == ["submit"])
    }

    @Test(
        "ответ 200 не JSON или не по схеме — operation_failed (1)",
        arguments: [
            (ClientCall.job, "not json"), (.job, "{"), (.job, "[]"), (.job, #"{"progress":5}"#),
            (
                .job,
                #"{"state":"sleeping","progress":0,"lengths":[0,0],"languages":null,"source":"m4a","error":null}"#
            ),
            (.upload, "not json"), (.upload, #"{"lengths":"many"}"#),
            (.submit, "not json"), (.submit, #"{"state":"queued"}"#),
        ])
    func malformedBody(call: ClientCall, body: String) async throws {
        let server = try FakeJobServer()
        defer { server.stop() }
        server.seed(id, FakeJob(state: "receiving", lengths: [5, 0], samples: [Array(slice), []]))
        server.script(call.endpoint, .status(200, body))

        let error = await #expect(throws: EarmarkError.self) {
            try await call.run(FakeWhisper.client(server))
        }

        expectCounted(error)
        #expect(server.calls == [call.logged])
    }

    @Test("тело ответа больше 16 MiB — operation_failed; чуть меньше — разбирается")
    func bodyLimit() async throws {
        let server = try FakeJobServer()
        defer { server.stop() }
        let head =
            #"{"state":"receiving","progress":0,"lengths":[0,0],"languages":null,"source":"m4a","error":""#
        let big = { (megabytes: Int) in head + String(repeating: "x", count: megabytes << 20) + #""}"# }
        server.script(.job, .status(200, big(15)), .status(200, big(17)))
        let client = FakeWhisper.client(server, timeouts: .init(health: 5, request: 30))

        let fits = try await client.job(id)
        let error = await #expect(throws: EarmarkError.self) { try await client.job(id) }

        #expect(fits?.error?.count == 15 << 20)
        expectCounted(error)
    }

    /// До proof сервер не наш: огромный ответ рукопожатия — сбой среды, попытку не тратим.
    @Test("тело ответа /v2/health больше 16 MiB — remote_failed (69), не operation_failed")
    func healthBodyLimit() async throws {
        let server = try FakeJobServer()
        defer { server.stop() }
        let padding = String(repeating: "x", count: 17 << 20)
        server.script(.health, .status(200, #"{"whisper":"\#(padding)"}"#))

        let error = await #expect(throws: EarmarkError.self) {
            try await FakeWhisper.client(server, timeouts: .init(health: 30, request: 30)).checkCompatible()
        }

        expectEnvironmental(error)
        #expect(server.calls == ["health"])
    }

    @Test(
        "3xx не выполняется: remote_failed, туда не уходят ни запрос, ни Bearer",
        arguments: ClientCall.allCases)
    func redirectNotFollowed(call: ClientCall) async throws {
        let elsewhere = try FakeJobServer()
        defer { elsewhere.stop() }
        let server = try FakeJobServer()
        defer { server.stop() }
        server.script(call.endpoint, FakeWhisper.redirect(to: elsewhere.baseURL, path: call.path))

        let error = await #expect(throws: EarmarkError.self) {
            try await call.run(FakeWhisper.client(server))
        }

        expectEnvironmental(error)
        #expect(elsewhere.requests.isEmpty)
    }

    @Test(
        "никто не слушает порт — remote_failed сразу, без ожидания таймаутов", arguments: ClientCall.allCases)
    func connectionRefused(call: ClientCall) async throws {
        let client = RemoteTranscriptionClient(
            baseURL: try FakeWhisper.deadURL(), token: FakeWhisper.token,
            timeouts: .init(health: 30, request: 30))
        let start = Date()

        let error = await #expect(throws: EarmarkError.self) { try await call.run(client) }

        expectEnvironmental(error)
        #expect(seconds(since: start) < 5)
    }

    @Test("соединение закрыто без ответа — remote_failed", arguments: ClientCall.allCases)
    func droppedConnection(call: ClientCall) async throws {
        let server = try FakeJobServer()
        defer { server.stop() }
        // Трижды: даже если URLSession сам повторит запрос, ответа он не получит.
        server.script(call.endpoint, .drop, .drop, .drop)

        let error = await #expect(throws: EarmarkError.self) {
            try await call.run(FakeWhisper.client(server))
        }

        expectEnvironmental(error)
    }

    @Test("запрос к задаче висит — remote_failed примерно через timeouts.request", arguments: ClientCall.jobs)
    func requestHangs(call: ClientCall) async throws {
        let server = try FakeJobServer()
        defer { server.stop() }
        server.script(call.endpoint, .hang)
        let start = Date()

        let error = await #expect(throws: EarmarkError.self) {
            try await call.run(FakeWhisper.client(server, timeouts: .init(health: 30, request: 1)))
        }

        expectEnvironmental(error)
        #expect((0.5..<3.5).contains(seconds(since: start)))
    }
}
