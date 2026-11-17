import EarmarkAudio
import EarmarkCore
import Foundation
import Testing

@testable import EarmarkTranscription

/// Паритет удалённого сервера с локальным whisper на одном и том же TTS. Только по явному запросу:
/// нужен живой сервер в LAN, его токен и локальные модель с VAD.
enum RemoteParity {
    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    static var url: URL? { environment["EARMARK_REMOTE_URL"].flatMap { URL(string: $0) } }

    static var tokenFile: URL {
        environment["EARMARK_REMOTE_TOKEN_FILE"].map { URL(fileURLWithPath: $0) }
            ?? EarmarkPaths.remoteTokenFile
    }

    static var enabled: Bool {
        environment["EARMARK_REMOTE_PARITY"] == "1" && url != nil
            && FileManager.default.fileExists(atPath: tokenFile.path)
            && [Parity.model, Parity.vad].allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func engines() throws -> (local: WhisperEngine, remote: RemoteWhisperEngine) {
        // Core ML-энкодер рядом с моделью уводит локальный энкодер с Metal: паритета не будет.
        let coreML = Parity.model.deletingPathExtension().path + "-encoder.mlmodelc"
        try #require(!FileManager.default.fileExists(atPath: coreML), "рядом с моделью лежит \(coreML)")
        let token =
            try String(contentsOf: tokenFile, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let client = RemoteWhisperClient(baseURL: try #require(url), token: token)
        return (
            try WhisperEngine(modelPath: Parity.model, vadModelPath: Parity.vad),
            RemoteWhisperEngine(client: client)
        )
    }

    static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(
            path: "earmark-remote-parity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func transcribe(_ engine: some SpeechEngine, _ samples: [Float], language: String) async throws
        -> [RawSegment]
    {
        try await engine.transcribe(
            samples, params: .reference(language: language), progress: { _ in /* здесь не проверяем */ },
            shouldAbort: { false })
    }
}

@Suite(
    "Паритет удалённого whisper с локальным",
    .enabled(
        if: RemoteParity.enabled,
        "нужны EARMARK_REMOTE_PARITY=1, EARMARK_REMOTE_URL, токен (remote-token или EARMARK_REMOTE_TOKEN_FILE), модель и VAD"
    ))
struct RemoteParityTests {
    @Test("один язык (ru): сегменты сервера совпадают с локальными — текст и таймстемпы")
    func singleLanguage() async throws {
        let (local, remote) = try RemoteParity.engines()
        let channel = try MultiLanguage.speech("Milena", Parity.text, in: try RemoteParity.tempDir())

        let ours = try await RemoteParity.transcribe(local, channel, language: "ru")
        let theirs = try await RemoteParity.transcribe(remote, channel, language: "ru")

        #expect(!ours.isEmpty)
        #expect(theirs == ours)
    }

    @Test("список языков (ru,en): русская фраза, пауза, английская — сегменты и языки совпадают")
    func languageList() async throws {
        let (local, remote) = try RemoteParity.engines()
        let dir = try RemoteParity.tempDir()
        let channel =
            try MultiLanguage.speech("Milena", MultiLanguage.russian, in: dir)
            + [Float](repeating: 0, count: 24_000)
            + MultiLanguage.speech("Daniel", MultiLanguage.english, in: dir)

        let ours = try await RemoteParity.transcribe(local, channel, language: "ru,en")
        let theirs = try await RemoteParity.transcribe(remote, channel, language: "ru,en")

        #expect(Set(ours.compactMap(\.language)) == ["ru", "en"])
        #expect(theirs == ours)
    }
}
