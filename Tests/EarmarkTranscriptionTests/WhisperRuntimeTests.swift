import EarmarkTranscription
import Testing

struct WhisperRuntimeTests {
    /// whisper.framework подключён бинарным таргетом и грузится по @rpath. Сломанный checksum,
    /// раскладка zip или rpath падают здесь, а не посреди первой транскрипции.
    @Test func frameworkLoads() {
        #expect(WhisperRuntime.version == "1.9.4-dev")
    }
}
