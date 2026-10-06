// Спайк S2 (Task 3): грузится ли whisper.framework в CLI из бандла через symlink и компилирует ли
// Metal под Hardened Runtime. Одноразовый: ветку `_whisper-probe` убирает Task 18, файл — Task 22.
// Параметры — эталонная связка (§8.1) из research/probes/probes/wprobe/Sources/wprobe/main.swift.

import AVFAudio
import Foundation
import whisper

public enum WhisperProbe {
    /// `earmark _whisper-probe <audio> [language]`. Модель — из EARMARK_PROBE_MODEL: своей у earmark
    /// ещё нет (Task 21), а чужую копию трогаем только на чтение.
    public static func run(_ args: [String]) -> Int32 {
        guard let audioPath = args.first else {
            fail("usage: earmark _whisper-probe <audio> [language]")
            return 64
        }
        let language = args.count > 1 ? args[1] : "ru"
        guard let modelPath = ProcessInfo.processInfo.environment["EARMARK_PROBE_MODEL"],
            FileManager.default.isReadableFile(atPath: modelPath)
        else {
            fail("EARMARK_PROBE_MODEL: model file is not set or not readable")
            return 69
        }
        // VAD лежит в Resources бандла. Путь строим от настоящего бинаря: запущенный через
        // ~/.local/bin/earmark executableURL может указывать на сам symlink.
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
            fail("Bundle.main.executableURL == nil")
            return 1
        }
        let vad = executable.deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Resources/ggml-silero-v5.1.2.bin")
        print("executable: \(executable.path)")
        print("vad: \(vad.path) exists=\(FileManager.default.fileExists(atPath: vad.path))")
        print("whisper: \(WhisperRuntime.version)")
        // Первый вызов ggml поднимает бэкенды, и на первом запуске нового бинаря Metal компилирует
        // встроенные шейдеры (~20 с, замер в прототипе). Поэтому system_info меряем отдельно от load.
        let backendStart = ContinuousClock.now
        let systemInfo = String(cString: whisper_print_system_info())
        print("backend_init_s: \(seconds(since: backendStart))")
        print("system_info: \(systemInfo)")

        var contextParams = whisper_context_default_params()
        contextParams.use_gpu = true
        contextParams.flash_attn = true
        let loadStart = ContinuousClock.now
        guard let context = whisper_init_from_file_with_params(modelPath, contextParams) else {
            fail("whisper_init_from_file_with_params returned NULL")
            return 1
        }
        defer { whisper_free(context) }
        print("load_s: \(seconds(since: loadStart))")

        let samples: [Float]
        do {
            samples = try load16kMono(URL(filePath: audioPath))
        } catch {
            fail("audio: \(error)")
            return 65
        }

        var params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)
        params.n_threads = Int32(min(4, ProcessInfo.processInfo.activeProcessorCount))
        // Пресет BEAM_SEARCH оставляет оба поля -1, и fallback идёт одним декодером.
        params.beam_search.beam_size = 5
        params.greedy.best_of = 5
        params.n_max_text_ctx = 0
        params.entropy_thold = 2.8
        params.temperature = 0
        params.temperature_inc = 0.2
        params.logprob_thold = -1
        params.no_speech_thold = 0.6
        params.detect_language = false
        params.no_context = true
        params.suppress_blank = true
        params.suppress_nst = false
        params.print_progress = false
        params.vad = true
        params.vad_params = whisper_vad_default_params()

        let runStart = ContinuousClock.now
        // C-строки language и vad_model_path обязаны жить весь вызов whisper_full (§8.1).
        let status = language.withCString { languagePointer in
            vad.path.withCString { vadPointer in
                params.language = languagePointer
                params.vad_model_path = vadPointer
                return samples.withUnsafeBufferPointer { buffer in
                    whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
                }
            }
        }
        let audioSeconds = String(format: "%.1f", Double(samples.count) / 16_000)
        print("whisper_full: \(status), run_s: \(seconds(since: runStart)), audio_s: \(audioSeconds)")
        guard status == 0 else { return 1 }
        for index in 0..<whisper_full_n_segments(context) {
            let start = Double(whisper_full_get_segment_t0(context, index)) / 100
            let end = Double(whisper_full_get_segment_t1(context, index)) / 100
            print("[\(start) -> \(end)] \(String(cString: whisper_full_get_segment_text(context, index)))")
        }
        return 0
    }

    /// Любой файл, который читает AVFoundation, → 16 kHz mono Float32 (вместо ffmpeg). Из wprobe.
    private static func load16kMono(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard
            let output = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
            let input = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
            let converter = AVAudioConverter(from: file.processingFormat, to: output)
        else { throw ProbeFailure(message: "cannot build a 16 kHz mono converter") }
        try file.read(into: input)
        let capacity = AVAudioFrameCount(
            Double(input.frameLength) * 16_000 / file.processingFormat.sampleRate)
        guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity + 4096) else {
            throw ProbeFailure(message: "cannot allocate the 16 kHz buffer")
        }
        var fed = false
        var conversionError: NSError?
        converter.convert(to: converted, error: &conversionError) { _, status in
            // Весь файл одним буфером, затем конец потока.
            if fed {
                status.pointee = .endOfStream
                return nil
            }
            fed = true
            status.pointee = .haveData
            return input
        }
        if let conversionError { throw conversionError }
        guard let channel = converted.floatChannelData?[0] else {
            throw ProbeFailure(message: "the converter returned no samples")
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
    }

    /// String(format:) — без локали: в ru_RU .formatted() печатал бы «1,76».
    private static func seconds(since start: ContinuousClock.Instant) -> String {
        String(format: "%.2f", (ContinuousClock.now - start) / .seconds(1))
    }

    private static func fail(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

private struct ProbeFailure: Error {
    let message: String
}
