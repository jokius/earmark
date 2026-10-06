import Foundation
import Testing

@testable import EarmarkCore

@Suite("AtomicFile: всё или ничего")
struct AtomicFileTests {
    /// Свежий каталог на каждый тест: Swift Testing гоняет тесты параллельно.
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("earmark-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("перезапись заменяет содержимое, файл 0600, temp-файлов не остаётся")
    func overwriteLeavesNoTemp() throws {
        let dir = try makeTempDir()
        let target = dir.appendingPathComponent("meta.json")

        try AtomicFile.write(Data("old".utf8), to: target)
        try AtomicFile.write(Data("new".utf8), to: target)

        #expect(try String(contentsOf: target, encoding: .utf8) == "new")
        let mode = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["meta.json"])
    }

    @Test("запись в несуществующий каталог падает и ничего не создаёт")
    func missingDirectoryFails() throws {
        let missing = try makeTempDir().appendingPathComponent("absent", isDirectory: true)

        #expect(throws: (any Error).self) {
            try AtomicFile.write(Data("x".utf8), to: missing.appendingPathComponent("meta.json"))
        }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test("если rename не удался, цель цела, а temp удалён")
    func failedRenameKeepsTarget() throws {
        let dir = try makeTempDir()
        // rename(2) файла поверх непустого каталога падает — temp к этому моменту уже записан
        let target = dir.appendingPathComponent("meta.json", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try Data("old".utf8).write(to: target.appendingPathComponent("inside.txt"))

        #expect(throws: (any Error).self) { try AtomicFile.write(Data("new".utf8), to: target) }

        #expect(try String(contentsOf: target.appendingPathComponent("inside.txt"), encoding: .utf8) == "old")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["meta.json"])
    }
}
