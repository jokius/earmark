import EarmarkAudio
import EarmarkCore
import Foundation
import Testing

@Suite("StereoMuxer")
struct StereoMuxerTests {
    /// Сведение двух CAF со сдвигом: каналы не перепутаны и начала тонов совпадают на общей шкале.
    @Test("L — mic, R — system, сдвиг mic_offset_ms выравнивает начала")
    func separatesAndAligns() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mic = dir.appendingPathComponent("mic.caf")
        let system = dir.appendingPathComponent("system.caf")
        let output = dir.appendingPathComponent("audio.partial.m4a")
        // mic стартовал на 250 мс позже system: его тон в 0.50 с своей шкалы = 0.75 с общей,
        // как и тон system в 0.75 с.
        try writeToneCAF(mic, seconds: 2, channels: [ToneSpec(hz: 440, onset: 0.5)])
        try writeToneCAF(system, seconds: 2, channels: [ToneSpec(hz: 1_000, onset: 0.75)])

        let info = try StereoMuxer.mux(mic: mic, system: system, micOffsetMs: 250, output: output)

        #expect(
            info
                == AudioInfo(
                    file: "audio.m4a", codec: "aac", sampleRate: 48_000, channels: ["mic", "system"],
                    micOffsetMs: 250))
        let (channels, rate) = try readChannels(output)
        try #require(channels.count == 2)
        #expect(rate == 48_000)
        #expect(abs(channels[0].count - 108_000) <= 2_048)  // 2 с mic + 0.25 с сдвига
        let window = 48_000..<96_000
        let left = channels[0][window], right = channels[1][window]
        #expect(
            goertzelPower(left, hz: 440, sampleRate: rate) > 100
                * goertzelPower(left, hz: 1_000, sampleRate: rate))
        #expect(
            goertzelPower(right, hz: 1_000, sampleRate: rate) > 100
                * goertzelPower(right, hz: 440, sampleRate: rate))
        let leftOnset = try #require(onsetFrame(channels[0]))
        let rightOnset = try #require(onsetFrame(channels[1]))
        #expect(abs(leftOnset - rightOnset) <= 480)  // ≤ 10 мс
        #expect(abs(leftOnset - 36_000) <= 480)  // 0.75 с: AVAudioFile срезает priming AAC
    }

    @Test("нет трека или он пустой — тишина в его канале на всю длину другого")
    func missingTrackBecomesSilence() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mic = dir.appendingPathComponent("mic.caf")
        let empty = dir.appendingPathComponent("system.caf")
        try writeToneCAF(mic, seconds: 1, channels: [ToneSpec(hz: 440)])
        FileManager.default.createFile(atPath: empty.path, contents: Data())  // упали до заголовка

        let output = dir.appendingPathComponent("a.m4a")
        _ = try StereoMuxer.mux(mic: mic, system: empty, micOffsetMs: -100, output: output)
        let (channels, _) = try readChannels(output)
        #expect(abs(channels[0].count - 48_000) <= 2_048)  // сдвиг system без трека длину не добавляет
        #expect(rms(channels[0][4_800..<43_200]) > 0.2)
        #expect(rms(channels[1][...]) < 0.0001)

        let onlySystem = dir.appendingPathComponent("b.m4a")
        _ = try StereoMuxer.mux(mic: nil, system: mic, micOffsetMs: 0, output: onlySystem)
        let swapped = try readChannels(onlySystem).channels
        #expect(rms(swapped[0][...]) < 0.0001)
        #expect(rms(swapped[1][4_800..<43_200]) > 0.2)
    }

    @Test("ни одного трека с данными — noAudio, файл не создаётся")
    func noTracks() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let output = dir.appendingPathComponent("audio.partial.m4a")
        #expect(throws: EarmarkAudioError.noAudio) {
            try StereoMuxer.mux(
                mic: dir.appendingPathComponent("mic.caf"), system: nil, micOffsetMs: 0, output: output)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test("трек с мусором вместо CAF — ошибка, а не тишина")
    func garbageTrackThrows() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let garbage = dir.appendingPathComponent("mic.caf")
        try Data(repeating: 0x5A, count: 10_000).write(to: garbage)
        #expect(throws: EarmarkAudioError.unreadable("mic.caf")) {
            try StereoMuxer.mux(
                mic: garbage, system: nil, micOffsetMs: 0, output: dir.appendingPathComponent("a.m4a"))
        }
    }
}
