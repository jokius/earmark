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

    /// Один язык или auto — весь канал одним вызовом whisper_full: резка ради памяти меняет границы
    /// окон, а паритет с эталоном при ней не проверен (§8.1). Список языков — по прогонам (decodeMulti).
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
        guard case .multi(let languages)? = TranscriptionLanguage(params.language) else {
            return try full(samples[...], params, callbacks)
        }
        return try decodeMulti(samples, params, languages, callbacks)
    }

    /// Список языков: VAD → куски до 30 с → язык куска из списка → прогоны одного языка, каждый
    /// своим whisper_full. auto определил бы язык один раз на весь канал, а один код переводит
    /// чужую речь в себя. Прогресс: 0–10 — определение языка, 10–100 — прогоны пропорционально длине.
    private func decodeMulti(
        _ samples: [Float], _ params: WhisperParams, _ languages: [String], _ callbacks: Callbacks
    ) throws(EarmarkError) -> [RawSegment] {
        let chunks = LanguagePlan.chunks(try speech(samples, threads: params.threads))
        var picked: [String] = []
        for (index, chunk) in chunks.enumerated() {
            if callbacks.shouldAbort() { throw .interrupted }
            callbacks.progress(index * 10 / chunks.count)
            let probabilities = try languageProbabilities(slice(samples, chunk), threads: params.threads)
            picked.append(LanguagePlan.pick(probabilities, allowed: languages))
        }
        let runs = LanguagePlan.runs(chunks, languages: picked)
        let total = max(1, runs.reduce(0) { $0 + $1.endMs - $1.startMs })
        var done = 0
        var segments: [RawSegment] = []
        for run in runs {
            if callbacks.shouldAbort() { throw .interrupted }
            let length = run.endMs - run.startMs
            let scaled = Callbacks(
                progress: { [done] percent in
                    let share = done * 100 + length * min(max(percent, 0), 100)
                    callbacks.progress(10 + 90 * share / (total * 100))
                },
                shouldAbort: callbacks.shouldAbort)
            var runParams = params
            runParams.language = run.language
            let span = SpeechSpan(startMs: run.startMs, endMs: run.endMs)
            // whisper считает время от начала переданных сэмплов: сдвигаем на начало прогона.
            segments += try full(slice(samples, span), runParams, scaled).map { segment in
                RawSegment(
                    startMs: segment.startMs + run.startMs, endMs: segment.endMs + run.startMs,
                    text: segment.text, language: run.language)
            }
            done += length
        }
        callbacks.progress(100)
        return segments
    }

    /// Отрезки речи отдельным VAD: тот же Silero с дефолтами, что whisper_full берёт внутри.
    /// VAD-контекст свой на вызов и освобождается на любом выходе.
    private func speech(_ samples: [Float], threads: Int32) throws(EarmarkError) -> [SpeechSpan] {
        var contextParams = whisper_vad_default_context_params()
        contextParams.n_threads = threads
        guard let vad = whisper_vad_init_from_file_with_params(vadModelPath, contextParams) else {
            throw .unavailable("whisper.cpp failed to load the VAD model \(vadModelPath)")
        }
        defer { whisper_vad_free(vad) }
        let found = samples.withUnsafeBufferPointer { pcm in
            whisper_vad_segments_from_samples(
                vad, whisper_vad_default_params(), pcm.baseAddress, Int32(pcm.count))
        }
        guard let found else { throw .operationFailed("whisper VAD failed to detect speech") }
        defer { whisper_vad_free_segments(found) }
        // t0/t1 — сантисекунды, как у сегментов whisper_full.
        return (0..<whisper_vad_segments_n_segments(found)).map { index in
            SpeechSpan(
                startMs: Int((whisper_vad_segments_get_segment_t0(found, index) * 10).rounded()),
                endMs: Int((whisper_vad_segments_get_segment_t1(found, index) * 10).rounded()))
        }
    }

    /// Вероятности всех языков whisper для куска: тот же энкодер и шаг декодера, что у auto.
    private func languageProbabilities(_ samples: ArraySlice<Float>, threads: Int32) throws(EarmarkError)
        -> [String: Float]
    {
        guard !samples.isEmpty else { return [:] }
        let mel = samples.withUnsafeBufferPointer { pcm in
            whisper_pcm_to_mel(context, pcm.baseAddress, Int32(pcm.count), threads)
        }
        guard mel == 0 else { throw .operationFailed("whisper_pcm_to_mel returned \(mel)") }
        var probabilities = [Float](repeating: 0, count: Int(whisper_lang_max_id()) + 1)
        let top = whisper_lang_auto_detect(context, 0, threads, &probabilities)
        guard top >= 0 else { throw .operationFailed("whisper_lang_auto_detect returned \(top)") }
        var byCode: [String: Float] = [:]
        for (id, probability) in probabilities.enumerated() {
            guard let code = whisper_lang_str(Int32(id)) else { continue }
            byCode[String(cString: code)] = probability
        }
        return byCode
    }

    /// Сэмплы отрезка в мс; границы VAD с паддингом могут чуть вылезать за канал — обрезаем.
    private func slice(_ samples: [Float], _ span: SpeechSpan) -> ArraySlice<Float> {
        let perMs = Int(WHISPER_SAMPLE_RATE) / 1000
        let lower = min(max(0, span.startMs * perMs), samples.count)
        let upper = min(max(lower, span.endMs * perMs), samples.count)
        return samples[lower..<upper]
    }

    /// Один whisper_full с эталонными параметрами; время сегментов — от начала samples.
    private func full(_ samples: ArraySlice<Float>, _ params: WhisperParams, _ callbacks: Callbacks)
        throws(EarmarkError) -> [RawSegment]
    {
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
