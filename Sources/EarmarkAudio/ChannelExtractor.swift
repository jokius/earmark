// Из прототипа research/probes/runtime/conv/conv.swift (свой код): там же замерено, что channelMap
// берёт нужный канал без сведения, а чтение ровно на EOF у CAF/WAV кидает eofErr (−39).
@preconcurrency import AVFoundation
import Foundation

/// Один канал записи как 16 kHz mono Float32 — вход whisper.cpp.
public enum ChannelExtractor {
    /// Декод + channelMap + ресемпл, потоково: в памяти секунда входа и итоговый массив, без ffmpeg и WAV.
    public static func extract(from url: URL, channel: Int, sampleRate: Double = 16_000) throws -> [Float] {
        let input = try AVAudioFile(forReading: url)
        let inFormat = input.processingFormat
        guard channel >= 0, channel < Int(inFormat.channelCount) else {
            throw EarmarkAudioError.noSuchChannel(channel)
        }
        let inChunk = AVAudioFrameCount(inFormat.sampleRate)
        guard
            let outFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: inFormat, to: outFormat),
            let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: inChunk),
            let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 16_384)
        else { throw EarmarkAudioError.invalidOperation("no converter from \(inFormat) to 16 kHz mono") }
        // Без channelMap конвертер при меньшем числе каналов берёт левый: правый канал (собеседники)
        // превратился бы в копию микрофона.
        converter.channelMap = [NSNumber(value: channel)]
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue

        // Блок ввода у AVAudioConverter — @Sendable: ошибку чтения выносим через ящик, а не через var.
        final class ReadState: @unchecked Sendable { var error: (any Error)? }
        let state = ReadState()
        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(input.length) * sampleRate / inFormat.sampleRate) + 16_384)
        while true {
            var convertError: NSError?
            let status = converter.convert(to: outBuffer, error: &convertError) { _, inputStatus in
                // Конец файла решает framePosition: чтение ровно на EOF не «ноль кадров», а ошибка.
                guard state.error == nil, input.framePosition < input.length else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try input.read(into: inBuffer, frameCount: inChunk)
                } catch {
                    state.error = error
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                guard inBuffer.frameLength > 0 else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return inBuffer
            }
            // Сбой чтения посреди файла — битый вход, а не конец: молча обрезать нельзя.
            if let readError = state.error { throw readError }
            if status == .error {
                throw convertError ?? EarmarkAudioError.unreadable(url.lastPathComponent)
            }
            if outBuffer.frameLength > 0, let data = outBuffer.floatChannelData?[0] {
                samples.append(
                    contentsOf: UnsafeBufferPointer(start: data, count: Int(outBuffer.frameLength)))
            }
            if status == .endOfStream { break }
        }
        return samples
    }
}
