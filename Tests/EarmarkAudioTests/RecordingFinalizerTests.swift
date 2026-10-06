import EarmarkAudio
import EarmarkCore
import Foundation
import Testing

@Suite("RecordingFinalizer")
struct RecordingFinalizerTests {
    static let started = Date(timeIntervalSince1970: 1_790_000_000)

    /// Папка записи как после старта сеанса: manifest уже на диске, треки тест кладёт сам.
    struct Recording {
        let store: RecordingStore
        let folder: URL
        let manifest: RecordingManifest
    }

    static func makeRecording(root: URL, trigger: RecordingTrigger = .manual) throws -> Recording {
        let store = RecordingStore(root: root)
        let folder = try store.createRecordingFolder(calendarFolder: nil, title: "Sync", startedAt: started)
        let manifest = RecordingManifest(
            pid: 4_242, startedAt: started, appVersion: "0.1.0", id: "20261002-1400-a1b2", trigger: trigger,
            title: "Sync")
        try store.writeManifest(manifest, in: folder)
        return Recording(store: store, folder: folder, manifest: manifest)
    }

    @Test(
        "finalize: audio.m4a через rename, meta.json, manifest убран, CAF по keep_raw_tracks",
        arguments: [false, true])
    func finalizes(keepRawTracks: Bool) throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recording = try Self.makeRecording(root: root)
        let (store, folder, manifest) = (recording.store, recording.folder, recording.manifest)
        try writeToneCAF(
            folder.appendingPathComponent(RecordingFiles.mic), seconds: 2, channels: [ToneSpec(hz: 440)])
        try writeToneCAF(
            folder.appendingPathComponent(RecordingFiles.system), seconds: 2, channels: [ToneSpec(hz: 1_000)])
        let ended = Self.started.addingTimeInterval(125)

        let meta = try #require(
            try RecordingFinalizer.finalize(
                folder: folder, manifest: manifest, stopReason: .manual, endedAt: ended, micOffsetMs: 12,
                callApps: ["Zoom"], keepRawTracks: keepRawTracks, stop: .defaults, store: store))

        #expect(meta.status == .recorded)
        #expect(meta.stopReason == .manual)
        #expect(meta.durationSec == 125)
        #expect(meta.callApps == ["Zoom"])
        #expect(meta.recovered == false)
        #expect(meta.audio?.micOffsetMs == 12)
        #expect(try store.readMeta(in: folder) == meta)
        #expect(try store.readManifest(in: folder) == nil)
        let files = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        #expect(files.contains(RecordingFiles.audio))
        #expect(!files.contains(RecordingFiles.audioPartial))
        #expect(files.contains(RecordingFiles.mic) == keepRawTracks)
        #expect(files.contains(RecordingFiles.system) == keepRawTracks)
    }

    @Test("авто-запись короче min_keep_seconds — папка удаляется целиком")
    func discardsShortAutoRecording() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recording = try Self.makeRecording(root: root, trigger: .calendar)
        let (store, folder, manifest) = (recording.store, recording.folder, recording.manifest)
        try writeToneCAF(
            folder.appendingPathComponent(RecordingFiles.mic), seconds: 1, channels: [ToneSpec(hz: 440)])

        let meta = try RecordingFinalizer.finalize(
            folder: folder, manifest: manifest, stopReason: .callEnded,
            endedAt: Self.started.addingTimeInterval(30),
            micOffsetMs: 0, callApps: [], keepRawTracks: false, stop: .defaults, store: store)

        #expect(meta == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    /// Фокус ревью №3: kill -9 посреди записи → при следующем старте audio.m4a сводится из того, что успело
    /// дойти до диска, с recovered: true.
    @Test("recover: CAF после SIGKILL сводятся, recovered, ended_at = mtime свежего трека")
    func recoversKilledRecording() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recording = try Self.makeRecording(root: root)
        let (store, folder, manifest) = (recording.store, recording.folder, recording.manifest)
        let mic = folder.appendingPathComponent(RecordingFiles.mic)
        let system = folder.appendingPathComponent(RecordingFiles.system)
        async let killedMic = killedRecording(at: mic, mode: "sync")
        async let killedSystem = killedRecording(at: system, mode: "async")
        _ = try await (killedMic, killedSystem)
        let newest = try [mic, system]
            .compactMap {
                try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            }
            .max()

        let meta = try RecordingFinalizer.recover(
            folder: folder, manifest: manifest, keepRawTracks: false, store: store)

        #expect(meta.recovered)
        #expect(meta.stopReason == .recovered)
        #expect(meta.status == .recorded)
        #expect(meta.endedAt == newest)
        #expect(meta.audio?.file == RecordingFiles.audio)
        #expect(
            FileManager.default.fileExists(atPath: folder.appendingPathComponent(RecordingFiles.audio).path))
        #expect(try store.readManifest(in: folder) == nil)
        #expect(!FileManager.default.fileExists(atPath: mic.path))
    }

    @Test("recover без единого кадра — meta с ошибкой no_audio, без audio, manifest убран")
    func recoversWithoutAudio() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recording = try Self.makeRecording(root: root)
        let (store, folder, manifest) = (recording.store, recording.folder, recording.manifest)
        FileManager.default.createFile(
            atPath: folder.appendingPathComponent(RecordingFiles.mic).path, contents: Data())

        let meta = try RecordingFinalizer.recover(
            folder: folder, manifest: manifest, keepRawTracks: false, store: store)

        #expect(meta.status == .transcriptionFailed)
        #expect(meta.transcription.errorKind == "permanent")
        #expect(meta.transcription.error?.hasPrefix("no_audio") == true)
        #expect(meta.audio == nil)
        #expect(meta.recovered)
        #expect(try store.readManifest(in: folder) == nil)
        #expect(try store.readMeta(in: folder)?.status == .transcriptionFailed)
    }

    @Test("recover после чистого стопа, не успевшего убрать manifest, — только уборка")
    func recoverKeepsFinishedMeta() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recording = try Self.makeRecording(root: root)
        let (store, folder, manifest) = (recording.store, recording.folder, recording.manifest)
        let finished = RecordingMeta(
            id: manifest.id, status: .recorded, trigger: .manual, title: "Sync", startedAt: Self.started,
            endedAt: Self.started.addingTimeInterval(60), durationSec: 60, stopReason: .manual,
            appVersion: "0.1.0")
        try store.writeMeta(finished, in: folder)

        let meta = try RecordingFinalizer.recover(
            folder: folder, manifest: manifest, keepRawTracks: false, store: store)

        #expect(meta == finished)
        #expect(try store.readManifest(in: folder) == nil)
    }
}
