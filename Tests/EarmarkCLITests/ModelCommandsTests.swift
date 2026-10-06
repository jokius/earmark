import EarmarkCore
import Foundation
import Testing

@testable import EarmarkCLI

@Suite("CLI: earmark model")
struct ModelCommandsTests {
    private func emptyDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "earmark-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Registry знает model status/download/import, у import аргумент path")
    func wiring() throws {
        #expect(try CommandTable.parse(["model", "import", "/tmp/m.bin"]).arguments["path"] == "/tmp/m.bin")
        for key in ["model status", "model download", "model import"] {
            #expect(Registry.handlers[key] != nil, "нет обработчика \(key)")
        }
    }

    @Test("model status без модели — state missing")
    func statusMissing() throws {
        let data = try ModelCommands.state(store: ModelStore(dir: try emptyDir()))
        #expect(data["state"]?.stringValue == "missing")
    }

    @Test("model import чужого файла — bad_data (exit 65), модели не появилось")
    func importWrongFile() throws {
        let wrong = try emptyDir().appending(path: "not-a-model.bin")
        try Data("не модель".utf8).write(to: wrong)
        let store = ModelStore(dir: try emptyDir())

        let error = #expect(throws: EarmarkError.self) { try ModelCommands.copy(wrong.path, store: store) }

        #expect(error?.exitCode == 65)
        #expect(!FileManager.default.fileExists(atPath: store.path(for: Models.largeV3Turbo).path))
    }
}
