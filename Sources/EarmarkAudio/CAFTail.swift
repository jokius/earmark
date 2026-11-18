@preconcurrency import AVFoundation
import Foundation

/// Растущий LPCM Int16 mono CAF (его прямо сейчас пишет CAFWriter) как поток Float32 mono на `sampleRate` —
/// для стрима на сервер расшифровки во время записи. Файл только читается.
///
/// Заголовок разбирается сам, а не через AudioFile: тот читает размер `data` из заголовка один раз при
/// открытии и растущий файл дальше не видит. Байты на диске появляются страницами, в том числе посреди
/// заголовка и посреди кадра.
public final class CAFTail {
    private let handle: FileHandle
    private let name: String
    private let sampleRate: Double
    /// Создаётся, когда на диске появился `desc`: один на всю жизнь, иначе на стыках кусков щелчки и сдвиг.
    private var converter: AVAudioConverter?
    private var bigEndian = false
    /// Следующий непрочитанный байт файла.
    private var position: UInt64 = 0
    private var finished = false

    /// Кусок чтения: ~11 с звука 48 kHz. Без предела finish() без единого read() на многочасовой записи
    /// разом поднял бы в память весь вход.
    private static let chunk = 1 << 20

    /// Открывает файл сразу и держит дескриптор: финализация записи может удалить файл, чтение продолжится.
    public init(url: URL, sampleRate: Double = 16_000) throws {
        handle = try FileHandle(forReadingFrom: url)
        name = url.lastPathComponent
        self.sampleRate = sampleRate
        _ = try locateData()
    }

    /// Сэмплы, дописанные на диск с прошлого вызова (целые кадры), через один ресемплер на всю жизнь.
    public func read() throws -> [Float] {
        guard !finished else { return [] }
        return try drain(end: false)
    }

    /// После close() писателя: дочитать до конца файла и сбросить хвост ресемплера. Дальше — `[]`.
    public func finish() throws -> [Float] {
        guard !finished else { return [] }
        finished = true
        return try drain(end: true)
    }

    /// Всё от position до конца файла, но не дальше объявленного размера `data`, кусками через конвертер.
    private func drain(end: Bool) throws -> [Float] {
        var samples: [Float] = []
        // Заголовок перечитывается каждый раз: после close() у `data` появляется размер.
        if let data = try locateData() {
            position = max(position, data.start)
            while true {
                let left = data.end.map { $0 > position ? $0 - position : 0 } ?? UInt64(Self.chunk)
                let want = Int(min(left, UInt64(Self.chunk)))
                let bytes = try self.bytes(at: position, count: want)
                // Полкадра на диске — дочитаем в следующий раз.
                let frames = bytes.count / 2
                if frames > 0 {
                    try convert(pcm(bytes.prefix(frames * 2)), end: false, into: &samples)
                    position += UInt64(frames * 2)
                }
                if bytes.count < want || frames == 0 { break }
            }
        }
        if end { try convert(nil, end: true, into: &samples) }
        return samples
    }

    /// Начало звука (после 4 байт edit count) и конец chunk'а `data`; end nil — размер ещё −1 (пишется).
    /// nil — `data` ещё не на диске. Формат проверяется, как только `desc` на диске.
    private func locateData() throws -> (start: UInt64, end: UInt64?)? {
        let magic = try bytes(at: 0, count: 4)
        guard Array("caff".utf8).starts(with: magic) else { throw EarmarkAudioError.unreadable(name) }
        var offset: UInt64 = 8
        var described = converter != nil
        while true {
            let header = try bytes(at: offset, count: 12)
            guard header.count == 12 else { return nil }
            let body = offset + 12
            let size = Int64(bitPattern: Self.number(header[4..<12]))
            let type = header[0..<4]
            if type.elementsEqual("data".utf8) {
                guard described else { throw EarmarkAudioError.unreadable(name) }
                return (body + 4, size < 0 ? nil : body + UInt64(size))
            }
            if type.elementsEqual("desc".utf8) {
                let desc = try bytes(at: body, count: 32)
                guard desc.count == 32 else { return nil }
                if converter == nil { try describe(desc) }
                described = true
            }
            // Размер −1 бывает только у `data`, и она последняя.
            guard size >= 0, case let (next, false) = body.addingReportingOverflow(UInt64(size)) else {
                throw EarmarkAudioError.unreadable(name)
            }
            offset = next
        }
    }

