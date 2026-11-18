@preconcurrency import AVFoundation
import EarmarkAudio
import Foundation
import Testing

@testable import EarmarkCore
@testable import EarmarkTranscription

private let id = "20261118-1000-live"

/// Интервал тиков стрима в тестах.
private let tick = Duration.milliseconds(20)

/// Разный звук каналов: перепутанные mic и system не сойдутся с эталоном. За 0,1 с — целое число
/// периодов (44 и 130), поэтому один и тот же буфер, записанный подряд, — непрерывный тон.
private let toneHz: [Double] = [440, 1_300]

/// mic.caf и system.caf, которые тест растит между тиками стрима, как запись: CAFWriter, Float32 48 kHz.
private final class Tracks {
    let mic: URL
    let system: URL
    private let writers: [CAFWriter]
    /// 0,1 с тона каждого канала; nil — канал не растёт.
    private let chunks: [AVAudioPCMBuffer?]

    /// systemEmpty: system.caf создан, но в него не пишется ни кадра.
    init(systemEmpty: Bool = false) throws {
        let folder = FileManager.default.temporaryDirectory.appending(
            path: "earmark-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        mic = folder.appending(path: "mic.caf")
        system = folder.appending(path: "system.caf")
        let format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        writers = [try CAFWriter(url: mic, format: format), try CAFWriter(url: system, format: format)]
        let frames = 4_800
        chunks = try toneHz.enumerated().map { channel, hz in
            guard channel == 0 || !systemEmpty else { return nil }
            let buffer = try #require(
                AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
            buffer.frameLength = AVAudioFrameCount(frames)
            let samples = try #require(buffer.floatChannelData)[0]
            for frame in 0..<frames {
                samples[frame] = Float(0.3 * sin(2 * .pi * hz * Double(frame) / 48_000))
            }
            return buffer
        }
    }

    /// Дописывает 0,1 с в каждую растущую дорожку.
    func grow() throws {
        for (writer, chunk) in zip(writers, chunks) {
            if let chunk { try writer.write(chunk) }
        }
    }

    /// Растит дорожки раз в тик, пока `condition` не станет истинным; false — не дождались за 3 с.
    func grow(until condition: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            guard Date() < deadline else { return false }
            try grow()
            try await Task.sleep(for: tick)
        }
        return true
    }

    /// Ещё `ticks` тиков записи: у лишних запросов стрима есть время проявиться.
    func grow(ticks: Int) async throws {
        for _ in 0..<ticks {
            try grow()
            try await Task.sleep(for: tick)
        }
    }

    func close() throws { for writer in writers { try writer.close() } }

    /// Эталон: каналы закрытых дорожек так, как их видит ChannelExtractor (16 kHz).
    func reference() throws -> [[Float]] {
        try [mic, system].map { try ChannelExtractor.extract(from: $0, channel: 0) }
    }
}

private func live(_ tracks: Tracks, _ server: FakeJobServer, client: RemoteTranscriptionClient? = nil)
    -> LiveStream
{
    LiveStream(
        id: id, mic: tracks.mic, system: tracks.system, server: client ?? FakeWhisper.client(server),
        interval: tick)
}

/// Клиент, который не сдаётся сам раньше, чем finish по deadline.
private func patient(_ server: FakeJobServer) -> RemoteTranscriptionClient {
    FakeWhisper.client(server, timeouts: .init(health: 10, request: 10))
}

private func bothChannelsUploaded(_ server: FakeJobServer) -> Bool {
    (0...1).allSatisfy { !server.uploads(channel: $0).isEmpty }
}

private func seconds(since start: Date) -> TimeInterval { Date().timeIntervalSince(start) }

/// Ждёт, пока стрим пройдёт `ticks` тиков подряд без PUT; false — не дождались за 5 с. Время меряется
/// тиками, а не часами: под нагрузкой тики идут реже `interval`. Тик — health: proof в начале каждого тика,
/// поэтому законченный тик без PUT — health, за которым уже следующий health.
private func quiet(_ server: FakeJobServer, ticks: Int) async throws -> Bool {
    let deadline = Date().addingTimeInterval(5)
    while server.calls.reversed().prefix(while: { !$0.hasPrefix("put") }).count(where: { $0 == "health" })
        <= ticks
    {
        guard Date() < deadline else { return false }
        try await Task.sleep(for: .milliseconds(5))
    }
    return true
}

