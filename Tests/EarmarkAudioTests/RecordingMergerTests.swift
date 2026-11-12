@preconcurrency import AVFoundation
import EarmarkAudio
import EarmarkCore
import Foundation
import Testing

@Suite("RecordingMerger: склейка записи с предыдущей")
struct RecordingMergerTests {
    /// Цель склейки: календарная, восстановленная после сбоя, уже расшифрованная.
    static let targetMeta: [String: JSONValue] = [
        "schema_version": 1, "id": "t1", "status": "transcribed", "trigger": "calendar",
        "title": "Daily sync",
        "calendar": ["id": "cal-work", "title": "Work"],
        "event": [
            "id": "evt-1", "external_id": "ext-1", "start": "2026-10-02T11:00:00Z",
            "end": "2026-10-02T11:30:00Z",
        ],
        "started_at": "2026-10-02T11:00:00Z", "ended_at": "2026-10-02T11:30:00Z", "duration_sec": 1800.5,
        "stop_reason": "recovered", "call_apps": ["Zoom", "Teams"],
        "audio": [
            "file": "audio.m4a", "codec": "aac", "sample_rate": 48000, "channels": ["mic", "system"],
            "mic_offset_ms": 12,
        ],
        "recovered": true, "transcription": ["attempts": 1, "language": "ru"], "app_version": "0.1.0",
    ]
    /// Приклеиваемая: ручная, начата через 2 минуты после конца цели.
    static let sourceMeta: [String: JSONValue] = [
        "schema_version": 1, "id": "s1", "status": "recorded", "trigger": "manual",
        "title": "Manual recording",
        "started_at": "2026-10-02T11:32:00Z", "ended_at": "2026-10-02T11:40:00Z", "duration_sec": 480.25,
        "stop_reason": "manual", "call_apps": ["Teams", "Chrome"],
        "audio": [
            "file": "audio.m4a", "codec": "aac", "sample_rate": 48000, "channels": ["mic", "system"],
            "mic_offset_ms": 40,
        ],
        "recovered": false, "transcription": ["attempts": 0], "app_version": "0.1.0",
    ]
    static let transcripts = [
        RecordingFiles.transcriptMic, RecordingFiles.transcriptSystem, RecordingFiles.transcript,
        RecordingFiles.transcriptText,
    ]

    private struct Fixture {
        let store: RecordingStore
        let target: URL
        let source: URL

        /// Две законченные записи: цель с транскриптами (L 440 Гц / R 1000 Гц) и приклеиваемая (660 / 1500).
        init(targetSeconds: Double = 2, sourceSeconds: Double = 1.5) throws {
            store = RecordingStore(root: try makeTempDirectory())
            target = store.root.appendingPathComponent("Work/2026-10-02 14-00 Daily sync", isDirectory: true)
            source = store.root.appendingPathComponent(
                "Manual/2026-10-02 14-32 Manual recording", isDirectory: true)
            try Self.recording(
                target, RecordingMergerTests.targetMeta, seconds: targetSeconds, mic: 440, system: 1_000)
            try Self.recording(
                source, RecordingMergerTests.sourceMeta, seconds: sourceSeconds, mic: 660, system: 1_500)
            for name in RecordingMergerTests.transcripts {
                try Data("old \(name)".utf8).write(to: target.appendingPathComponent(name))
            }
        }

