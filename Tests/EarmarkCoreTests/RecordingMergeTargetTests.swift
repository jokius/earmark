import Foundation
import Testing

@testable import EarmarkCore

@Suite("Кандидат на склейку: RecordingStore.mergeTarget")
struct RecordingMergeTargetTests {
    /// Старт записи X, для которой ищем, к чему её приклеить.
    private static let start = "2026-10-02T11:30:00Z"

    private struct Fixture {
        let store: RecordingStore

        /// Свежий каталог на каждый тест: Swift Testing гоняет тесты параллельно.
        init() throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("earmark-tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            store = RecordingStore(root: root)
        }

        func url(_ path: String) -> URL { store.root.appendingPathComponent(path, isDirectory: true) }

        /// Законченная запись в <root>/<path>: meta.json сырым JSON (формат на диске) и audio.m4a.
        @discardableResult
        func recording(
            _ path: String, id: String, start: String, end: String, _ overrides: [String: JSONValue] = [:]
        ) throws -> URL {
            let dir = url(path)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let base: [String: JSONValue] = [
                "schema_version": 1, "id": .string(id), "status": "recorded", "trigger": "manual",
                "title": "Manual recording", "started_at": .string(start), "ended_at": .string(end),
                "duration_sec": 60, "stop_reason": "manual", "call_apps": [],
                "audio": [
                    "file": "audio.m4a", "codec": "aac", "sample_rate": 48000, "channels": ["mic", "system"],
                    "mic_offset_ms": 0,
                ],
                "recovered": false, "transcription": ["attempts": 0], "app_version": "0.1.0",
            ]
            let meta = JSONValue.object(base.merging(overrides) { $1 })
            try JSONEncoder().encode(meta).write(to: dir.appendingPathComponent(RecordingFiles.meta))
            try Data("aac bytes \(id)".utf8).write(to: dir.appendingPathComponent(RecordingFiles.audio))
            return dir
        }

        /// Идущая запись: только .recording.json.
        func running(_ path: String, id: String, start: String) throws {
            let dir = url(path)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try store.writeManifest(manifest(id, start: start), in: dir)
        }

        func manifest(_ id: String, start: String) throws -> RecordingManifest {
            RecordingManifest(
                pid: ProcessInfo.processInfo.processIdentifier, startedAt: try date(start),
                appVersion: "0.1.0",
                id: id, trigger: .manual, title: "Manual recording")
        }
    }

    private func path(_ url: URL) -> String { url.resolvingSymlinksInPath().path }

    @Test("окно по умолчанию — 10 минут")
    func defaultWindow() {
        #expect(RecordingStore.mergeWindow == 600)
    }

    @Test("самая свежая из начатых раньше, любого trigger'а и календаря; позже начатые и сама X не в счёт")
    func picksNewestEarlier() throws {
        let fixture = try Fixture()
        try fixture.recording(
            "Manual/A", id: "A", start: "2026-10-02T10:00:00Z", end: "2026-10-02T10:30:00Z")
        let previous = try fixture.recording(
            "Work/B", id: "B", start: "2026-10-02T10:40:00Z", end: "2026-10-02T11:25:00Z",
            [
                "trigger": "calendar", "calendar": ["id": "cal-work", "title": "Work"],
                "status": "transcribed",
                "title": "Daily sync",
            ])
        try fixture.recording(
            "Manual/C", id: "C", start: "2026-10-02T11:45:00Z", end: "2026-10-02T12:00:00Z")
        // X в момент стопа: meta ещё нет, только manifest
        try fixture.running("Manual/X", id: "X", start: Self.start)

        let found = try fixture.store.mergeTarget(id: "X", startedAt: try date(Self.start))

        #expect(found?.id == "B")
        #expect(found.map { path($0.url) } == path(previous))
    }

    /// Случай границы окна: структура, а не кортеж из трёх (SwiftLint large_tuple).
    struct Boundary: Sendable, CustomTestStringConvertible {
        let end: String
        let window: TimeInterval
        let found: Bool
        var testDescription: String { "\(end), window \(Int(window)) → \(found)" }
    }

