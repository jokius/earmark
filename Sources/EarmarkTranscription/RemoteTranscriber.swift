import EarmarkCore
import Foundation

/// Сколько воркер ждёт сервер после submit: опрос раз в poll, не дольше limit, потом exit 69.
public struct RemoteWait: Equatable, Sendable {
    public var poll: Duration
    public var limit: Duration
    public static let standard = RemoteWait(poll: .seconds(3), limit: .seconds(30))

    public init(poll: Duration, limit: Duration) {
        self.poll = poll
        self.limit = limit
    }
}

extension Transcriber {
    /// Удалённый путь (протокол v2): whisper на маке не создаётся ни в одной ветке. run(folder:force:
    /// progress:shouldAbort:) — тот же метод, что у локального пути, с тем же контрактом meta/lock/ошибок.
    public init(
        store: RecordingStore, config: Config, server: RemoteTranscriptionClient, wait: RemoteWait = .standard
    ) {
        self.init(
            store: store, config: config,
            makeEngine: { () async throws(EarmarkError) -> any SpeechEngine in
                throw .operationFailed("local whisper is never used in remote transcription")
            },
            remote: (server, wait))
    }
}

/// Одна попытка удалённого пути для одной записи; задача на сервере — с id записи. Любой сбой среды
/// уходит наверх с префиксом "waiting for server: ": в meta и status видно, что запись ждёт сервер.
struct RemoteAttempt: Sendable {
    let id: String
    let language: String
    let server: RemoteTranscriptionClient
    let shouldAbort: @Sendable () -> Bool

    /// Кусок загрузки: 8 Mi сэмплов = 32 MiB, вдвое меньше лимита тела у сервера.
    static let uploadChunk = 8_388_608
    /// Задача сервера — та же запись, если длины каналов расходятся с audio.m4a не больше чем на 1 с
    /// (стрим пишет из CAF, а m4a — их сведение с ресемплом).
    static let lengthTolerance = 16_000
    static let waitingPrefix = RemoteTranscription.waitingPrefix

    /// proof → (--force: удалить задачу; без него — готовые файлы каналов этого сервера) → задача сервера
    /// (взять готовую, докачать или залить заново и поставить) → ждать → сегменты каналов в
    /// transcript.<ch>.json. reused — каналы взяты из файлов, задачу на сервере не трогали.
    func transcribe(
        _ folder: URL, meta: RecordingMeta, force: Bool, wait: RemoteWait,
        progress: @escaping @Sendable (TranscribeProgress) -> Void
    ) async throws(EarmarkError) -> (
        channels: (mic: ChannelTranscript, system: ChannelTranscript), reused: Bool
    ) {
        do throws(EarmarkError) {
            // Сначала proof: Bearer не уходит серверу, который не доказал, что знает токен, — и DELETE тоже.
            let health = try await call { [server] in try await server.checkCompatible() }
            if force {
                try await call { [server, id] in try await server.delete(id) }
            } else if let channels = reused(folder, health: health) {
                return (channels, true)
            }
            let (submitted, failure) = try await prepare(folder)
            let job: RemoteJob
            do throws(EarmarkError) {
                job = try await result(of: submitted, wait: wait, progress: progress)
            } catch {
                // Упавшую на сервере задачу поставили снова — прогон засчитан, даже если сервер её не досчитал
                // или пропал: иначе задача, роняющая сервер, крутилась бы вечно, а не ушла в transcription_failed.
                guard let failure, error.exitCode == ExitCode.unavailable.rawValue else { throw error }
                throw .operationFailed("transcription failed on the server: \(failure)")
            }
            return (try channelTranscripts(job, meta: meta, health: health, folder: folder), false)
        } catch {
            guard error.exitCode == ExitCode.unavailable.rawValue,
                !error.message.hasPrefix(Self.waitingPrefix)
            else { throw error }
            throw EarmarkError(
                code: error.code, message: Self.waitingPrefix + error.message, exitCode: .unavailable)
        }
    }

    /// Оба файла каналов, уже посчитанные этим сервером (модель, sha, параметры) на языке записи, — как
    /// у локального пути: повторный прогон не льёт звук и не считает заново.
    private func reused(_ folder: URL, health: RemoteServerHealth)
        -> (mic: ChannelTranscript, system: ChannelTranscript)?
    {
        let fingerprint = Self.fingerprint(model: health.model, sha256: health.modelSha256)
        guard
            let mic = Transcriber.reusable(
                folder.appending(path: RecordingFiles.transcriptMic), fingerprint: fingerprint,
                language: language),
            let system = Transcriber.reusable(
                folder.appending(path: RecordingFiles.transcriptSystem), fingerprint: fingerprint,
                language: language)
        else { return nil }
        return (mic, system)
    }

