import AVFoundation
import EarmarkCore
import Foundation
import Testing

/// Папка записи в свежем temp-каталоге: meta.json (recorded) + настоящий стерео AAC audio.m4a.
struct RecordingFixture {
    let root: URL
    let folder: URL
    var store: RecordingStore { RecordingStore(root: root) }

    /// calendarId: запись по событию этого календаря (meta.calendar); nil — ручная запись.
    /// micOffsetMs: блок meta.audio с этим сдвигом mic; nil — блока нет.
    /// sampleRate: частота audio.m4a (длинные записи пишем в 16 kHz — так кодируются быстрее).
    init(
        status: String = "recorded", attempts: Int = 0, seconds: Double = 2, calendarId: String? = nil,
        micOffsetMs: Int? = nil, sampleRate: Double = 48_000,
        left: (Int) -> Float = { _ in 0 }, right: (Int) -> Float = { _ in 0 }
    )
        throws
    {
        root = FileManager.default.temporaryDirectory.appending(path: "earmark-tr-\(UUID().uuidString)")
        folder = root.appending(path: "Manual/2026-10-02 14-00 Test")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Календарная запись в meta — как в примере спеки §7.2: trigger, calendar и event.
        let trigger =
            calendarId.map {
                #""trigger":"calendar","calendar":{"id":"\#($0)","title":"Calls"},"#
                    + #""event":{"id":"evt-1","external_id":"ext-1","start":"2026-10-02T10:00:00Z","#
                    + #""end":"2026-10-02T10:30:00Z"},"#
            } ?? #""trigger":"manual","#
        let audio =
            micOffsetMs.map {
                #""audio":{"file":"audio.m4a","codec":"aac","sample_rate":48000,"#
                    + #""channels":["mic","system"],"mic_offset_ms":\#($0)},"#
            } ?? ""
        // meta пишем JSON-литералом: так фикстура не зависит от инициализаторов RecordingMeta.
        let meta = """
            {"schema_version":1,"id":"20261002-1400-a1b2","status":"\(status)",\(trigger)\
            "title":"Test","started_at":"2026-10-02T10:00:00Z","duration_sec":\(seconds),"call_apps":[],\
            \(audio)"recovered":false,"transcription":{"attempts":\(attempts)},"app_version":"0.1.0"}
            """
        try Data(meta.utf8).write(to: folder.appending(path: RecordingFiles.meta))
        try Self.writeStereoM4A(
            folder.appending(path: RecordingFiles.audio), seconds: seconds, rate: sampleRate, left: left,
            right: right)
    }

    var meta: RecordingMeta { get throws { try #require(try store.readMeta(in: folder)) } }

    func file(_ name: String) -> URL { folder.appending(path: name) }

    static func writeStereoM4A(
        _ url: URL, seconds: Double, rate: Double = 48_000, left: (Int) -> Float, right: (Int) -> Float
    ) throws {
        let format = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false))
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
        ]
        // 96 kbit/s — для 48 kHz; на 16 kHz битрейт выбирает кодер.
        if rate == 48_000 { settings[AVEncoderBitRateKey] = 96_000 }
        let file = try AVAudioFile(
            forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
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
