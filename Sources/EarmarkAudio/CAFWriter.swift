// Copyright © 2024 Apple Inc.
// Портировано из Apple sample «Capturing system audio with Core Audio taps» (AudioTapSample,
// MIT-style license): запись из IOProc через ExtAudioFileWriteAsync с прогревом вне IO-потока.
@preconcurrency import AVFoundation
import AudioToolbox
import Foundation
import Synchronization

/// Ошибки EarmarkAudio. Один тип на модуль: вызывающим (финализатор, воркер транскрипции) важно
/// отличать «аудио нет вовсе» от «файл битый», остальное — просто текст в лог и meta.json.
/// Текст — по-английски: через localizedDescription он уходит в meta.json, stderr воркера и MCP.
public enum EarmarkAudioError: Error, Equatable, Sendable, LocalizedError {
    case osStatus(operation: String, status: Int32)
    /// Ни одного трека с данными: сводить нечего.
    case noAudio
    /// Файл есть и не пустой, но AudioFile его не открывает или чтение обрывается.
    case unreadable(String)
    case noSuchChannel(Int)
    /// AAC-файл вышел короче источника — значит, энкодер молча что-то потерял.
    case truncatedOutput(expected: Int64, actual: Int64)
    case writerClosed
    case invalidOperation(String)

    public var errorDescription: String? {
        switch self {
        case .osStatus(let operation, let status): "\(operation) failed (OSStatus \(status))"
        case .noAudio: "neither track has a single frame"
        case .unreadable(let file): "\(file) is not readable audio"
        case .noSuchChannel(let channel): "the file has no channel \(channel)"
        case .truncatedOutput(let expected, let actual):
            "the AAC output is shorter than its source: \(actual) of \(expected) frames"
        case .writerClosed: "the CAF writer is already closed"
        case .invalidOperation(let reason): reason
        }
    }
}

/// LPCM Int16 CAF на ExtAudioFile.
///
/// Почему CAF и LPCM: после SIGKILL посреди записи AAC (.m4a и в CAF) и FLAC не читаются вовсе, а
/// LPCM CAF читается целиком — у chunk'а `data` размер −1, «до конца файла» (замер на 27.0.1, дважды).
///
/// Два режима, и смешивать их нельзя — ExtendedAudioFile.h: «must not mix synchronous and asynchronous
/// writes to the same file». Микрофон пишет синхронно `write` со своей очереди. Системный звук после
/// `primeAsync` пишет `writeAsync` прямо из IOProc; с этого момента и `write`, и `writeSilence` тоже идут
/// через ExtAudioFileWriteAsync.
///
/// Потоки: `writeAsync` — только из одного IO-потока; остальные методы — с одной очереди владельца;
/// `framesWritten` можно читать откуда угодно.
public final class CAFWriter: @unchecked Sendable {
    /// Формат буферов, которые принимает writer. Меняется только до первой записи: дальше
    /// ExtAudioFile отказывает (kExtAudioFileError_InvalidOperationOrder, −66565 — замер на 27.0.1).
    public private(set) var clientFormat: AVAudioFormat

    private let file: ExtAudioFileRef
    private let frames = Atomic<Int64>(0)
    private let closed = Atomic<Bool>(false)
    private let asyncMode = Atomic<Bool>(false)

    /// Файл — LPCM Int16 с частотой и числом каналов `format`; клиентский формат — сам `format`.
    public init(url: URL, format: AVAudioFormat) throws {
        let channels = format.channelCount
        var fileFormat = AudioStreamBasicDescription(
            mSampleRate: format.sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2 * channels, mFramesPerPacket: 1, mBytesPerFrame: 2 * channels,
            mChannelsPerFrame: channels, mBitsPerChannel: 16, mReserved: 0)
        var created: ExtAudioFileRef?
        let status = ExtAudioFileCreateWithURL(
            url as CFURL, kAudioFileCAFType, &fileFormat, nil, AudioFileFlags.eraseFile.rawValue, &created)
        guard status == noErr, let created else {
            throw EarmarkAudioError.osStatus(operation: "ExtAudioFileCreateWithURL", status: status)
        }
        // Клиентский формат ставим до присваивания свойств: если он не встанет, файл закрываем здесь,
        // а не в deinit недоинициализированного объекта.
        do {
            try Self.apply(format, to: created)
        } catch {
            ExtAudioFileDispose(created)
            throw error
        }
        file = created
        clientFormat = format
    }

    deinit {
        if !closed.load(ordering: .relaxed) { ExtAudioFileDispose(file) }
    }

    /// Кадров отдано в файл — в кадрах клиентского формата (по ним считается паддинг).
    public var framesWritten: Int64 { frames.load(ordering: .relaxed) }

