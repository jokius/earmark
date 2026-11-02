import EarmarkAudio
import EarmarkCore
import Foundation
import Synchronization
import Testing

@testable import EarmarkTranscription

/// Настоящая модель на синтетическом TTS, как у паритета, но whisper-cli не нужен: сверяем не с эталоном,
/// а с тем, что каждый кусок речи расшифрован на своём языке из списка и стоит на шкале канала.
enum MultiLanguage {
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["EARMARK_PARITY"] == "1"
            && [Parity.model, Parity.vad].allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
    }

    static let russian = """
        Добрый день, коллеги. Давайте начнём еженедельную встречу и сначала обсудим сборку: \
        в прошлую пятницу тесты упали дважды.
        """
    static let english = """
        Good afternoon, everyone. Let's review the release plan for next week \
        and decide which tasks we move to the next sprint.
        """

    /// 16 kHz моно-сэмплы фразы: say → AIFF → WAV 16 kHz → тот же ChannelExtractor, что у записи.
    static func speech(_ voice: String, _ text: String, in dir: URL) throws -> [Float] {
        let aiff = dir.appending(path: "\(voice).aiff"), wav = dir.appending(path: "\(voice).wav")
        try Parity.sh("/usr/bin/say", "-v", voice, "-o", aiff.path, text)
        try Parity.sh("/usr/bin/afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff.path, wav.path)
        return try ChannelExtractor.extract(from: wav, channel: 0)
    }

    static func hasCyrillic(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
    }

    static func hasLatin(_ text: String) -> Bool {
        text.unicodeScalars.contains { ("a"..."z").contains($0) || ("A"..."Z").contains($0) }
    }
}

@Suite(
    "Несколько языков на канале: настоящая модель",
    .enabled(if: MultiLanguage.enabled, "нужны EARMARK_PARITY=1, модель и Silero VAD"))
struct MultiLanguageTests {
    @Test("русская фраза, пауза, английская: каждый кусок на своём языке и на шкале канала")
    func russianThenEnglish() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(
            path: "earmark-langs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let russian = try MultiLanguage.speech("Milena", MultiLanguage.russian, in: dir)
        let english = try MultiLanguage.speech("Daniel", MultiLanguage.english, in: dir)
        // 1.5 с тишины — больше паузы склейки кусков (1 с): фразы гарантированно попадут в разные куски.
        let silence = [Float](repeating: 0, count: 24_000)
        let channel = russian + silence + english
        let russianEndMs = russian.count / 16
        let totalMs = channel.count / 16

        let engine = try WhisperEngine(modelPath: Parity.model, vadModelPath: Parity.vad)
        let progress = Mutex<[Int]>([])
        let segments = try await engine.transcribe(
            channel, params: .reference(language: "ru,en"),
            progress: { percent in progress.withLock { $0.append(percent) } }, shouldAbort: { false })

        let ru = segments.filter { $0.language == "ru" }
        let en = segments.filter { $0.language == "en" }
        #expect(!ru.isEmpty && !en.isEmpty, "\(segments)")
        #expect(ru.count + en.count == segments.count, "у каждого сегмента язык из списка: \(segments)")
        for segment in ru {
            #expect(MultiLanguage.hasCyrillic(segment.text), "\(segment)")
            #expect(segment.startMs < russianEndMs, "\(segment)")
        }
        for segment in en {
            #expect(MultiLanguage.hasLatin(segment.text), "\(segment)")
            #expect(!MultiLanguage.hasCyrillic(segment.text), "\(segment)")
            // Без сдвига на начало прогона английские сегменты начинались бы около нуля.
            #expect(segment.startMs >= russianEndMs, "\(segment)")
            #expect(segment.endMs <= totalMs + 500, "\(segment)")
        }
        #expect(zip(segments, segments.dropFirst()).allSatisfy { $0.startMs <= $1.startMs })
        let percents = progress.withLock { $0 }
        #expect(zip(percents, percents.dropFirst()).allSatisfy { $0 <= $1 }, "\(percents)")
        #expect(percents.last == 100, "\(percents)")

        // Один язык — прежний путь: сегменты без языка.
        let single = try await engine.transcribe(
            russian, params: .reference(language: "ru"), progress: { _ in /* здесь не проверяем */ },
            shouldAbort: { false })
        #expect(!single.isEmpty)
        #expect(single.allSatisfy { $0.language == nil })

        // Одна тишина при списке — пустой канал, а не ошибка.
        let quiet = try await engine.transcribe(
            [Float](repeating: 0, count: 48_000), params: .reference(language: "ru,en"),
            progress: { _ in /* здесь не проверяем */ }, shouldAbort: { false })
        #expect(quiet.isEmpty)

        // SIGTERM при списке — interrupted, как в одноязычном пути.
        let error = await #expect(throws: EarmarkError.self) {
            try await engine.transcribe(
                channel, params: .reference(language: "ru,en"), progress: { _ in /* здесь не проверяем */ },
                shouldAbort: { true })
        }
        #expect(error == .interrupted)
    }
}
