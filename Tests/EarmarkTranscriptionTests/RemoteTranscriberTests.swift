import AVFoundation
import EarmarkAudio
import Foundation
import Synchronization
import Testing

@testable import EarmarkCore
@testable import EarmarkTranscription

private let id = "20261002-1400-a1b2"

/// Различимый звук каналов: «залито ровно то, что в m4a» на тишине прошло бы случайно.
private func micTone(_ frame: Int) -> Float { sin(Float(frame) * 0.05) * 0.2 }
private func systemTone(_ frame: Int) -> Float { sin(Float(frame) * 0.031) * 0.2 }

/// Быстрое ожидание сервера: опрос раз в 10 мс, не дольше 3 с.
private let quick = RemoteWait(poll: .milliseconds(10), limit: .seconds(3))

private let baseConfig = Config(values: [
    "transcription.language": .string("ru"), "transcript.label_me": .string("Я"),
    "transcript.label_them": .string("Собеседники"),
])

/// Результат, который сервер посчитает заново, и результат, который уже лежал в найденной задаче.
private let fresh: [[FakeSegment]] = [[FakeSegment(startMs: 0, endMs: 800, text: "новое")], []]
private let stale: [[FakeSegment]] = [[FakeSegment(startMs: 0, endMs: 800, text: "старое")], []]

private func recording(calendarId: String? = nil, micOffsetMs: Int? = nil) throws -> RecordingFixture {
    try RecordingFixture(calendarId: calendarId, micOffsetMs: micOffsetMs, left: micTone, right: systemTone)
}

/// Каналы audio.m4a так, как их отдаёт ChannelExtractor (16 kHz): эталон загрузки и длин.
private func channels(_ fixture: RecordingFixture) throws -> [[Float]] {
    try (0...1).map { try ChannelExtractor.extract(from: fixture.file(RecordingFiles.audio), channel: $0) }
}

/// Длины каналов, с которыми шаг 4 сверяет найденную задачу: по числу кадров audio.m4a
/// (кадры × 16 000 / частота файла), без декодирования. Эталон границ допуска в 1 с.
private func frameLengths(_ fixture: RecordingFixture) throws -> [Int] {
    let file = try AVAudioFile(forReading: fixture.file(RecordingFiles.audio))
    let rate = Int(file.fileFormat.sampleRate)
    let scaled = Int(file.length) * 16_000
    // Граница допуска проверяется точно, поэтому длина фикстуры должна быть целой и без округления.
    try #require(scaled % rate == 0, "\(file.length) кадров при \(rate) Гц")
    return [scaled / rate, scaled / rate]
}

private func transcriber(
    _ fixture: RecordingFixture, _ server: FakeJobServer, config: Config = baseConfig,
    wait: RemoteWait = quick,
    client: RemoteTranscriptionClient? = nil
) -> Transcriber {
    Transcriber(
        store: fixture.store, config: config, server: client ?? FakeWhisper.client(server), wait: wait)
}

private func run(_ transcriber: Transcriber, _ fixture: RecordingFixture, force: Bool = false)
    async throws(EarmarkError) -> Transcript
{
    try await transcriber.run(
        folder: fixture.folder, force: force, progress: { _ in /* прогресс здесь не проверяем */ },
        shouldAbort: { false })
}

private func texts(_ transcript: Transcript) -> [String] { transcript.segments.map(\.text) }

private func channelFile(_ fixture: RecordingFixture, _ name: String) throws -> ChannelTranscript {
    try EarmarkJSON.decoder.decode(ChannelTranscript.self, from: Data(contentsOf: fixture.file(name)))
}

/// fingerprint удалённого результата по спеке: remote|<модель>|<sha256[:12]>|<версия параметров>.
private func remoteFingerprint(model: String = "large-v3-turbo", sha: String = Models.largeV3Turbo.sha256)
    -> String
{
    "remote|\(model)|\(sha.prefix(12))|\(WhisperParams.version)"
}

/// Запись ждёт сервер: exit 69, попытка не засчитана, в meta — «waiting for server: …», расшифровки нет.
private func expectWaiting(
    _ error: EarmarkError?, _ fixture: RecordingFixture, sourceLocation: SourceLocation = #_sourceLocation
) throws {
    #expect(error?.exitCode == 69, "\(String(describing: error))", sourceLocation: sourceLocation)
    let meta = try fixture.meta
    #expect(meta.status == .recorded, sourceLocation: sourceLocation)
    #expect(meta.transcription.attempts == 0, sourceLocation: sourceLocation)
    #expect(meta.transcription.errorKind == "environmental", sourceLocation: sourceLocation)
    let text = meta.transcription.error ?? ""
    #expect(text.hasPrefix("waiting for server: "), "«\(text)»", sourceLocation: sourceLocation)
    #expect(
        !FileManager.default.fileExists(atPath: fixture.file(RecordingFiles.transcript).path),
        "локальная расшифровка вместо ожидания", sourceLocation: sourceLocation)
}

/// Сервер пропадает, как только `condition` стало истинным: дальше соединения рвутся и отклоняются.
private func vanish(_ server: FakeJobServer, once condition: @escaping @Sendable () -> Bool) {
    Thread {
        let deadline = Date().addingTimeInterval(30)
        while !condition(), Date() < deadline { Thread.sleep(forTimeInterval: 0.002) }
        server.stop()
    }.start()
}

/// Засчитанный сбой: operation_failed (1), attempts += 1, retryable, запись ещё в recorded.
private func expectCounted(
    _ error: EarmarkError?, _ fixture: RecordingFixture, sourceLocation: SourceLocation = #_sourceLocation
) throws {
    #expect(error?.code == "operation_failed", "\(String(describing: error))", sourceLocation: sourceLocation)
    #expect(error?.exitCode == 1, sourceLocation: sourceLocation)
    let meta = try fixture.meta
    #expect(meta.status == .recorded, sourceLocation: sourceLocation)
    #expect(meta.transcription.attempts == 1, sourceLocation: sourceLocation)
    #expect(meta.transcription.errorKind == "retryable", sourceLocation: sourceLocation)
}

