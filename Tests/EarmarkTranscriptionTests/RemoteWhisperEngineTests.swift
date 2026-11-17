import EarmarkCore
import Foundation
import Synchronization
import Testing

@testable import EarmarkTranscription

/// Канал-рампа: сэмпл i равен Float(i) (точно до 2^24). По первому сэмплу тела сервер и тест видят,
/// с какого места канала вырезан кусок, не завися от того, как именно оркестрация его режет.
private func ramp(seconds: Double) -> [Float] { (0..<Int(seconds * 16_000)).map(Float.init) }

/// Тело — непрерывный кусок рампы; его начало в сэмплах канала.
private func rampStart(_ request: FakeRequest, sourceLocation: SourceLocation = #_sourceLocation) -> Int {
    let floats = request.floats
    let start = Int(floats.first ?? 0)
    #expect(
        floats == (start..<start + floats.count).map(Float.init), "тело не непрерывный кусок канала",
        sourceLocation: sourceLocation)
    return start
}

private func transcribe(
    _ engine: RemoteWhisperEngine, _ samples: [Float], language: String,
    progress: ProgressLog = ProgressLog(),
    abort: AbortFlag = AbortFlag()
) async throws(EarmarkError) -> [RawSegment] {
    try await engine.transcribe(
        samples, params: .reference(language: language), progress: { progress.append($0) },
        shouldAbort: { abort.isRaised })
}

private func expectMonotonicTo100(_ progress: ProgressLog, sourceLocation: SourceLocation = #_sourceLocation)
{
    let values = progress.all
    #expect(values.last == 100, "\(values)", sourceLocation: sourceLocation)
    #expect(values.allSatisfy { (0...100).contains($0) }, "\(values)", sourceLocation: sourceLocation)
    #expect(
        zip(values, values.dropFirst()).allSatisfy { $0 <= $1 }, "\(values)", sourceLocation: sourceLocation)
}

@Suite("RemoteWhisperEngine: контракт SpeechEngine поверх сервера")
struct RemoteWhisperEngineTests {
    @Test("пустой канал — [] и ни одного запроса, даже health", arguments: ["ru", "auto", "ru,en"])
    func emptyChannel(language: String) async throws {
        let server = try FakeWhisper.server()
        defer { server.stop() }

        let segments = try await transcribe(
            RemoteWhisperEngine(client: FakeWhisper.client(server)), [], language: language)

        #expect(segments.isEmpty)
        #expect(server.requests.isEmpty)
    }

    @Test("несовместимый сервер — ошибка, аудио и токен на сервер не уходят")
    func incompatible() async throws {
        let server = try FakeWhisper.server(health: { FakeWhisper.health(for: $0, commit: "0000deadbeef") })
        defer { server.stop() }

        let error = await #expect(throws: EarmarkError.self) {
            try await transcribe(
                RemoteWhisperEngine(client: FakeWhisper.client(server)), ramp(seconds: 1), language: "ru")
        }

