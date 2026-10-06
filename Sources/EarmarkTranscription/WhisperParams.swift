import Foundation
import whisper

/// Параметры эталонной связки (§8.1). Паритет с отлаженным whisper-cli держится только на точном
/// совпадении этих значений, поэтому они собраны в одном месте, а `version` входит в fingerprint:
/// поменял что-то здесь — подними версию, и готовые transcript.<ch>.json пересчитаются.
public struct WhisperParams: Equatable, Sendable {
    /// Код языка whisper или "auto": тогда whisper сам определяет язык на весь канал.
    public var language: String
    public var threads: Int32

    /// Как whisper-cli: потоков min(4, ядра) — больше на M-чипах не быстрее, энкодер всё равно на GPU.
    public static func reference(language: String) -> WhisperParams {
        WhisperParams(
            language: language, threads: Int32(min(4, ProcessInfo.processInfo.activeProcessorCount)))
    }

    public static let version = "ref-1"
}

extension WhisperParams {
    /// whisper_full_params ровно как у whisper-cli с флагами эталона
    /// (`-l <lang> --vad -vm <silero> --max-context 0 --entropy-thold 2.8 --temperature-inc 0.2`).
    /// Указатели должны жить весь вызов whisper_full: вызывающий держит их в withCString.
    func fullParams(language: UnsafePointer<CChar>, vadModelPath: UnsafePointer<CChar>) -> whisper_full_params
    {
        var params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)
        params.n_threads = threads
        params.beam_search.beam_size = 5
        // Пресет BEAM_SEARCH оставляет best_of = -1, и на temperature fallback декодер один,
        // а у whisper-cli их пять. Без этой строки паритет ломается ровно на трудных кусках.
        params.greedy.best_of = 5
        params.n_max_text_ctx = 0
        params.entropy_thold = 2.8
        params.temperature = 0
        params.temperature_inc = 0.2
        params.logprob_thold = -1
        params.no_speech_thold = 0.6
        params.language = language
        // true значило бы «только определить язык», без транскрипции; "auto" работает и так.
        params.detect_language = false
        params.no_context = true
        params.suppress_blank = true
        params.suppress_nst = false
        // Прогресс идёт через progress_callback в JSON-lines; печать whisper засоряла бы stderr.
        params.print_progress = false
        params.vad = true
        params.vad_model_path = vadModelPath
        params.vad_params = whisper_vad_default_params()
        return params
    }
}
