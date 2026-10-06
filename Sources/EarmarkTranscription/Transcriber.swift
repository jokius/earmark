import EarmarkAudio
import EarmarkCore
import Foundation

/// Одна задача транскрипции записи (§8.3): lock → meta → каналы → слияние → файлы → meta.
///
/// Очередь — это сами папки записей: состояние в meta.json, а живость задачи — во flock на
/// <папка>/.transcribe.lock. Ядро снимает lock со смертью процесса, поэтому `transcribing` при
/// свободном lock'е — протухшая задача, и pid для этого не нужен.
public struct Transcriber: Sendable {
    typealias EngineFactory = @Sendable () async throws(EarmarkError) -> any SpeechEngine

    /// После стольких засчитанных неудач запись уходит в transcription_failed (§7.3).
    static let maxAttempts = 3
    /// Версия whisper.cpp + начало sha модели + версия параметров. Совпал — готовый канал
    /// не пересчитываем; сменилось хоть что-то — пересчитываем.
    static let fingerprint =
        "whisper-b5130|" + String(Models.largeV3Turbo.sha256.prefix(12)) + "|" + WhisperParams.version

    private let store: RecordingStore
    private let config: Config
    private let makeEngine: EngineFactory

    public init(store: RecordingStore, modelPath: URL, vadModelPath: URL, config: Config) {
        self.init(store: store, config: config) { () async throws(EarmarkError) -> any SpeechEngine in
            // Загрузка модели блокирует 1–2 с, а первый запуск нового бинаря ещё ~20 с компилирует
            // шейдеры Metal — не в кооперативном пуле.
            try await DedicatedThread.run("whisper load") { () throws(EarmarkError) -> WhisperEngine in
                try WhisperEngine(modelPath: modelPath, vadModelPath: vadModelPath)
            }
        }
    }

    init(store: RecordingStore, config: Config, makeEngine: @escaping EngineFactory) {
        self.store = store
        self.config = config
        self.makeEngine = makeEngine
    }

    /// Lock → meta(transcribing, attempts++) → каналы → PostFilter → merge → transcript.json/txt
    /// → meta(transcribed).
    ///
    /// Ошибки: busy — lock у другого процесса (meta не тронута); unavailable — нет модели/VAD
    /// (попытка возвращается); interrupted — SIGTERM или вытеснение (попытка возвращается);
    /// bad_data — аудио не читается (сразу transcription_failed); остальное — operation_failed
    /// (transcription_failed после maxAttempts засчитанных неудач, раньше — обратно в recorded).
    public func run(
        folder: URL, force: Bool, progress: @escaping @Sendable (TranscribeProgress) -> Void,
        shouldAbort: @escaping @Sendable () -> Bool
    ) async throws(EarmarkError) -> Transcript {
        guard let lock = try Self.tryLock(folder) else {
            throw .busy("another process is already transcribing this recording")
        }
        defer { lock.release() }
        let before = try claim(folder, force: force)
        do throws(EarmarkError) {
            let channels = try await transcribeChannels(
                folder, force: force, progress: progress, shouldAbort: shouldAbort)
            if shouldAbort() { throw .interrupted }
            let transcript = Transcript(
                recordingId: before.id, model: Models.largeV3Turbo.name,
                language: config.transcriptionLanguage,
                segments: TranscriptMerge.merge(mic: channels.mic, system: channels.system))
            try publish(transcript, in: folder)
            try update(folder) { meta in
                meta.status = .transcribed
                meta.transcription.attempts = 0
                meta.transcription.error = nil
                meta.transcription.errorKind = nil
            }
            return transcript
        } catch {
            // Отмену и настоящую ошибку разом отдаём как отмену: незасчитанная попытка и exit 75
            // должны совпадать, поэтому флаг читаем один раз.
            let failure = shouldAbort() ? EarmarkError.interrupted : error
            recordFailure(failure, in: folder, restoring: before)
            throw failure
        }
    }

    // MARK: - шаги

