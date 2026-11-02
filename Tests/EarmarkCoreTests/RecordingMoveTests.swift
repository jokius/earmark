import Foundation
import Testing

@testable import EarmarkCore

@Suite("Ручная запись → календарь: RecordingStore.move и needsProject")
struct RecordingMoveTests {
    /// meta.json как его пишет app (поля примера спеки §7.2) — без календаря и события.
    private static let baseMeta: [String: JSONValue] = [
        "schema_version": 1, "id": "m1", "status": "transcribed", "trigger": "manual", "title": "Idea",
        "started_at": "2026-10-02T11:00:00Z", "ended_at": "2026-10-02T11:30:00Z", "duration_sec": 1800.5,
        "stop_reason": "manual", "call_apps": ["Zoom"],
        "audio": [
            "file": "audio.m4a", "codec": "aac", "sample_rate": 48000, "channels": ["mic", "system"],
            "mic_offset_ms": 12,
        ],
        "recovered": false, "transcription": ["attempts": 1, "language": "ru"], "app_version": "0.1.0",
    ]
    private static let workJSON: JSONValue = ["id": "cal-work", "title": "Work"]
    private static let eventJSON: JSONValue = [
        "id": "evt-1", "external_id": "ext-1", "start": "2026-10-02T11:00:00Z", "end": "2026-10-02T11:30:00Z",
    ]
    private static let leaf = "2026-10-02 14-00 Idea"

    private struct Fixture {
        let store: RecordingStore
        let work = CalendarRef(id: "cal-work", title: "Work")

        /// Свежий каталог на каждый тест: Swift Testing гоняет тесты параллельно.
        init() throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("earmark-tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            store = RecordingStore(root: root)
        }

        func url(_ path: String) -> URL { store.root.appendingPathComponent(path, isDirectory: true) }

        /// Законченная запись в <root>/<path>: meta.json сырым JSON (формат на диске), аудио и транскрипты.
        @discardableResult
        func recording(_ path: String, _ overrides: [String: JSONValue] = [:]) throws -> URL {
            let dir = url(path)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let meta = JSONValue.object(baseMeta.merging(overrides) { $1 })
            try JSONEncoder().encode(meta).write(to: dir.appendingPathComponent(RecordingFiles.meta))
            try Data("aac bytes \(path)".utf8).write(to: dir.appendingPathComponent(RecordingFiles.audio))
            try Data(#"{"segments":[]}"#.utf8).write(to: dir.appendingPathComponent("transcript.json"))
            try Data("# Idea\n".utf8).write(to: dir.appendingPathComponent("transcript.md"))
            return dir
        }

        /// Файлы записи с содержимым, кроме meta.json и служебных точечных (lock'и).
        func files(_ dir: URL) throws -> [String: Data] {
            let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
                .filter { !$0.hasPrefix(".") && $0 != RecordingFiles.meta }
            return try Dictionary(
                uniqueKeysWithValues: names.map { name in
                    (name, try Data(contentsOf: dir.appendingPathComponent(name)))
                })
        }

        /// Поля meta без calendar: всё, что move обязан оставить как было.
        func fieldsExceptCalendar(_ dir: URL) throws -> [String: JSONValue] {
            let meta = try #require(try store.readMeta(in: dir))
            guard
                case .object(var fields) = try JSONDecoder().decode(
                    JSONValue.self, from: EarmarkJSON.encoder.encode(meta))
            else { return [:] }
            fields["calendar"] = nil
            return fields
        }

        /// Освобождённый lock может мгновение числиться занятым (см. FileLockTests.acquireSoon).
        func acquireSoon(_ url: URL) throws -> FileLock? {
            let deadline = Date().addingTimeInterval(2)
            repeat {
                if let lock = try FileLock.tryAcquire(at: url) { return lock }
                Thread.sleep(forTimeInterval: 0.01)
            } while Date() < deadline
            return nil
        }
    }

    private func path(_ url: URL) -> String { url.resolvingSymlinksInPath().path }

    @Test("в календарь: meta.calendar, папка под <root>/<folder>/ с тем же именем, файлы и прочие поля целы")
    func movesIntoCalendar() throws {
        let fixture = try Fixture()
        let store = fixture.store
        let source = try fixture.recording("Manual/\(Self.leaf)")
        let filesBefore = try fixture.files(source)
        let fieldsBefore = try fixture.fieldsExceptCalendar(source)
        let target = fixture.url("Work/\(Self.leaf)")

        let moved = try store.move(id: "m1", to: fixture.work, folder: "Work")

        #expect(moved.id == "m1")
        #expect(path(moved.url) == path(target))
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try fixture.files(target) == filesBefore)
        #expect(try store.readMeta(in: target)?.calendar == fixture.work)
        #expect(try fixture.fieldsExceptCalendar(target) == fieldsBefore)
        #expect(try store.list(.init(calendarId: "cal-work")).map(\.id) == ["m1"])
        #expect(try store.find(id: "m1").map { path($0.url) } == path(target))
        // пустую Manual не удаляет
        #expect(FileManager.default.fileExists(atPath: fixture.url("Manual").path))
        // lock отпущен: расшифровка на новом месте не получит отказ
        let lock = try fixture.acquireSoon(target.appendingPathComponent(RecordingFiles.transcribeLock))
        #expect(lock != nil)
    }