        /// meta.json сырым JSON (формат на диске), audio.m4a — тоны, сведённые StereoMuxer (L — mic, R — system).
        static func recording(
            _ dir: URL, _ meta: [String: JSONValue], seconds: Double, mic: Double, system: Double
        )
            throws
        {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try writeMeta(meta, in: dir)
            let tracks = try makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: tracks) }
            let micURL = tracks.appendingPathComponent(RecordingFiles.mic)
            let systemURL = tracks.appendingPathComponent(RecordingFiles.system)
            try writeToneCAF(micURL, seconds: seconds, channels: [ToneSpec(hz: mic)])
            try writeToneCAF(systemURL, seconds: seconds, channels: [ToneSpec(hz: system)])
            _ = try StereoMuxer.mux(
                mic: micURL, system: systemURL, micOffsetMs: 0,
                output: dir.appendingPathComponent(RecordingFiles.audio))
        }

        static func writeMeta(_ meta: [String: JSONValue], in dir: URL) throws {
            try JSONEncoder().encode(JSONValue.object(meta)).write(
                to: dir.appendingPathComponent(RecordingFiles.meta))
        }

        /// Все нескрытые файлы и папки под root с содержимым (lock'и и manifest — точечные, не в счёт):
        /// «ничего не поменялось» = снимок тот же.
        func snapshot() throws -> [String: Data] {
            var files: [String: Data] = [:]
            for sub in try FileManager.default.subpathsOfDirectory(atPath: store.root.path)
            where !sub.split(separator: "/").contains(where: { $0.hasPrefix(".") }) {
                let url = store.root.appendingPathComponent(sub)
                var isDirectory: ObjCBool = false
                _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                files[sub] = isDirectory.boolValue ? Data() : try Data(contentsOf: url)
            }
            return files
        }

        /// Освобождённый lock может мгновение числиться занятым (см. FileLockTests.acquireSoon),
        /// поэтому очередь проверяем с ожиданием до двух секунд.
        func pendingSoon() throws -> [String?] {
            let deadline = Date().addingTimeInterval(2)
            var ids = try store.pendingTranscription().map(\.id)
            while ids.isEmpty, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
                ids = try store.pendingTranscription().map(\.id)
            }
            return ids
        }
    }

    private func path(_ url: URL) -> String { url.resolvingSymlinksInPath().path }

    /// meta.json как JSON, без null-полей: синтезированный Codable их опускает.
    private func metaJSON(_ dir: URL) throws -> JSONValue {
        let json = try JSONDecoder().decode(
            JSONValue.self, from: Data(contentsOf: dir.appendingPathComponent(RecordingFiles.meta)))
        return droppingNulls(json)
    }

    private func droppingNulls(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let fields): .object(fields.filter { $0.value != .null }.mapValues(droppingNulls))
        case .array(let items): .array(items.map(droppingNulls))
        default: value
        }
    }

    private func frames(_ url: URL) throws -> Int { try readChannels(url).channels[0].count }

    @Test("аудио: цель + приклеиваемая подряд, без тишины, AAC 48 кГц 2 канала, L — mic, R — system")
    func appendsAudio() throws {
        let fixture = try Fixture()
        let targetAudio = fixture.target.appendingPathComponent(RecordingFiles.audio)
        let first = try frames(targetAudio)
        let second = try frames(fixture.source.appendingPathComponent(RecordingFiles.audio))

        _ = try RecordingMerger.merge("s1", into: "t1", store: fixture.store)

        let format = try AVAudioFile(forReading: targetAudio).fileFormat
        #expect(format.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC)
        let (channels, rate) = try readChannels(targetAudio)
        try #require(channels.count == 2)
        #expect(rate == 48_000)
        #expect(
            abs(channels[0].count - (first + second)) <= 2 * 2_048,
            "\(channels[0].count) vs \(first + second)")
        // первая часть — цель, вторая — приклеенная; окна в стороне от стыка
        let early = 12_000..<84_000
        let late = (first + 12_000)..<(first + 60_000)
        let (left, right) = (channels[0], channels[1])
        #expect(
            goertzelPower(left[early], hz: 440, sampleRate: rate) > 100
                * goertzelPower(left[early], hz: 660, sampleRate: rate))
        #expect(
            goertzelPower(right[early], hz: 1_000, sampleRate: rate)
                > 100 * goertzelPower(right[early], hz: 1_500, sampleRate: rate))
        #expect(
            goertzelPower(left[late], hz: 660, sampleRate: rate) > 100
                * goertzelPower(left[late], hz: 440, sampleRate: rate))
        #expect(
            goertzelPower(right[late], hz: 1_500, sampleRate: rate)
                > 100 * goertzelPower(right[late], hz: 1_000, sampleRate: rate))
    }

    @Test("meta цели — ровно по п. 7, транскрипты цели удалены, папка приклеенной исчезла, цель в очереди")
    func mergesMetaAndFolders() throws {
        let fixture = try Fixture()
        let store = fixture.store

        let merged = try RecordingMerger.merge("s1", into: "t1", store: store)

        #expect(merged.id == "t1")
        #expect(path(merged.url) == path(fixture.target))
        let expected = Self.targetMeta.merging([
            "ended_at": "2026-10-02T11:40:00Z", "duration_sec": 2280.75, "stop_reason": "manual",
            "call_apps": ["Zoom", "Teams", "Chrome"], "recovered": true, "status": "recorded",
            "transcription": ["attempts": 0],
        ]) { $1 }
        let expectedJSON = try JSONDecoder().decode(
            JSONValue.self, from: JSONEncoder().encode(JSONValue.object(expected)))
        #expect(try metaJSON(fixture.target) == expectedJSON)
        #expect(try store.readMeta(in: fixture.target)?.status == .recorded)
        // остались только аудио и meta: транскрипты удалены, partial не брошен
        let files = try FileManager.default.contentsOfDirectory(atPath: fixture.target.path).filter {
            !$0.hasPrefix(".")
        }
        #expect(Set(files) == [RecordingFiles.audio, RecordingFiles.meta])
        #expect(!FileManager.default.fileExists(atPath: fixture.source.path))
        #expect(try store.find(id: "s1") == nil)
        #expect(try store.find(id: "t1").map { path($0.url) } == path(fixture.target))
        #expect(try fixture.pendingSoon() == ["t1"])
    }

    @Test(
        "id или цель не найдены — not_found, ничего не меняется",
        arguments: [("nope", "t1"), ("s1", "nope")])
    func unknownID(id: String, target: String) throws {
        let fixture = try Fixture(targetSeconds: 1, sourceSeconds: 1)
        let before = try fixture.snapshot()

        let error = #expect(throws: EarmarkError.self) {
            try RecordingMerger.merge(id, into: target, store: fixture.store)
        }
        #expect(error?.code == "not_found")
        #expect(try fixture.snapshot() == before)
    }

    @Test(
        "у одной из записей есть .recording.json (идёт или сводится) — busy, ничего не меняется",
        arguments: [true, false])
    func manifestIsBusy(onTarget: Bool) throws {
        let fixture = try Fixture(targetSeconds: 1, sourceSeconds: 1)
        let (dir, id) = onTarget ? (fixture.target, "t1") : (fixture.source, "s1")
        let manifest = RecordingManifest(
            pid: ProcessInfo.processInfo.processIdentifier, startedAt: Date(), appVersion: "0.1.0", id: id,
            trigger: .manual, title: "Manual recording")
        try fixture.store.writeManifest(manifest, in: dir)
        let before = try fixture.snapshot()

        let error = #expect(throws: EarmarkError.self) {
            try RecordingMerger.merge("s1", into: "t1", store: fixture.store)
        }
        #expect(error?.code == "busy")
        #expect(try fixture.snapshot() == before)
    }

    @Test(
        "у одной из записей занят .transcribe.lock — busy «is being transcribed», ничего не меняется",
        arguments: [true, false])
    func transcribeLockIsBusy(onTarget: Bool) throws {
        let fixture = try Fixture(targetSeconds: 1, sourceSeconds: 1)
        let dir = onTarget ? fixture.target : fixture.source
        let worker = try #require(
            try FileLock.tryAcquire(at: dir.appendingPathComponent(RecordingFiles.transcribeLock)))
        defer { worker.release() }
        let before = try fixture.snapshot()

        let error = #expect(throws: EarmarkError.self) {
            try RecordingMerger.merge("s1", into: "t1", store: fixture.store)
        }
        #expect(error?.code == "busy")
        #expect(error?.message.contains("is being transcribed") == true, "\(error?.message ?? "")")
        #expect(try fixture.snapshot() == before)
    }

    /// Чего нет у записи: файла audio.m4a или блока audio в meta.
    enum MissingAudio: String, CaseIterable, Sendable { case file, meta }

    @Test(
        "у одной из записей нет аудио (файла или meta.audio) — bad_data, ничего не меняется",
        arguments: [true, false], MissingAudio.allCases)
    func withoutAudioIsBadData(onTarget: Bool, missing: MissingAudio) throws {
        let fixture = try Fixture(targetSeconds: 1, sourceSeconds: 1)
        let dir = onTarget ? fixture.target : fixture.source
        switch missing {
        case .file:
            try FileManager.default.removeItem(at: dir.appendingPathComponent(RecordingFiles.audio))
        case .meta:
            var meta = onTarget ? Self.targetMeta : Self.sourceMeta
            meta["audio"] = nil
            try Fixture.writeMeta(meta, in: dir)
        }
        let before = try fixture.snapshot()

        let error = #expect(throws: EarmarkError.self) {
            try RecordingMerger.merge("s1", into: "t1", store: fixture.store)
        }
        #expect(error?.code == "bad_data")
        #expect(try fixture.snapshot() == before)
    }

    @Test(
        "цель начата не раньше (позже, в ту же секунду или это та же запись) — invalid_arguments, ничего не меняется",
        arguments: [("t1", "s1"), ("twin", "t1"), ("t1", "t1")])
    func targetMustStartEarlier(id: String, target: String) throws {
        let fixture = try Fixture(targetSeconds: 1, sourceSeconds: 1)
        // twin начата в ту же секунду, что и t1
        try Fixture.recording(
            fixture.store.root.appendingPathComponent(
                "Manual/2026-10-02 14-00 Manual recording", isDirectory: true),
            Self.sourceMeta.merging(["id": "twin", "started_at": "2026-10-02T11:00:00Z"]) { $1 }, seconds: 1,
            mic: 660, system: 1_500)
        let before = try fixture.snapshot()

        let error = #expect(throws: EarmarkError.self) {
            try RecordingMerger.merge(id, into: target, store: fixture.store)
        }
        #expect(error?.code == "invalid_arguments")
        #expect(try fixture.snapshot() == before)
    }

    @Test(
        "аудио одной из записей не читается — ошибка, ни аудио, ни meta, ни транскрипты, ни папки не тронуты",
        arguments: [true, false])
    func unreadableAudioChangesNothing(onTarget: Bool) throws {
        let fixture = try Fixture(targetSeconds: 1, sourceSeconds: 1)
        let dir = onTarget ? fixture.target : fixture.source
        try Data(repeating: 0x5A, count: 10_000).write(to: dir.appendingPathComponent(RecordingFiles.audio))
        let before = try fixture.snapshot()

        #expect(throws: EarmarkError.self) {
            try RecordingMerger.merge("s1", into: "t1", store: fixture.store)
        }
        #expect(try fixture.snapshot() == before)
        #expect(try fixture.store.find(id: "s1") != nil)
    }
}