    @Test(
        "граница окна: endedAt ≥ startedAt − window включительно",
        arguments: [
            Boundary(end: "2026-10-02T11:20:00Z", window: 600, found: true),
            Boundary(end: "2026-10-02T11:19:59Z", window: 600, found: false),
            Boundary(end: "2026-10-02T11:25:00Z", window: 60, found: false),
            Boundary(end: "2026-10-02T11:29:00Z", window: 60, found: true),
        ])
    func windowBoundary(_ boundary: Boundary) throws {
        let fixture = try Fixture()
        try fixture.recording("Manual/B", id: "B", start: "2026-10-02T11:00:00Z", end: boundary.end)

        let target = try fixture.store.mergeTarget(
            id: "X", startedAt: try date(Self.start), window: boundary.window)

        #expect(target?.id == (boundary.found ? "B" : nil))
    }

    /// Что не так с самой свежей предыдущей записью B. Старшая A при этом годится — но вглубь не ищем.
    enum Defect: String, CaseIterable, Sendable {
        case running, finalizing, noAudioFile, noAudioInMeta, outOfWindow
    }

    @Test("самая свежая предыдущая не годится — nil, глубже в прошлое не ищем", arguments: Defect.allCases)
    func newestEarlierUnusable(defect: Defect) throws {
        let fixture = try Fixture()
        // A длинная: началась раньше B, а кончилась в окне X
        try fixture.recording(
            "Manual/A", id: "A", start: "2026-10-02T10:00:00Z", end: "2026-10-02T11:28:00Z")
        let bStart = "2026-10-02T10:40:00Z"
        switch defect {
        case .running:
            try fixture.running("Manual/B", id: "B", start: bStart)
        case .finalizing:
            let dir = try fixture.recording("Manual/B", id: "B", start: bStart, end: "2026-10-02T11:25:00Z")
            try fixture.store.writeManifest(try fixture.manifest("B", start: bStart), in: dir)
        case .noAudioFile:
            let dir = try fixture.recording("Manual/B", id: "B", start: bStart, end: "2026-10-02T11:25:00Z")
            try FileManager.default.removeItem(at: dir.appendingPathComponent(RecordingFiles.audio))
        case .noAudioInMeta:
            try fixture.recording(
                "Manual/B", id: "B", start: bStart, end: "2026-10-02T11:25:00Z", ["audio": .null])
        case .outOfWindow:
            try fixture.recording("Manual/B", id: "B", start: bStart, end: "2026-10-02T11:00:00Z")
        }

        #expect(try fixture.store.mergeTarget(id: "X", startedAt: try date(Self.start)) == nil)
    }

    @Test("сама запись не кандидат, даже если её meta начата раньше переданного startedAt")
    func notItself() throws {
        let fixture = try Fixture()
        try fixture.recording(
            "Manual/B", id: "B", start: "2026-10-02T10:40:00Z", end: "2026-10-02T11:25:00Z")
        try fixture.recording(
            "Manual/X", id: "X", start: "2026-10-02T11:29:00Z", end: "2026-10-02T11:40:00Z")

        let found = try fixture.store.mergeTarget(id: "X", startedAt: try date(Self.start))

        #expect(found?.id == "B")
    }

    @Test("начатая в ту же секунду — не раньше: пропускается, кандидат — предыдущая")
    func sameStartIsNotEarlier() throws {
        let fixture = try Fixture()
        try fixture.recording(
            "Manual/B", id: "B", start: "2026-10-02T10:40:00Z", end: "2026-10-02T11:25:00Z")
        try fixture.recording("Manual/Y", id: "Y", start: Self.start, end: "2026-10-02T11:31:00Z")

        let found = try fixture.store.mergeTarget(id: "X", startedAt: try date(Self.start))

        #expect(found?.id == "B")
    }

    @Test("раньше ничего не начиналось — nil")
    func nothingEarlier() throws {
        let fixture = try Fixture()
        let startedAt = try date(Self.start)
        #expect(try fixture.store.mergeTarget(id: "X", startedAt: startedAt) == nil)

        try fixture.recording("Manual/C", id: "C", start: "2026-10-02T11:45:00Z", end: "2026-10-02T12:00:00Z")
        try fixture.recording("Manual/X", id: "X", start: Self.start, end: "2026-10-02T11:40:00Z")

        #expect(try fixture.store.mergeTarget(id: "X", startedAt: startedAt) == nil)
    }
}

private func date(_ text: String) throws -> Date {
    try #require(ISO8601DateFormatter().date(from: text))
}
