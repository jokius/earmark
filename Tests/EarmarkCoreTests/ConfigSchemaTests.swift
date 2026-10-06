import Foundation
import Testing

@testable import EarmarkCore

@Suite("Схема конфига: разбор строки из CLI и валидация")
struct ConfigSchemaTests {
    /// Свежий каталог на каждый тест: Swift Testing гоняет тесты параллельно.
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("earmark-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Разбор recordings_dir падает с invalidValue, и причина называет TCC.
    private func expectTCCRejection(_ raw: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let error = #expect(throws: ConfigError.self, sourceLocation: sourceLocation) {
            try ConfigSchema.parse(raw, for: "recordings_dir")
        }
        guard case .invalidValue(_, let reason)? = error else {
            Issue.record(
                "ожидали invalidValue, получили \(String(describing: error))", sourceLocation: sourceLocation)
            return
        }
        #expect(reason.contains("TCC-protected"), sourceLocation: sourceLocation)
    }

    @Test(
        "разбор по типу ключа",
        arguments: [
            ("auto_record", "true", ConfigValue.bool(true)),
            ("auto_record", "YES", .bool(true)),
            ("auto_record", "on", .bool(true)),
            ("auto_record", "1", .bool(true)),
            ("launch_at_login", "false", .bool(false)),
            ("launch_at_login", "No", .bool(false)),
            ("launch_at_login", "off", .bool(false)),
            ("launch_at_login", "0", .bool(false)),
            ("lead_seconds", " 0 ", .int(0)),
            ("lead_seconds", "3600", .int(3600)),
            ("calendar.CAL-1.lead_seconds", "120", .int(120)),
            ("stop.max_minutes", "1440", .int(1440)),
            ("calendars", "a, b,,c ", .stringList(["a", "b", "c"])),
            ("calendars", #"["x", " y ", ""]"#, .stringList(["x", "y"])),
            ("calendars", "", .stringList([])),
            ("calendar.CAL-1.folder", "Calls", .string("Calls")),
            ("transcription.language", "auto", .string("auto")),
            ("transcription.language", "ru", .string("ru")),
            ("transcription.language", "haw", .string("haw")),
            ("transcript.label_me", " Я ", .string("Я")),
        ])
    func parses(key: String, raw: String, expected: ConfigValue) throws {
        #expect(try ConfigSchema.parse(raw, for: key) == expected)
    }

    @Test(
        "невалидное значение — invalidValue с этим ключом",
        arguments: [
            ("auto_record", "maybe"),
            ("lead_seconds", "soon"),
            ("lead_seconds", "-1"),
            ("lead_seconds", "3601"),
            ("lead_seconds", "1.5"),
            ("calendar.CAL-1.lead_seconds", "4000"),
            ("stop.max_minutes", "0"),
            ("stop.silence_minutes", "241"),
            ("calendars", "[1, 2]"),
            ("calendar.CAL-1.folder", ""),
            ("calendar.CAL-1.folder", "a/b"),
            ("calendar.CAL-1.folder", "a:b"),
            ("calendar.CAL-1.folder", ".."),
            ("transcription.language", "russian"),
            ("transcription.language", "RU"),
            ("transcription.language", "r"),
            ("transcript.label_them", "   "),
            ("recordings_dir", "relative/dir"),
            ("recordings_dir", "/System/earmark-test"),
        ])
    func rejects(key: String, raw: String) {
        let error = #expect(throws: ConfigError.self) { try ConfigSchema.parse(raw, for: key) }
        guard case .invalidValue(let rejected, _)? = error else {
            Issue.record("ожидали invalidValue, получили \(String(describing: error))")
            return
        }
        #expect(rejected == key)
    }

    @Test(
        "Desktop, Documents, Downloads и всё внутри них отклоняются с упоминанием TCC",
        arguments: [
            "~/Desktop", "~/Documents", "~/Downloads", "~/Documents/Earmark", "~/downloads/x",
            "~/Desktop/../Desktop/r",
        ])
    func protectedFolders(raw: String) {
        expectTCCRejection(raw)
    }

    /// Ссылка лежит в своём временном каталоге, внутри защищённой папки ничего не создаём.
    /// HOME подменить нельзя: Foundation берёт домашний каталог не из $HOME, поэтому цель — настоящая папка.
    @Test(
        "симлинк на защищённую папку и ещё не созданный путь за ним отклоняются с упоминанием TCC",
        arguments: ["Downloads", "Desktop"], ["", "/NotYetCreated", "/a/b"])
    func symlinkToProtectedFolder(target: String, suffix: String) throws {
        let link = try makeTempDir().appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(target)
        )
        expectTCCRejection(link.path + suffix)
    }