    private static func tryLock(_ folder: URL) throws(EarmarkError) -> FileLock? {
        do {
            return try FileLock.tryAcquire(at: folder.appending(path: RecordingFiles.transcribeLock))
        } catch {
            throw .operationFailed("\(RecordingFiles.transcribeLock): \(error.localizedDescription)")
        }
    }

    /// Захват задачи: attempts++ сразу, так крэш посреди работы засчитается без лишнего кода.
    /// Возвращает meta до захвата: незасчитанная попытка возвращает из неё статус и блок transcription.
    private func claim(_ folder: URL, force: Bool) throws(EarmarkError) -> RecordingMeta {
        guard let meta = try readMeta(folder) else {
            throw .notFound("\(folder.lastPathComponent) has no meta.json: the recording is not finished")
        }
        if !force && meta.transcription.attempts >= Self.maxAttempts {
            // Сюда приходят задачи, трижды оборвавшиеся крэшем (abort в ggml): без этой проверки
            // очередь гоняла бы их по кругу, каждый раз поднимая 1.6 GB модели.
            try update(folder) { meta in
                meta.status = .transcriptionFailed
                meta.transcription.errorKind = meta.transcription.errorKind ?? "retryable"
                meta.transcription.error =
                    meta.transcription.error ?? "the worker died \(Self.maxAttempts) times in a row"
            }
            throw .operationFailed(
                "attempts exhausted (\(meta.transcription.attempts)); "
                    + "retry with: earmark transcribe \(meta.id) --force")
        }
        try update(folder) { meta in
            if force {
                meta.transcription.attempts = 0
                meta.transcription.error = nil
                meta.transcription.errorKind = nil
            }
            meta.status = .transcribing
            meta.transcription.attempts += 1
            meta.transcription.fingerprint = Self.fingerprint
            meta.transcription.language = config.transcriptionLanguage
        }
        return meta
    }

    /// Каналы по очереди: 0 — mic, 1 — system. Готовый канал с тем же fingerprint и языком не
    /// пересчитываем (воркер мог упасть на втором канале). Язык в fingerprint не входит (D4), поэтому
    /// сверяем его отдельно: иначе после смены языка в конфиге старый канал выдавался бы за новый язык.
    /// Модель грузим, только если хоть один канал нужно
    /// считать, и отпускаем вместе с этой функцией — до слияния.
    private func transcribeChannels(
        _ folder: URL, force: Bool, progress: @escaping @Sendable (TranscribeProgress) -> Void,
        shouldAbort: @escaping @Sendable () -> Bool
    ) async throws(EarmarkError) -> (mic: ChannelTranscript, system: ChannelTranscript) {
        var engine: (any SpeechEngine)?
        var done: [Channel: ChannelTranscript] = [:]
        for (index, channel) in [Channel.mic, .system].enumerated() {
            let url = folder.appending(
                path: channel == .mic ? RecordingFiles.transcriptMic : RecordingFiles.transcriptSystem)
            if !force, let existing = try? Self.decode(ChannelTranscript.self, at: url),
                existing.fingerprint == Self.fingerprint, existing.language == config.transcriptionLanguage
            {
                done[channel] = existing
                continue
            }
            if shouldAbort() { throw .interrupted }
            // Декод раньше загрузки модели: битое аудио отсекаем, не поднимая 1.6 GB.
            let samples = try Self.extract(folder.appending(path: RecordingFiles.audio), channel: index)
            // Декод многочасовой записи и холодная компиляция Metal идут десятки секунд без abort:
            // флаг проверяем после каждого из них, а не только внутри whisper_full.
            if shouldAbort() { throw .interrupted }
            let active: any SpeechEngine
            if let engine {
                active = engine
            } else {
                active = try await makeEngine()
                engine = active
                if shouldAbort() { throw .interrupted }
            }
            let raw = try await active.transcribe(
                samples, params: .reference(language: config.transcriptionLanguage),
                progress: { progress(TranscribeProgress(channel: channel, percent: $0)) },
                shouldAbort: shouldAbort)
            let result = ChannelTranscript(
                channel: channel, model: Models.largeV3Turbo.name, language: config.transcriptionLanguage,
                fingerprint: Self.fingerprint, segments: PostFilter.apply(raw))
            try Self.writeJSON(result, to: url)
            done[channel] = result
        }
        guard let mic = done[.mic], let system = done[.system] else {
            throw .operationFailed("transcript channels are missing")
        }
        return (mic, system)
    }

