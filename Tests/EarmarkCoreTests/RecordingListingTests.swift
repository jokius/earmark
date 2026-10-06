import Foundation
import Testing

@testable import EarmarkCore

@Suite("Обход записей: list, find, interrupted, pendingTranscription")
struct RecordingListingTests {
    /// Дерево записей для обхода: что считается записью, порядок, фильтры.
    private struct Fixture {
        let store: RecordingStore
        let t1 = Date(timeIntervalSince1970: 1_790_920_000)  // старейшая
        let t2 = Date(timeIntervalSince1970: 1_790_930_000)
        let t3 = Date(timeIntervalSince1970: 1_790_940_000)  // свежайшая
        let work = CalendarRef(id: "cal-work", title: "Work")

        /// Свежий каталог на каждый тест: Swift Testing гоняет тесты параллельно.
        init() throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("earmark-tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            store = RecordingStore(root: root)
        }

        func folder(_ path: String) throws -> URL {
            let url = store.root.appendingPathComponent(path, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        func meta(_ id: String, _ status: RecordingStatus, _ start: Date, calendar: CalendarRef? = nil)
            -> RecordingMeta
        {
            RecordingMeta(
                id: id, status: status, trigger: calendar == nil ? .manual : .calendar, title: id,
                calendar: calendar, startedAt: start, appVersion: "0.1.0")
        }

        func manifest(_ id: String, _ start: Date, pid: Int32, calendar: CalendarRef? = nil)
            -> RecordingManifest
        {
            RecordingManifest(
                pid: pid, startedAt: start, appVersion: "0.1.0", id: id,
                trigger: calendar == nil ? .manual : .calendar, title: id, calendar: calendar)
        }

        /// Work/A — recorded (t1), Work/B — идёт запись (t3), Manual/C — transcribed (t2) и мусор вокруг.
        func populate() throws {
            try store.writeMeta(meta("A", .recorded, t1, calendar: work), in: folder("Work/A"))
            try store.writeManifest(manifest("B", t3, pid: 111, calendar: work), in: folder("Work/B"))
            try store.writeMeta(meta("C", .transcribed, t2), in: folder("Manual/C"))
            _ = try folder("Manual/empty")
            try store.writeMeta(meta("hidden", .recorded, t3), in: folder(".trash/D"))
            try store.writeMeta(meta("deep", .recorded, t3), in: folder("Work/E/F"))
            try Data("{".utf8).write(to: folder("Work/broken").appendingPathComponent(RecordingFiles.meta))
            try Data("x".utf8).write(to: store.root.appendingPathComponent("stray.txt"))
        }
    }

    @Test("ровно два уровня под root, только папки с meta или manifest, новые первыми")
    func listsNewestFirst() throws {
        let fixture = try Fixture()
        try fixture.populate()

        let ids = try fixture.store.list().map(\.id)

        #expect(ids == ["B", "C", "A"])
        #expect(try RecordingStore(root: fixture.store.root.appendingPathComponent("absent")).list().isEmpty)
    }

    @Test("фильтры: статус (recording = есть manifest), календарь, since включительно, until — нет, limit")
    func filters() throws {
        let fixture = try Fixture()
        try fixture.populate()
        let store = fixture.store

        #expect(try store.list(.init(status: .recording)).map(\.id) == ["B"])
        #expect(try store.list(.init(status: .recorded)).map(\.id) == ["A"])
        #expect(try store.list(.init(calendarId: "cal-work")).map(\.id) == ["B", "A"])
        #expect(try store.list(.init(since: fixture.t2)).map(\.id) == ["B", "C"])
        #expect(try store.list(.init(until: fixture.t2)).map(\.id) == ["A"])
        #expect(try store.list(.init(limit: 1)).map(\.id) == ["B"])
        #expect(try store.list(.init(limit: 0)).isEmpty)
    }

    @Test("find ищет и по meta, и по manifest")
    func find() throws {
        let fixture = try Fixture()
        try fixture.populate()

        #expect(try fixture.store.find(id: "C")?.url.lastPathComponent == "C")
        #expect(try fixture.store.find(id: "B")?.isRecording == true)
        #expect(try fixture.store.find(id: "nope") == nil)
    }

    @Test("окно финализации (D7): meta уже записан, manifest ещё не удалён — запись всё ещё идёт")
    func finalizingCountsAsRecording() throws {
        let fixture = try Fixture()
        let store = fixture.store
        let finalizing = try fixture.folder("Manual/finalizing")
        try store.writeMeta(fixture.meta("finalizing", .recorded, fixture.t1), in: finalizing)
        try store.writeManifest(fixture.manifest("finalizing", fixture.t1, pid: 111), in: finalizing)
        try store.writeMeta(fixture.meta("done", .recorded, fixture.t2), in: fixture.folder("Manual/done"))

        #expect(try store.find(id: "finalizing")?.status == .recording)
        #expect(try store.list(.init(status: .recorded)).map(\.id) == ["done"])
        #expect(try store.list(.init(status: .recording)).map(\.id) == ["finalizing"])
        #expect(try store.pendingTranscription().map(\.id) == ["done"])
    }

    @Test("прерванные — manifest есть, а pid мёртв (фокус ревью №3)")
    func interrupted() throws {
        let fixture = try Fixture()
        let store = fixture.store
        try store.writeManifest(
            fixture.manifest("live", fixture.t2, pid: 100), in: fixture.folder("Manual/live"))
        try store.writeManifest(
            fixture.manifest("dead", fixture.t1, pid: 200), in: fixture.folder("Manual/dead"))
        try store.writeMeta(fixture.meta("done", .recorded, fixture.t3), in: fixture.folder("Manual/done"))

        let found = try store.interrupted { pid in pid == 100 }

        #expect(found.map(\.id) == ["dead"])
    }

    @Test("в очередь: recorded и transcribing со свободным lock'ом, старые первыми")
    func pending() throws {
        let fixture = try Fixture()
        let store = fixture.store
        let stale = try fixture.folder("Manual/stale")
        let busy = try fixture.folder("Manual/busy")
        try store.writeMeta(fixture.meta("stale", .transcribing, fixture.t1), in: stale)
        try store.writeMeta(
            fixture.meta("recorded", .recorded, fixture.t2), in: fixture.folder("Manual/recorded"))
        try store.writeMeta(fixture.meta("busy", .transcribing, fixture.t3), in: busy)
        try store.writeMeta(fixture.meta("done", .transcribed, fixture.t3), in: fixture.folder("Manual/done"))
        try store.writeMeta(
            fixture.meta("failed", .transcriptionFailed, fixture.t3), in: fixture.folder("Manual/failed"))
        try store.writeManifest(
            fixture.manifest("live", fixture.t3, pid: 1), in: fixture.folder("Manual/live"))
        let worker = try #require(
            try FileLock.tryAcquire(at: busy.appendingPathComponent(RecordingFiles.transcribeLock)))

        let ids = try store.pendingTranscription().map(\.id)

        #expect(ids == ["stale", "recorded"])
        // проверка свободы lock'а не должна его утащить: занятый остаётся занятым
        #expect(
            try FileLock.tryAcquire(at: busy.appendingPathComponent(RecordingFiles.transcribeLock)) == nil)
        worker.release()
    }

