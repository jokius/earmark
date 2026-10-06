import EarmarkCore
import Foundation
import Testing

@testable import EarmarkCLI

@Suite("CLI: earmark transcribe --now")
struct TranscribeNowCommandTests {
    /// recordings_dir с одной завершённой записью (meta.json, status recorded).
    private func recordings() throws -> (config: Config, folder: URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "earmark-now-\(UUID().uuidString)")
        let folder = root.appending(path: "Manual/2026-10-02 14-00 Test")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let meta = """
            {"schema_version":1,"id":"20261002-1400-a1b2","status":"recorded","trigger":"manual",\
            "title":"Test","started_at":"2026-10-02T10:00:00Z","call_apps":[],"recovered":false,\
            "transcription":{"attempts":0},"app_version":"0.1.0"}
            """
        try Data(meta.utf8).write(to: folder.appending(path: RecordingFiles.meta))
        return (Config(values: ["recordings_dir": .string(root.path)]), folder)
    }

    private func emptyModels() -> ModelStore {
        ModelStore(
            dir: FileManager.default.temporaryDirectory.appending(path: "earmark-models-\(UUID().uuidString)")
        )
    }

    @Test("таблица команд разбирает transcribe <id> --now --force")
    func parse() throws {
        let cmd = try CommandTable.parse(["transcribe", "20261002-1400-a1b2", "--now", "--force"])
        #expect(cmd.path == ["transcribe"])
        #expect(cmd.arguments["id"] == "20261002-1400-a1b2")
        #expect(cmd.options["now"] == "true" && cmd.options["force"] == "true")
    }

    @Test("нет модели — unavailable (69), meta не тронута: попытка не потрачена")
    func modelMissing() throws {
        let (config, folder) = try recordings()

        let error = #expect(throws: EarmarkError.self) {
            try TranscribeNowCommand.locate(
                id: "20261002-1400-a1b2", config: config, modelStore: emptyModels(), vadModel: nil)
        }

        #expect(error?.exitCode == 69)
        let meta = try #require(try RecordingStore(root: config.recordingsDir).readMeta(in: folder))
        #expect(meta.status == .recorded)
        #expect(meta.transcription.attempts == 0)
    }

    @Test("неизвестный id — not_found (2)")
    func unknownID() throws {
        let (config, _) = try recordings()

        let error = #expect(throws: EarmarkError.self) {
            try TranscribeNowCommand.locate(
                id: "20990101-0000-ffff", config: config, modelStore: emptyModels(), vadModel: nil)
        }

        #expect(error?.exitCode == 2)
    }

    @Test("битый config.json — unavailable (69): виновата машина, а не запись")
    func unreadableConfig() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "earmark-cfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "config.json")
        try Data("{".utf8).write(to: url)
        let parsed = try CommandTable.parse(["transcribe", "20261002-1400-a1b2", "--now"])

        // run падает на чтении конфига — раньше, чем ставит обработчик SIGTERM.
        let error = await #expect(throws: EarmarkError.self) {
            try await TranscribeNowCommand.run(parsed, CLIContext(configStore: ConfigStore(url: url)))
        }

        #expect(error?.code == "unavailable")
        #expect(error?.exitCode == 69)
    }
}