    /// Задача сервера, которую можно ждать, и текст её сбоя на сервере, если её пришлось поставить снова
    /// (такой прогон засчитан). Готовую (queued/running/done) с теми же языками и длинами берём как есть;
    /// failed — ставим снова; receiving из m4a докачиваем; остальное (нет задачи, стрим, другие языки или
    /// длины после склейки и смены проекта) — удалить и залить оба канала из m4a заново.
    private func prepare(_ folder: URL) async throws(EarmarkError) -> (job: RemoteJob, failure: String?) {
        let audio = folder.appending(path: RecordingFiles.audio)
        // Сверка — по заголовку m4a, без декода: прогон, который только ждёт сервер (раз в минуту), должен
        // стоить маку миллисекунды, а не декод многочасовой записи.
        let length = try Transcriber.length(audio)
        let existing = try await call { [server, id] in try await server.job(id) }
        if let job = existing, job.languages == language, job.lengths.count == 2,
            job.lengths.allSatisfy({ abs($0 - length) <= Self.lengthTolerance })
        {
            switch job.state {
            case .queued, .running, .done:
                return (job, nil)
            case .failed:
                let failure = job.error ?? "no details"
                return (
                    try await submit(lengths: job.lengths, audio: audio, samples: nil, reupload: true),
                    failure
                )
            case .receiving:
                break
            }
        }
        let samples = try decode(audio)
        var from = [0, 0]
        if let job = existing {
            if job.state == .receiving, job.source == .m4a, job.lengths.count == 2,
                zip(job.lengths, samples).allSatisfy({ $0 <= $1.count })
            {
                from = job.lengths
            } else {
                try await call { [server, id] in try await server.delete(id) }
            }
        }
        let job = try await submit(
            lengths: try await upload(samples, from: from), audio: audio, samples: samples, reupload: true)
        return (job, nil)
    }

    /// Оба канала 16 kHz — полный декод m4a, только когда звук действительно надо загрузить.
    private func decode(_ audio: URL) throws(EarmarkError) -> [[Float]] {
        // ponytail: оба канала в памяти разом (5 ч — 2.3 GB, как у локального пути модель + канал);
        // по каналу за раз, если станет тесно.
        var samples: [[Float]] = []
        for channel in 0..<2 {
            if shouldAbort() { throw .interrupted }
            samples.append(try Transcriber.extract(audio, channel: channel))
        }
        if shouldAbort() { throw .interrupted }
        return samples
    }

    /// submit; 409 (задачу тем временем поменяли) — один раз удалить и залить заново, второй — дефект.
    /// samples nil — каналы ещё не декодированы: декод нужен, только если дошло до перезаливки.
    private func submit(lengths: [Int], audio: URL, samples: [[Float]]?, reupload: Bool)
        async throws(EarmarkError) -> RemoteJob
    {
        let outcome = try await call { [server, id, language] in
            try await server.submit(id, languages: language, lengths: lengths)
        }
        switch outcome {
        case .success(let job):
            return job
        case .failure(let conflict):
            guard reupload else {
                throw .operationFailed(
                    "the server refused the job twice: \(conflict.state.rawValue), lengths \(conflict.lengths), "
                        + "languages \(conflict.languages ?? "none")")
            }
            let channels: [[Float]]
            if let samples { channels = samples } else { channels = try decode(audio) }
            try await call { [server, id] in try await server.delete(id) }
            return try await submit(
                lengths: try await upload(channels, from: [0, 0]), audio: audio, samples: channels,
                reupload: false)
        }
    }

    /// Каналы с позиции `from` кусками ≤ uploadChunk, source m4a. Каждый канал — хотя бы одним PUT: первый
    /// создаёт задачу и при пустом канале. 409 — один раз продолжить канал с длины сервера (receiving),
    /// второй — дефект. Возвращает длины на сервере.
    private func upload(_ samples: [[Float]], from start: [Int]) async throws(EarmarkError) -> [Int] {
        var lengths = start
        var retried = false
        for (channel, audio) in samples.enumerated() {
            var offset = start[channel]
            repeat {
                let end = min(offset + Self.uploadChunk, audio.count)
                let at = offset
                let chunk = audio[at..<end]
                let outcome = try await call { [server, id] in
                    try await server.upload(id, channel: channel, offset: at, samples: chunk, source: .m4a)
                }
                switch outcome {
                case .success(let now):
                    lengths = now
                    offset = end
                case .failure(let conflict):
                    guard !retried, conflict.state == .receiving, conflict.lengths.count == 2,
                        conflict.lengths[channel] <= audio.count
                    else {
                        throw .operationFailed(
                            "upload of channel \(channel) conflicts with the server job: "
                                + "\(conflict.state.rawValue), lengths \(conflict.lengths)")
                    }
                    retried = true
                    lengths = conflict.lengths
                    offset = conflict.lengths[channel]
                }
            } while offset < audio.count
        }
        return lengths
    }

