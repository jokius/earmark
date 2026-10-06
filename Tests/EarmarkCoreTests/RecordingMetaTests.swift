import Foundation
import Testing

@testable import EarmarkCore

@Suite("meta.json и .recording.json")
struct RecordingMetaTests {
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

    /// Синтезированный Codable опускает nil-поля, а в спеке они записаны явным null — для сравнения убираем их.
    private func droppingNulls(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let fields): .object(fields.filter { $0.value != .null }.mapValues(droppingNulls))
        case .array(let items): .array(items.map(droppingNulls))
        default: value
        }
    }

    /// Пример из спеки §7.2 дословно, только «…» заменены синтетическими id.
    private let specJSON = """
        {
          "schema_version": 1,
          "id": "20261002-1400-a1b2",
          "status": "recorded",
          "trigger": "calendar",
          "title": "Daily sync",
          "calendar": {"id": "cal-1", "title": "Work"},
          "event": {"id": "evt-1", "external_id": "ext-1", "start": "2026-10-02T10:00:00Z", "end": "2026-10-02T10:30:00Z"},
          "started_at": "2026-10-02T09:59:00Z",
          "ended_at": "2026-10-02T10:31:40Z",
          "duration_sec": 1960.4,
          "stop_reason": "call_ended",
          "call_apps": ["Zoom"],
          "audio": {"file": "audio.m4a", "codec": "aac", "sample_rate": 48000, "channels": ["mic", "system"], "mic_offset_ms": 12},
          "recovered": false,
          "transcription": {"attempts": 0, "error_kind": null, "error": null, "fingerprint": null, "language": "ru"},
          "app_version": "0.1.0"
        }
        """

    @Test("golden: ключи и значения совпадают с примером спеки §7.2 в обе стороны")
    func goldenSpecExample() throws {
        let meta = try EarmarkJSON.decoder.decode(RecordingMeta.self, from: Data(specJSON.utf8))

        #expect(meta.status == .recorded)
        #expect(meta.trigger == .calendar)
        #expect(meta.event?.externalId == "ext-1")
        #expect(meta.startedAt == (try utc("2026-10-02T09:59:00Z")))
        #expect(meta.stopReason == .callEnded)
        #expect(meta.audio?.micOffsetMs == 12)
        #expect(meta.transcription == TranscriptionState(language: "ru"))

        let encoded = try JSONDecoder().decode(JSONValue.self, from: EarmarkJSON.encoder.encode(meta))
        let expected = try JSONDecoder().decode(JSONValue.self, from: Data(specJSON.utf8))
        #expect(encoded == droppingNulls(expected))
    }

    @Test("нет файла — nil; запись и чтение возвращают то же; битый JSON — ошибка")
    func readWrite() throws {
        let dir = try makeTempDir()
        let store = RecordingStore(root: dir)
        #expect(try store.readMeta(in: dir) == nil)
        #expect(try store.readManifest(in: dir) == nil)

        let start = try utc("2026-10-02T11:00:00Z")
        let manifest = RecordingManifest(
            pid: 4242, startedAt: start, appVersion: "0.1.0", id: "20261002-1400-a1b2", trigger: .manual,
            title: "Idea")
        let meta = RecordingMeta(
            id: "20261002-1400-a1b2", status: .recorded, trigger: .manual, title: "Idea", startedAt: start,
            appVersion: "0.1.0")
        try store.writeManifest(manifest, in: dir)
        try store.writeMeta(meta, in: dir)

        #expect(try store.readManifest(in: dir) == manifest)
        #expect(try store.readMeta(in: dir) == meta)

        try store.removeManifest(in: dir)
        try store.removeManifest(in: dir)  // повторно — без ошибки
        #expect(try store.readManifest(in: dir) == nil)

        try Data("{\"id\": ".utf8).write(to: dir.appendingPathComponent(RecordingFiles.meta))
        #expect(throws: (any Error).self) { try store.readMeta(in: dir) }
    }

    @Test("updateMeta меняет и сохраняет; без meta.json — ошибка")
    func update() throws {
        let dir = try makeTempDir()
        let store = RecordingStore(root: dir)
        #expect(throws: (any Error).self) { try store.updateMeta(in: dir) { $0.status = .transcribing } }

        let meta = RecordingMeta(
            id: "20261002-1400-a1b2", status: .recorded, trigger: .manual, title: "Idea",
            startedAt: try utc("2026-10-02T11:00:00Z"), appVersion: "0.1.0")
        try store.writeMeta(meta, in: dir)

        let updated = try store.updateMeta(in: dir) {
            $0.status = .transcribing
            $0.transcription.attempts += 1
        }

        #expect(updated.transcription.attempts == 1)
        #expect(try store.readMeta(in: dir) == updated)
    }
}
