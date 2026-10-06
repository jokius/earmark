import EarmarkAudio
import Foundation
import Testing

@Suite("ChannelExtractor")
struct ChannelExtractorTests {
    @Test(
        "каждый канал отдельно, 16 kHz mono, длина ≈ длительность × 16000",
        arguments: [(0, 440.0), (1, 1_000.0)])
    func extractsOneChannel(channel: Int, hz: Double) throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("stereo.caf")
        try writeToneCAF(url, seconds: 3, channels: [ToneSpec(hz: 440), ToneSpec(hz: 1_000)])

        let samples = try ChannelExtractor.extract(from: url, channel: channel)

        #expect(abs(Double(samples.count) - 48_000) <= 480)  // ±1 %
        let middle = samples[8_000..<40_000]
        let other = hz == 440 ? 1_000.0 : 440.0
        #expect(
            goertzelPower(middle, hz: hz, sampleRate: 16_000) > 100
                * goertzelPower(middle, hz: other, sampleRate: 16_000))
    }

    @Test("канала нет — ошибка")
    func missingChannel() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("mono.caf")
        try writeToneCAF(url, seconds: 1, channels: [ToneSpec(hz: 440)])
        #expect(throws: EarmarkAudioError.noSuchChannel(1)) {
            try ChannelExtractor.extract(from: url, channel: 1)
        }
    }
}
