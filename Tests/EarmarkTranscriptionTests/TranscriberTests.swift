import AVFoundation
import EarmarkCore
import Foundation
import Synchronization
import Testing

@testable import EarmarkTranscription

/// Движок-фейк: отдаёт заготовленные ответы по порядку вызовов (сначала mic, потом system)
/// и запоминает, сколько сэмплов получил.
private final class FakeEngine: SpeechEngine {
    private let replies: Mutex<[Result<[RawSegment], EarmarkError>]>
    private let seen = Mutex<[Int]>([])

    init(_ replies: [Result<[RawSegment], EarmarkError>]) { self.replies = Mutex(replies) }

    var sampleCounts: [Int] { seen.withLock { $0 } }

    func transcribe(
        _ samples: [Float], params: WhisperParams, progress: @escaping @Sendable (Int) -> Void,
        shouldAbort: @escaping @Sendable () -> Bool
    ) async throws(EarmarkError) -> [RawSegment] {
        seen.withLock { $0.append(samples.count) }
        progress(100)
        let reply = replies.withLock { $0.isEmpty ? .success([]) : $0.removeFirst() }
        return try reply.get()
    }
}

/// Счётчик вызовов фабрики движка: сколько раз Transcriber пытался поднять модель.
private final class Counter: Sendable {
    private let value = Mutex(0)
    func increment() { value.withLock { $0 += 1 } }
    var total: Int { value.withLock { $0 } }
}

/// Папка записи в свежем temp-каталоге: meta.json (recorded) + настоящий стерео AAC audio.m4a.
private struct RecordingFixture {
    let root: URL
    let folder: URL
    var store: RecordingStore { RecordingStore(root: root) }

    init(
        status: String = "recorded", attempts: Int = 0, seconds: Double = 2,
        left: (Int) -> Float = { _ in 0 }, right: (Int) -> Float = { _ in 0 }
    )
        throws
    {
        root = FileManager.default.temporaryDirectory.appending(path: "earmark-tr-\(UUID().uuidString)")
        folder = root.appending(path: "Manual/2026-10-02 14-00 Test")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // meta пишем JSON-литералом: так фикстура не зависит от инициализаторов RecordingMeta.
        let meta = """
            {"schema_version":1,"id":"20261002-1400-a1b2","status":"\(status)","trigger":"manual",\
            "title":"Test","started_at":"2026-10-02T10:00:00Z","duration_sec":\(seconds),"call_apps":[],\
            "recovered":false,"transcription":{"attempts":\(attempts)},"app_version":"0.1.0"}
            """
        try Data(meta.utf8).write(to: folder.appending(path: RecordingFiles.meta))
        try Self.writeStereoM4A(
            folder.appending(path: RecordingFiles.audio), seconds: seconds, left: left, right: right)
    }

    var meta: RecordingMeta { get throws { try #require(try store.readMeta(in: folder)) } }

    func file(_ name: String) -> URL { folder.appending(path: name) }

    static func writeStereoM4A(_ url: URL, seconds: Double, left: (Int) -> Float, right: (Int) -> Float)
        throws
    {
        let rate = 48_000.0
        let format = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false))
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 96_000,
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let total = Int(seconds * rate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        let channels = try #require(buffer.floatChannelData)
        var written = 0
        while written < total {
            let count = min(48_000, total - written)
            buffer.frameLength = AVAudioFrameCount(count)
            for frame in 0..<count {
                channels[0][frame] = left(written + frame)
                channels[1][frame] = right(written + frame)
            }
            try file.write(from: buffer)
            written += count
        }
        file.close()
    }
}

@Suite("Transcriber: задача транскрипции")
struct TranscriberTests {
    private let config = Config(values: [
        "transcription.language": .string("ru"), "transcript.label_me": .string("Я"),
        "transcript.label_them": .string("Собеседники"),
    ])

    private func transcriber(_ fixture: RecordingFixture, _ engine: FakeEngine, calls: Counter = Counter())
        -> Transcriber
    {
        Transcriber(store: fixture.store, config: config) {
            () async throws(EarmarkError) -> any SpeechEngine in
            calls.increment()
            return engine
        }
    }

