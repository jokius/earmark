import AVFAudio
import Foundation
import Testing

struct AACEncoderTests {
    /// Итоговый audio.m4a — AAC-LC 48 kHz стерео 96 kbps (§4.3). Кодер обязан принять ровно эти
    /// параметры и на этой машине, и на CI — на них стоит сведение записей.
    @Test func acceptsFinalMixFormat() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "mix.m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 96_000,
        ]
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let second = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        second.frameLength = 48_000
        let file = try AVAudioFile(
            forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: second)
        file.close()

        let written = try AVAudioFile(forReading: url)
        #expect(written.fileFormat.sampleRate == 48_000)
        #expect(written.fileFormat.channelCount == 2)
        #expect(written.length >= 47_000)
    }
}