        #expect(error?.code == "remote_failed")
        #expect(server.paths == ["/v1/health"])
        #expect(server.requests.allSatisfy { $0.headers["authorization"] == nil })
    }

    @Test(
        "сервер не доказал знание токена — remote_failed; ни Bearer, ни аудио: только /v1/health без Authorization",
        arguments: FakeWhisper.Proof.forged, ["ru", "auto", "ru,en"])
    func unprovenServer(proof: FakeWhisper.Proof, language: String) async throws {
        // Остальное сервер отдал бы охотно: утечку видно по любому запросу дальше health.
        let server = try FakeWhisper.server(
            health: { FakeWhisper.health(for: $0, proof: proof) },
            vad: { _ in FakeWhisper.spans([(100, 900)]) },
            language: { _ in FakeWhisper.probs(["ru": 0.9, "en": 0.1]) },
            full: { _ in FakeWhisper.segments([(0, 50, "leak")]) })
        defer { server.stop() }

        let error = await #expect(throws: EarmarkError.self) {
            try await transcribe(
                RemoteWhisperEngine(client: FakeWhisper.client(server)), ramp(seconds: 10), language: language
            )
        }

        #expect(error?.code == "remote_failed")
        #expect(
            error?.message.contains("server did not prove it knows the token") == true,
            "\(String(describing: error))")
        #expect(server.paths == ["/v1/health"])
        #expect(server.requests.allSatisfy { $0.headers["authorization"] == nil && $0.body.isEmpty })
    }

    @Test("один язык: один /v1/full на весь канал, сантисекунды → мс, текст обрезан, языка у сегмента нет")
    func singleLanguage() async throws {
        let server = try FakeWhisper.server(full: { _ in
            FakeWhisper.segments([(12, 34, "  Привет, мир. "), (34, 150, "\nВторая фраза\n")])
        })
        defer { server.stop() }
        let channel = ramp(seconds: 2)
        let progress = ProgressLog()
        let params = WhisperParams.reference(language: "ru")

        let segments = try await transcribe(
            RemoteWhisperEngine(client: FakeWhisper.client(server)), channel, language: "ru",
            progress: progress)

        #expect(
            segments == [
                RawSegment(startMs: 120, endMs: 340, text: "Привет, мир."),
                RawSegment(startMs: 340, endMs: 1_500, text: "Вторая фраза"),
            ])
        #expect(segments.allSatisfy { $0.language == nil })
        #expect(server.paths == ["/v1/health", "/v1/full"])
        let request = try #require(server.requests("/v1/full").first)
        #expect(request.body == littleEndianBytes(channel))
        #expect(request.query["language"] == "ru")
        #expect(request.query["threads"] == "\(params.threads)")
        expectMonotonicTo100(progress)
    }

    @Test("auto: один /v1/full с language=auto, без VAD и определения языка")
    func autoLanguage() async throws {
        let server = try FakeWhisper.server(full: { _ in FakeWhisper.segments([(0, 50, " hello ")]) })
        defer { server.stop() }
        let progress = ProgressLog()

        let segments = try await transcribe(
            RemoteWhisperEngine(client: FakeWhisper.client(server)), ramp(seconds: 1), language: "auto",
            progress: progress)

        #expect(segments == [RawSegment(startMs: 0, endMs: 500, text: "hello")])
        #expect(server.paths == ["/v1/health", "/v1/full"])
        #expect(server.requests("/v1/full").first?.query["language"] == "auto")
        expectMonotonicTo100(progress)
    }

    @Test("совместимость проверяется один раз на объект: второй канал идёт без health")
    func healthOncePerEngine() async throws {
        let server = try FakeWhisper.server()
        defer { server.stop() }
        let engine = RemoteWhisperEngine(client: FakeWhisper.client(server))

        _ = try await transcribe(engine, ramp(seconds: 1), language: "ru")
        _ = try await transcribe(engine, ramp(seconds: 1), language: "ru")

        #expect(server.paths == ["/v1/health", "/v1/full", "/v1/full"])
    }

    @Test("сбой сервера на /v1/full — remote_failed наружу (его ловит фолбэк)")
    func serverFailure() async throws {
        let server = try FakeWhisperServer { request, connection in
            if request.path == "/v1/health" {
                connection.respond(200, FakeWhisper.health(for: request))
            } else {
                connection.respond(500, #"{"error":"cuda out of memory"}"#)
            }
        }
        defer { server.stop() }

        let error = await #expect(throws: EarmarkError.self) {
            try await transcribe(
                RemoteWhisperEngine(client: FakeWhisper.client(server)), ramp(seconds: 1), language: "ru")
        }

        #expect(error?.code == "remote_failed")
    }

    @Test("shouldAbort посреди /v1/full — interrupted быстро")
    func abort() async throws {
        let server = try FakeWhisperServer { request, connection in
            guard request.path == "/v1/full" else {
                connection.respond(200, FakeWhisper.health(for: request))
                return
            }
            connection.startStream()
            while connection.line(#"{"progress":10}"#), !connection.pause(0.1) { /* heartbeat */  }
        }
        defer { server.stop() }
        let start = Date()

        let error = await #expect(throws: EarmarkError.self) {
            try await transcribe(
                RemoteWhisperEngine(client: FakeWhisper.client(server)), ramp(seconds: 1), language: "ru",
                abort: .after(0.3))
        }

        #expect(error == .interrupted)
        #expect(Date().timeIntervalSince(start) < 2.3)
    }
}

