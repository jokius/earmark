// Помощник SIGKILL-теста (из research/probes/crashtest/crashtest.swift, свой код): пишет синтетический
// синус 440 Hz в CAF через CAFWriter, пока его не убьют. Никаких устройств — только память и диск.
//
//   earmark-crash-helper <out.caf> sync|async
//
// async — как IOProc системного звука: primeAsync, затем writeAsync. Аудио идёт в 4 раза быстрее
// реального времени, чтобы тест не ждал долго.
@preconcurrency import AVFoundation
import EarmarkAudio
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3, arguments[2] == "sync" || arguments[2] == "async",
    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)
else {
    FileHandle.standardError.write(Data("usage: earmark-crash-helper <out.caf> sync|async\n".utf8))
    exit(64)
}
let useAsync = arguments[2] == "async"
let writer = try CAFWriter(url: URL(fileURLWithPath: arguments[1]), format: format)
if useAsync { try writer.primeAsync() }

let chunk: AVAudioFrameCount = 4_800
guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk),
    let samples = buffer.floatChannelData?[0]
else { exit(70) }
buffer.frameLength = chunk
var written = 0
while true {
    for index in 0..<Int(chunk) {
        samples[index] = Float(0.3 * sin(2 * Double.pi * 440 * Double(written + index) / 48_000))
    }
    written += Int(chunk)
    if useAsync {
        let status = writer.writeAsync(buffer.audioBufferList, frames: chunk)
        if status != noErr { FileHandle.standardError.write(Data("writeAsync: \(status)\n".utf8)) }
    } else {
        try writer.write(buffer)
    }
    usleep(25_000)
}