    @Test("обратно в Manual: calendar nil, папка под Manual, файлы целы")
    func movesBackToManual() throws {
        let fixture = try Fixture()
        let store = fixture.store
        let source = try fixture.recording("Manual/\(Self.leaf)")
        let filesBefore = try fixture.files(source)
        let fieldsBefore = try fixture.fieldsExceptCalendar(source)
        _ = try store.move(id: "m1", to: fixture.work, folder: "Work")

        let moved = try store.move(id: "m1", to: nil, folder: nil)

        #expect(path(moved.url) == path(source))
        #expect(!FileManager.default.fileExists(atPath: fixture.url("Work/\(Self.leaf)").path))
        #expect(try store.readMeta(in: source)?.calendar == nil)
        #expect(try fixture.files(source) == filesBefore)
        #expect(try fixture.fieldsExceptCalendar(source) == fieldsBefore)
        #expect(try store.list(.init(calendarId: "cal-work")).isEmpty)
        #expect(try store.find(id: "m1").map { path($0.url) } == path(source))
    }

    @Test("родитель тот же (без учёта регистра) — папка остаётся, меняется только meta.calendar")
    func sameParentUpdatesOnlyMeta() throws {
        let fixture = try Fixture()
        let store = fixture.store
        let source = try fixture.recording("work/\(Self.leaf)")
        let filesBefore = try fixture.files(source)
        let fieldsBefore = try fixture.fieldsExceptCalendar(source)

        let moved = try store.move(id: "m1", to: fixture.work, folder: "Work")

        #expect(try FileManager.default.contentsOfDirectory(atPath: store.root.path) == ["work"])
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: source.deletingLastPathComponent().path)
                == [Self.leaf])
        #expect(moved.url.lastPathComponent == Self.leaf)
        #expect(try store.readMeta(in: source)?.calendar == fixture.work)
        #expect(try fixture.files(source) == filesBefore)
        #expect(try fixture.fieldsExceptCalendar(source) == fieldsBefore)
        #expect(try store.list(.init(calendarId: "cal-work")).map(\.id) == ["m1"])
    }

    @Test("тот же родитель и тот же календарь — ничего не пишется")
    func sameCalendarIsNoOp() throws {
        let fixture = try Fixture()
        let store = fixture.store
        let source = try fixture.recording("Work/\(Self.leaf)", ["calendar": Self.workJSON])
        let metaURL = source.appendingPathComponent(RecordingFiles.meta)
        let past = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: metaURL.path)
        let bytes = try Data(contentsOf: metaURL)

        let moved = try store.move(id: "m1", to: fixture.work, folder: "Work")

        #expect(path(moved.url) == path(source))
        #expect(try Data(contentsOf: metaURL) == bytes)
        let attributes = try FileManager.default.attributesOfItem(atPath: metaURL.path)
        let modified = attributes[.modificationDate] as? Date
        #expect(modified == past)
    }

    @Test("имя занято в назначении — « (2)», чужая папка не тронута")
    func collisionGetsSuffix() throws {
        let fixture = try Fixture()
        let store = fixture.store
        let other = try fixture.recording("Work/\(Self.leaf)", ["id": "other", "calendar": Self.workJSON])
        let otherFiles = try fixture.files(other)
        let otherMeta = try Data(contentsOf: other.appendingPathComponent(RecordingFiles.meta))
        try fixture.recording("Manual/\(Self.leaf)")

        let moved = try store.move(id: "m1", to: fixture.work, folder: "Work")

        #expect(path(moved.url) == path(fixture.url("Work/\(Self.leaf) (2)")))
        #expect(try store.readMeta(in: moved.url)?.id == "m1")
        #expect(try fixture.files(other) == otherFiles)
        #expect(try Data(contentsOf: other.appendingPathComponent(RecordingFiles.meta)) == otherMeta)
        #expect(Set(try store.list(.init(calendarId: "cal-work")).map(\.id)) == ["m1", "other"])
    }

    @Test("имя папки календаря проходит sanitize: «/» и «..» не выводят запись из root")
    func folderIsSanitized() throws {
        let fixture = try Fixture()
        let store = fixture.store
        try fixture.recording("Manual/\(Self.leaf)")
        let hostile = "../A/B"

        let moved = try store.move(id: "m1", to: CalendarRef(id: "cal-x", title: "A/B"), folder: hostile)

        let parent = moved.url.deletingLastPathComponent()
        #expect(path(parent) == path(fixture.url(RecordingStore.sanitize(hostile))))
        #expect(path(parent.deletingLastPathComponent()) == path(store.root))
        #expect(moved.url.lastPathComponent == Self.leaf)
    }

    @Test("calendar и folder заданы не парой — invalid_arguments, запись на месте")
    func calendarAndFolderGoTogether() throws {
        let fixture = try Fixture()
        let store = fixture.store
        let source = try fixture.recording("Manual/\(Self.leaf)")

        for (calendar, folder) in [(fixture.work, nil), (nil, "Work")] as [(CalendarRef?, String?)] {
            let error = #expect(throws: EarmarkError.self) {
                try store.move(id: "m1", to: calendar, folder: folder)
            }
            #expect(error?.code == "invalid_arguments")
        }
        #expect(try store.readMeta(in: source)?.calendar == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.url("Work").path))
    }

    @Test("неизвестный id — not_found")
    func unknownID() throws {
        let fixture = try Fixture()
        try fixture.recording("Manual/\(Self.leaf)")

        let error = #expect(throws: EarmarkError.self) {
            try fixture.store.move(id: "20990101-0000-ffff", to: fixture.work, folder: "Work")
        }
        #expect(error?.code == "not_found")
    }

    @Test("есть .recording.json (запись идёт или не восстановлена) — busy, запись на месте")
    func manifestIsBusy() throws {
        let fixture = try Fixture()
        let store = fixture.store
        let source = try fixture.recording("Manual/\(Self.leaf)")
        let manifest = RecordingManifest(
            pid: ProcessInfo.processInfo.processIdentifier, startedAt: Date(), appVersion: "0.1.0", id: "m1",
            trigger: .manual, title: "Idea")
        try store.writeManifest(manifest, in: source)

        let error = #expect(throws: EarmarkError.self) {
            try store.move(id: "m1", to: fixture.work, folder: "Work")
        }
        #expect(error?.code == "busy")
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try store.readMeta(in: source)?.calendar == nil)
    }

    @Test(
        "не ручная или внутри события — invalid_arguments, запись на месте",
        arguments: [
            ["trigger": "calendar", "calendar": workJSON],
            ["event": eventJSON],
        ] as [[String: JSONValue]])
    func onlyManualOutsideEvents(overrides: [String: JSONValue]) throws {
        let fixture = try Fixture()
        let store = fixture.store
        let source = try fixture.recording("Manual/\(Self.leaf)", overrides)
        let metaBefore = try Data(contentsOf: source.appendingPathComponent(RecordingFiles.meta))

        let error = #expect(throws: EarmarkError.self) {
            try store.move(id: "m1", to: CalendarRef(id: "cal-team", title: "Team"), folder: "Team")
        }
        #expect(error?.code == "invalid_arguments")
        #expect(error?.message.contains("only manual recordings outside a calendar event") == true)
        #expect(try Data(contentsOf: source.appendingPathComponent(RecordingFiles.meta)) == metaBefore)
        #expect(!FileManager.default.fileExists(atPath: fixture.url("Team").path))
    }

    @Test("идёт расшифровка (.transcribe.lock занят) — busy, ничего не двигается")
    func transcribeLockIsBusy() throws {
        let fixture = try Fixture()
        let store = fixture.store
        let source = try fixture.recording("Manual/\(Self.leaf)", ["status": "transcribing"])
        let worker = try #require(
            try FileLock.tryAcquire(at: source.appendingPathComponent(RecordingFiles.transcribeLock)))
        defer { worker.release() }

        let error = #expect(throws: EarmarkError.self) {
            try store.move(id: "m1", to: fixture.work, folder: "Work")
        }
        #expect(error?.code == "busy")
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try store.readMeta(in: source)?.calendar == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.url("Work/\(Self.leaf)").path))
    }

    @Test("ошибка ФС (на месте папки календаря — файл) — operation_failed, запись на месте")
    func fileSystemErrorIsOperationFailed() throws {
        let fixture = try Fixture()
        let store = fixture.store
        let source = try fixture.recording("Manual/\(Self.leaf)")
        let filesBefore = try fixture.files(source)
        try Data("not a folder".utf8).write(to: store.root.appendingPathComponent("Work"))

        let error = #expect(throws: EarmarkError.self) {
            try store.move(id: "m1", to: fixture.work, folder: "Work")
        }
        #expect(error?.code == "operation_failed")
        #expect(try fixture.files(source) == filesBefore)
        #expect(try store.readMeta(in: source)?.calendar == nil)
        #expect(try store.find(id: "m1").map { path($0.url) } == path(source))
    }

    @Test(
        "needsProject: ручная, без календаря и события, не после восстановления",
        arguments: [
            ([:], true),
            (["stop_reason": .null], true),
            (["stop_reason": "call_ended"], true),
            (["trigger": "calendar"], false),
            (["calendar": workJSON], false),
            (["event": eventJSON], false),
            (["stop_reason": "recovered", "recovered": true], false),
        ] as [([String: JSONValue], Bool)])
    func needsProject(overrides: [String: JSONValue], expected: Bool) throws {
        let json = JSONValue.object(Self.baseMeta.merging(overrides) { $1 })
        let meta = try EarmarkJSON.decoder.decode(RecordingMeta.self, from: JSONEncoder().encode(json))
        #expect(meta.needsProject == expected)
    }
}