/// Звук канала на сервере совпадает с эталоном: длина ±16 сэмплов, значения ≤ 1e-3 (как у CAFTail).
private func expectSameAudio(
    _ got: [Float], _ reference: [Float], channel: Int, sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(
        abs(got.count - reference.count) <= 16,
        "канал \(channel): на сервере \(got.count) сэмплов, ChannelExtractor — \(reference.count)",
        sourceLocation: sourceLocation)
    let worst = zip(got, reference).map { abs($0 - $1) }.max() ?? 0
    #expect(worst <= 1e-3, "канал \(channel): max |разность| \(worst)", sourceLocation: sourceLocation)
}

/// PUT канала: только source=stream, offset подряд от 0 без дыр и наложений, сумма — длина на сервере.
private func expectContiguous(
    _ server: FakeJobServer, channel: Int, sourceLocation: SourceLocation = #_sourceLocation
) throws {
    let job = try #require(server.job(id), "задачи нет: \(server.calls)", sourceLocation: sourceLocation)
    let puts = server.uploads(channel: channel)
    #expect(!puts.isEmpty, "канал \(channel) без PUT: \(server.calls)", sourceLocation: sourceLocation)
    #expect(
        puts.allSatisfy { $0.query["source"] == "stream" }, "\(puts.map { $0.query["source"] ?? "nil" })",
        sourceLocation: sourceLocation)
    var offset = 0
    for put in puts {
        #expect(
            put.query["offset"] == "\(offset)", "канал \(channel): \(server.calls)",
            sourceLocation: sourceLocation)
        offset += put.body.count / 4
    }
    #expect(offset == job.lengths[channel], sourceLocation: sourceLocation)
}

@Suite("LiveStream: звук на сервер во время записи")
struct LiveStreamTests {
    @Test(
        "звук обоих каналов уходит во время записи: source=stream, offset подряд, сумма и значения = ChannelExtractor; submit с языками и длинами сервера"
    )
    func streamsDuringRecording() async throws {
        let tracks = try Tracks()
        let server = try FakeJobServer()
        defer { server.stop() }
        let stream = live(tracks, server)

        await stream.start()
        let streamed = try await tracks.grow { bothChannelsUploaded(server) }
        #expect(streamed, "до стопа записи PUT по обоим каналам так и не пришли: \(server.calls)")
        try await tracks.grow(ticks: 5)
        try tracks.close()
        // finish сразу после стопа, посреди тиков: порции не должны наложиться.
        let ok = await stream.finish(languages: "ru,en")

        let failure = await stream.failure
        #expect(ok, "\(String(describing: failure))")
        #expect(failure == nil)
        let reference = try tracks.reference()
        let job = try #require(server.job(id), "\(server.calls)")
        #expect(job.source == "stream")
        for channel in 0...1 {
            try expectContiguous(server, channel: channel)
            expectSameAudio(job.samples[channel], reference[channel], channel: channel)
        }
        #expect(server.submits.map(\.languages) == ["ru,en"])
        #expect(server.submits.map(\.lengths) == [job.lengths])
        #expect(server.calls.last == "submit", "\(server.calls)")
        #expect(job.state == "queued")
    }

    @Test("повторный finish — false и ни одного запроса")
    func secondFinish() async throws {
        let tracks = try Tracks()
        let server = try FakeJobServer()
        defer { server.stop() }
        let stream = live(tracks, server)
        await stream.start()
        try #require(try await tracks.grow { bothChannelsUploaded(server) }, "\(server.calls)")
        try tracks.close()
        try #require(await stream.finish(languages: "ru"))
        let calls = server.calls

        let again = await stream.finish(languages: "ru")

        #expect(!again)
        try await Task.sleep(for: .milliseconds(100))
        #expect(server.calls == calls)
    }