@Suite("RemoteWhisperEngine: список языков — VAD, язык куска, прогоны")
struct RemoteWhisperEngineMultiLanguageTests {
    /// Сырые отрезки VAD в сантисекундах. A и B (пауза 0.3 с) — один кусок; C и D — отдельные куски.
    private static let vad: [(Float, Float)] = [(100.04, 200), (230, 300), (500, 650), (850, 950)]
    /// Речь до 4 с — русская, дальше английская.
    private static let boundary = 4 * 16_000

    private static func probabilities(_ request: FakeRequest) -> [String: Float] {
        Int(request.floats.first ?? 0) < boundary
            ? ["ru": 0.9, "en": 0.05, "de": 0.02] : ["en": 0.85, "ru": 0.1, "de": 0.03]
    }

    /// Ответ /v1/full прогона: сегменты на шкале присланного куска.
    private static let replies: [String: [(Int64, Int64, String)]] = [  // swiftlint:disable:this large_tuple
        "ru": [(10, 150, " раз ")],
        "en": [(20, 300, " two "), (300, 420, "three\n")],
    ]

    @Test(
        "VAD на весь канал, язык на каждый кусок, /v1/full на каждый прогон; сегменты на шкале канала с языком прогона"
    )
    func runs() async throws {
        let progress = ProgressLog()
        let beforeFirstRun = Mutex<[Int]?>(nil)
        let server = try FakeWhisper.server(
            vad: { _ in FakeWhisper.spans(Self.vad) },
            language: { FakeWhisper.probs(Self.probabilities($0)) },
            full: { request in
                beforeFirstRun.withLock { if $0 == nil { $0 = progress.all } }
                return FakeWhisper.segments(Self.replies[request.query["language"] ?? ""] ?? [])
            })
        defer { server.stop() }
        let channel = ramp(seconds: 10)

        let segments = try await transcribe(
            RemoteWhisperEngine(client: FakeWhisper.client(server)), channel, language: "ru,en",
            progress: progress)

        // Ожидания — из того же LanguagePlan, по переводу VAD из спеки: Int((t * 10).rounded()).
        let speech = Self.vad.map {
            SpeechSpan(startMs: Int(($0.0 * 10).rounded()), endMs: Int(($0.1 * 10).rounded()))
        }
        let chunks = LanguagePlan.chunks(speech)
        let languages = chunks.map { $0.startMs * 16 < Self.boundary ? "ru" : "en" }
        let plan = LanguagePlan.runs(chunks, languages: languages)
        #expect(chunks.count == 3 && plan.count == 2, "фикстура рассчитана на 3 куска и 2 прогона")

        let vadRequests = server.requests("/v1/vad")
        #expect(vadRequests.count == 1)
        #expect(vadRequests.first?.body == littleEndianBytes(channel))

        let languageRequests = server.requests("/v1/language")
        try #require(languageRequests.count == chunks.count)
        for (request, chunk) in zip(languageRequests, chunks) {
            let start = rampStart(request)
            // Кусок для определения языка пересекается со своим куском речи.
            #expect(start < chunk.endMs * 16 && start + request.floats.count > chunk.startMs * 16)
        }

        let runRequests = server.requests("/v1/full")
        try #require(runRequests.count == plan.count)
        #expect(runRequests.map { $0.query["language"] } == plan.map(\.language))
        #expect(server.paths.last == "/v1/full")
        var expected: [RawSegment] = []
        for (request, run) in zip(runRequests, plan) {
            let start = rampStart(request)
            // Прогон уходит целиком: тело покрывает его отрезок канала.
            #expect(start <= run.startMs * 16)
            #expect(start + request.floats.count >= min(run.endMs * 16, channel.count))
            let offsetMs = start / 16
            for (t0, t1, text) in Self.replies[run.language] ?? [] {
                expected.append(
                    RawSegment(
                        startMs: offsetMs + Int(t0) * 10, endMs: offsetMs + Int(t1) * 10,
                        text: text.trimmingCharacters(in: .whitespacesAndNewlines), language: run.language))
            }
        }
        #expect(segments == expected)

        expectMonotonicTo100(progress)
        // 0–10 — определение языка, 10–100 — прогоны.
        let early = try #require(beforeFirstRun.withLock { $0 })
        #expect(early.allSatisfy { $0 <= 10 }, "\(early)")
        #expect(progress.all.dropFirst(early.count).allSatisfy { $0 >= 10 }, "\(progress.all)")
    }