    public func setClientFormat(_ format: AVAudioFormat) throws {
        guard frames.load(ordering: .relaxed) == 0, !asyncMode.load(ordering: .relaxed) else {
            throw EarmarkAudioError.invalidOperation("the client format is fixed after the first write")
        }
        try Self.apply(format, to: file)
        clientFormat = format
    }

    /// Первый вызов ExtAudioFileWriteAsync аллоцирует внутреннее кольцо — делаем его здесь, вне IO-потока.
    public func primeAsync() throws {
        guard frames.load(ordering: .relaxed) == 0 else {
            throw EarmarkAudioError.invalidOperation("primeAsync after a synchronous write")
        }
        let status = ExtAudioFileWriteAsync(file, 0, nil)
        guard status == noErr else {
            throw EarmarkAudioError.osStatus(operation: "ExtAudioFileWriteAsync(prime)", status: status)
        }
        asyncMode.store(true, ordering: .releasing)
    }

    public func write(_ buffer: AVAudioPCMBuffer) throws {
        guard buffer.frameLength > 0 else { return }
        guard !closed.load(ordering: .relaxed) else { throw EarmarkAudioError.writerClosed }
        guard buffer.format.sampleRate == clientFormat.sampleRate,
            buffer.format.channelCount == clientFormat.channelCount
        else {
            throw EarmarkAudioError.invalidOperation("the buffer is not in the writer's client format")
        }
        let status =
            asyncMode.load(ordering: .acquiring)
            ? ExtAudioFileWriteAsync(file, buffer.frameLength, buffer.audioBufferList)
            : ExtAudioFileWrite(file, buffer.frameLength, buffer.audioBufferList)
        guard status == noErr else {
            throw EarmarkAudioError.osStatus(operation: "ExtAudioFileWrite", status: status)
        }
        frames.wrappingAdd(Int64(buffer.frameLength), ordering: .relaxed)
    }

    /// Единственный метод для IOProc: без локов, без аллокаций, без исключений.
    public func writeAsync(_ bufferList: UnsafePointer<AudioBufferList>, frames count: UInt32) -> OSStatus {
        guard count > 0 else { return noErr }
        guard !closed.load(ordering: .relaxed) else { return kExtAudioFileError_InvalidOperationOrder }
        // Без primeAsync первый ExtAudioFileWriteAsync аллоцирует кольцо прямо в IO-потоке, а файл уходит
        // в async-режим в обход флага — и следующий синхронный write смешает режимы.
        guard asyncMode.load(ordering: .acquiring) else { return kAudio_ParamError }
        let status = ExtAudioFileWriteAsync(file, count, bufferList)
        if status == noErr { frames.wrappingAdd(Int64(count), ordering: .relaxed) }
        return status
    }

    /// Тишина кусками по 4096 кадров в клиентском формате.
    ///
    /// В async-режиме — с паузой 2 мс на кусок (~40x реального времени). Кольцо ExtAudioFileWriteAsync
    /// держит лишь несколько секунд, а переполнение (−66570) молча убивает writer целиком: всё, что
    /// пишется дальше, теряется, и даже уже отданное не доходит до диска (замер на 27.0.1: 60 с тишины
    /// одним махом — файл с 0 кадров).
    public func writeSilence(frames count: AVAudioFrameCount) throws {
        guard count > 0 else { return }
        let chunk: AVAudioFrameCount = 4_096
        guard let zeros = AVAudioPCMBuffer(pcmFormat: clientFormat, frameCapacity: chunk) else {
            throw EarmarkAudioError.invalidOperation("cannot allocate the silence buffer")
        }
        zeros.frameLength = chunk
        for buffer in UnsafeMutableAudioBufferListPointer(zeros.mutableAudioBufferList) {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        let paced = asyncMode.load(ordering: .acquiring)
        var left = count
        while left > 0 {
            let step = min(chunk, left)
            zeros.frameLength = step
            try write(zeros)
            if paced { usleep(2_000) }
            left -= step
        }
    }

    /// ExtAudioFileDispose дописывает всё из async-кольца и закрывает файл. Повторный вызов — no-op.
    /// Вызывать только после остановки IOProc: dispose параллельно с writeAsync — гонка.
    public func close() throws {
        guard !closed.exchange(true, ordering: .acquiringAndReleasing) else { return }
        let status = ExtAudioFileDispose(file)
        guard status == noErr else {
            throw EarmarkAudioError.osStatus(operation: "ExtAudioFileDispose", status: status)
        }
    }

    private static func apply(_ format: AVAudioFormat, to file: ExtAudioFileRef) throws {
        var client = format.streamDescription.pointee
        let status = ExtAudioFileSetProperty(
            file, kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client)
        guard status == noErr else {
            throw EarmarkAudioError.osStatus(
                operation: "ExtAudioFileSetProperty(ClientDataFormat)", status: status)
        }
    }
}
