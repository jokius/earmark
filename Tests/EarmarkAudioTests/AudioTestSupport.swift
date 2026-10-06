@preconcurrency import AVFoundation
import Foundation
import Testing

/// Свежий временный каталог на тест: Swift Testing гоняет тесты параллельно, общих путей быть не должно.
func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("earmark-audio-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Один тон в треке: `hz` начиная с `onset` секунд (до него — тишина).
struct ToneSpec {
    var hz: Double
    var onset: Double = 0
    var amplitude: Double = 0.5
}

/// LPCM Int16 CAF с тонами по каналам — так же, как пишет запись (Int16, 48 kHz по умолчанию).
func writeToneCAF(
    _ url: URL, seconds: Double, channels: [ToneSpec], sampleRate: Double = 48_000
) throws {
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: channels.count, AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
    ]
    let file = try AVAudioFile(
        forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let frames = AVAudioFrameCount(seconds * sampleRate)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
    buffer.frameLength = frames
    let data = try #require(buffer.floatChannelData)
    for (channel, tone) in channels.enumerated() {
        let onsetFrame = Int(tone.onset * sampleRate)
        for frame in 0..<Int(frames) {
            let time = Double(frame - onsetFrame) / sampleRate
            data[channel][frame] =
                frame < onsetFrame ? 0 : Float(tone.amplitude * sin(2 * .pi * tone.hz * time))
        }
    }
    try file.write(from: buffer)
    file.close()
}

/// Файл целиком в память по каналам (тестовые файлы — секунды).
func readChannels(_ url: URL) throws -> (channels: [[Float]], sampleRate: Double) {
    let file = try AVAudioFile(forReading: url)
    let buffer = try #require(
        AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    let data = try #require(buffer.floatChannelData)
    let count = Int(buffer.frameLength)
    let channels = (0..<Int(file.processingFormat.channelCount)).map {
        Array(UnsafeBufferPointer(start: data[$0], count: count))
    }
    return (channels, file.processingFormat.sampleRate)
}

/// Мощность частоты `hz` (алгоритм Гёрцеля): одна частота дешевле FFT и не тянет зависимостей.
func goertzelPower(_ samples: ArraySlice<Float>, hz: Double, sampleRate: Double) -> Double {
    let coefficient = 2 * cos(2 * .pi * hz / sampleRate)
    var previous = 0.0
    var beforePrevious = 0.0
    for sample in samples {
        let current = Double(sample) + coefficient * previous - beforePrevious
        beforePrevious = previous
        previous = current
    }
    return previous * previous + beforePrevious * beforePrevious - coefficient * previous * beforePrevious
}

/// Первый кадр, где сигнал достигает `threshold` по модулю, — начало тона.
func onsetFrame(_ samples: [Float], threshold: Float = 0.25) -> Int? {
    samples.firstIndex { abs($0) >= threshold }
}

func rms(_ samples: ArraySlice<Float>) -> Float {
    guard !samples.isEmpty else { return 0 }
    return (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
}

/// Запускает earmark-crash-helper, через `after` убивает его SIGKILL'ом — kill -9 посреди записи.
/// Процесс возвращается, чтобы тест проверил: умер он именно от сигнала.
func killedRecording(at url: URL, mode: String, after: Duration = .milliseconds(1_500)) async throws
    -> Process
{
    let helper = productsDirectory().appendingPathComponent("earmark-crash-helper")
    try #require(FileManager.default.isExecutableFile(atPath: helper.path), "нет \(helper.path)")
    let process = Process()
    process.executableURL = helper
    process.arguments = [url.path, mode]
    try process.run()
    try await Task.sleep(for: after)
    kill(process.processIdentifier, SIGKILL)
    process.waitUntilExit()
    return process
}

/// Каталог продуктов сборки (`.build/<конфигурация>`): там рядом с .xctest-бандлом тестов лежит
/// и исполняемый earmark-crash-helper. Бандл находим по классу из этого модуля.
func productsDirectory() -> URL {
    Bundle(for: BundleToken.self).bundleURL.deletingLastPathComponent()
}

private final class BundleToken {}
