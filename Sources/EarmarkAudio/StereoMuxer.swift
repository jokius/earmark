// Copyright (c) 2026 Andrew Jones
// Copyright (c) 2026 Samat Galimov
// Портировано из gsamat/amanu@fbccc13: Sources/amanu/Audio/TrackCompressor.swift (encodeStereo, L242-320)
// и Sources/amanu/Audio/AudioTrackReader.swift (MIT). Чтение переведено на ExtAudioFile с клиентским
// форматом 48 kHz mono: ресемплинг делает сам ExtAudioFile, без AVAudioConverter.
@preconcurrency import AVFoundation
import AudioToolbox
import EarmarkCore
import Foundation

/// Сводит mic.caf и system.caf в стерео AAC-LC: L — микрофон, R — собеседники.
public enum StereoMuxer {
    static let sampleRate: Double = 48_000
    /// ~1 с на блок: в памяти никогда не больше пары секунд, сколько бы ни шёл созвон.
    static let blockFrames: AVAudioFrameCount = 48_000

    /// Потоково: L = mic (сдвиг `micOffsetMs`; > 0 — mic начался позже, тишина впереди mic; < 0 — впереди
    /// system), R = system → AAC-LC 48 kHz 96 kbps в `output`. Трек, которого нет или в котором 0 кадров,
    /// становится тишиной на всю длину другого. Нет ни одного — `EarmarkAudioError.noAudio`.
    /// Пишет в `output` напрямую: `.partial` и rename — забота вызывающего.
    public static func mux(mic: URL?, system: URL?, micOffsetMs: Int, output: URL) throws -> AudioInfo {
        let offset = Int64((Double(abs(micOffsetMs)) / 1000 * sampleRate).rounded())
        let micTrack = try TrackReader.open(mic, lead: micOffsetMs > 0 ? offset : 0)
        let systemTrack = try TrackReader.open(system, lead: micOffsetMs < 0 ? offset : 0)
        let tracks = [micTrack, systemTrack].compactMap(\.self)
        guard !tracks.isEmpty else { throw EarmarkAudioError.noAudio }
        let total = tracks.map(\.end).max() ?? 0

        guard
            let stereo = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false),
            let block = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: blockFrames),
            let left = block.floatChannelData?[0], let right = block.floatChannelData?[1]
        else { throw EarmarkAudioError.invalidOperation("cannot allocate the stereo buffer") }

        // Остаток прошлого падения (audio.partial.m4a) мешает AVAudioFile создать файл заново.
        try? FileManager.default.removeItem(at: output)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 96_000,
            AVAudioFileTypeKey: kAudioFileM4AType,
        ]
        let file = try AVAudioFile(
            forWriting: output, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        var position: Int64 = 0
        while position < total {
            let count = Int(min(Int64(blockFrames), total - position))
            block.frameLength = AVAudioFrameCount(count)
            left.update(repeating: 0, count: count)
            right.update(repeating: 0, count: count)
            try micTrack?.fill(left, count: count, at: position)
            try systemTrack?.fill(right, count: count, at: position)
            try file.write(from: block)
            position += Int64(count)
        }
        // close() (macOS 15+) дописывает moov; без него m4a нечитаем, а deinit у AVAudioFile не гарантирован.
        file.close()

        // Финализатор после этого удаляет CAF, и всё, чего нет в AAC, теряется насовсем. Поэтому не процент
        // (1% от часа — 36 с молча), а два AAC-пакета (2 × 1024 кадра) люфта: муксер пишет ровно `total`
        // кадров (замер: written == total на 221 792, 960 000 и 172 800 000 кадрах).
        let written = try AVAudioFile(forReading: output).length
        guard written >= total - 2_048 else {
            throw EarmarkAudioError.truncatedOutput(expected: total, actual: written)
        }
        return AudioInfo(
            file: RecordingFiles.audio, codec: "aac", sampleRate: Int(sampleRate),
            channels: ["mic", "system"], micOffsetMs: micOffsetMs)
    }
}

/// Один CAF как поток 48 kHz mono Float32, поставленный на общую шкалу со сдвигом `lead`.
///
/// Mono-клиент у ExtAudioFile берёт канал 0, а не сводит каналы (замер: правый канал стерео-файла
/// отбрасывается). Треки earmark пишутся моно, поэтому это не мешает.
private final class TrackReader {
    /// Первый кадр после трека на общей шкале.
    let end: Int64
    private let file: ExtAudioFileRef
    private let lead: Int64

    private init(file: ExtAudioFileRef, lead: Int64, frames: Int64) {
        self.file = file
        self.lead = lead
        end = lead + frames
    }

    deinit { ExtAudioFileDispose(file) }

    /// nil — трека нет: файла нет, он пустой (0 байт) или в нём 0 кадров (запись упала сразу после
    /// заголовка). Файл с байтами, который не открывается, — ошибка: тишину вместо него не пишем.
    static func open(_ url: URL?, lead: Int64) throws -> TrackReader? {
        guard let url, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else {
            return nil
        }
        var opened: ExtAudioFileRef?
        guard ExtAudioFileOpenURL(url as CFURL, &opened) == noErr, let file = opened else {
            throw EarmarkAudioError.unreadable(url.lastPathComponent)
        }
        var fileFormat = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var fileFrames: Int64 = 0
        var framesSize = UInt32(MemoryLayout<Int64>.size)
        var client = AudioStreamBasicDescription(
            mSampleRate: StereoMuxer.sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1,
            mBitsPerChannel: 32, mReserved: 0)
        guard
            ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &formatSize, &fileFormat)
                == noErr,
            ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileLengthFrames, &framesSize, &fileFrames)
                == noErr,
            ExtAudioFileSetProperty(
                file, kExtAudioFileProperty_ClientDataFormat,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client) == noErr,
            fileFormat.mSampleRate > 0
        else {
            ExtAudioFileDispose(file)
            throw EarmarkAudioError.unreadable(url.lastPathComponent)
        }
        let frames = Int64(
            (Double(fileFrames) * StereoMuxer.sampleRate / fileFormat.mSampleRate).rounded(.up))
        guard frames > 0 else {
            ExtAudioFileDispose(file)
            return nil
        }
        return TrackReader(file: file, lead: lead, frames: frames)
    }

    /// Свой кусок блока [position, position + count) в `destination` (уже обнулён). Блоки идут по порядку,
    /// поэтому файл читается последовательно; за концом файла остаётся тишина.
    func fill(_ destination: UnsafeMutablePointer<Float>, count: Int, at position: Int64) throws {
        var filled = Int(max(0, min(Int64(count), lead - position)))
        while filled < count {
            var frames = UInt32(count - filled)
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 1, mDataByteSize: frames * 4,
                    mData: UnsafeMutableRawPointer(destination + filled)))
            let status = ExtAudioFileRead(file, &frames, &list)
            guard status == noErr else {
                throw EarmarkAudioError.osStatus(operation: "ExtAudioFileRead", status: status)
            }
            if frames == 0 { return }
            filled += Int(frames)
        }
    }
}
