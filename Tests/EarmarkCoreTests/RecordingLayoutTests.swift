import Foundation
import Testing

@testable import EarmarkCore

@Suite("Раскладка записей: id, санитизация, папки")
struct RecordingLayoutTests {
    /// Свежий каталог на каждый тест: Swift Testing гоняет тесты параллельно.
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("earmark-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func utc(_ text: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: text))
    }

    private func moscow() throws -> TimeZone {
        try #require(TimeZone(identifier: "Europe/Moscow"))
    }

    @Test("id — локальное время старта и 4 строчных hex")
    func ids() throws {
        let start = try utc("2026-10-02T11:00:00Z")
        #expect(
            RecordingStore.makeID(startedAt: start, timeZone: try moscow(), random: 0xA1B2)
                == "20261002-1400-a1b2")
        #expect(
            RecordingStore.makeID(startedAt: start, timeZone: .gmt, random: 0x00F) == "20261002-1100-000f")
        // за полночь по местному времени — уже следующие сутки
        let late = try utc("2026-10-02T23:30:00Z")
        #expect(
            RecordingStore.makeID(startedAt: late, timeZone: try moscow(), random: 0) == "20261003-0230-0000")
    }

    @Test(
        "враждебные названия превращаются в одно безопасное имя (фокус ревью №1)",
        arguments: [
            ("Daily sync", "Daily sync"),
            ("a/b:c\\d", "a b c d"),
            ("../../etc/passwd", "etc passwd"),
            ("..", "Untitled"),
            (".", "Untitled"),
            ("", "Untitled"),
            ("   ", "Untitled"),
            ("line1\nline2\tTab\r", "line1 line2 Tab"),
            (".hidden", "hidden"),
            ("  spaced   out  ", "spaced out"),
            ("Созвон 🎉 с командой", "Созвон 🎉 с командой"),
            ("\u{202E}fdp.exe", "fdp.exe"),
        ])
    func sanitizes(title: String, expected: String) {
        let name = RecordingStore.sanitize(title)
        #expect(name == expected)
        #expect(!name.contains("/"))
        #expect(name != "." && name != "..")
        #expect(name.utf8.first != UInt8(ascii: "."))
    }

    @Test(
        "точка в одной графеме с меткой или за невидимым символом не делает имя скрытым",
        arguments: [
            (".\u{0307}Work", "Work"),
            (".\u{FE0F}x", "x"),
            (".\u{200D}x", "x"),
            (" .\u{0301}y", "y"),
            ("\u{202E}.x", "x"),
            ("\u{200B}.x", "x"),
            ("\n.x", "x"),
            (". . .x", "x"),
        ])
    func noHiddenNames(title: String, tail: String) {
        let name = RecordingStore.sanitize(title)
        // hasPrefix(".") и first == "." сравнивают графемы и ".\u{0307}" пропускают, а Finder смотрит на байты
        #expect(name.utf8.first != UInt8(ascii: "."))
        #expect(name.hasSuffix(tail))
    }

    @Test("длинные названия режутся по границе графемы: 80 символов и не больше 200 байт")
    func longTitles() {
        #expect(
            RecordingStore.sanitize(String(repeating: "я", count: 300)) == String(repeating: "я", count: 80))
        let family = "👨‍👩‍👧‍👦"  // одна графема, 25 байт UTF-8
        let name = RecordingStore.sanitize(String(repeating: family, count: 100))
        #expect(name == String(repeating: family, count: 8))
    }

    @Test("папка календаря: override побеждает, одинаковые названия различаются аккаунтом")
    func calendarFolders() {
        let work = CalendarInfo(id: "c1", title: "Work", account: "iCloud")
        let otherWork = CalendarInfo(id: "c2", title: "work", account: "Exchange")
        let personal = CalendarInfo(id: "c3", title: "Personal/Home", account: "iCloud")
        let all = [work, otherWork, personal]

        #expect(RecordingStore.calendarFolderName(for: work, override: "Calls", allCalendars: all) == "Calls")
        #expect(
            RecordingStore.calendarFolderName(for: work, override: nil, allCalendars: all) == "Work (iCloud)")
        #expect(
            RecordingStore.calendarFolderName(for: otherWork, override: nil, allCalendars: all)
                == "work (Exchange)")
        #expect(
            RecordingStore.calendarFolderName(for: personal, override: nil, allCalendars: all)
                == "Personal Home")
        #expect(RecordingStore.calendarFolderName(for: work, override: nil, allCalendars: [work]) == "Work")
    }

    @Test("папка записи: дата, время, название; корень 0700; ручная — в Manual")
    func createsFolders() throws {
        let root = try makeTempDir().appendingPathComponent("Earmark", isDirectory: true)
        let store = RecordingStore(root: root)
        let start = try utc("2026-10-02T11:00:00Z")

        let auto = try store.createRecordingFolder(
            calendarFolder: "Work", title: "Daily sync", startedAt: start, timeZone: try moscow())
        let manual = try store.createRecordingFolder(
            calendarFolder: nil, title: "Idea", startedAt: start, timeZone: try moscow())

        #expect(auto.path == root.appendingPathComponent("Work/2026-10-02 14-00 Daily sync").path)
        #expect(manual.path == root.appendingPathComponent("Manual/2026-10-02 14-00 Idea").path)
        let mode = try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
    }

    @Test("коллизии получают (2), (3); враждебные имена не выводят папку из корня")
    func collisionsAndEscapes() throws {
        let root = try makeTempDir().appendingPathComponent("Earmark", isDirectory: true)
        let store = RecordingStore(root: root)
        let start = try utc("2026-10-02T11:00:00Z")

        let names = try (1...3).map { _ in
            try store.createRecordingFolder(
                calendarFolder: "Work", title: "Sync", startedAt: start, timeZone: .gmt
            )
            .lastPathComponent
        }
        #expect(names == ["2026-10-02 11-00 Sync", "2026-10-02 11-00 Sync (2)", "2026-10-02 11-00 Sync (3)"])

        let hostile = try store.createRecordingFolder(
            calendarFolder: "../..", title: "../../../tmp/x", startedAt: start, timeZone: .gmt)
        #expect(hostile.deletingLastPathComponent().path == root.appendingPathComponent("Untitled").path)
        #expect(hostile.lastPathComponent == "2026-10-02 11-00 tmp x")
    }
}