    private func run(_ transcriber: Transcriber, _ fixture: RecordingFixture, force: Bool = false)
        async throws(EarmarkError) -> Transcript
    {
        try await transcriber.run(
            folder: fixture.folder, force: force, progress: { _ in /* прогресс здесь не проверяем */ },
            shouldAbort: { false })
    }

    @Test("успех: оба канала, пост-фильтр, файлы на месте, meta → transcribed")
    func success() async throws {
        let fixture = try RecordingFixture()
        let engine = FakeEngine([
            .success([
                RawSegment(startMs: 0, endMs: 1_000, text: "привет"),
                RawSegment(startMs: 1_000, endMs: 1_900, text: "Продолжение следует..."),
            ]),
            .success([RawSegment(startMs: 500, endMs: 1_500, text: "здравствуйте")]),
        ])
        let progress = Mutex<[TranscribeProgress]>([])

        let transcript = try await transcriber(fixture, engine).run(
            folder: fixture.folder, force: false,
            progress: { update in progress.withLock { $0.append(update) } },
            shouldAbort: { false })

        #expect(transcript.segments.map(\.text) == ["привет", "здравствуйте"])
        #expect(transcript.segments.map(\.speaker) == [.me, .them])
        #expect(transcript.recordingId == "20261002-1400-a1b2")
        // Настоящий декод audio.m4a: 2 с стерео 48 kHz → по 32 000 сэмплов 16 kHz на канал.
        #expect(engine.sampleCounts.count == 2)
        #expect(engine.sampleCounts.allSatisfy { abs($0 - 32_000) < 1_600 })
        #expect(
            progress.withLock { $0 } == [
                .init(channel: .mic, percent: 100), .init(channel: .system, percent: 100),
            ])
        #expect(
            try String(contentsOf: fixture.file(RecordingFiles.transcriptText), encoding: .utf8)
                == "[00:00:00] Я: привет\n[00:00:00] Собеседники: здравствуйте\n")
        let saved = try EarmarkJSON.decoder.decode(
            Transcript.self, from: Data(contentsOf: fixture.file(RecordingFiles.transcript)))
        #expect(saved == transcript)
        let mic = try EarmarkJSON.decoder.decode(
            ChannelTranscript.self, from: Data(contentsOf: fixture.file(RecordingFiles.transcriptMic)))
        #expect(mic.segments.map(\.text) == ["привет"])
        #expect(mic.fingerprint == Transcriber.fingerprint)
        // Атомарные записи не оставляют временных файлов.
        #expect(
            Set(try FileManager.default.contentsOfDirectory(atPath: fixture.folder.path)) == [
                RecordingFiles.meta, RecordingFiles.audio, RecordingFiles.transcribeLock,
                RecordingFiles.transcriptMic,
                RecordingFiles.transcriptSystem, RecordingFiles.transcript, RecordingFiles.transcriptText,
            ])
        let meta = try fixture.meta
        #expect(meta.status == .transcribed)
        #expect(meta.transcription.attempts == 0)
        #expect(meta.transcription.error == nil && meta.transcription.errorKind == nil)
        #expect(meta.transcription.fingerprint == Transcriber.fingerprint)
        #expect(meta.transcription.language == "ru")
    }

    @Test("lock держит другой процесс — busy (75), meta не тронута, модель не грузим")
    func lockBusy() async throws {
        let fixture = try RecordingFixture()
        let held = try #require(try FileLock.tryAcquire(at: fixture.file(RecordingFiles.transcribeLock)))
        defer { held.release() }
        let calls = Counter()

        let error = await #expect(throws: EarmarkError.self) {
            try await run(transcriber(fixture, FakeEngine([]), calls: calls), fixture)
        }

        #expect(error?.exitCode == 75)
        #expect(try fixture.meta.status == .recorded)
        #expect(try fixture.meta.transcription.attempts == 0)
        #expect(calls.total == 0)
    }

    @Test("готовый канал с тем же fingerprint не пересчитываем; --force пересчитывает оба")
    func skipAndForce() async throws {
        let fixture = try RecordingFixture()
        let ready = ChannelTranscript(
            channel: .mic, model: "ggml-large-v3-turbo", language: "ru", fingerprint: Transcriber.fingerprint,
            segments: [RawSegment(startMs: 0, endMs: 500, text: "уже было")])
        try EarmarkJSON.encoder.encode(ready).write(to: fixture.file(RecordingFiles.transcriptMic))
        let engine = FakeEngine([
            .success([RawSegment(startMs: 100, endMs: 600, text: "собеседник")]),
            .success([RawSegment(startMs: 0, endMs: 500, text: "заново mic")]),
            .success([RawSegment(startMs: 100, endMs: 600, text: "заново system")]),
        ])

        let first = try await run(transcriber(fixture, engine), fixture)
        #expect(first.segments.map(\.text) == ["уже было", "собеседник"])
        #expect(engine.sampleCounts.count == 1)

        let forced = try await run(transcriber(fixture, engine), fixture, force: true)
        #expect(forced.segments.map(\.text) == ["заново mic", "заново system"])
        #expect(engine.sampleCounts.count == 3)
    }

    @Test("канал с чужим fingerprint (другие параметры) пересчитывается")
    func staleFingerprint() async throws {
        let fixture = try RecordingFixture()
        let stale = ChannelTranscript(
            channel: .mic, model: "ggml-large-v3-turbo", language: "ru",
            fingerprint: "whisper-b5130|old|ref-0",
            segments: [RawSegment(startMs: 0, endMs: 500, text: "старое")])
        try EarmarkJSON.encoder.encode(stale).write(to: fixture.file(RecordingFiles.transcriptMic))
        let engine = FakeEngine([.success([RawSegment(startMs: 0, endMs: 500, text: "новое")]), .success([])])

        #expect(try await run(transcriber(fixture, engine), fixture).segments.map(\.text) == ["новое"])
    }

    @Test("канал с тем же fingerprint, но на другом языке пересчитывается на языке конфига")
    func staleLanguage() async throws {
        let fixture = try RecordingFixture()
        let english = ChannelTranscript(
            channel: .mic, model: "ggml-large-v3-turbo", language: "en", fingerprint: Transcriber.fingerprint,
            segments: [RawSegment(startMs: 0, endMs: 500, text: "old english")])
        try EarmarkJSON.encoder.encode(english).write(to: fixture.file(RecordingFiles.transcriptMic))
        let engine = FakeEngine([
            .success([RawSegment(startMs: 0, endMs: 500, text: "по-русски")]), .success([]),
        ])

        #expect(try await run(transcriber(fixture, engine), fixture).segments.map(\.text) == ["по-русски"])
        #expect(engine.sampleCounts.count == 2)
        let mic = try EarmarkJSON.decoder.decode(
            ChannelTranscript.self, from: Data(contentsOf: fixture.file(RecordingFiles.transcriptMic)))
        #expect(mic.language == "ru")
        #expect(try fixture.meta.transcription.language == "ru")
    }

    @Test("сбой whisper засчитывается; после третьей попытки — transcription_failed, дальше только --force")
    func retryableUntilFailed() async throws {
        let fixture = try RecordingFixture()
        let boom = EarmarkError.operationFailed("whisper_full returned -6")
        let engine = FakeEngine(Array(repeating: .failure(boom), count: 3) + [.success([]), .success([])])

        for attempt in 1...3 {
            let error = await #expect(throws: EarmarkError.self) {
                try await run(transcriber(fixture, engine), fixture)
            }
            #expect(error == boom)
            let meta = try fixture.meta
            #expect(meta.transcription.attempts == attempt)
            #expect(meta.transcription.errorKind == "retryable")
            #expect(meta.transcription.error == boom.message)
            #expect(meta.status == (attempt < 3 ? .recorded : .transcriptionFailed))
        }

        let calls = Counter()
        let exhausted = await #expect(throws: EarmarkError.self) {
            try await run(transcriber(fixture, engine, calls: calls), fixture)
        }
        #expect(exhausted?.code == "operation_failed")
        #expect(calls.total == 0)

        _ = try await run(transcriber(fixture, engine), fixture, force: true)
        #expect(try fixture.meta.status == .transcribed)
        #expect(try fixture.meta.transcription.attempts == 0)
    }

    @Test("трижды оборвавшийся крэшем воркер (attempts уже 3) сразу уходит в transcription_failed")
    func crashLoopStops() async throws {
        let fixture = try RecordingFixture(attempts: 3)
        let calls = Counter()

        await #expect(throws: EarmarkError.self) {
            try await run(transcriber(fixture, FakeEngine([]), calls: calls), fixture)
        }

        #expect(try fixture.meta.status == .transcriptionFailed)
        #expect(calls.total == 0)
    }

    @Test("битое аудио — bad_data (65), permanent: сразу transcription_failed, модель не грузим")
    func corruptAudio() async throws {
        let fixture = try RecordingFixture()
        try Data("это не m4a".utf8).write(to: fixture.file(RecordingFiles.audio))
        let calls = Counter()

        let error = await #expect(throws: EarmarkError.self) {
            try await run(transcriber(fixture, FakeEngine([]), calls: calls), fixture)
        }

        #expect(error?.exitCode == 65)
        let meta = try fixture.meta
        #expect(meta.transcription.attempts == 1)
        #expect(meta.transcription.errorKind == "permanent")
        #expect(meta.status == .transcriptionFailed)
        #expect(calls.total == 0)
    }

    @Test("нет модели — unavailable (69), попытка не засчитана, запись ждёт в recorded")
    func modelUnavailable() async throws {
        let fixture = try RecordingFixture()
        let transcriber = Transcriber(store: fixture.store, config: config) {
            () async throws(EarmarkError) -> any SpeechEngine in
            throw .unavailable("whisper.cpp failed to load the model")
        }

        let error = await #expect(throws: EarmarkError.self) { try await run(transcriber, fixture) }

        #expect(error?.exitCode == 69)
        let meta = try fixture.meta
        #expect(meta.transcription.attempts == 0)
        #expect(meta.transcription.errorKind == "environmental")
        #expect(meta.status == .recorded)
    }

    @Test("SIGTERM (shouldAbort) — interrupted (75), попытка не засчитана, запись в recorded")
    func interrupted() async throws {
        let fixture = try RecordingFixture()

        let error = await #expect(throws: EarmarkError.self) {
            try await transcriber(fixture, FakeEngine([])).run(
                folder: fixture.folder, force: false, progress: { _ in /* прогресс здесь не проверяем */ },
                shouldAbort: { true })
        }

        #expect(error?.code == "interrupted")
        #expect(error?.exitCode == 75)
        #expect(try fixture.meta.transcription.attempts == 0)
        #expect(try fixture.meta.status == .recorded)
    }

    @Test("прерванный --force из transcription_failed возвращает transcription_failed, попытка не засчитана")
    func interruptedRestoresStatus() async throws {
        let fixture = try RecordingFixture(status: "transcription_failed", attempts: 3)
        let engine = FakeEngine([.failure(.interrupted)])

        // SIGTERM приходит, когда движок уже работает: claim к этому моменту сделан.
        let error = await #expect(throws: EarmarkError.self) {
            try await transcriber(fixture, engine).run(
                folder: fixture.folder, force: true, progress: { _ in /* прогресс здесь не проверяем */ },
                shouldAbort: { !engine.sampleCounts.isEmpty })
        }

        #expect(error?.code == "interrupted")
        #expect(engine.sampleCounts.count == 1)
        let meta = try fixture.meta
        #expect(meta.status == .transcriptionFailed)
        // Прерванной попытки как не было: meta возвращается к снимку до claim, обнуление от --force тоже.
        #expect(meta.transcription.attempts == 3)
    }

    @Test("SIGTERM во время настоящего сбоя whisper — всё равно interrupted (75), попытка не засчитана")
    func abortWinsOverEngineFailure() async throws {
        let fixture = try RecordingFixture()
        let engine = FakeEngine([.failure(.operationFailed("whisper_full returned -6"))])

        let error = await #expect(throws: EarmarkError.self) {
            try await transcriber(fixture, engine).run(
                folder: fixture.folder, force: false, progress: { _ in /* прогресс здесь не проверяем */ },
                shouldAbort: { !engine.sampleCounts.isEmpty })
        }

        #expect(error?.code == "interrupted")
        #expect(error?.exitCode == 75)
        #expect(engine.sampleCounts.count == 1)
        let meta = try fixture.meta
        #expect(meta.transcription.attempts == 0)
        #expect(meta.status == .recorded)
    }
}