/// SIGTERM: interrupted (75) в пределах опроса после флага, попытка не засчитана, meta как до захвата.
private func expectInterrupted(
    _ error: EarmarkError?, _ fixture: RecordingFixture, raisedAt: Date?,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    #expect(error?.code == "interrupted", "\(String(describing: error))", sourceLocation: sourceLocation)
    #expect(error?.exitCode == 75, sourceLocation: sourceLocation)
    // Опрос — 100 мс; остальное — запас на загруженную параллельными тестами машину.
    let raised = try #require(raisedAt, "флаг так и не взвёлся", sourceLocation: sourceLocation)
    #expect(Date().timeIntervalSince(raised) < 1, sourceLocation: sourceLocation)
    let meta = try fixture.meta
    #expect(meta.status == .recorded, sourceLocation: sourceLocation)
    #expect(meta.transcription.attempts == 0, sourceLocation: sourceLocation)
    #expect(meta.transcription.errorKind == nil, sourceLocation: sourceLocation)
}

@Suite("Transcriber, удалённый режим: звук на сервер, результат с сервера")
struct RemoteTranscriberTests {
    @Test(
        "задачи нет: оба канала из m4a залиты, submit с языком и длинами, done → файлы, meta transcribed, DELETE"
    )
    func success() async throws {
        let fixture = try recording()
        let local = try channels(fixture)
        let audio = try Data(contentsOf: fixture.file(RecordingFiles.audio))
        let server = try FakeJobServer {
            $0.result = [
                [
                    FakeSegment(startMs: 0, endMs: 900, text: " привет "),
                    FakeSegment(startMs: 1_000, endMs: 1_900, text: "Продолжение следует..."),
                ],
                [FakeSegment(startMs: 500, endMs: 1_500, text: "здравствуйте")],
            ]
        }
        defer { server.stop() }

        let transcript = try await run(transcriber(fixture, server), fixture)

        #expect(texts(transcript) == ["привет", "здравствуйте"])
        #expect(transcript.segments.map(\.speaker) == [.me, .them])
        #expect(transcript.recordingId == id)
        #expect(transcript.model == "large-v3-turbo")
        #expect(transcript.language == "ru")
        // На сервер ушло ровно то, что в audio.m4a, и submit — с языком записи и длинами её каналов.
        let job = try #require(server.lastSeen(id))
        #expect(job.samples == local)
        #expect(job.source == "m4a")
        #expect(server.submits.map(\.languages) == ["ru"])
        #expect(server.submits.map(\.lengths) == [local.map(\.count)])
        #expect(server.calls.first == "health")
        #expect(server.calls.last == "delete")
        #expect(server.job(id) == nil)
        #expect(
            try String(contentsOf: fixture.file(RecordingFiles.transcriptText), encoding: .utf8)
                == "[00:00:00] Я: привет\n[00:00:00] Собеседники: здравствуйте\n")
        let saved = try EarmarkJSON.decoder.decode(
            Transcript.self, from: Data(contentsOf: fixture.file(RecordingFiles.transcript)))
        #expect(saved == transcript)
        let mic = try channelFile(fixture, RecordingFiles.transcriptMic)
        let system = try channelFile(fixture, RecordingFiles.transcriptSystem)
        #expect(mic.segments.map(\.text) == ["привет"])
        #expect(system.segments.map(\.text) == ["здравствуйте"])
        #expect([mic.fingerprint, system.fingerprint] == [remoteFingerprint(), remoteFingerprint()])
        let meta = try fixture.meta
        #expect(meta.status == .transcribed)
        #expect(meta.transcription.attempts == 0)
        #expect(meta.transcription.error == nil && meta.transcription.errorKind == nil)
        #expect(meta.transcription.fingerprint == remoteFingerprint())
        #expect(meta.transcription.language == "ru")
        #expect(try Data(contentsOf: fixture.file(RecordingFiles.audio)) == audio)
    }

    @Test(
        "языки задачи — языки записи по её календарю: свой список календаря, иначе глобальный",
        arguments: [("CAL-LANGS", "ru,en,az"), ("CAL-PLAIN", "ru"), (nil, "ru")] as [(String?, String)])
    func languagePerCalendar(calendarId: String?, expected: String) async throws {
        let fixture = try recording(calendarId: calendarId)
        let server = try FakeJobServer()
        defer { server.stop() }
        let config = Config(values: [
            "transcription.language": .string("ru"), "calendar.CAL-LANGS.language": .string("ru,en,az"),
        ])

        let transcript = try await run(transcriber(fixture, server, config: config), fixture)

        #expect(server.submits.map(\.languages) == [expected])
        #expect(transcript.language == expected)
        #expect(try fixture.meta.transcription.language == expected)
    }

    @Test("модель и fingerprint — из ответа сервера, модель на маке не пинится")
    func modelFromServer() async throws {
        let fixture = try recording()
        let sha = "0123456789ab" + String(repeating: "f", count: 52)
        let server = try FakeJobServer {
            $0.model = "ggml-large-v3.bin"
            $0.modelSha256 = sha
            $0.result = fresh
        }
        defer { server.stop() }

        let transcript = try await run(transcriber(fixture, server), fixture)

        let expected = remoteFingerprint(model: "large-v3", sha: sha)
        #expect(expected.hasPrefix("remote|large-v3|0123456789ab|"))
        #expect(transcript.model == "large-v3")
        let mic = try channelFile(fixture, RecordingFiles.transcriptMic)
        let system = try channelFile(fixture, RecordingFiles.transcriptSystem)
        #expect([mic.model, system.model] == ["large-v3", "large-v3"])
        #expect([mic.fingerprint, system.fingerprint] == [expected, expected])
        #expect(try fixture.meta.transcription.fingerprint == expected)
    }

    /// Языки записи и то, чем сервер помечает сегменты: язык прогона есть у каждого сегмента всегда.
    enum SegmentLanguages: String, CaseIterable {
        case single, auto, list

        var languages: String {
            switch self {
            case .single: "ru"
            case .auto: "auto"
            case .list: "ru,en"
            }
        }

        var calendarId: String? { self == .list ? "CAL-LANGS" : nil }

        var config: Config {
            Config(values: [
                "transcription.language": .string(self == .auto ? "auto" : "ru"),
                "calendar.CAL-LANGS.language": .string("ru,en"),
            ])
        }

        /// language сегментов сервера: [mic0, mic1], system0. Для auto — что определил whisper.
        var labels: (mic: [String], system: String) {
            switch self {
            case .single: (["ru", "ru"], "ru")
            case .auto: (["en", "en"], "en")
            case .list: (["ru", "en"], "en")
            }
        }
    }

    @Test(
        "язык сегмента как у локального пути: один код или auto — без языка, хоть сервер его и пишет; список — язык прогона",
        arguments: SegmentLanguages.allCases)
    func segmentLanguage(_ setup: SegmentLanguages) async throws {
        let fixture = try recording(calendarId: setup.calendarId)
        let labels = setup.labels
        let server = try FakeJobServer {
            $0.result = [
                [
                    FakeSegment(startMs: 0, endMs: 900, text: "привет", language: labels.mic[0]),
                    FakeSegment(startMs: 2_000, endMs: 2_900, text: "hello there", language: labels.mic[1]),
                ],
                [FakeSegment(startMs: 500, endMs: 1_500, text: "good afternoon", language: labels.system)],
            ]
        }
        defer { server.stop() }

        _ = try await run(transcriber(fixture, server, config: setup.config), fixture)

        #expect(server.submits.map(\.languages) == [setup.languages])
        let mic = try channelFile(fixture, RecordingFiles.transcriptMic)
        let system = try channelFile(fixture, RecordingFiles.transcriptSystem)
        #expect(mic.segments.map(\.text) == ["привет", "hello there"])
        #expect(system.segments.map(\.text) == ["good afternoon"])
        if setup == .list {
            #expect(mic.segments.map(\.language) == ["ru", "en"])
            #expect(system.segments.map(\.language) == ["en"])
        } else {
            #expect(mic.segments.allSatisfy { $0.language == nil }, "\(mic.segments.map(\.language))")
            #expect(system.segments.allSatisfy { $0.language == nil }, "\(system.segments.map(\.language))")
        }
    }

    @Test("--force: рукопожатие, затем DELETE задачи; готовая задача не переиспользуется")
    func forceDeletesAfterHandshake() async throws {
        let fixture = try recording()
        let local = try channels(fixture)
        let server = try FakeJobServer { $0.result = fresh }
        defer { server.stop() }
        server.seed(
            id,
            FakeJob(
                state: "done", progress: 100, lengths: local.map(\.count), languages: "ru", result: stale))

        let transcript = try await run(transcriber(fixture, server), fixture, force: true)

        #expect(Array(server.calls.prefix(2)) == ["health", "delete"])
        #expect(texts(transcript) == ["новое"])
        #expect(server.submits.count == 1)
        #expect(server.lastSeen(id)?.samples == local)
        #expect(try fixture.meta.status == .transcribed)
    }

    @Test("--force с чужим proof — DELETE не уходит: токен не отдаётся непроверенному серверу")
    func forceWithForgedProofSendsNoDelete() async throws {
        let fixture = try recording()
        let server = try FakeJobServer { $0.proof = .otherToken }
        defer { server.stop() }

        let error = await #expect(throws: EarmarkError.self) {
            try await run(transcriber(fixture, server), fixture, force: true)
        }

        #expect(error?.exitCode == 69)
        #expect(server.calls == ["health"])
    }

    enum DeleteFailure: String, CaseIterable { case serverError, badRequest, dropped }

    @Test(
        "DELETE после done не прошёл — успех не теряется: transcribed и файлы на месте",
        arguments: DeleteFailure.allCases)
    func finalDeleteFails(failure: DeleteFailure) async throws {
        let fixture = try recording()
        let local = try channels(fixture)
        let server = try FakeJobServer()
        defer { server.stop() }
        server.seed(
            id,
            FakeJob(
                state: "done", progress: 100, lengths: local.map(\.count), languages: "ru", result: fresh))
        let reply: FakeJobServer.Scripted =
            switch failure {
            case .serverError: .status(500, #"{"error":"boom"}"#)
            case .badRequest: .status(400, #"{"error":"bad id"}"#)
            case .dropped: .drop
            }
        server.script(.delete, reply, reply, reply)

        let transcript = try await run(transcriber(fixture, server), fixture)

        #expect(texts(transcript) == ["новое"])
        #expect(server.calls.last == "delete")
        let meta = try fixture.meta
        #expect(meta.status == .transcribed)
        #expect(meta.transcription.error == nil)
        #expect(FileManager.default.fileExists(atPath: fixture.file(RecordingFiles.transcript).path))
    }

    @Test("прогресс сервера во время ожидания — TranscribeProgress канала mic с percent сервера")
    func serverProgress() async throws {
        let fixture = try recording()
        let server = try FakeJobServer { $0.afterSubmit = [.running(30), .running(70), .done] }
        defer { server.stop() }
        let log = Mutex<[TranscribeProgress]>([])

        _ = try await transcriber(fixture, server).run(
            folder: fixture.folder, force: false, progress: { update in log.withLock { $0.append(update) } },
            shouldAbort: { false })

        let updates = log.withLock { $0 }
        #expect(updates.allSatisfy { $0.channel == .mic }, "\(updates)")
        let percents = updates.map(\.percent)
        let thirty = try #require(percents.firstIndex(of: 30), "\(percents)")
        let seventy = try #require(percents.firstIndex(of: 70), "\(percents)")
        #expect(thirty < seventy)
    }

    @Test(
        "source=stream: сегменты mic сдвинуты так, как mic лежит в audio.m4a по mic_offset_ms; m4a — без сдвига",
        arguments: [
            // mic стартовал на 250 мс позже system: StereoMuxer кладёт mic в m4a на 250 мс правее.
            ("stream", 250, 1_250, 2_000),
            // mic стартовал на 100 мс раньше: в m4a mic с нуля, а system сдвинут на 100 мс.
            ("stream", -100, 1_000, 2_100),
            // Звук из самого m4a: время уже на его шкале.
            ("m4a", 250, 1_000, 2_000),
        ])
    func streamShift(source: String, micOffsetMs: Int, micStart: Int, systemStart: Int) async throws {
        let fixture = try recording(micOffsetMs: micOffsetMs)
        let local = try channels(fixture)
        let server = try FakeJobServer()
        defer { server.stop() }
        server.seed(
            id,
            FakeJob(
                state: "done", progress: 100, lengths: local.map(\.count), languages: "ru", source: source,
                result: [
                    [FakeSegment(startMs: 1_000, endMs: 1_500, text: "слово мика")],
                    [FakeSegment(startMs: 2_000, endMs: 2_600, text: "слово собеседника")],
                ]))

        let transcript = try await run(transcriber(fixture, server), fixture)

        let byText = Dictionary(uniqueKeysWithValues: transcript.segments.map { ($0.text, $0) })
        #expect(byText["слово мика"]?.startMs == micStart)
        #expect(byText["слово мика"]?.endMs == micStart + 500)
        #expect(byText["слово собеседника"]?.startMs == systemStart)
        #expect(byText["слово собеседника"]?.endMs == systemStart + 600)
        let mic = try channelFile(fixture, RecordingFiles.transcriptMic)
        #expect(mic.segments.map(\.startMs) == [micStart])
    }
}

@Suite("Transcriber, удалённый режим: что найдено на сервере (шаг 4)")
struct RemoteTranscriberFoundJobTests {
    /// Что воркер должен сделать с найденным.
    enum Action: Equatable {
        /// Взять задачу как есть: ни загрузки, ни submit.
        case reuse
        /// failed с теми же языками и длинами: только submit, звук не перезаливается.
        case resubmit
        /// receiving от m4a: докачать каналы с длин сервера.
        case resume
        /// DELETE (если было что удалять), оба канала с нуля с source=m4a, submit.
        case recompute
    }

    enum Found: String, CaseIterable, CustomTestStringConvertible {
        case nothing, doneSame, doneWithinSecond, doneBeyondSecond, doneOtherLanguages, queuedSame,
            runningSame
        case failedSame, failedOtherLengths, receivingFromM4A, receivingFromStream, receivingLongerThanM4A

        var testDescription: String { rawValue }

        var action: Action {
            switch self {
            case .doneSame, .doneWithinSecond, .queuedSame, .runningSame: .reuse
            case .failedSame: .resubmit
            case .receivingFromM4A: .resume
            case .nothing, .doneBeyondSecond, .doneOtherLanguages, .failedOtherLengths, .receivingFromStream,
                .receivingLongerThanM4A:
                .recompute
            }
        }

        /// Докачка в .resume начинается с этих длин.
        static let prefix = [10_000, 5_000]

        // Задача на сервере для каналов m4a `local` (`frames` — их длины по кадрам m4a): по ветке на случай.
        // swiftlint:disable:next cyclomatic_complexity
        func job(_ local: [[Float]], frames: [Int]) -> FakeJob? {
            let lengths = local.map(\.count)
            let prefixes = zip(local, Self.prefix).map { Array($0.prefix($1)) }
            func done(_ lengths: [Int], languages: String = "ru") -> FakeJob {
                FakeJob(state: "done", progress: 100, lengths: lengths, languages: languages, result: stale)
            }
            switch self {
            case .nothing: return nil
            case .doneSame: return done(lengths)
            // Допуск — 16 000 сэмплов (1 с) включительно, в обе стороны, от длины по кадрам m4a.
            case .doneWithinSecond: return done([frames[0] + 16_000, frames[1] - 16_000])
            case .doneBeyondSecond: return done([frames[0], frames[1] + 16_001])
            case .doneOtherLanguages: return done(lengths, languages: "en")
            case .queuedSame:
                return FakeJob(
                    state: "queued", lengths: lengths, languages: "ru", result: stale,
                    steps: [.queued, .done])
            case .runningSame:
                return FakeJob(
                    state: "running", progress: 40, lengths: lengths, languages: "ru", result: stale,
                    steps: [.running(60), .done])
            case .failedSame:
                return FakeJob(state: "failed", lengths: lengths, languages: "ru", error: "boom")
            case .failedOtherLengths:
                return FakeJob(
                    state: "failed", lengths: [frames[0] + 16_001, frames[1]], languages: "ru",
                    error: "boom")
            case .receivingFromM4A:
                return FakeJob(state: "receiving", lengths: Self.prefix, samples: prefixes)
            case .receivingFromStream:
                return FakeJob(state: "receiving", lengths: Self.prefix, samples: prefixes, source: "stream")
            case .receivingLongerThanM4A:
                let longer = [local[0] + [Float](repeating: 0.1, count: 100), prefixes[1]]
                return FakeJob(state: "receiving", lengths: longer.map(\.count), samples: longer)
            }
        }
    }

    @Test("найденная задача → действие воркера", arguments: Found.allCases)
    func found(_ found: Found) async throws {
        let fixture = try recording()
        let local = try channels(fixture)
        let server = try FakeJobServer { $0.result = fresh }
        defer { server.stop() }
        if let job = found.job(local, frames: try frameLengths(fixture)) { server.seed(id, job) }

        let transcript = try await run(transcriber(fixture, server), fixture)

        let calls = server.calls
        let puts = calls.filter { $0.hasPrefix("put") }
        let firstOffsets = (0...1).map { server.uploads(channel: $0).first?.query["offset"] }
        switch found.action {
        case .reuse:
            #expect(texts(transcript) == ["старое"])
            #expect(puts.isEmpty && !calls.contains("submit"), "\(calls)")
            #expect(!calls.dropLast().contains("delete"), "\(calls)")
        case .resubmit:
            #expect(texts(transcript) == ["новое"])
            #expect(puts.isEmpty, "\(calls)")
            #expect(server.submits.map(\.lengths) == [local.map(\.count)])
            #expect(!calls.dropLast().contains("delete"), "\(calls)")
        case .resume:
            #expect(texts(transcript) == ["новое"])
            #expect(firstOffsets == Found.prefix.map { Optional("\($0)") }, "\(calls)")
            #expect(!calls.dropLast().contains("delete"), "\(calls)")
            #expect(server.lastSeen(id)?.samples == local)
        case .recompute:
            #expect(texts(transcript) == ["новое"])
            #expect(firstOffsets == ["0", "0"], "\(calls)")
            #expect(server.lastSeen(id)?.samples == local)
            #expect(server.lastSeen(id)?.source == "m4a")
            if found != .nothing {
                let deleted = try #require(calls.firstIndex(of: "delete"), "\(calls)")
                let uploaded = try #require(calls.firstIndex { $0.hasPrefix("put") })
                #expect(deleted < uploaded, "\(calls)")
            }
        }
        #expect(calls.last == "delete")
        #expect(try fixture.meta.status == .transcribed)
    }
}

@Suite("Transcriber, удалённый режим: загрузка и конфликты")
struct RemoteTranscriberUploadTests {
    @Test(
        "канал длиннее 8 388 608 сэмплов уходит кусками не больше 32 MiB подряд по offset",
        .timeLimit(.minutes(2)))
    func chunkedUpload() async throws {
        // 530 с в 16 kHz — 8 480 000 сэмплов на канал: два куска.
        let fixture = try RecordingFixture(seconds: 530, sampleRate: 16_000, left: micTone, right: systemTone)
        let local = try channels(fixture)
        try #require(local.allSatisfy { $0.count > 8_388_608 })
        let server = try FakeJobServer()
        defer { server.stop() }
        let client = FakeWhisper.client(server, timeouts: .init(health: 5, request: 60))

        _ = try await run(transcriber(fixture, server, client: client), fixture)

        for channel in 0...1 {
            let puts = server.uploads(channel: channel)
            #expect(puts.count >= 2)
            #expect(puts.allSatisfy { $0.body.count <= 8_388_608 * 4 })
            #expect(puts.allSatisfy { $0.mediaType == "application/octet-stream" })
            var offset = 0
            for put in puts {
                #expect(put.query["offset"] == "\(offset)")
                offset += put.body.count / 4
            }
            #expect(offset == local[channel].count)
        }
        #expect(server.lastSeen(id)?.samples == local)
    }

    @Test("409 на загрузке (канал уже дописан кем-то): канал продолжается с длины из конфликта")
    func uploadConflictResumes() async throws {
        let fixture = try recording()
        let local = try channels(fixture)
        let server = try FakeJobServer { $0.result = fresh }
        defer { server.stop() }
        // Пока воркер собирался залить канал, в него уже дописали первые 4000 сэмплов.
        server.script(
            .upload,
            .conflict { job, channel in
                job.samples[channel] = Array(local[channel].prefix(4_000))
                job.lengths[channel] = 4_000
            })

        let transcript = try await run(transcriber(fixture, server), fixture)

        let first = try #require(server.calls.first { $0.hasPrefix("put") })
        let channel = first.hasPrefix("put0") ? 0 : 1
        #expect(server.uploads(channel: channel).prefix(2).map { $0.query["offset"] } == ["0", "4000"])
        #expect(server.lastSeen(id)?.samples == local)
        #expect(texts(transcript) == ["новое"])
        #expect(try fixture.meta.status == .transcribed)
    }

    @Test("409 на загрузке повторился — operation_failed (1), попытка засчитана")
    func uploadConflictTwice() async throws {
        let fixture = try recording()
        let server = try FakeJobServer()
        defer { server.stop() }
        let conflict = FakeJobServer.Scripted.conflictAsIs
        server.script(.upload, conflict, conflict, conflict, conflict)

        let error = await #expect(throws: EarmarkError.self) {
            try await run(transcriber(fixture, server), fixture)
        }

        try expectCounted(error, fixture)
        // Первая загрузка и одна попытка заново — обе получили 409.
        #expect(server.calls.filter { $0.hasPrefix("put") }.count >= 2, "\(server.calls)")
        #expect(!server.calls.contains("submit"))
    }

    @Test("409 на submit: DELETE и полная перезаливка обоих каналов один раз, затем submit")
    func submitConflictReuploads() async throws {
        let fixture = try recording()
        let local = try channels(fixture)
        let server = try FakeJobServer { $0.result = fresh }
        defer { server.stop() }
        server.script(.submit, .conflictAsIs)

        let transcript = try await run(transcriber(fixture, server), fixture)

        let calls = server.calls
        let firstSubmit = try #require(calls.firstIndex(of: "submit"))
        let tail = Array(calls[(firstSubmit + 1)...])
        let deleted = try #require(tail.firstIndex(of: "delete"), "\(calls)")
        let resubmitted = try #require(tail.firstIndex(of: "submit"), "\(calls)")
        #expect(deleted < resubmitted, "\(calls)")
        #expect(Set(tail[deleted..<resubmitted]).isSuperset(of: ["put0@0", "put1@0"]), "\(calls)")
        #expect(server.submits.count == 2)
        #expect(server.lastSeen(id)?.samples == local)
        #expect(texts(transcript) == ["новое"])
        #expect(try fixture.meta.status == .transcribed)
    }

    @Test("409 на submit повторился после перезаливки — operation_failed (1), второй перезаливки нет")
    func submitConflictTwice() async throws {
        let fixture = try recording()
        let server = try FakeJobServer()
        defer { server.stop() }
        let conflict = FakeJobServer.Scripted.conflictAsIs
        server.script(.submit, conflict, conflict, conflict)

        let error = await #expect(throws: EarmarkError.self) {
            try await run(transcriber(fixture, server), fixture)
        }

        try expectCounted(error, fixture)
        #expect(server.submits.count == 2)
    }
}

