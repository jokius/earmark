// Copyright (c) 2026 Andrew Jones (MIT)
// Copyright (c) 2026 Samat Galimov (MIT)
// Портировано из amanu@fbccc13: Sources/amanu/Transcription/WhisperEngine.swift (WhisperCPPRuntime),
// параметры заменены эталонными (WhisperParams), чанкинг по 10 минут убран.

import EarmarkCore
import Foundation
import whisper

/// Шов между Transcriber и движком: настоящий WhisperEngine и фейк в тестах Transcriber.
protocol SpeechEngine: Sendable {
    func transcribe(
        _ samples: [Float], params: WhisperParams, progress: @escaping @Sendable (Int) -> Void,
        shouldAbort: @escaping @Sendable () -> Bool
    ) async throws(EarmarkError) -> [RawSegment]
}

extension EarmarkError {
    /// Вытеснение (SIGTERM от app) или отмена. Не ошибка записи: попытка не засчитывается,
    /// а exit 75 значит для очереди «повтори позже».
    static let interrupted = EarmarkError(
        code: "interrupted", message: "transcription interrupted (signal or cancellation)", exitCode: .busy)
}

/// whisper.cpp внутри воркера `earmark transcribe --now`, никогда в app: ggml на любом assert
/// делает abort(), а после whisper_free в процессе остаётся ~233 MB.
///
/// Один контекст на оба канала: модель грузится один раз.
public final class WhisperEngine: SpeechEngine, @unchecked Sendable {
    /// whisper_context нельзя трогать из двух потоков сразу (whisper.h). Transcriber и так ходит
    /// по каналам последовательно; lock делает @unchecked Sendable честным.
    private let lock = NSLock()
    private let context: OpaquePointer
    private let vadModelPath: String

    /// Модель и VAD не загрузились — unavailable: виновата машина, а не запись (попытка не считается).
    public init(modelPath: URL, vadModelPath: URL) throws(EarmarkError) {
        guard FileManager.default.fileExists(atPath: vadModelPath.path) else {
            throw .unavailable("VAD model not found: \(vadModelPath.path)")
        }
        Self.silenceLogsUnlessAsked()
        var params = whisper_context_default_params()
        params.use_gpu = true
        params.flash_attn = true
        guard let context = whisper_init_from_file_with_params(modelPath.path, params) else {
            throw .unavailable("whisper.cpp failed to load the model \(modelPath.path)")
        }
        self.context = context
        self.vadModelPath = vadModelPath.path
    }

    deinit { whisper_free(context) }

    /// Весь канал одним вызовом whisper_full: резка ради памяти меняет границы окон,
    /// а паритет с эталоном при ней не проверен (§8.1).
    public func transcribe(
        _ samples: [Float], params: WhisperParams, progress: @escaping @Sendable (Int) -> Void,
        shouldAbort: @escaping @Sendable () -> Bool
    ) async throws(EarmarkError) -> [RawSegment] {
        guard !samples.isEmpty else { return [] }
        let callbacks = Callbacks(progress: progress, shouldAbort: shouldAbort)
        return try await DedicatedThread.run("whisper") { () throws(EarmarkError) -> [RawSegment] in
            try self.decode(samples, params, callbacks)
        }
    }

    private func decode(_ samples: [Float], _ params: WhisperParams, _ callbacks: Callbacks)
        throws(EarmarkError)
        -> [RawSegment]
    {
        lock.lock()
        defer { lock.unlock() }
        // C-колбэки не захватывают контекст: замыкания едут через user_data.
        let box = Unmanaged.passRetained(callbacks)
        defer { box.release() }
        let code = params.language.withCString { language in
            vadModelPath.withCString { vad in
                var full = params.fullParams(language: language, vadModelPath: vad)
                full.progress_callback = { _, _, percent, user in
                    guard let user else { return }
                    Unmanaged<Callbacks>.fromOpaque(user).takeUnretainedValue().progress(Int(percent))
                }
                full.progress_callback_user_data = box.toOpaque()
                // Зовётся перед каждым вычислением ggml: по SIGTERM выходим меньше чем за секунду.
                full.abort_callback = { user in
                    guard let user else { return false }
                    return Unmanaged<Callbacks>.fromOpaque(user).takeUnretainedValue().shouldAbort()
                }
                full.abort_callback_user_data = box.toOpaque()
                return samples.withUnsafeBufferPointer { pcm in
                    whisper_full(context, full, pcm.baseAddress, Int32(pcm.count))
                }
            }
        }
        if callbacks.shouldAbort() { throw .interrupted }
        guard code == 0 else { throw .operationFailed("whisper_full returned \(code)") }
        // t0/t1 — сантисекунды на исходной шкале (VAD уже пересчитан), отсюда ×10.
        return (0..<whisper_full_n_segments(context)).map { index in
            RawSegment(
                startMs: Int(whisper_full_get_segment_t0(context, index)) * 10,
                endMs: Int(whisper_full_get_segment_t1(context, index)) * 10,
                text: whisper_full_get_segment_text(context, index).map { String(cString: $0) }?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        }
    }

    /// whisper и ggml по умолчанию пишут в stderr сотни строк, а stderr воркера — канал JSON-ошибки,
    /// которую читает очередь в app. EARMARK_WHISPER_LOG=1 возвращает логи для отладки.
    private static func silenceLogsUnlessAsked() {
        guard ProcessInfo.processInfo.environment["EARMARK_WHISPER_LOG"] == nil else { return }
        whisper_log_set({ _, _, _ in /* молчим */ }, nil)
    }
}

private final class Callbacks: Sendable {
    let progress: @Sendable (Int) -> Void
    let shouldAbort: @Sendable () -> Bool

    init(progress: @escaping @Sendable (Int) -> Void, shouldAbort: @escaping @Sendable () -> Bool) {
        self.progress = progress
        self.shouldAbort = shouldAbort
    }
}
