import EarmarkCore
import Foundation
import Synchronization
import os

/// whisper.cpp на своём сервере в LAN: те же примитивы, что у WhisperEngine, по HTTP, и та же
/// оркестрация (decode / decodeMulti / slice) — она синхронная и идёт на DedicatedThread, а каждый
/// примитив ждёт свой async-запрос на этом потоке, не занимая кооперативный пул.
public final class RemoteWhisperEngine: SpeechEngine, WhisperPrimitives {
    private let client: RemoteWhisperClient
    /// checkCompatible прошёл: сверяем один раз на объект, до первой отправки аудио.
    private let compatible = Mutex(false)

    public init(client: RemoteWhisperClient) {
        self.client = client
    }

    public func transcribe(
        _ samples: [Float], params: WhisperParams, progress: @escaping @Sendable (Int) -> Void,
        shouldAbort: @escaping @Sendable () -> Bool
    ) async throws(EarmarkError) -> [RawSegment] {
        guard !samples.isEmpty else { return [] }
        if !compatible.withLock({ $0 }) {
            _ = try await client.checkCompatible()
            compatible.withLock { $0 = true }
        }
        let callbacks = Callbacks(progress: progress, shouldAbort: shouldAbort)
        return try await DedicatedThread.run("whisper remote") { () throws(EarmarkError) -> [RawSegment] in
            try self.decode(samples, params, callbacks)
        }
    }

    func vad(_ samples: [Float], threads: Int32, shouldAbort: @escaping @Sendable () -> Bool)
        throws(EarmarkError) -> [RemoteVADSpan]
    {
        try wait { [client] () async throws(EarmarkError) in
            try await client.vad(samples[...], threads: threads, shouldAbort: shouldAbort)
        }
    }

    func languageProbabilities(
        _ samples: ArraySlice<Float>, threads: Int32, shouldAbort: @escaping @Sendable () -> Bool
    ) throws(EarmarkError) -> [String: Float] {
        try wait { [client] () async throws(EarmarkError) in
            try await client.language(samples, threads: threads, shouldAbort: shouldAbort)
        }
    }

    func whisperFull(_ samples: ArraySlice<Float>, _ params: WhisperParams, _ callbacks: Callbacks)
        throws(EarmarkError) -> [RemoteSegment]
    {
        try wait { [client] () async throws(EarmarkError) in
            try await client.full(
                samples, language: params.language, threads: params.threads, progress: callbacks.progress,
                shouldAbort: callbacks.shouldAbort)
        }
    }

    /// Ждёт async-вызов клиента на текущем (выделенном) потоке; сам запрос идёт отдельной задачей.
    private func wait<T: Sendable>(_ call: @escaping @Sendable () async throws(EarmarkError) -> T)
        throws(EarmarkError) -> T
    {
        let outcome = Outcome<T>()
        Task.detached {
            do throws(EarmarkError) {
                outcome.finish(.success(try await call()))
            } catch {
                outcome.finish(.failure(error))
            }
        }
        return try outcome.wait().get()
    }
}

/// Результат задачи для потока, который её ждёт.
private final class Outcome<T: Sendable>: Sendable {
    private let result = Mutex<Result<T, EarmarkError>?>(nil)
    private let done = DispatchSemaphore(value: 0)

    func finish(_ value: Result<T, EarmarkError>) {
        result.withLock { $0 = value }
        done.signal()
    }

    func wait() -> Result<T, EarmarkError> {
        done.wait()
        // finish записывает результат до signal, так что nil здесь не бывает.
        return result.withLock { $0 } ?? .failure(.operationFailed("remote call finished without a result"))
    }
}

/// Сначала удалённый движок, при любом его сбое (кроме отмены) — локальный.
final class FallbackSpeechEngine: SpeechEngine {
    typealias LocalFactory = @Sendable () async throws(EarmarkError) -> any SpeechEngine

    private static let logger = Logger(subsystem: EarmarkPaths.bundleID, category: "transcription")

    private let remote: any SpeechEngine
    private let makeLocal: LocalFactory
    /// remote сломан до конца жизни объекта; локальный движок поднимается одной задачей, один раз.
    private let state = Mutex<
        (remoteBroken: Bool, local: Task<Result<any SpeechEngine, EarmarkError>, Never>?)
    >(
        (false, nil))

    init(remote: any SpeechEngine, local: @escaping LocalFactory) {
        self.remote = remote
        self.makeLocal = local
    }

    func transcribe(
        _ samples: [Float], params: WhisperParams, progress: @escaping @Sendable (Int) -> Void,
        shouldAbort: @escaping @Sendable () -> Bool
    ) async throws(EarmarkError) -> [RawSegment] {
        if !state.withLock({ $0.remoteBroken }) {
            do throws(EarmarkError) {
                let segments = try await remote.transcribe(
                    samples, params: params, progress: progress, shouldAbort: shouldAbort)
                Self.logger.notice("transcribed channel remotely")
                return segments
            } catch {
                if error.code == EarmarkError.interrupted.code { throw error }
                Self.logger.error(
                    "remote transcription failed, transcribing locally: \(error.message, privacy: .public)")
                state.withLock { $0.remoteBroken = true }
                // Сбой совпал с SIGTERM: не поднимаем 1.6 GB модели ради отмены.
                if shouldAbort() { throw .interrupted }
            }
        }
        let engine = try await local()
        // Пока грузилась модель, мог прийти SIGTERM: как Transcriber после makeEngine.
        if shouldAbort() { throw .interrupted }
        return try await engine.transcribe(
            samples, params: params, progress: progress, shouldAbort: shouldAbort)
    }

    private func local() async throws(EarmarkError) -> any SpeechEngine {
        let task = state.withLock { state in
            if let task = state.local { return task }
            let task = Task { [makeLocal] () async -> Result<any SpeechEngine, EarmarkError> in
                do throws(EarmarkError) {
                    return .success(try await makeLocal())
                } catch {
                    return .failure(error)
                }
            }
            state.local = task
            return task
        }
        return try await task.value.get()
    }
}
