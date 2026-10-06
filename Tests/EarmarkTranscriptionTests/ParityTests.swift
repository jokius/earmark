import EarmarkAudio
import EarmarkCore
import Foundation
import Testing

@testable import EarmarkTranscription

/// Паритет с отлаженной связкой (§8.1): WhisperEngine на b5130 против brew whisper-cli с флагами
/// эталона, на синтетическом TTS. Только на dev-машине — нужны модель и whisper-cli, в CI пропуск.
enum Parity {
    static let whisperCLI = URL(fileURLWithPath: "/opt/homebrew/bin/whisper-cli")
    /// Там же, где её ищет CLI: ~/Library/Application Support/earmark/models (или $EARMARK_HOME/models).
    static var model: URL { ModelStore().path(for: Models.largeV3Turbo) }
    static var vad: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Resources/Models/\(Models.sileroVAD.fileName)")
    }
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["EARMARK_PARITY"] == "1"
            && [whisperCLI, model, vad].allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
    }

    static let text = """
        Добрый день, коллеги. Давайте начнём еженедельную встречу. Сначала обсудим сборку: \
        в прошлую пятницу тесты упали дважды. Потом посмотрим на план релиза и решим, что переносим \
        на следующую неделю. Если вопросов нет, переходим к задачам.
        """

    static func sh(_ tool: String, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "\(tool) завершился с \(process.terminationStatus)")
    }

    /// -oj whisper-cli: offsets — миллисекунды (t0/t1 × 10), text с ведущим пробелом.
    struct CLIOutput: Decodable {
        struct Item: Decodable {
            struct Offsets: Decodable { let from: Int; let to: Int }
            let offsets: Offsets
            let text: String
        }
        let transcription: [Item]
    }
}

@Suite("Паритет с whisper-cli", .enabled(if: Parity.enabled, "нужны EARMARK_PARITY=1, модель и whisper-cli"))
struct ParityTests {
    @Test("сегменты WhisperEngine совпадают с whisper-cli побайтно: текст и таймстемпы")
    func parity() async throws {
        // whisper.framework собран с COREML=1: найдя рядом с моделью *-encoder.mlmodelc, он молча
        // переводит энкодер на Core ML, и паритет ломается невнятным диффом сегментов.
        let coreML = Parity.model.deletingPathExtension().path + "-encoder.mlmodelc"
        try #require(
            !FileManager.default.fileExists(atPath: coreML),
            "рядом с моделью лежит \(coreML): энкодер уйдёт на Core ML, паритета с whisper-cli не будет")
        let dir = FileManager.default.temporaryDirectory.appending(
            path: "earmark-parity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let aiff = dir.appending(path: "fixture.aiff"), wav = dir.appending(path: "fixture.wav")
        try Parity.sh("/usr/bin/say", "-v", "Milena", "-o", aiff.path, Parity.text)
        try Parity.sh("/usr/bin/afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff.path, wav.path)
        try Parity.sh(
            Parity.whisperCLI.path, "-m", Parity.model.path, "-f", wav.path, "-l", "ru", "-np", "--vad",
            "-vm",
            Parity.vad.path, "--max-context", "0", "--entropy-thold", "2.8", "--temperature-inc", "0.2",
            "-oj",
            "-of", dir.appending(path: "cli").path)
        let reference = try JSONDecoder().decode(
            Parity.CLIOutput.self, from: Data(contentsOf: dir.appending(path: "cli.json"))
        ).transcription.map {
            RawSegment(
                startMs: $0.offsets.from, endMs: $0.offsets.to,
                text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let engine = try WhisperEngine(modelPath: Parity.model, vadModelPath: Parity.vad)
        let ours = try await engine.transcribe(
            try ChannelExtractor.extract(from: wav, channel: 0), params: .reference(language: "ru"),
            progress: { _ in /* прогресс здесь не проверяем */ }, shouldAbort: { false })

        #expect(!reference.isEmpty)
        #expect(ours == reference)
    }
}