    /// txt раньше json: потребители считают появление transcript.json сигналом «готово» (§7.3),
    /// и к этому моменту txt уже должен лежать рядом.
    private func publish(_ transcript: Transcript, in folder: URL) throws(EarmarkError) {
        let text = TranscriptRender.text(transcript, labelMe: config.labelMe, labelThem: config.labelThem)
        try Self.writeData(Data(text.utf8), to: folder.appending(path: RecordingFiles.transcriptText))
        try Self.writeJSON(transcript, to: folder.appending(path: RecordingFiles.transcript))
    }

    /// Сколько стоила неудача: вытеснение и environmental — ничего (статус и весь блок transcription —
    /// как до захвата, будто попытки не было: прерванный --force-повтор transcription_failed не должен
    /// стать recorded с обнулёнными attempts, иначе очередь молча возьмёт его снова; файлы каналов,
    /// записанные за попытку, остаются — их переиспользование проверяется по каждому файлу);
    /// остальное засчитано. Битое аудио (permanent) повтор не починит — сразу transcription_failed;
    /// сбой whisper (retryable) — после maxAttempts. Пишем best effort: если не вышло, meta останется
    /// `transcribing` при свободном lock'е — очередь сочтёт задачу протухшей.
    private func recordFailure(_ error: EarmarkError, in folder: URL, restoring previous: RecordingMeta) {
        let environmental = error.exitCode == ExitCode.unavailable.rawValue
        let notCounted = error.code == EarmarkError.interrupted.code || environmental
        let permanent = error.exitCode == ExitCode.badData.rawValue
        _ = try? store.updateMeta(in: folder) { meta in
            if notCounted {
                meta.transcription = previous.transcription
                meta.status = previous.status
                if environmental {
                    meta.transcription.errorKind = "environmental"
                    meta.transcription.error = error.message
                }
                return
            }
            meta.transcription.errorKind = permanent ? "permanent" : "retryable"
            meta.transcription.error = error.message
            let exhausted = meta.transcription.attempts >= Self.maxAttempts
            meta.status = permanent || exhausted ? .transcriptionFailed : .recorded
        }
    }

    // MARK: - ввод-вывод с типизированными ошибками

    /// Любая ошибка декода — EarmarkAudioError или NSError от AVAudioFile — значит битое аудио: bad_data.
    /// Текст — localizedDescription: у EarmarkAudioError английский errorDescription (Task 9, D21).
    private static func extract(_ audio: URL, channel: Int) throws(EarmarkError) -> [Float] {
        do {
            return try ChannelExtractor.extract(from: audio, channel: channel)
        } catch {
            let reason = error.localizedDescription
            throw .badData("\(audio.lastPathComponent) is unreadable (channel \(channel)): \(reason)")
        }
    }

    private func readMeta(_ folder: URL) throws(EarmarkError) -> RecordingMeta? {
        do { return try store.readMeta(in: folder) } catch {
            throw .badData("meta.json: \(error.localizedDescription)")
        }
    }

    @discardableResult
    private func update(_ folder: URL, _ body: (inout RecordingMeta) -> Void) throws(EarmarkError)
        -> RecordingMeta
    {
        do {
            return try store.updateMeta(in: folder, body)
        } catch {
            throw .operationFailed("meta.json: \(error.localizedDescription)")
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
        try EarmarkJSON.decoder.decode(T.self, from: Data(contentsOf: url))
    }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws(EarmarkError) {
        let data: Data
        do {
            data = try EarmarkJSON.encoder.encode(value)
        } catch {
            throw .operationFailed("\(url.lastPathComponent): \(error.localizedDescription)")
        }
        try writeData(data, to: url)
    }

    private static func writeData(_ data: Data, to url: URL) throws(EarmarkError) {
        do {
            try AtomicFile.write(data, to: url)
        } catch {
            throw .operationFailed("\(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