@Suite("Transcriber, удалённый режим: ожидание сервера и ошибки")
struct RemoteTranscriberWaitTests {
    @Test(
        "не done за limit — remote_pending (69) «waiting for server: <state> <progress>%», опрос раз в poll, задача остаётся",
        arguments: [([], "queued 0%"), ([.running(40)], "running 40%")] as [([FakeJob.Step], String)])
    func waitLimit(steps: [FakeJob.Step], status: String) async throws {
        let fixture = try recording()
        let server = try FakeJobServer { $0.afterSubmit = steps }
        defer { server.stop() }
        let wait = RemoteWait(poll: .milliseconds(20), limit: .milliseconds(300))
        let start = Date()

        let error = await #expect(throws: EarmarkError.self) {
            try await run(transcriber(fixture, server, wait: wait), fixture)
        }

        #expect(Date().timeIntervalSince(start) < 3)
        // Сервер ответил с верным proof, результата просто ещё нет: это не недоступность.
        #expect(error?.code == "remote_pending", "\(String(describing: error))")
        #expect(error?.message == "waiting for server: \(status)")
        try expectWaiting(error, fixture)
        #expect(try fixture.meta.transcription.error == "waiting for server: \(status)")
        let polls = server.calls.drop { $0 != "submit" }.filter { $0 == "get" }.count
        #expect((3...40).contains(polls), "опросов: \(polls)")
        #expect(server.job(id) != nil)
    }

    @Test("после 69 по ожиданию повторный запуск находит задачу и сразу ждёт её: без загрузки и submit")
    func resumeAfterWaiting() async throws {
        let fixture = try recording()
        let server = try FakeJobServer {
            $0.afterSubmit = [.running(40)]
            $0.result = fresh
        }
        defer { server.stop() }
        let short = RemoteWait(poll: .milliseconds(20), limit: .milliseconds(200))
        await #expect(throws: EarmarkError.self) {
            try await run(transcriber(fixture, server, wait: short), fixture)
        }
        let before = server.calls.count
        server.update(id) { $0.steps = [.done] }

        let transcript = try await run(transcriber(fixture, server), fixture)

        let second = Array(server.calls.dropFirst(before))
        #expect(!second.contains { $0.hasPrefix("put") || $0 == "submit" }, "\(second)")
        #expect(texts(transcript) == ["новое"])
        let meta = try fixture.meta
        #expect(meta.status == .transcribed)
        #expect(meta.transcription.attempts == 0)
        #expect(meta.transcription.error == nil && meta.transcription.errorKind == nil)
    }

    @Test(
        "SIGTERM (shouldAbort) во время ожидания — interrupted (75) за ~poll, не засчитано, задача на сервере остаётся"
    )
    func abortWhileWaiting() async throws {
        let fixture = try recording()
        let server = try FakeJobServer { $0.afterSubmit = [] }
        defer { server.stop() }
        let abort = AbortFlag.after(0.25) { server.job(id)?.state == "queued" }

        let error = await #expect(throws: EarmarkError.self) {
            try await transcriber(
                fixture, server, wait: RemoteWait(poll: .milliseconds(100), limit: .seconds(20))
            )
            .run(
                folder: fixture.folder, force: false, progress: { _ in /* прогресс здесь не проверяем */ },
                shouldAbort: { abort.isRaised })
        }

        try expectInterrupted(error, fixture, raisedAt: abort.raisedAt)
        // Сервер доделает задачу сам, следующий запуск её заберёт.
        #expect(!server.calls.contains("delete"), "\(server.calls)")
        #expect(server.job(id)?.state == "queued")
    }

    @Test(
        "SIGTERM во время загрузки (сервер принял PUT и молчит) — interrupted (75) быстро, не засчитано, без DELETE"
    )
    func abortWhileUploading() async throws {
        let fixture = try recording()
        let server = try FakeJobServer()
        defer { server.stop() }
        server.script(.upload, .hang)
        let abort = AbortFlag.after(0.2) { server.calls.contains { $0.hasPrefix("put") } }
        let client = FakeWhisper.client(server, timeouts: .init(health: 5, request: 30))

        let error = await #expect(throws: EarmarkError.self) {
            try await transcriber(
                fixture, server, wait: RemoteWait(poll: .milliseconds(100), limit: .seconds(20)),
                client: client
            )
            .run(
                folder: fixture.folder, force: false, progress: { _ in /* прогресс здесь не проверяем */ },
                shouldAbort: { abort.isRaised })
        }

        try expectInterrupted(error, fixture, raisedAt: abort.raisedAt)
        #expect(!server.calls.contains("delete"), "\(server.calls)")
        #expect(!server.calls.contains("submit"), "\(server.calls)")
    }

    @Test(
        "сервер провалил задачу — operation_failed с его текстом; после третьей — transcription_failed; --force спасает"
    )
    func serverFailure() async throws {
        let fixture = try recording()
        let server = try FakeJobServer {
            $0.afterSubmit = [.failed("whisper_full returned -6")]
            $0.result = fresh
        }
        defer { server.stop() }
        var afterFirst = 0

        for attempt in 1...3 {
            let error = await #expect(throws: EarmarkError.self) {
                try await run(transcriber(fixture, server), fixture)
            }
            #expect(error?.code == "operation_failed")
            #expect(error?.exitCode == 1)
            #expect(
                error?.message.contains("whisper_full returned -6") == true, "\(String(describing: error))")
            let meta = try fixture.meta
            #expect(meta.transcription.attempts == attempt)
            #expect(meta.transcription.errorKind == "retryable")
            #expect(meta.transcription.error?.contains("whisper_full returned -6") == true)
            #expect(meta.status == (attempt < 3 ? .recorded : .transcriptionFailed))
            if attempt == 1 { afterFirst = server.calls.count }
        }
        // Повторы на failed-задаче — только submit: звук уже на сервере.
        #expect(server.submits.count == 3)
        #expect(!server.calls.dropFirst(afterFirst).contains { $0.hasPrefix("put") }, "\(server.calls)")

        server.configure { $0.afterSubmit = [.done] }
        let transcript = try await run(transcriber(fixture, server), fixture, force: true)

        #expect(texts(transcript) == ["новое"])
        #expect(try fixture.meta.status == .transcribed)
        #expect(try fixture.meta.transcription.attempts == 0)
    }

    /// Почему повторно поставленная failed-задача не дошла до done за этот прогон.
    enum Unfinished: String, CaseIterable {
        /// Сервер жив, задача стоит в очереди дольше limit.
        case waitExpires
        /// Сервер пропал сразу после submit: дальше соединения рвутся и отклоняются.
        case serverGone
    }

    @Test(
        "failed → submit, и прогон не дошёл до done — засчитан: operation_failed (1) с текстом сервера; третий — transcription_failed",
        arguments: Unfinished.allCases)
    func resubmittedNotDone(_ unfinished: Unfinished) async throws {
        let fixture = try recording()
        let local = try channels(fixture)
        let crash = "server crashed on this job twice"
        let wait = RemoteWait(poll: .milliseconds(20), limit: .milliseconds(500))

        for attempt in 1...3 {
            // Задача роняет сервер: каждый прогон находит её снова failed.
            let server = try FakeJobServer { $0.afterSubmit = [] }
            defer { server.stop() }
            server.seed(
                id, FakeJob(state: "failed", lengths: local.map(\.count), languages: "ru", error: crash))
            if unfinished == .serverGone { vanish(server) { server.calls.contains("submit") } }

            let error = await #expect(throws: EarmarkError.self) {
                try await run(transcriber(fixture, server, wait: wait), fixture)
            }

            #expect(error?.code == "operation_failed", "\(String(describing: error))")
            #expect(error?.exitCode == 1)
            #expect(error?.message.contains(crash) == true, "\(String(describing: error))")
            let meta = try fixture.meta
            #expect(meta.transcription.attempts == attempt)
            #expect(meta.transcription.errorKind == "retryable")
            #expect(
                meta.transcription.error?.contains(crash) == true,
                "\(String(describing: meta.transcription.error))")
            #expect(meta.status == (attempt < 3 ? .recorded : .transcriptionFailed))
            // Звук уже на сервере: прогон — один повторный submit, без загрузки.
            #expect(server.submits.count == 1, "\(server.calls)")
            #expect(!server.calls.contains { $0.hasPrefix("put") }, "\(server.calls)")
        }
    }

    @Test("SIGTERM во время ожидания после повторного submit failed-задачи — interrupted (75), не засчитано")
    func abortWhileWaitingAfterResubmit() async throws {
        let fixture = try recording()
        let local = try channels(fixture)
        let server = try FakeJobServer { $0.afterSubmit = [] }
        defer { server.stop() }
        server.seed(
            id,
            FakeJob(
                state: "failed", lengths: local.map(\.count), languages: "ru",
                error: "server crashed on this job twice"))
        let abort = AbortFlag.after(0.25) { server.job(id)?.state == "queued" }

        let error = await #expect(throws: EarmarkError.self) {
            try await transcriber(
                fixture, server, wait: RemoteWait(poll: .milliseconds(100), limit: .seconds(20))
            )
            .run(
                folder: fixture.folder, force: false, progress: { _ in /* прогресс здесь не проверяем */ },
                shouldAbort: { abort.isRaised })
        }

        try expectInterrupted(error, fixture, raisedAt: abort.raisedAt)
        #expect(server.submits.count == 1, "\(server.calls)")
        #expect(!server.calls.contains("delete"), "\(server.calls)")
        #expect(server.job(id)?.state == "queued")
    }

    enum Outage: String, CaseIterable {
        case refused, healthDown, forgedProof, wrongCommit, wrongVAD, unauthorized, jobDown, quotaFull
        case submitDown, redirect, hangs

        func configure(_ settings: inout FakeJobServer.Settings) {
            switch self {
            case .forgedProof: settings.proof = .otherToken
            case .wrongCommit: settings.commit = "ffff0000commit"
            case .wrongVAD: settings.vadSha256 = "ffff0000vad"
            default: break
            }
        }

        /// Сбой трижды подряд: даже повтор запроса внутри клиента не обойдёт его.
        func script(_ server: FakeJobServer) {
            func thrice(_ endpoint: FakeJobServer.Endpoint, _ status: Int) {
                let reply = FakeJobServer.Scripted.status(status, #"{"error":"\#(rawValue)"}"#)
                server.script(endpoint, reply, reply, reply)
            }
            switch self {
            case .healthDown: thrice(.health, 503)
            case .unauthorized: thrice(.job, 401)
            case .jobDown: thrice(.job, 500)
            case .quotaFull: thrice(.upload, 507)
            case .submitDown: thrice(.submit, 503)
            // Пойди клиент по редиректу — получил бы обычный 404 и залил бы звук: тест бы это увидел.
            case .redirect:
                server.script(.job, FakeWhisper.redirect(to: server.baseURL, path: "/v2/jobs/\(id)"))
            case .hangs: server.script(.job, .hang)
            default: break
            }
        }
    }

    @Test(
        "сервер недоступен или не тот — exit 69, не засчитано, «waiting for server: …», m4a цел, локально не расшифровано",
        arguments: Outage.allCases)
    func outage(_ outage: Outage) async throws {
        let fixture = try recording()
        let audio = try Data(contentsOf: fixture.file(RecordingFiles.audio))
        let server = try FakeJobServer { outage.configure(&$0) }
        defer { server.stop() }
        outage.script(server)
        let client =
            if outage == .refused {
                RemoteTranscriptionClient(
                    baseURL: try FakeWhisper.deadURL(), token: FakeWhisper.token, timeouts: FakeWhisper.fast)
            } else {
                FakeWhisper.client(server)
            }

        let error = await #expect(throws: EarmarkError.self) {
            try await run(transcriber(fixture, server, client: client), fixture)
        }

        try expectWaiting(error, fixture)
        // Сервера нет или он не доказал, что наш: это недоступность, а не «результат ещё считается».
        #expect(error?.code == "remote_failed", "\(String(describing: error))")
        #expect(try Data(contentsOf: fixture.file(RecordingFiles.audio)) == audio)
    }

    /// Чья задача пропала во время ожидания.
    enum Vanished: String, CaseIterable {
        /// Воркер сам залил звук и поставил задачу.
        case afterSubmit
        /// Воркер нашёл готовую к ожиданию задачу (queued) и ждал её.
        case foundQueued
    }

    @Test(
        "задача пропала с сервера во время ожидания — remote_pending (69) «waiting for server: the job disappeared…», не засчитано",
        arguments: Vanished.allCases)
    func jobVanishedWhileWaiting(_ vanished: Vanished) async throws {
        let fixture = try recording()
        let local = try channels(fixture)
        let server = try FakeJobServer { $0.afterSubmit = [.queued, .vanish] }
        defer { server.stop() }
        if vanished == .foundQueued {
            server.seed(
                id,
                FakeJob(
                    state: "queued", lengths: local.map(\.count), languages: "ru", result: stale,
                    steps: [.queued, .vanish]))
        }

        let error = await #expect(throws: EarmarkError.self) {
            try await run(transcriber(fixture, server), fixture)
        }

        #expect(error?.code == "remote_pending", "\(String(describing: error))")
        try expectWaiting(error, fixture)
        let text = try fixture.meta.transcription.error ?? ""
        #expect(text.hasPrefix("waiting for server: the job disappeared"), "«\(text)»")
        #expect(server.job(id) == nil)
        #expect(server.submits.count == (vanished == .afterSubmit ? 1 : 0), "\(server.calls)")
    }

    enum Defect: String, CaseIterable { case uploadRejected, jobNotJSON, jobWrongSchema, submitRejected }

    @Test(
        "ответ не по контракту или 4xx — operation_failed (1), попытка засчитана", arguments: Defect.allCases)
    func defect(_ defect: Defect) async throws {
        let fixture = try recording()
        let server = try FakeJobServer()
        defer { server.stop() }
        switch defect {
        case .uploadRejected:
            server.script(.upload, .status(400, #"{"error":"body length must be a multiple of 4"}"#))
        case .jobNotJSON: server.script(.job, .status(200, "<html>hello</html>"))
        case .jobWrongSchema: server.script(.job, .status(200, #"{"progress":5}"#))
        case .submitRejected: server.script(.submit, .status(400, #"{"error":"unknown language"}"#))
        }

        let error = await #expect(throws: EarmarkError.self) {
            try await run(transcriber(fixture, server), fixture)
        }

        try expectCounted(error, fixture)
        // Ошибку дал именно этот ответ сервера, и дальше него воркер не пошёл.
        let calls = server.calls
        switch defect {
        case .uploadRejected:
            #expect(calls.contains { $0.hasPrefix("put") } && !calls.contains("submit"), "\(calls)")
        case .jobNotJSON, .jobWrongSchema:
            #expect(calls.contains("get") && !calls.contains { $0.hasPrefix("put") }, "\(calls)")
        case .submitRejected: #expect(calls.contains("submit"), "\(calls)")
        }
    }

    @Test("lock держит другой процесс — busy (75), meta не тронута, на сервер ни запроса")
    func lockBusy() async throws {
        let fixture = try recording()
        let held = try #require(try FileLock.tryAcquire(at: fixture.file(RecordingFiles.transcribeLock)))
        defer { held.release() }
        let server = try FakeJobServer()
        defer { server.stop() }

        let error = await #expect(throws: EarmarkError.self) {
            try await run(transcriber(fixture, server), fixture)
        }

        #expect(error?.exitCode == 75)
        #expect(try fixture.meta.status == .recorded)
        #expect(try fixture.meta.transcription.attempts == 0)
        #expect(server.calls.isEmpty, "\(server.calls)")
    }

    @Test("битое audio.m4a — bad_data (65), permanent; звук на сервер не уходит")
    func corruptAudio() async throws {
        let fixture = try recording()
        try Data("это не m4a".utf8).write(to: fixture.file(RecordingFiles.audio))
        let server = try FakeJobServer()
        defer { server.stop() }

        let error = await #expect(throws: EarmarkError.self) {
            try await run(transcriber(fixture, server), fixture)
        }

        #expect(error?.exitCode == 65)
        let meta = try fixture.meta
        #expect(meta.transcription.errorKind == "permanent")
        #expect(meta.status == .transcriptionFailed)
        #expect(!server.calls.contains { $0.hasPrefix("put") || $0 == "submit" }, "\(server.calls)")
    }
}

/// Готовые файлы каналов, как их оставил прошлый удалённый прогон этой записи.
private func writeReadyChannels(_ fixture: RecordingFixture, fingerprint: String, language: String = "ru")
    throws
{
    let mic = ChannelTranscript(
        channel: .mic, model: "large-v3-turbo", language: language, fingerprint: fingerprint,
        segments: [RawSegment(startMs: 0, endMs: 900, text: "уже было")])
    let system = ChannelTranscript(
        channel: .system, model: "large-v3-turbo", language: language, fingerprint: fingerprint,
        segments: [RawSegment(startMs: 500, endMs: 1_500, text: "собеседник")])
    try EarmarkJSON.encoder.encode(mic).write(to: fixture.file(RecordingFiles.transcriptMic))
    try EarmarkJSON.encoder.encode(system).write(to: fixture.file(RecordingFiles.transcriptSystem))
}

@Suite("Transcriber, удалённый режим: готовые файлы каналов, как у локального пути")
struct RemoteTranscriberReadyChannelsTests {
    @Test(
        "оба файла каналов с fingerprint сервера и языком записи — переиспользованы: ни задачи, ни PUT, ни submit; transcribed"
    )
    func reused() async throws {
        let fixture = try recording()
        let audio = try Data(contentsOf: fixture.file(RecordingFiles.audio))
        try writeReadyChannels(fixture, fingerprint: remoteFingerprint())
        let server = try FakeJobServer { $0.result = fresh }
        defer { server.stop() }

        let transcript = try await run(transcriber(fixture, server), fixture)

        // fingerprint сервера известен только после рукопожатия.
        #expect(server.calls.first == "health", "\(server.calls)")
        #expect(!server.calls.contains { $0.hasPrefix("put") || $0 == "submit" }, "\(server.calls)")
        #expect(server.lastSeen(id) == nil, "на сервере создана задача: \(server.calls)")
        #expect(texts(transcript) == ["уже было", "собеседник"])
        #expect(transcript.model == "large-v3-turbo")
        #expect(transcript.language == "ru")
        let saved = try EarmarkJSON.decoder.decode(
            Transcript.self, from: Data(contentsOf: fixture.file(RecordingFiles.transcript)))
        #expect(saved == transcript)
        #expect(
            try String(contentsOf: fixture.file(RecordingFiles.transcriptText), encoding: .utf8)
                == "[00:00:00] Я: уже было\n[00:00:00] Собеседники: собеседник\n")
        let meta = try fixture.meta
        #expect(meta.status == .transcribed)
        #expect(meta.transcription.attempts == 0)
        #expect(meta.transcription.error == nil && meta.transcription.errorKind == nil)
        #expect(meta.transcription.fingerprint == remoteFingerprint())
        #expect(meta.transcription.language == "ru")
        #expect(try Data(contentsOf: fixture.file(RecordingFiles.audio)) == audio)
    }

    /// Почему готовые файлы каналов не годятся и звук уходит на сервер заново.
    enum Stale: String, CaseIterable {
        /// `--force`.
        case forced
        /// У календаря записи свой список языков, а файлы — на глобальном языке.
        case calendarLanguage
        /// На сервере теперь другая модель (имя и sha256), файлы — от прежней.
        case serverModelChanged
        /// Те же модель и sha, но другая версия параметров whisper.
        case otherParamsVersion
        /// Файлы от локального whisper на маке.
        case localFingerprint

        var calendarId: String? { self == .calendarLanguage ? "CAL-LANGS" : nil }

        var languages: String { self == .calendarLanguage ? "ru,en,az" : "ru" }

        var fileFingerprint: String {
            switch self {
            case .otherParamsVersion:
                "remote|large-v3-turbo|\(Models.largeV3Turbo.sha256.prefix(12))|params-before-\(WhisperParams.version)"
            case .localFingerprint: Transcriber.fingerprint
            default: remoteFingerprint()
            }
        }

        static let otherSha = "0123456789ab" + String(repeating: "e", count: 52)

        /// fingerprint, с которым сервер посчитает заново.
        var serverFingerprint: String {
            self == .serverModelChanged
                ? remoteFingerprint(model: "large-v3", sha: Self.otherSha) : remoteFingerprint()
        }
    }

    @Test(
        "файлы каналов не годятся (--force, другой язык записи, другая модель сервера, другие параметры) — звук залит и посчитан заново",
        arguments: Stale.allCases)
    func recomputed(_ stale: Stale) async throws {
        let fixture = try recording(calendarId: stale.calendarId)
        let local = try channels(fixture)
        try writeReadyChannels(fixture, fingerprint: stale.fileFingerprint)
        let server = try FakeJobServer {
            $0.result = fresh
            if stale == .serverModelChanged {
                $0.model = "ggml-large-v3.bin"
                $0.modelSha256 = Stale.otherSha
            }
        }
        defer { server.stop() }
        let config = Config(values: [
            "transcription.language": .string("ru"), "calendar.CAL-LANGS.language": .string("ru,en,az"),
        ])

        let transcript = try await run(
            transcriber(fixture, server, config: config), fixture, force: stale == .forced)

        #expect(texts(transcript) == ["новое"])
        #expect(server.submits.map(\.languages) == [stale.languages], "\(server.calls)")
        #expect(server.lastSeen(id)?.samples == local)
        let mic = try channelFile(fixture, RecordingFiles.transcriptMic)
        let system = try channelFile(fixture, RecordingFiles.transcriptSystem)
        #expect(mic.segments.map(\.text) == ["новое"])
        #expect(system.segments.isEmpty)
        #expect([mic.fingerprint, system.fingerprint] == [stale.serverFingerprint, stale.serverFingerprint])
        #expect([mic.language, system.language] == [stale.languages, stale.languages])
        let meta = try fixture.meta
        #expect(meta.status == .transcribed)
        #expect(meta.transcription.fingerprint == stale.serverFingerprint)
        #expect(meta.transcription.language == stale.languages)
    }
}