    @Test("календарь с точкой в одной графеме с меткой: папка не скрыта, list и find находят запись")
    func dottedCalendarIsListed() throws {
        let fixture = try Fixture()
        let store = fixture.store
        let shared = CalendarInfo(id: "cal-shared", title: ".\u{0307}Shared", account: "iCloud")
        let calendarFolder = RecordingStore.calendarFolderName(
            for: shared, override: nil, allCalendars: [shared])
        let dir = try store.createRecordingFolder(
            calendarFolder: calendarFolder, title: "Sync", startedAt: fixture.t1, timeZone: .gmt)
        let ref = CalendarRef(id: shared.id, title: shared.title)
        try store.writeMeta(fixture.meta("S", .recorded, fixture.t1, calendar: ref), in: dir)

        // hasPrefix(".") сравнивает графемы и ".\u{0307}" пропускает, а Finder смотрит на байты
        #expect(calendarFolder.utf8.first != UInt8(ascii: "."))
        for url in [dir.deletingLastPathComponent(), dir] {
            #expect(try url.resourceValues(forKeys: [.isHiddenKey]).isHidden == false)
        }
        #expect(try store.list().map(\.id) == ["S"])
        let found = try #require(try store.find(id: "S"))
        #expect(found.url.resolvingSymlinksInPath().path == dir.resolvingSymlinksInPath().path)
    }

    @Test(
        "нечитаемая папка группы или записи не прячет остальные записи",
        arguments: [("Locked", "Locked/L"), ("Work/L", "Work/L")])
    func unreadableFolderIsSkipped(lockedPath: String, recordingPath: String) throws {
        let fixture = try Fixture()
        let store = fixture.store
        let files = FileManager.default
        try store.writeMeta(fixture.meta("A", .recorded, fixture.t1), in: fixture.folder("Work/A"))
        try store.writeMeta(fixture.meta("L", .recorded, fixture.t2), in: fixture.folder(recordingPath))
        let locked = store.root.appendingPathComponent(lockedPath, isDirectory: true)
        try files.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        // вернуть права, иначе временный каталог не удалить
        defer { try? files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
        try #require(!files.isReadableFile(atPath: locked.path), "под root права 000 не работают")

        #expect(try store.list().map(\.id) == ["A"])
        #expect(try store.find(id: "A")?.id == "A")
    }
}
