import EarmarkCore
import Foundation
import Synchronization
import Testing

@testable import EarmarkTranscription

/// Движок-фейк: на каждый вызов один и тот же ответ, запоминает сэмплы и параметры.
private final class ScriptedEngine: SpeechEngine {
    struct Call: Equatable {
        var samples: [Float]
        var language: String
        var threads: Int32
    }

    private let reply: Mutex<Result<[RawSegment], EarmarkError>>
    private let log = Mutex<[Call]>([])

    init(_ reply: Result<[RawSegment], EarmarkError>) { self.reply = Mutex(reply) }

    var calls: [Call] { log.withLock { $0 } }
    func answer(_ reply: Result<[RawSegment], EarmarkError>) { self.reply.withLock { $0 = reply } }

    func transcribe(
        _ samples: [Float], params: WhisperParams, progress: @escaping @Sendable (Int) -> Void,
        shouldAbort: @escaping @Sendable () -> Bool
    ) async throws(EarmarkError) -> [RawSegment] {
        log.withLock { $0.append(Call(samples: samples, language: params.language, threads: params.threads)) }
        return try reply.withLock { $0 }.get()
    }
}

/// Фабрика локального движка со счётчиком вызовов.
private final class LocalFactory: Sendable {
    private let made = Mutex(0)
    private let result: Result<ScriptedEngine, EarmarkError>

    init(_ result: Result<ScriptedEngine, EarmarkError>) { self.result = result }

    var created: Int { made.withLock { $0 } }

    func make() throws(EarmarkError) -> any SpeechEngine {
        made.withLock { $0 += 1 }
        return try result.get()
    }
}

private let remoteSegments = [RawSegment(startMs: 0, endMs: 900, text: "удалённо")]
private let localSegments = [RawSegment(startMs: 100, endMs: 800, text: "локально")]

private func fallback(_ remote: ScriptedEngine, _ local: LocalFactory) -> FallbackSpeechEngine {
    FallbackSpeechEngine(remote: remote) { () async throws(EarmarkError) -> any SpeechEngine in
        try local.make()
    }
}

private func transcribe(
    _ engine: FallbackSpeechEngine, _ samples: [Float], language: String = "ru",
    abort: @escaping @Sendable () -> Bool = { false }
) async throws(EarmarkError) -> [RawSegment] {
    try await engine.transcribe(
        samples, params: .reference(language: language), progress: { _ in /* здесь не проверяем */ },
        shouldAbort: abort)
}

@Suite("FallbackSpeechEngine: удалённо, при сбое — локально")
struct FallbackSpeechEngineTests {
    @Test("remote справился — его сегменты, локальная модель не создаётся")
    func remoteSucceeds() async throws {
        let remote = ScriptedEngine(.success(remoteSegments))
        let local = LocalFactory(.success(ScriptedEngine(.success(localSegments))))

        let segments = try await transcribe(fallback(remote, local), [1, 2, 3])

        #expect(segments == remoteSegments)
        #expect(remote.calls.map(\.samples) == [[1, 2, 3]])
        #expect(local.created == 0)
    }

    @Test(
        "сбой remote — тот же канал с теми же параметрами считает локальный движок",
        arguments: [
            EarmarkError.remoteFailed("connection refused"), .operationFailed("not what we expected"),
            .unavailable("server busy"),
        ])
    func remoteFailsOver(failure: EarmarkError) async throws {
        let remote = ScriptedEngine(.failure(failure))
        let localEngine = ScriptedEngine(.success(localSegments))
        let local = LocalFactory(.success(localEngine))

        let segments = try await transcribe(fallback(remote, local), [0.5, -0.5, 0.25], language: "ru,en")

        #expect(segments == localSegments)
        #expect(local.created == 1)
        #expect(remote.calls.count == 1)
        #expect(localEngine.calls == remote.calls)
        #expect(localEngine.calls.first?.language == "ru,en")
    }