    /// Опрос раз в poll, не дольше limit; прогресс сервера — как прогресс mic. Не done за limit — exit 69:
    /// очередь вернётся через минуту и найдёт ту же задачу. failed — засчитанная ошибка.
    private func result(
        of submitted: RemoteJob, wait: RemoteWait, progress: @escaping @Sendable (TranscribeProgress) -> Void
    ) async throws(EarmarkError) -> RemoteJob {
        let deadline = ContinuousClock.now + wait.limit
        var job = submitted
        while true {
            switch job.state {
            case .done:
                return job
            case .failed:
                throw .operationFailed("transcription failed on the server: \(job.error ?? "no details")")
            case .receiving, .queued, .running:
                break
            }
            progress(TranscribeProgress(channel: .mic, percent: job.progress))
            let left = deadline - ContinuousClock.now
            guard left > .zero else {
                throw .remotePending(Self.waitingPrefix + "\(job.state.rawValue) \(job.progress)%")
            }
            let pause = min(wait.poll, left)
            try await call { try? await Task.sleep(for: pause) }
            guard let next = try await call({ [server, id] in try await server.job(id) }) else {
                throw .remotePending(Self.waitingPrefix + "the job disappeared from the server")
            }
            job = next
        }
    }

    /// Сегменты done-задачи → transcript.<ch>.json, как у локального пути. Звук из стрима шёл из CAF до
    /// сведения: сдвиг между каналами — как у StereoMuxer (> 0 — mic позже, < 0 — system позже).
    private func channelTranscripts(
        _ job: RemoteJob, meta: RecordingMeta, health: RemoteServerHealth, folder: URL
    ) throws(EarmarkError) -> (mic: ChannelTranscript, system: ChannelTranscript) {
        guard let channels = job.channels, channels.count == 2 else {
            throw .operationFailed("the server returned a done job without two channels")
        }
        let model = Self.modelName(job.model ?? health.model)
        let fingerprint = Self.fingerprint(
            model: job.model ?? health.model, sha256: job.modelSha256 ?? health.modelSha256)
        let offset = job.source == .stream ? meta.audio?.micOffsetMs ?? 0 : 0
        // Язык у сегмента — только при списке языков, как у локального движка.
        var perSegment = false
        if case .multi? = TranscriptionLanguage(language) { perSegment = true }
        var result: [ChannelTranscript] = []
        for (index, channel) in [Channel.mic, .system].enumerated() {
            let shift = channel == .mic ? max(offset, 0) : max(-offset, 0)
            let raw = channels[index].map { segment in
                RawSegment(
                    startMs: segment.startMs + shift, endMs: segment.endMs + shift, text: segment.text,
                    language: perSegment ? segment.language : nil)
            }
            let transcript = ChannelTranscript(
                channel: channel, model: model, language: language, fingerprint: fingerprint,
                segments: PostFilter.apply(raw))
            let file = channel == .mic ? RecordingFiles.transcriptMic : RecordingFiles.transcriptSystem
            try Transcriber.writeJSON(transcript, to: folder.appending(path: file))
            result.append(transcript)
        }
        return (result[0], result[1])
    }

    /// fingerprint транскрипта и файлов каналов: модель сервера ("ggml-x.bin" → "x"), начало её sha, параметры.
    static func fingerprint(model: String, sha256: String) -> String {
        "remote|" + modelName(model) + "|" + String(sha256.prefix(12)) + "|" + WhisperParams.version
    }

    /// "ggml-large-v3-turbo.bin" → "large-v3-turbo".
    static func modelName(_ file: String) -> String {
        var name = file
        if name.hasPrefix("ggml-") { name.removeFirst("ggml-".count) }
        if name.hasSuffix(".bin") { name.removeLast(".bin".count) }
        return name
    }

    /// Запрос к серверу (или пауза), который прерывается по shouldAbort: сторож раз в 50 мс, true —
    /// запрос отменяется (URLSession закрывает соединение) и бросается interrupted. body бросает
    /// EarmarkError; throws нетипизированный, только чтобы замыкания писались без аннотаций.
    private func call<T: Sendable>(_ body: @escaping @Sendable () async throws -> T)
        async throws(EarmarkError) -> T
    {
        if shouldAbort() { throw .interrupted }
        do {
            return try await withThrowingTaskGroup(of: T?.self) { [shouldAbort] group in
                group.addTask { try await body() }
                group.addTask {
                    while !shouldAbort() { try await Task.sleep(for: .milliseconds(50)) }
                    throw EarmarkError.interrupted
                }
                defer { group.cancelAll() }
                // Первым заканчивается запрос — результатом или ошибкой — либо сторож, всегда ошибкой.
                guard case let value?? = try await group.next() else { throw CancellationError() }
                return value
            }
        } catch {
            // Отмена, совпавшая с любым другим сбоем (соединение закрыто и т.п.), — всё равно отмена.
            if shouldAbort() { throw .interrupted }
            if let error = error as? EarmarkError { throw error }
            throw .remoteFailed("cancelled")
        }
    }
}
