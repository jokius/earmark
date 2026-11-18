import EarmarkCore
import Foundation
import os

/// Звук записи на сервер расшифровки, пока она идёт: раз в `interval` proof и дописанное из обоих CAF
/// (source=stream). Любая ошибка — стрим молча прекращается; запись он не трогает никогда.
///
/// Повторов нет: после стопа записи воркер дольёт недостающее из audio.m4a (шаг 4 RemoteAttempt).
/// Живёт в EarmarkAudio, а не в EarmarkTranscription: app линкует только Core и Audio, whisper в его
/// процесс не попадает (project.yml).
public actor LiveStream {
    /// Текст ошибки, остановившей стрим; nil — ошибок не было.
    public private(set) var failure: String?

    private let id: String
    private let files: [URL]
    private let server: RemoteTranscriptionClient
    private let interval: Duration
    /// Цикл тиков; его отмена прерывает и летящий запрос. true — finish дослал всё.
    private var worker: Task<Bool, Never>?
    /// Пауза между тиками отдельной задачей: finish будит цикл, не отменяя запросы самого worker.
    private var nap: Task<Void, Never>?
    private var finishing = false
    private var languages: String?
    /// cancel, ошибка или конец finish: ни одного нового запроса.
    private var stopped = false
    /// Сэмплов канала, принятых сервером: offset следующей порции.
    private var sent = [0, 0]
    /// Длины задачи из последнего ответа на PUT — для submit.
    private var lengths: [Int] = []

    private static let log = Logger(subsystem: EarmarkPaths.bundleID, category: "stream")

    public init(
        id: String, mic: URL, system: URL, server: RemoteTranscriptionClient, interval: Duration = .seconds(2)
    ) {
        self.id = id
        files = [mic, system]
        self.server = server
        self.interval = interval
    }

    /// Возвращается сразу, работа — в фоне.
    public func start() {
        guard worker == nil, !stopped else { return }
        worker = Task { await run() }
    }

    /// После закрытия CAF: дослать хвост и, если `languages` не nil, поставить задачу в очередь сервера.
    /// true — сервер получил весь звук (и submit прошёл, если просили).
    public func finish(languages: String?, deadline: Duration = .seconds(30)) async -> Bool {
        guard !finishing, !stopped else { return false }
        finishing = true
        self.languages = languages
        start()
        nap?.cancel()
        guard let worker else { return false }
        let timer = Task {
            try? await Task.sleep(for: deadline)
            if !Task.isCancelled { expire(deadline) }
        }
        defer { timer.cancel() }
        return await worker.value
    }

    /// Немедленно: после возврата стрим не начинает ни одного запроса.
    public func cancel() {
        stopped = true
        worker?.cancel()
        nap?.cancel()
    }

    /// Тики, пока жив; после finish — последний тик с хвостом и submit.
    private func run() async -> Bool {
        let tails: [CAFTail]
        do {
            tails = try files.map { try CAFTail(url: $0) }
        } catch {
            stop(error.localizedDescription)
            return false
        }
        while !stopped {
            let last = finishing
            guard await tick(tails, last: last) else { return false }
            if last {
                stopped = true
                return true
            }
            if finishing { continue }
            let nap = Task { _ = try? await Task.sleep(for: interval) }
            self.nap = nap
            await nap.value
            self.nap = nil
        }
        return false
    }

    /// proof, затем дописанное по каждому каналу по очереди (offset непрерывны). last — CAF закрыты:
    /// дочитать до конца, пустому каналу — пустой PUT (задача на сервере с длинами обоих), затем submit,
    /// если просили. false — стрим остановлен.
    private func tick(_ tails: [CAFTail], last: Bool) async -> Bool {
        do {
            try alive()
            // Mac мог сменить сеть: Bearer и звук — только серверу, который доказал токен в этом тике.
            _ = try await server.checkCompatible()
            for (channel, tail) in tails.enumerated() {
                let samples = last ? try tail.finish() : try tail.read()
                guard !samples.isEmpty || (last && sent[channel] == 0) else { continue }
                var start = 0
                repeat {
                    let end = min(start + RemoteTranscriptionClient.uploadChunk, samples.count)
                    try alive()
                    switch try await server.upload(
                        id, channel: channel, offset: sent[channel], samples: samples[start..<end],
                        source: .stream)
                    {
                    case .success(let now):
                        lengths = now
                    case .failure(let conflict):
                        throw EarmarkError.operationFailed(
                            "upload of channel \(channel) at \(sent[channel]) conflicts with the server job: "
                                + "\(conflict.state.rawValue), lengths \(conflict.lengths)")
                    }
                    sent[channel] += end - start
                    start = end
                } while start < samples.count
            }
            if last, let languages {
                try alive()
                if case .failure(let conflict) = try await server.submit(
                    id, languages: languages, lengths: lengths)
                {
                    throw EarmarkError.operationFailed(
                        "the server refused the job: \(conflict.state.rawValue), lengths \(conflict.lengths)")
                }
            }
            return true
        } catch {
            stop(error.localizedDescription)
            return false
        }
    }

    private func alive() throws {
        if stopped { throw CancellationError() }
    }

    /// Навсегда: дальше ни одного запроса, finish вернёт false.
    private func stop(_ reason: String) {
        if !stopped {
            failure = reason
            Self.log.error("stream of \(self.id, privacy: .public) stopped: \(reason, privacy: .public)")
        }
        stopped = true
    }

    private func expire(_ deadline: Duration) {
        guard !stopped else { return }
        stop("not finished within \(deadline)")
        worker?.cancel()
    }
}
