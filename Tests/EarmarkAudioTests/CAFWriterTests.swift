@preconcurrency import AVFoundation
import EarmarkAudio
import Foundation
import Testing

@Suite("CAFWriter")
struct CAFWriterTests {
    /// Фокус ревью №3: процесс убит посреди записи → CAF читается и в нём настоящий звук.
    @Test("SIGKILL посреди записи — CAF читается", arguments: ["sync", "async"])
    func survivesSIGKILL(mode: String) async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let caf = dir.appendingPathComponent("killed.caf")

        let process = try await killedRecording(at: caf, mode: mode)

        #expect(process.terminationReason == .uncaughtSignal)
        #expect(process.terminationStatus == SIGKILL)
        // ~1.4 с работы в 4x реального времени — это ~5 с звука; async теряет до ~170 мс хвоста.
        let file = try AVAudioFile(forReading: caf)
        #expect(file.length >= 48_000)
        let (channels, rate) = try readChannels(caf)
        let tone = goertzelPower(channels[0][0..<24_000], hz: 440, sampleRate: rate)
        let other = goertzelPower(channels[0][0..<24_000], hz: 1_000, sampleRate: rate)
        #expect(tone > other * 100)
    }

    @Test("close идемпотентен, framesWritten считает кадры клиента, тишина — нули")
    func closeAndSilence() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("silence.caf")
        let format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let writer = try CAFWriter(url: url, format: format)
        try writer.writeSilence(frames: 10_000)
        #expect(writer.framesWritten == 10_000)
        try writer.close()
        try writer.close()
        #expect(throws: EarmarkAudioError.writerClosed) { try writer.writeSilence(frames: 1) }

        let (channels, _) = try readChannels(url)
        #expect(channels[0].count == 10_000)
        #expect(channels[0].allSatisfy { $0 == 0 })
    }

    /// Тишина в async-режиме идёт с паузами: залп целиком переполнил бы кольцо и убил writer (замер).
    @Test("writeSilence в async-режиме не переполняет кольцо ExtAudioFileWriteAsync")
    func asyncSilenceIsPaced() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("async-silence.caf")
        let format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let writer = try CAFWriter(url: url, format: format)
        try writer.primeAsync()
        try writer.writeSilence(frames: 48_000 * 20)
        try writer.close()
        #expect(try AVAudioFile(forReading: url).length == 48_000 * 20)
    }

    @Test("клиентский формат меняется до записи и не меняется после")
    func clientFormatOnlyBeforeFirstWrite() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileFormat = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let tapFormat = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false))
        let url = dir.appendingPathComponent("resampled.caf")
        let writer = try CAFWriter(url: url, format: fileFormat)
        try writer.setClientFormat(tapFormat)
        try writer.writeSilence(frames: 44_100)
        #expect(throws: EarmarkAudioError.self) { try writer.setClientFormat(fileFormat) }
        try writer.close()
        // ExtAudioFile сам ресемплит 44.1k клиента в 48k файла.
        let length = try AVAudioFile(forReading: url).length
        #expect(abs(length - 48_000) <= 48)
    }
}
