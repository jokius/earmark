@preconcurrency import AVFoundation
import EarmarkAudio
import Foundation
import Testing

/// Звук с деталями по всей полосе 16 kHz: щелчок, пропуск или сдвиг на стыке кусков не спрячутся.
private func signal(_ frame: Int) -> Float {
    let time = Double(frame) / 48_000
    return Float(
        0.3 * sin(2 * .pi * 440 * time) + 0.2 * sin(2 * .pi * 2_950 * time) + 0.1
            * sin(2 * .pi * 6_100 * time))
}

/// Дорожка записи так, как её пишет запись: CAFWriter, Float32 48 kHz mono на входе, LPCM Int16 в файле.
private final class Track {
    let url: URL
    private let writer: CAFWriter
    private let format: AVAudioFormat
    private(set) var frames = 0

    init(_ url: URL) throws {
        format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        writer = try CAFWriter(url: url, format: format)
        self.url = url
    }

    /// Синхронная запись `count` кадров сигнала, продолжая с того места, где остановились.
    func write(_ count: Int) throws {
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
        buffer.frameLength = AVAudioFrameCount(count)
        let samples = try #require(buffer.floatChannelData)[0]
        for index in 0..<count { samples[index] = signal(frames + index) }
        try writer.write(buffer)
        frames += count
    }

    func close() throws { try writer.close() }
}

/// Склейка кусков совпадает с ChannelExtractor того же закрытого файла: длина ±16 сэмплов,
/// значения на общей части — max |разность| ≤ 1e-3.
private func expectMatches(
    _ got: [Float], _ reference: [Float], _ context: String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(
        abs(got.count - reference.count) <= 16, "\(context) длина \(got.count), эталон \(reference.count)",
        sourceLocation: sourceLocation)
    let common = min(got.count, reference.count)
    let differences = zip(got.prefix(common), reference.prefix(common)).map { abs($0 - $1) }
    let worst = differences.indices.max { differences[$0] < differences[$1] }
    let value = worst.map { differences[$0] } ?? 0
    #expect(
        value <= 1e-3, "\(context) max |разность| \(value) на сэмпле \(worst ?? -1) из \(common)",
        sourceLocation: sourceLocation)
}

/// Chunk `data` в CAF: где начинаются сэмплы (после edit count) и заявленный размер (-1 — до конца файла).
private func dataChunk(_ bytes: Data) -> (start: Int, size: Int64)? {
    var offset = 8
    while offset + 12 <= bytes.count {
        let size = bytes[offset + 4..<offset + 12].reduce(Int64(0)) { $0 << 8 | Int64($1) }
        if bytes[offset..<offset + 4].elementsEqual("data".utf8) { return (offset + 16, size) }
        offset += 12 + Int(size)
    }
    return nil
}

@Suite("CAFTail: чтение растущего CAF записи")
struct CAFTailTests {
    /// Как файл режут на записи и вызовы read().
    enum Split: String, CaseIterable, CustomTestStringConvertible {
        /// Записи по 10 мс, после каждой — read() дважды подряд.
        case smallWritesReadEach
        /// Записи по 250 мс, после каждой — read().
        case largeWritesReadEach
        /// Записи неровного размера (от 1 кадра), read() после каждой второй.
        case irregular
        /// Ни одного read() до close: всё отдаёт finish().
        case onlyFinish

        var testDescription: String { rawValue }

        /// Размер очередной записи и сколько read() после неё.
        func step(_ number: Int) -> (frames: Int, reads: Int) {
            switch self {
            case .smallWritesReadEach: (480, 2)
            case .largeWritesReadEach: (12_000, 1)
            case .irregular: ([1, 4_801, 333, 24_000, 7, 9_999][number % 6], number % 2)
            case .onlyFinish: (4_800, 0)
            }
        }
    }

    @Test(
        "склейка всех read() и finish() растущего файла = ChannelExtractor закрытого (±16 сэмплов, ≤ 1e-3) при любой нарезке; после finish — пусто",
        arguments: Split.allCases)
    func matchesExtractor(_ split: Split) throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let track = try Track(dir.appendingPathComponent("mic.caf"))
        let tail = try CAFTail(url: track.url)
        var got: [Float] = []

        var number = 0
        while track.frames < 96_000 {
            let step = split.step(number)
            try track.write(step.frames)
            for _ in 0..<step.reads { got += try tail.read() }
            number += 1
        }
        if split != .onlyFinish {
            #expect(!got.isEmpty, "за 2 с записи read() не отдал ни сэмпла")
        }
        try track.close()
        got += try tail.finish()