    @Test("список языков, а VAD речи не нашёл — пустой канал без определения языка и прогонов")
    func silence() async throws {
        let server = try FakeWhisper.server()
        defer { server.stop() }

        let segments = try await transcribe(
            RemoteWhisperEngine(client: FakeWhisper.client(server)), ramp(seconds: 3), language: "ru,en")

        #expect(segments.isEmpty)
        #expect(server.paths == ["/v1/health", "/v1/vad"])
    }

    @Test("proof сошёлся — дальше каждый запрос (vad, language, full) с Bearer, а сам health — без")
    func bearerAfterProof() async throws {
        let server = try FakeWhisper.server(
            vad: { _ in FakeWhisper.spans(Self.vad) },
            language: { FakeWhisper.probs(Self.probabilities($0)) },
            full: { FakeWhisper.segments(Self.replies[$0.query["language"] ?? ""] ?? []) })
        defer { server.stop() }

        _ = try await transcribe(
            RemoteWhisperEngine(client: FakeWhisper.client(server)), ramp(seconds: 10), language: "ru,en")

        #expect(server.paths.first == "/v1/health")
        #expect(Set(server.paths) == ["/v1/health", "/v1/vad", "/v1/language", "/v1/full"])
        for request in server.requests {
            let expected = request.path == "/v1/health" ? nil : "Bearer \(FakeWhisper.token)"
            #expect(request.headers["authorization"] == expected, "\(request.path)")
        }
    }

    enum Stage: CaseIterable { case vad, language, vadUpload }

    @Test(
        "shouldAbort доходит до /v1/vad и /v1/language: флаг посреди запроса (ждём ответ или упёрлись в отправку) — interrupted быстро",
        arguments: Stage.allCases)
    func abortReachesEveryRequest(stage: Stage) async throws {
        let abort = AbortFlag()
        let stalled = stage == .language ? "/v1/language" : "/v1/vad"
        // Флаг взводит сам сервер, когда запрос уже у него: отмена приходится ровно на этот запрос.
        let server = try FakeWhisperServer(readsBody: stage != .vadUpload) { request, connection in
            switch request.path {
            case "/v1/health": connection.respond(200, FakeWhisper.health(for: request))
            case stalled:
                if !connection.pause(0.2) { abort.raise() }
                connection.hang()
            case "/v1/vad": connection.respond(200, FakeWhisper.spans(Self.vad))
            default: connection.respond(500, #"{"error":"unexpected request"}"#)
            }
        }
        defer { server.stop() }
        // 32 MB для застрявшей отправки — больше буферов loopback-сокета.
        let channel = stage == .vadUpload ? [Float](repeating: 0.25, count: 8_000_000) : ramp(seconds: 10)
        let client = FakeWhisper.client(server, timeouts: .init(health: 30, request: 5, idle: 5, stall: 30))
        let start = Date()

        let error = await #expect(throws: EarmarkError.self) {
            try await transcribe(
                RemoteWhisperEngine(client: client), channel, language: "ru,en", abort: abort)
        }

        #expect(abort.isRaised, "запрос \(stalled) до сервера не дошёл")
        #expect(error == .interrupted)
        #expect(Date().timeIntervalSince(start) < 2.5)
    }
}
