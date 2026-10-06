import AVFoundation
import EarmarkAudio
import EarmarkCore
import os

/// Проверка канала собеседников коротким тихим тоном 440 Hz (§10): единственный честный способ.
/// Неавторизованный или не тому процессу приписанный tap отдаёт ровные нули без единой ошибки, и это
/// не отличить от тихого созвона, пока не издашь звук нарочно.
enum AudioSelfTest {
    /// Пользователь обычно в наушниках: громкий тон бьёт по ушам. Пик RMS такого тона ≈ 0.035 —
    /// всё ещё в 35 раз выше ActivityTracker.quietThreshold.
    private static let amplitude = 0.05

    private static let logger = Logger(subsystem: EarmarkPaths.bundleID, category: "audio-test")

    @MainActor
    static func run() async -> DoctorCheck {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("earmark-selftest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tone = dir.appendingPathComponent("tone.caf")
        let capture = dir.appendingPathComponent("capture.caf")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try writeTone(to: tone)
        } catch {
            return report(ok: false, "cannot prepare the test tone: \(error.localizedDescription)")
        }
        do {
            try await captureSystemAudio(to: capture) {
                await play(tone)
                // Буферы tap приходят чуть позже звука: стоп сразу после проигрывания срезал бы хвост тона.
                try? await Task.sleep(for: .milliseconds(400))
            }
        } catch {
            return report(ok: false, error.message)
        }

        let peak = (try? peakRMS(of: capture)) ?? 0
        let level = String(format: "peak RMS %.4f", peak)
        // Порог тот же, что у стоп-правил для «собеседники затихли»: тон должен быть громче тишины.
        return peak > ActivityTracker.quietThreshold
            ? report(ok: true, "played a short quiet 440 Hz tone, and the tap heard it (\(level))")
            : report(
                ok: false,
                "played a short quiet 440 Hz tone, but the tap captured silence (\(level)): "
                    + "System Audio Recording is not granted to Earmark, or the output is muted")
    }

    /// Пишет в `url` настоящий tap рекордера записи, пока идёт `body`. После возврата CAF закрыт и
    /// читается: async-кольцо ExtAudioFile дописывает на диск только close() (D5). Первый старт tap
    /// показывает запрос на запись системного звука — им же пользуется Permissions.
    @MainActor
    static func captureSystemAudio(to url: URL, during body: @MainActor () async -> Void)
        async throws(EarmarkError)
    {
        // Файл как у треков записи (Int16 48 kHz mono); клиентский формат — формат tap — рекордер
        // ставит writer'у сам (Task 10).
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1) else {
            throw .operationFailed("cannot build the 48 kHz mono capture format")
        }
        let writer: CAFWriter
        do {
            writer = try CAFWriter(url: url, format: format)
        } catch {
            throw .operationFailed("cannot create the capture file: \(error.localizedDescription)")
        }
        let recorder = SystemAudioRecorder()
        // Ни main, ни пул Swift concurrency: первый старт tap держит поток, пока пользователь не ответит
        // на системный запрос (S1).
        let started = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    returning: Result { () throws(EarmarkError) in try recorder.start(writer: writer) })
            }
        }
        if case .failure(let error) = started {
            try? writer.close()
            throw .operationFailed("tap failed to start: \(error.message)")
        }
        await body()
        recorder.stop()
        do {
            try writer.close()
        } catch {
            throw .operationFailed("capture file did not close: \(error.localizedDescription)")
        }
    }

    private static func report(ok: Bool, _ detail: String) -> DoctorCheck {
        logger.notice("audio self-test: \(detail, privacy: .public)")
        return DoctorCheck(name: "audio_test", ok: ok, detail: detail)
    }

    /// 1.5 с тона с плавными краями: резкий старт и стоп — это щелчок в ушах у сидящего за Mac.
    private static func writeTone(to url: URL) throws {
        let sampleRate = 48_000.0
        let frames = AVAudioFrameCount(sampleRate * 1.5)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
            let samples = buffer.floatChannelData?[0]
        else { throw EarmarkError.operationFailed("cannot allocate the tone buffer") }
        buffer.frameLength = frames
        let fade = Double(frames) * 0.05
        for index in 0..<Int(frames) {
            let position = Double(index)
            let envelope = min(1, min(position, Double(frames) - position) / fade)
            samples[index] = Float(amplitude * envelope * sin(2 * .pi * 440 * position / sampleRate))
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        file.close()
    }

    /// Тон играет отдельный процесс, а не AVAudioEngine внутри app: tap глобальный, но исключает
    /// собственный процесс Earmark (§4.1), и свой же тон он бы не услышал (S1).
    private static func play(_ url: URL) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        process.arguments = [url.path]
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                logger.error("afplay: \(error.localizedDescription, privacy: .public)")
                continuation.resume()
            }
        }
    }

    /// Максимальный RMS по окнам 100 мс: тон занимает часть записи, и среднее по всему файлу
    /// размыло бы его тишиной до и после.
    private static func peakRMS(of url: URL) throws -> Float {
        let file = try AVAudioFile(forReading: url)
        let window = AVAudioFrameCount(file.processingFormat.sampleRate / 10)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: window) else {
            return 0
        }
        var peak: Float = 0
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: window)
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { break }
            var sum: Float = 0
            for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
            peak = max(peak, (sum / Float(buffer.frameLength)).squareRoot())
        }
        return peak
    }
}
