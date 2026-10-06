import Foundation
import Testing
import whisper

@testable import EarmarkTranscription

@Suite("Параметры whisper")
struct WhisperParamsTests {
    @Test("whisper_full_params совпадают с whisper-cli эталона, включая ловушку best_of")
    func referenceParams() {
        let params = WhisperParams.reference(language: "ru")
        #expect(params.threads == Int32(min(4, ProcessInfo.processInfo.activeProcessorCount)))
        "ru".withCString { language in
            "/tmp/vad.bin".withCString { vad in
                let full = params.fullParams(language: language, vadModelPath: vad)
                #expect(full.strategy == WHISPER_SAMPLING_BEAM_SEARCH)
                #expect(full.beam_search.beam_size == 5)
                #expect(full.greedy.best_of == 5)
                #expect(full.n_max_text_ctx == 0)
                #expect(full.entropy_thold == 2.8)
                #expect(full.temperature == 0 && full.temperature_inc == 0.2)
                #expect(full.logprob_thold == -1 && full.no_speech_thold == 0.6)
                #expect(String(cString: full.language) == "ru" && !full.detect_language)
                #expect(full.no_context && full.suppress_blank && !full.suppress_nst)
                #expect(full.vad && String(cString: full.vad_model_path) == "/tmp/vad.bin")
                #expect(full.vad_params.threshold == 0.5 && full.vad_params.min_speech_duration_ms == 250)
            }
        }
    }
}