    @Test("после сбоя remote больше не зовётся: следующие каналы сразу локально, фабрика — один раз")
    func brokenForLifetime() async throws {
        let remote = ScriptedEngine(.failure(.remoteFailed("timed out")))
        let localEngine = ScriptedEngine(.success(localSegments))
        let local = LocalFactory(.success(localEngine))
        let engine = fallback(remote, local)

        _ = try await transcribe(engine, [1])
        remote.answer(.success(remoteSegments))  // сервер «ожил» — объекту уже всё равно
        let second = try await transcribe(engine, [2])
        let third = try await transcribe(engine, [3])

        #expect(second == localSegments && third == localSegments)
        #expect(remote.calls.map(\.samples) == [[1]])
        #expect(localEngine.calls.map(\.samples) == [[1], [2], [3]])
        #expect(local.created == 1)
    }

    @Test("interrupted от remote пробрасывается как есть, без локального; remote не считается сломанным")
    func interruptedPassesThrough() async throws {
        let remote = ScriptedEngine(.failure(.interrupted))
        let local = LocalFactory(.success(ScriptedEngine(.success(localSegments))))
        let engine = fallback(remote, local)

        let error = await #expect(throws: EarmarkError.self) { try await transcribe(engine, [1]) }

        #expect(error == .interrupted)
        #expect(local.created == 0)

        remote.answer(.success(remoteSegments))
        #expect(try await transcribe(engine, [2]) == remoteSegments)
        #expect(remote.calls.count == 2)
        #expect(local.created == 0)
    }

    @Test("локальную модель поднять не удалось — эта ошибка и пробрасывается")
    func localFactoryFails() async throws {
        let remote = ScriptedEngine(.failure(.remoteFailed("connection refused")))
        let missing = EarmarkError.unavailable("whisper.cpp failed to load the model")
        let local = LocalFactory(.failure(missing))

        let error = await #expect(throws: EarmarkError.self) {
            try await transcribe(fallback(remote, local), [1])
        }

        #expect(error == missing)
    }

    @Test(
        "remote упал не interrupted'ом, а shouldAbort уже true — interrupted, локальная модель не грузится",
        arguments: [
            EarmarkError.remoteFailed("request cancelled"), .remoteFailed("connection refused"),
            .operationFailed("not what we expected"),
        ])
    func abortedBeforeFallback(failure: EarmarkError) async throws {
        let remote = ScriptedEngine(.failure(failure))
        let localEngine = ScriptedEngine(.success(localSegments))
        let local = LocalFactory(.success(localEngine))

        let error = await #expect(throws: EarmarkError.self) {
            try await transcribe(fallback(remote, local), [1], abort: { true })
        }

        #expect(error == .interrupted)
        #expect(local.created == 0)
        #expect(localEngine.calls.isEmpty)
    }

    @Test(
        "shouldAbort взвёлся, пока поднимали локальную модель — interrupted, локальный transcribe не зовётся")
    func abortedWhileLoadingLocal() async throws {
        let remote = ScriptedEngine(.failure(.remoteFailed("connection refused")))
        let localEngine = ScriptedEngine(.success(localSegments))
        let abort = AbortFlag()
        let engine = FallbackSpeechEngine(remote: remote) {
            () async throws(EarmarkError) -> any SpeechEngine in
            abort.raise()  // модель грузилась долго, пользователь успел остановить
            return localEngine
        }

        let error = await #expect(throws: EarmarkError.self) {
            try await transcribe(engine, [1], abort: { abort.isRaised })
        }

        #expect(abort.isRaised, "фабрика локального движка не вызывалась")
        #expect(error == .interrupted)
        #expect(localEngine.calls.isEmpty)
    }

    @Test("ошибка локального transcribe пробрасывается как есть")
    func localTranscribeFails() async throws {
        let remote = ScriptedEngine(.failure(.remoteFailed("HTTP 500")))
        let boom = EarmarkError.operationFailed("whisper_full returned -6")
        let local = LocalFactory(.success(ScriptedEngine(.failure(boom))))

        let error = await #expect(throws: EarmarkError.self) {
            try await transcribe(fallback(remote, local), [1])
        }

        #expect(error == boom)
    }
}