    enum DanglingShape: CaseIterable {
        /// link → ~/Downloads/<нет такого>
        case direct
        /// link2 → link → ~/Downloads/<нет такого>
        case chain
        /// l2 → ~/Downloads, mid → <temp>/l2/<нет такого>
        case middle
    }

    /// Цель висячей ссылки — отсутствующее имя внутри ~/Downloads: там ничего не создаём,
    /// разбор делает только поиск этого имени.
    @Test(
        "висячий симлинк в защищённую папку (прямо, цепочкой, ссылкой в середине) отклоняется с упоминанием TCC",
        arguments: DanglingShape.allCases, ["", "/x"])
    func danglingSymlinkToProtectedFolder(shape: DanglingShape, suffix: String) throws {
        let files = FileManager.default
        let dir = try makeTempDir()
        let downloads = files.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let missing = "missing-\(UUID().uuidString)"
        let danglingTarget = downloads.appendingPathComponent(missing)

        let entry: URL
        switch shape {
        case .direct:
            entry = dir.appendingPathComponent("link")
            try files.createSymbolicLink(at: entry, withDestinationURL: danglingTarget)
        case .chain:
            let link = dir.appendingPathComponent("link")
            try files.createSymbolicLink(at: link, withDestinationURL: danglingTarget)
            entry = dir.appendingPathComponent("link2")
            try files.createSymbolicLink(at: entry, withDestinationURL: link)
        case .middle:
            let l2 = dir.appendingPathComponent("l2")
            try files.createSymbolicLink(at: l2, withDestinationURL: downloads)
            entry = dir.appendingPathComponent("mid")
            try files.createSymbolicLink(at: entry, withDestinationURL: l2.appendingPathComponent(missing))
        }
        expectTCCRejection(entry.path + suffix)
    }

    /// Итог разбора из рабочего потока: пишется до signal, читается только после успешного wait.
    private final class ParseOutcome: @unchecked Sendable {
        var result: Result<ConfigValue, ConfigError>?
    }

    @Test("петля симлинков не вешает разбор и отклоняется", arguments: ["", "/x"])
    func symlinkLoop(suffix: String) throws {
        let dir = try makeTempDir()
        let loopA = dir.appendingPathComponent("loopA")
        let loopB = dir.appendingPathComponent("loopB")
        try FileManager.default.createSymbolicLink(at: loopA, withDestinationURL: loopB)
        try FileManager.default.createSymbolicLink(at: loopB, withDestinationURL: loopA)

        // Отдельный поток: зациклившийся разбор роняет тест по таймауту, а не вешает весь прогон.
        let raw = loopA.path + suffix
        let outcome = ParseOutcome()
        let done = DispatchSemaphore(value: 0)
        Thread {
            outcome.result = Result { () throws(ConfigError) in
                try ConfigSchema.parse(raw, for: "recordings_dir")
            }
            done.signal()
        }.start()
        guard done.wait(timeout: .now() + 10) == .success else {
            Issue.record("разбор петли симлинков не вернулся за 10 с")
            return
        }
        guard case .failure(.invalidValue(let key, _))? = outcome.result else {
            Issue.record("ожидали invalidValue, получили \(String(describing: outcome.result))")
            return
        }
        #expect(key == "recordings_dir")
    }

    @Test("путь: ~ раскрывается, путь нормализуется; файл вместо каталога отклоняется")
    func paths() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(try ConfigSchema.parse("~/Earmark", for: "recordings_dir") == .string(home + "/Earmark"))

        let dir = try makeTempDir()
        let nested = dir.appendingPathComponent("a/../rec").path
        #expect(
            try ConfigSchema.parse(nested, for: "recordings_dir")
                == .string(dir.appendingPathComponent("rec").path))

        let file = dir.appendingPathComponent("plain.txt")
        try Data().write(to: file)
        #expect(throws: ConfigError.self) { try ConfigSchema.parse(file.path, for: "recordings_dir") }
    }

    @Test(
        "неизвестные ключи и сами шаблоны — unknownKey",
        arguments: ["nope", "calendar.CAL-1.color", "calendar.*.folder", "calendar..folder", "stop"])
    func unknownKeys(key: String) {
        #expect(throws: ConfigError.unknownKey(key)) { try ConfigSchema.parse("1", for: key) }
    }
}