    @Test(
        "proof перед каждой порцией: первый запрос — health, между двумя health не больше одного PUT на канал"
    )
    func proofBeforeEachPortion() async throws {
        let tracks = try Tracks()
        let server = try FakeJobServer()
        defer { server.stop() }
        let stream = live(tracks, server)

        await stream.start()
        try #require(try await tracks.grow { bothChannelsUploaded(server) }, "\(server.calls)")
        try await tracks.grow(ticks: 10)
        try tracks.close()
        #expect(await stream.finish(languages: "ru"))

        let calls = server.calls
        #expect(calls.first == "health", "\(calls)")
        var sinceProof: [String] = []
        for call in calls {
            if call == "health" {
                sinceProof = []
                continue
            }
            guard let channel = call.hasPrefix("put") ? call.dropFirst(3).first : nil else { continue }
            #expect(
                !sinceProof.contains(String(channel)),
                "второй PUT канала \(channel) без нового proof: \(calls)")
            sinceProof.append(String(channel))
        }
        #expect(calls.filter { $0 == "health" }.count >= 2, "\(calls)")
    }

    @Test("канал без новых сэмплов в тик не шлётся: запись стоит — PUT нет, пустых тел до finish нет")
    func idleTicksSendNothing() async throws {
        let tracks = try Tracks()
        let server = try FakeJobServer()
        defer { server.stop() }
        let stream = live(tracks, server)

        await stream.start()
        try #require(try await tracks.grow { bothChannelsUploaded(server) }, "\(server.calls)")
        // Запись стоит (ничего не дописывается): первые тики добирают с диска хвост, дальше — тишина.
        try #require(try await quiet(server, ticks: 2), "стрим не затих: \(server.calls)")
        let settled = server.calls.count
        // Ещё не меньше пяти тиков.
        try #require(try await quiet(server, ticks: 7), "\(server.calls)")

        let late = server.calls.dropFirst(settled)
        #expect(
            !late.contains { $0.hasPrefix("put") },
            "PUT без новых сэмплов: \(Array(late)), всё: \(server.calls)")
        let empty = server.requests.filter { $0.method == "PUT" && $0.body.isEmpty }
        #expect(empty.isEmpty, "пустые PUT: \(empty.map(FakeJobServer.describe))")
        try tracks.close()
        #expect(await stream.finish(languages: nil))
    }

    @Test("finish(languages: nil) — весь звук на сервере, true, но без submit: задача ждёт в receiving")
    func withoutLanguagesNoSubmit() async throws {
        let tracks = try Tracks()
        let server = try FakeJobServer()
        defer { server.stop() }
        let stream = live(tracks, server)

        await stream.start()
        try #require(try await tracks.grow { bothChannelsUploaded(server) }, "\(server.calls)")
        try tracks.close()
        let ok = await stream.finish(languages: nil)

        let failure = await stream.failure
        #expect(ok, "\(String(describing: failure))")
        #expect(!server.calls.contains("submit"), "\(server.calls)")
        let job = try #require(server.job(id))
        #expect(job.state == "receiving")
        #expect(job.source == "stream")
        let reference = try tracks.reference()
        for channel in 0...1 {
            try expectContiguous(server, channel: channel)
            expectSameAudio(job.samples[channel], reference[channel], channel: channel)
        }
    }

    @Test("пустой канал всё равно получает PUT: пустое тело с offset 0, submit с длиной 0")
    func emptyChannelGetsEmptyPut() async throws {
        let tracks = try Tracks(systemEmpty: true)
        let server = try FakeJobServer()
        defer { server.stop() }
        let stream = live(tracks, server)

        await stream.start()
        try #require(try await tracks.grow { !server.uploads(channel: 0).isEmpty }, "\(server.calls)")
        try tracks.close()
        let ok = await stream.finish(languages: "ru")

        let failure = await stream.failure
        #expect(ok, "\(String(describing: failure))")
        let system = server.uploads(channel: 1)
        #expect(system.first?.query["offset"] == "0", "\(server.calls)")
        let bodiesEmpty = system.allSatisfy(\.body.isEmpty)
        #expect(bodiesEmpty, "\(system.map(\.body.count))")
        let job = try #require(server.job(id))
        #expect(job.lengths[1] == 0)
        #expect(job.lengths[0] > 0)
        #expect(server.submits.map(\.lengths) == [job.lengths])
    }

    @Test(
        "сервер перестал доказывать токен посреди записи — после первого чужого proof ни одного запроса, finish false"
    )
    func forgedProofMidStream() async throws {
        let tracks = try Tracks()
        let server = try FakeJobServer()
        defer { server.stop() }
        let stream = live(tracks, server)

        await stream.start()
        try #require(try await tracks.grow { bothChannelsUploaded(server) }, "\(server.calls)")
        // Мак сменил сеть: по тому же имени теперь чужой хост.
        server.configure { $0.proof = .otherToken }
        let switched = server.calls.count
        let forgedSeen = try await tracks.grow { server.calls.dropFirst(switched).contains("health") }
        try await tracks.grow(ticks: 10)
        try tracks.close()
        let ok = await stream.finish(languages: "ru")

        #expect(!ok)
        #expect(await stream.failure != nil)
        #expect(!server.calls.contains("submit"), "\(server.calls)")
        let calls = server.calls
        if forgedSeen, let forged = calls.indices.dropFirst(switched).first(where: { calls[$0] == "health" })
        {
            #expect(calls[(forged + 1)...].isEmpty, "после чужого proof: \(Array(calls[(forged + 1)...]))")
        }
    }

    /// Чем сервер отвечает посреди стрима.
    enum Failure: String, CaseIterable {
        case uploadServerError, uploadConflict, uploadRejected, uploadUnauthorized, uploadDropped, healthDown

        var endpoint: FakeJobServer.Endpoint { self == .healthDown ? .health : .upload }

        var reply: FakeJobServer.Scripted {
            switch self {
            case .uploadServerError: .status(500, #"{"error":"boom"}"#)
            case .uploadConflict: .conflictAsIs
            case .uploadRejected: .status(400, #"{"error":"bad upload"}"#)
            case .uploadUnauthorized: .status(401, #"{"error":"unauthorized"}"#)
            case .uploadDropped: .drop
            case .healthDown: .status(503, #"{"error":"down"}"#)
            }
        }
    }

    @Test(
        "любая ошибка посреди записи — стрим замолкает навсегда: ни тика, ни submit, finish false без запросов, failure задан",
        arguments: Failure.allCases)
    func errorStopsStream(_ failure: Failure) async throws {
        let tracks = try Tracks()
        let server = try FakeJobServer()
        defer { server.stop() }
        let stream = live(tracks, server)

        await stream.start()
        try #require(try await tracks.grow { bothChannelsUploaded(server) }, "\(server.calls)")
        server.script(failure.endpoint, failure.reply, failure.reply, failure.reply)
        try #require(try await tracks.grow { !server.scriptedAt.isEmpty }, "\(server.calls)")
        try await tracks.grow(ticks: 10)
        try tracks.close()
        let calls = server.calls
        let ok = await stream.finish(languages: "ru")

        #expect(!ok)
        #expect(await stream.failure != nil)
        let failedAt = try #require(server.scriptedAt.first)
        let after = Array(calls[(failedAt + 1)...])
        // Допустимы только PUT, уже летевшие в момент ошибки (второй канал того же тика).
        #expect(after.allSatisfy { $0.hasPrefix("put") } && after.count <= 3, "после ошибки: \(after)")
        try await Task.sleep(for: .milliseconds(100))
        #expect(
            server.calls == calls,
            "finish после ошибки слал запросы: \(Array(server.calls.dropFirst(calls.count)))")
    }

    /// Чем сервер отвечает, когда запись уже остановлена и finish досылает хвост.
    enum FinishFailure: String, CaseIterable {
        case submitConflict, submitDown, lastUploadFails
    }

    @Test(
        "ошибка во время finish (409 или 5xx на submit, сбой досылки) — false",
        arguments: FinishFailure.allCases)
    func finishFails(_ failure: FinishFailure) async throws {
        let tracks = try Tracks()
        let server = try FakeJobServer()
        defer { server.stop() }
        let stream = live(tracks, server)

        await stream.start()
        try #require(try await tracks.grow { bothChannelsUploaded(server) }, "\(server.calls)")
        switch failure {
        case .submitConflict: server.script(.submit, .conflictAsIs)
        case .submitDown: server.script(.submit, .status(503, #"{"error":"down"}"#))
        case .lastUploadFails:
            // Запись стоит, тики больше ничего не шлют; хвост после close уйдёт уже с ошибкой.
            try #require(try await quiet(server, ticks: 2), "стрим не затих: \(server.calls)")
            let reply = FakeJobServer.Scripted.status(500, #"{"error":"boom"}"#)
            server.script(.upload, reply, reply, reply)
        }
        try tracks.close()
        let ok = await stream.finish(languages: "ru")

        #expect(!ok, "\(server.calls)")
        #expect(await stream.failure != nil)
        if failure == .lastUploadFails {
            #expect(!server.scriptedAt.isEmpty, "досылки не было: \(server.calls)")
            #expect(!server.calls.contains("submit"), "\(server.calls)")
        }
    }

    @Test("сервер недоступен с самого начала — finish быстро false, failure задан")
    func unreachableFromStart() async throws {
        let tracks = try Tracks()
        let client = RemoteTranscriptionClient(
            baseURL: try FakeWhisper.deadURL(), token: FakeWhisper.token, timeouts: FakeWhisper.fast)
        let stream = LiveStream(
            id: id, mic: tracks.mic, system: tracks.system, server: client, interval: tick)

        await stream.start()
        try await tracks.grow(ticks: 10)
        try tracks.close()
        let start = Date()
        let ok = await stream.finish(languages: "ru")

        #expect(!ok)
        #expect(seconds(since: start) < 1)
        #expect(await stream.failure != nil)
    }

    @Test("дорожки mic.caf нет — стрим ничего не шлёт: ни одного запроса, finish false, failure задан")
    func missingTrack() async throws {
        let tracks = try Tracks()
        let server = try FakeJobServer()
        defer { server.stop() }
        let missing = tracks.mic.deletingLastPathComponent().appending(path: "absent.caf")
        let stream = LiveStream(
            id: id, mic: missing, system: tracks.system, server: FakeWhisper.client(server), interval: tick)

        await stream.start()
        try await tracks.grow(ticks: 10)
        try tracks.close()
        let ok = await stream.finish(languages: "ru")

        #expect(!ok)
        #expect(await stream.failure != nil)
        #expect(server.calls.isEmpty, "\(server.calls)")
    }

    /// Какой запрос висит, когда запись уже остановлена.
    enum Hang: String, CaseIterable {
        case upload, health, submit
    }

    @Test("сервер завис — finish false не позже deadline + 1 с, submit не прошёл", arguments: Hang.allCases)
    func deadline(_ hang: Hang) async throws {
        let tracks = try Tracks()
        let server = try FakeJobServer()
        defer { server.stop() }
        let stream = live(tracks, server, client: patient(server))

        await stream.start()
        try #require(try await tracks.grow { bothChannelsUploaded(server) }, "\(server.calls)")
        switch hang {
        case .upload:
            server.script(.upload, .hang)
            try #require(try await tracks.grow { !server.scriptedAt.isEmpty }, "\(server.calls)")
        case .health:
            server.script(.health, .hang)
            try #require(try await tracks.grow { !server.scriptedAt.isEmpty }, "\(server.calls)")
        case .submit: server.script(.submit, .hang)
        }
        try tracks.close()
        let start = Date()
        let ok = await stream.finish(languages: "ru", deadline: .milliseconds(600))
        let elapsed = seconds(since: start)

        #expect(!ok)
        #expect(elapsed <= 1.6, "finish вернулся через \(elapsed) с при deadline 0,6 с")
        if hang == .submit {
            #expect(server.calls.last == "submit", "\(server.calls)")
        } else {
            #expect(!server.calls.contains("submit"), "\(server.calls)")
        }
    }

    @Test("cancel посреди записи — новых запросов нет (летящий может завершиться), finish false без запросов")
    func cancelMidStream() async throws {
        let tracks = try Tracks()
        let server = try FakeJobServer()
        defer { server.stop() }
        let stream = live(tracks, server)

        await stream.start()
        try #require(try await tracks.grow { bothChannelsUploaded(server) }, "\(server.calls)")
        await stream.cancel()
        let cancelled = server.calls.count
        try await tracks.grow(ticks: 10)
        let late = Array(server.calls.dropFirst(cancelled))
        // Летящий в момент cancel: health тика или PUT двух каналов; тик, начавшийся с health, PUT уже не шлёт.
        #expect(late.count <= 2 && !late.contains("submit"), "после cancel: \(late)")
        if let proof = late.firstIndex(of: "health") {
            #expect(!late[proof...].contains { $0.hasPrefix("put") }, "после cancel: \(late)")
        }
        let settled = server.calls.count
        try await tracks.grow(ticks: 10)
        #expect(
            server.calls.count == settled, "стрим жив после cancel: \(Array(server.calls.dropFirst(settled)))"
        )
        try tracks.close()

        let ok = await stream.finish(languages: "ru")

        #expect(!ok)
        try await Task.sleep(for: .milliseconds(100))
        #expect(server.calls.count == settled, "\(Array(server.calls.dropFirst(settled)))")
        #expect(!server.calls.contains("submit"))
    }

    @Test("start не ждёт сервер (health висит); cancel посреди висящего health — PUT нет, finish false")
    func startDoesNotWait() async throws {
        let tracks = try Tracks()
        let server = try FakeJobServer()
        defer { server.stop() }
        server.script(.health, .hang)
        let stream = live(tracks, server, client: patient(server))

        let start = Date()
        await stream.start()
        #expect(seconds(since: start) < 0.5)
        try #require(try await tracks.grow { !server.scriptedAt.isEmpty }, "health так и не пришёл")
        await stream.cancel()
        try await tracks.grow(ticks: 5)
        try tracks.close()
        let finishing = Date()
        let ok = await stream.finish(languages: "ru", deadline: .seconds(1))

        #expect(!ok)
        #expect(seconds(since: finishing) <= 2)
        #expect(server.calls == ["health"], "\(server.calls)")
    }
}