        let reference = try ChannelExtractor.extract(from: track.url, channel: 0)
        try #require(reference.count > 30_000)
        expectMatches(got, reference)
        #expect(try tail.read().isEmpty)
        #expect(try tail.finish().isEmpty)
    }

    @Test("read() отдаёт то, что уже на диске, ещё до close: не копит у себя")
    func readsWhatIsOnDisk() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let track = try Track(dir.appendingPathComponent("mic.caf"))
        let tail = try CAFTail(url: track.url)
        for _ in 0..<20 { try track.write(4_800) }

        let bytes = try Data(contentsOf: track.url)
        let start = try #require(dataChunk(bytes)).start
        let onDisk = (bytes.count - start) / 2
        try #require(onDisk >= 48_000, "писатель сбросил на диск только \(onDisk) кадров из 96 000")
        let got = try tail.read()
        try track.close()

        // 48 kHz → 16 kHz; запас 0,1 с — на то, что держит в себе ресемплер до finish().
        #expect(got.count >= onDisk / 3 - 1_600, "на диске \(onDisk) кадров, read() отдал \(got.count)")
    }

    @Test(
        "файл появляется по байтам: без заголовка и без data — пусто, полкадра не читается; склейка = ChannelExtractor"
    )
    func headerArrivesLater() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Track(dir.appendingPathComponent("source.caf"))
        try source.write(96_000)
        try source.close()
        let bytes = try Data(contentsOf: source.url)
        let start = try #require(dataChunk(bytes)).start
        let reference = try ChannelExtractor.extract(from: source.url, channel: 0)

        let growing = dir.appendingPathComponent("growing.caf")
        #expect(FileManager.default.createFile(atPath: growing.path, contents: Data()))
        let tail = try CAFTail(url: growing)
        #expect(try tail.read().isEmpty, "пустой файл")
        let handle = try FileHandle(forWritingTo: growing)
        defer { try? handle.close() }
        var written = 0
        func append(upTo end: Int) throws {
            try handle.seekToEnd()
            try handle.write(contentsOf: bytes[written..<end])
            written = end
        }

        var got: [Float] = []
        // Середина заголовка файла, середина desc, середина заголовка data, до edit count, без сэмплов,
        // полкадра.
        for cut in [4, 20, start - 10, start - 4, start, start + 1] {
            try append(upTo: cut)
            #expect(try tail.read().isEmpty, "\(cut) байт из \(bytes.count), сэмплы с \(start)")
        }
        // Середина звука, нечётный байт: кадр разрезан.
        try append(upTo: start + ((bytes.count - start) / 2 | 1))
        got += try tail.read()
        #expect(!got.isEmpty, "половина звука на диске, read() пуст")
        try append(upTo: bytes.count)
        got += try tail.read()
        got += try tail.finish()

        expectMatches(got, reference)
    }

    @Test("закрытый CAF: размер data известен — то, что лежит за ним, не читается")
    func stopsAtDataSize() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Track(dir.appendingPathComponent("source.caf"))
        try source.write(48_000)
        try source.close()
        var bytes = try Data(contentsOf: source.url)
        let chunk = try #require(dataChunk(bytes))
        try #require(chunk.size >= 0, "у закрытого CAF размер data не записан")
        try #require(Int64(bytes.count) == Int64(chunk.start - 4) + chunk.size, "data не последний chunk")
        // Ещё 0,1 с после data — chunk free, его байты не звук.
        let padding = 9_600
        bytes += Data("free".utf8)
        bytes += Data(withUnsafeBytes(of: Int64(padding).bigEndian) { Array($0) })
        bytes += Data(repeating: 0x55, count: padding)
        let padded = dir.appendingPathComponent("padded.caf")
        try bytes.write(to: padded)

        let tail = try CAFTail(url: padded)
        let got = try tail.read() + tail.finish()

        expectMatches(got, try ChannelExtractor.extract(from: source.url, channel: 0))
    }

    @Test("файл удалён (unlink) после init — чтение продолжается до конца")
    func survivesUnlink() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let track = try Track(dir.appendingPathComponent("mic.caf"))
        let tail = try CAFTail(url: track.url)
        var got: [Float] = []
        for _ in 0..<10 {
            try track.write(4_800)
            got += try tail.read()
        }
        try track.write(48_000)
        try track.close()
        let reference = try ChannelExtractor.extract(from: track.url, channel: 0)

        // Финализация записи удаляет CAF, а стрим ещё не дочитал.
        try FileManager.default.removeItem(at: track.url)
        got += try tail.read()
        got += try tail.finish()

        expectMatches(got, reference)
    }

    @Test("файл только читается: read-only файл открывается, байты и время изменения не меняются")
    func readOnly() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let track = try Track(dir.appendingPathComponent("mic.caf"))
        try track.write(48_000)
        try track.close()
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: track.url.path)
        let bytes = try Data(contentsOf: track.url)
        let modified =
            try FileManager.default.attributesOfItem(atPath: track.url.path)[.modificationDate]
            as? Date

        let tail = try CAFTail(url: track.url)
        let got = try tail.read() + tail.finish()

        #expect(!got.isEmpty)
        #expect(try Data(contentsOf: track.url) == bytes)
        let after =
            try FileManager.default.attributesOfItem(atPath: track.url.path)[.modificationDate] as? Date
        #expect(after == modified)
    }

    enum Bad: String, CaseIterable {
        case missing, notCAF, stereo, float32
    }

    @Test("нет файла или он не LPCM Int16 mono — init бросает", arguments: Bad.allCases)
    func rejects(_ bad: Bad) throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("bad.caf")
        switch bad {
        case .missing: break
        case .notCAF: try Data(String(repeating: "это не CAF, а текст. ", count: 20).utf8).write(to: url)
        case .stereo: try writeToneCAF(url, seconds: 1, channels: [ToneSpec(hz: 440), ToneSpec(hz: 1_000)])
        case .float32:
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            ]
            let file = try AVAudioFile(
                forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = try #require(
                AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_800))
            buffer.frameLength = 4_800
            try file.write(from: buffer)
            file.close()
        }

        #expect(throws: (any Error).self) { try CAFTail(url: url) }
    }
}