    /// `desc` (big-endian): частота, формат, флаги, байт на пакет, кадров на пакет, каналов, бит.
    private func describe(_ desc: [UInt8]) throws {
        let rate = Double(bitPattern: Self.number(desc[0..<8]))
        let flags = Self.number(desc[12..<16])
        guard desc[8..<12].elementsEqual("lpcm".utf8), flags & 1 == 0,
            Self.number(desc[16..<20]) == 2, Self.number(desc[24..<28]) == 1,
            Self.number(desc[28..<32]) == 16,
            rate > 0
        else { throw EarmarkAudioError.invalidOperation("\(name) is not 16-bit mono LPCM") }
        // Как у ChannelExtractor: вход — Float32 (AVAudioFile так же отдаёт Int16 / 32768), quality .max.
        guard
            let input = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
            let output = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: input, to: output)
        else { throw EarmarkAudioError.invalidOperation("no converter from \(rate) Hz to \(sampleRate) Hz") }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        bigEndian = flags & 2 == 0
        self.converter = converter
    }

    /// Int16 кадры → Float32-буфер входа конвертера.
    private func pcm(_ bytes: ArraySlice<UInt8>) throws -> AVAudioPCMBuffer {
        let frames = bytes.count / 2
        guard let converter,
            let buffer = AVAudioPCMBuffer(
                pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(frames)),
            let out = buffer.floatChannelData?[0]
        else { throw EarmarkAudioError.invalidOperation("cannot allocate \(frames) frames of \(name)") }
        buffer.frameLength = AVAudioFrameCount(frames)
        var index = bytes.startIndex
        for frame in 0..<frames {
            let pair = UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1])
            let value = Int16(bitPattern: bigEndian ? pair : pair.byteSwapped)
            out[frame] = Float(value) / 32_768
            index += 2
        }
        return buffer
    }

    /// Вход через конвертер; end — входа больше не будет, сбросить хвост. Пока не end, конвертер держит
    /// своё состояние до следующего куска (noDataNow).
    private func convert(_ input: AVAudioPCMBuffer?, end: Bool, into samples: inout [Float]) throws {
        guard let converter else { return }
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: 16_384) else {
            throw EarmarkAudioError.invalidOperation("cannot allocate the output buffer")
        }
        // Блок ввода у AVAudioConverter — @Sendable: кусок отдаём через ящик, а не через var.
        final class Pending: @unchecked Sendable { var buffer: AVAudioPCMBuffer? }
        let pending = Pending()
        pending.buffer = input
        while true {
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, status in
                guard let buffer = pending.buffer else {
                    status.pointee = end ? .endOfStream : .noDataNow
                    return nil
                }
                pending.buffer = nil
                status.pointee = .haveData
                return buffer
            }
            if status == .error { throw error ?? EarmarkAudioError.unreadable(name) }
            if output.frameLength > 0, let data = output.floatChannelData?[0] {
                samples.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(output.frameLength)))
            }
            if status != .haveData { return }
        }
    }

    /// До `count` байт с `offset`; меньше — на диске пока столько.
    private func bytes(at offset: UInt64, count: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let read = buffer.withUnsafeMutableBytes {
                pread(
                    handle.fileDescriptor, $0.baseAddress?.advanced(by: got), count - got,
                    off_t(offset) + off_t(got))
            }
            if read < 0 && errno == EINTR { continue }
            guard read >= 0 else { throw EarmarkAudioError.unreadable(name) }
            if read == 0 { break }
            got += read
        }
        return Array(buffer.prefix(got))
    }

    /// Big-endian целое из байтов заголовка.
    private static func number(_ bytes: ArraySlice<UInt8>) -> UInt64 {
        bytes.reduce(0) { $0 << 8 | UInt64($1) }
    }
}
