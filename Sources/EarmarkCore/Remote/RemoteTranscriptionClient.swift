import CryptoKit
import Foundation

// Протокол v2: сервер расшифровки в LAN хранит звук каналов как задачу, расшифровывает сам и отдаёт
// сырые сегменты (server/, спека remote-v2-server).

public struct RemoteServerHealth: Codable, Equatable, Sendable {
    public var whisper: String
    public var commit: String
    public var model: String
    public var modelSha256: String
    public var vadSha256: String
    public var gpu: String

    public init(
        whisper: String, commit: String, model: String, modelSha256: String, vadSha256: String, gpu: String
    ) {
        self.whisper = whisper
        self.commit = commit
        self.model = model
        self.modelSha256 = modelSha256
        self.vadSha256 = vadSha256
        self.gpu = gpu
    }
}

public enum RemoteJobState: String, Codable, Sendable {
    case receiving, queued, running, done, failed
}

public enum RemoteAudioSource: String, Codable, Sendable {
    case stream, m4a
}

public struct RemoteJobSegment: Codable, Equatable, Sendable {
    public var startMs: Int
    public var endMs: Int
    public var text: String
    public var language: String

    public init(startMs: Int, endMs: Int, text: String, language: String) {
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.language = language
    }
}

public struct RemoteJob: Codable, Equatable, Sendable {
    public var state: RemoteJobState
    public var progress: Int
    public var lengths: [Int]
    public var languages: String?
    public var source: RemoteAudioSource
    public var error: String?
    /// Только у done.
    public var model: String?
    public var modelSha256: String?
    /// Только у done: [канал 0, канал 1].
    public var channels: [[RemoteJobSegment]]?

    public init(
        state: RemoteJobState, progress: Int, lengths: [Int], languages: String?, source: RemoteAudioSource,
        error: String?, model: String? = nil, modelSha256: String? = nil,
        channels: [[RemoteJobSegment]]? = nil
    ) {
        self.state = state
        self.progress = progress
        self.lengths = lengths
        self.languages = languages
        self.source = source
        self.error = error
        self.model = model
        self.modelSha256 = modelSha256
        self.channels = channels
    }
}

/// HTTP 409: задача не в том состоянии или длины/языки не совпали.
public struct RemoteConflict: Error, Equatable, Sendable {
    public var state: RemoteJobState
    public var lengths: [Int]
    public var languages: String?

    public init(state: RemoteJobState, lengths: [Int], languages: String?) {
        self.state = state
        self.lengths = lengths
        self.languages = languages
    }
}

/// HTTP-клиент сервера расшифровки. Ошибки: среда (транспорт, 3xx, 401, 5xx, 507, proof, совместимость)
/// — remoteFailed, exit 69, попытка не засчитана; прочие 4xx и кривой ответ — operationFailed.
public struct RemoteTranscriptionClient: Sendable {
    public struct Timeouts: Equatable, Sendable {
        /// Весь запрос /v2/health.
        public var health: TimeInterval
        /// Тишина (ни байта в обе стороны) на запросах задач.
        public var request: TimeInterval
        public static let standard = Timeouts(health: 5, request: 120)

        public init(health: TimeInterval, request: TimeInterval) {
            self.health = health
            self.request = request
        }
    }

    /// Коммит whisper.cpp, с которым доказан паритет (= b5130 = v1.9.4).
    public static let whisperCommit = "927cfce34f31707e17f2bff35c349632fb9e2c3a"

    public let baseURL: URL
    private let token: String
    private let timeouts: Timeouts

    public init(baseURL: URL, token: String, timeouts: Timeouts = .standard) {
        self.baseURL = baseURL
        self.token = token
        self.timeouts = timeouts
    }

    /// Без кэша и cookie. Редиректы не выполняются: наш сервер их не шлёт, а 307/308 переотправили бы
    /// Bearer и звук по чужому адресу. 3xx доходит до кода как не-200.
    private static let session = URLSession(
        configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest
        ) async -> URLRequest? { nil }
    }

    /// GET /v2/health?nonce=<свежие 32 случайных байта hex> без Authorization; proof сверяется (CryptoKit
    /// HMAC, за постоянное время) раньше остальных полей. Потом commit и vad_sha256; модель выбирает сервер.
    public func checkCompatible() async throws(EarmarkError) -> RemoteServerHealth {
        struct Signed: Decodable { let proof: String? }
        let nonce = SymmetricKey(size: .bits256).withUnsafeBytes {
            $0.map { String(format: "%02x", $0) }.joined()
        }
        let response = try await send(
            "GET", "v2/health", query: [URLQueryItem(name: "nonce", value: nonce)], authorized: false,
            limit: timeouts.health)
        // Любой не-200 (и 404 у сервера, ещё не говорящего v2) — нет proof: запись ждёт, попытка не тратится.
        guard response.status == 200 else {
            throw .remoteFailed("\(response.endpoint): \(Self.httpFailure(response.status, response.body))")
        }
        // Ответу, не доказавшему знание токена, не верим ни в чём: и мусор вместо JSON — тот же «чужой».
        guard
            let proof = (try? EarmarkJSON.decoder.decode(Signed.self, from: response.body))?.proof.flatMap(
                Self.unhex),
            HMAC<SHA256>.isValidAuthenticationCode(
                proof, authenticating: Data(nonce.utf8), using: SymmetricKey(data: Data(token.utf8)))
        else {
            throw .remoteFailed(
                "\(response.endpoint): server did not prove it knows the token (wrong server or token)")
        }
        let health = try decode(RemoteServerHealth.self, response)
        let mismatches = [
            ("commit", health.commit, Self.whisperCommit),
            ("vad_sha256", health.vadSha256, Models.sileroVAD.sha256),
        ].filter { $0.1 != $0.2 }.map { "\($0.0) \($0.1) != \($0.2)" }
        guard mismatches.isEmpty else {
            throw .remoteFailed(
                "\(baseURL.absoluteString): incompatible server: " + mismatches.joined(separator: ", "))
        }
        return health
    }

    /// nil — 404.
    public func job(_ id: String) async throws(EarmarkError) -> RemoteJob? {
        let response = try await send("GET", "v2/jobs/\(id)")
        switch response.status {
        case 200: return try decodeJob(response)
        case 404: return nil
        default: throw failure(response)
        }
    }

    /// .success(lengths) или .failure(RemoteConflict) на 409.
    public func upload(
        _ id: String, channel: Int, offset: Int, samples: ArraySlice<Float>, source: RemoteAudioSource
    ) async throws(EarmarkError) -> Result<[Int], RemoteConflict> {
        struct Lengths: Decodable { let lengths: [Int] }
        // Float в памяти мака (arm64, x86_64) — уже little-endian float32, как требует контракт.
        let body = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let response = try await send(
            "PUT", "v2/jobs/\(id)/channels/\(channel)",
            query: [
                URLQueryItem(name: "offset", value: String(offset)),
                URLQueryItem(name: "source", value: source.rawValue),
            ],
            body: body, contentType: "application/octet-stream")
        switch response.status {
        case 200: return .success(try decode(Lengths.self, response).lengths)
        case 409: return .failure(try conflict(response))
        default: throw failure(response)
        }
    }

    public func submit(_ id: String, languages: String, lengths: [Int]) async throws(EarmarkError)
        -> Result<RemoteJob, RemoteConflict>
    {
        struct Body: Encodable {
            let languages: String
            let lengths: [Int]
        }
        let body: Data
        do {
            body = try JSONEncoder().encode(Body(languages: languages, lengths: lengths))
        } catch {
            throw .operationFailed("submit: \(error.localizedDescription)")
        }
        let response = try await send(
            "POST", "v2/jobs/\(id)/submit", body: body, contentType: "application/json")
        switch response.status {
        case 200: return .success(try decodeJob(response))
        case 409: return .failure(try conflict(response))
        default: throw failure(response)
        }
    }

    /// 200 и 404 — успех.
    public func delete(_ id: String) async throws(EarmarkError) {
        let response = try await send("DELETE", "v2/jobs/\(id)")
        guard response.status == 200 || response.status == 404 else { throw failure(response) }
    }

    // MARK: - транспорт

    private struct Response {
        let endpoint: String
        let status: Int
        let body: Data
    }

    /// Причина сбоя без адреса: send допишет, какой запрос не удался.
    private struct Cause: Error {
        let text: String
        init(_ text: String) { self.text = text }
    }

    /// Один запрос: статус и тело (≤ maxBody; сверх — operationFailed, у health — remoteFailed). Тишину дольше `timeouts.request` режет сам URLSession;
    /// `limit` — срок на весь запрос (health). Отмена задачи вызывающего отменяет и запрос.
    private func send(
        _ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil,
        contentType: String? = nil, authorized: Bool = true, limit: TimeInterval? = nil
    ) async throws(EarmarkError) -> Response {
        let endpoint = baseURL.appending(path: path)
        let silence = limit ?? timeouts.request
        var request = URLRequest(
            url: query.isEmpty ? endpoint : endpoint.appending(queryItems: query), timeoutInterval: silence)
        request.httpMethod = method
        // health токен не несёт: сервер, ещё не доказавший знание токена, может оказаться чужим устройством.
        if authorized { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        request.httpBody = body
        let prepared = request
        do {
            let (status, data) = try await withThrowingTaskGroup(of: (Int, Data)?.self) { group in
                group.addTask {
                    let (bytes, response) = try await Self.session.bytes(for: prepared)
                    return ((response as? HTTPURLResponse)?.statusCode ?? 0, try await Self.collect(bytes))
                }
                if let limit {
                    group.addTask {
                        try await Task.sleep(for: .seconds(limit))
                        throw Cause("timed out after \(Self.seconds(limit)) s")
                    }
                }
                defer { group.cancelAll() }
                guard case let value?? = try await group.next() else { throw CancellationError() }
                return value
            }
            return Response(endpoint: endpoint.absoluteString, status: status, body: data)
        } catch let error as Cause where error.text == Self.tooLarge {
            // Без токена ходит только health: до proof отвечающий не доказал, что он наш сервер, — его
            // мусор значит среду (чужое устройство), а не дефект, и попытку не тратит.
            let text = "\(endpoint.absoluteString): \(error.text)"
            throw authorized ? .operationFailed(text) : .remoteFailed(text)
        } catch {
            throw .remoteFailed("\(endpoint.absoluteString): \(Self.describe(error, silence: silence))")
        }
    }

    /// /v2/jobs*: 3xx, 401, 507 и 5xx — среда (сервер выключен, чужой, без места, не тот токен); прочее — дефект.
    private func failure(_ response: Response) -> EarmarkError {
        let text = "\(response.endpoint): \(Self.httpFailure(response.status, response.body))"
        switch response.status {
        case 300..<400, 401, 507, 500...: return .remoteFailed(text)
        default: return .operationFailed(text)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ response: Response) throws(EarmarkError) -> T {
        guard let value = try? EarmarkJSON.decoder.decode(T.self, from: response.body) else {
            throw .operationFailed("\(response.endpoint): malformed response (HTTP \(response.status))")
        }
        return value
    }

    /// Каналы в ответе — `[{segments: [...]}, ...]`, в RemoteJob — `[[RemoteJobSegment]]`.
    private func decodeJob(_ response: Response) throws(EarmarkError) -> RemoteJob {
        struct Channel: Decodable { let segments: [RemoteJobSegment] }
        struct Wire: Decodable {
            let state: RemoteJobState
            let progress: Int
            let lengths: [Int]
            let languages: String?
            let source: RemoteAudioSource
            let error: String?
            let model: String?
            let modelSha256: String?
            let channels: [Channel]?
        }
        let wire = try decode(Wire.self, response)
        return RemoteJob(
            state: wire.state, progress: wire.progress, lengths: wire.lengths, languages: wire.languages,
            source: wire.source, error: wire.error, model: wire.model, modelSha256: wire.modelSha256,
            channels: wire.channels?.map(\.segments))
    }

    private func conflict(_ response: Response) throws(EarmarkError) -> RemoteConflict {
        struct Wire: Decodable {
            let state: RemoteJobState
            let lengths: [Int]
            let languages: String?
        }
        let wire = try decode(Wire.self, response)
        return RemoteConflict(state: wire.state, lengths: wire.lengths, languages: wire.languages)
    }

    private static func describe(_ error: any Error, silence: TimeInterval) -> String {
        if let error = error as? Cause { return error.text }
        if error is CancellationError { return "cancelled" }
        guard let error = error as? URLError else { return error.localizedDescription }
        return switch error.code {
        case .cancelled: "cancelled"
        case .timedOut: "timed out: no data for \(seconds(silence)) s"
        case .cannotConnectToHost: "connection refused or host unreachable"
        case .cannotFindHost, .dnsLookupFailed: "host not found"
        case .networkConnectionLost: "connection lost"
        default: "\(error.localizedDescription) (URLError \(error.code.rawValue))"
        }
    }

    /// "HTTP 409 offset mismatch": текст — поле error из JSON сервера, если он есть.
    private static func httpFailure(_ status: Int, _ body: Data) -> String {
        struct Failure: Decodable { let error: String }
        guard let failure = try? JSONDecoder().decode(Failure.self, from: body) else {
            return "HTTP \(status)"
        }
        return "HTTP \(status) \(failure.error)"
    }

    /// Ответы — килобайты, у done-задачи пятичасовой записи — единицы MB. Чужое устройство в сети,
    /// которое льёт бесконечное тело, не должно раздуть память app или воркера.
    private static let maxBody = 16 << 20
    private static let tooLarge = "response too large"

    private static func collect(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            guard data.count < maxBody else { throw Cause(tooLarge) }
            data.append(byte)
        }
        return data
    }

    /// Hex в любом регистре → байты; пусто, нечётная длина или не hex → nil.
    private static func unhex(_ text: String) -> Data? {
        let nibbles = text.map { $0.isASCII ? $0.hexDigitValue : nil }
        guard !nibbles.isEmpty, nibbles.count.isMultiple(of: 2) else { return nil }
        var bytes = Data()
        for index in stride(from: 0, to: nibbles.count, by: 2) {
            guard let high = nibbles[index], let low = nibbles[index + 1] else { return nil }
            bytes.append(UInt8(high << 4 | low))
        }
        return bytes
    }

    /// 600 → "600", 0.3 → "0.3".
    private static func seconds(_ value: TimeInterval) -> String { String(format: "%g", value) }
}

public enum RemoteTranscription {
    /// Начало сообщения воркера, который ждёт сервер (exit 69): по нему app ставит паузу бэклогу и
    /// remote_unreachable в status, а человек видит причину в meta.
    public static let waitingPrefix = "waiting for server: "

    /// nil — режим выключен; .failure — включён, но не настроен (нет url, нет/пустой/открытый токен).
    public static func client(config: Config, supportDir: URL) -> Result<
        RemoteTranscriptionClient, EarmarkError
    >? {
        guard config.remoteTranscriptionEnabled else { return nil }
        guard let url = config.remoteTranscriptionURL else {
            return .failure(.remoteFailed("transcription.remote.url is not set"))
        }
        let file = supportDir.appendingPathComponent(EarmarkPaths.remoteTokenName)
        // stat идёт по симлинку: проверяем права самого файла с токеном.
        var info = stat()
        guard stat(file.path, &info) == 0 else {
            return .failure(.remoteFailed("\(file.path) not found: put the server token there"))
        }
        guard info.st_mode & 0o077 == 0 else {
            return .failure(.remoteFailed("remote-token must be chmod 600: \(file.path)"))
        }
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let token = text.components(separatedBy: .newlines)[0].trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty else { return .failure(.remoteFailed("\(file.path) is empty")) }
        return .success(RemoteTranscriptionClient(baseURL: url, token: token))
    }
}

extension EarmarkPaths {
    static let remoteTokenName = "remote-token"
    public static var remoteTokenFile: URL { supportDir.appendingPathComponent(remoteTokenName) }
}

extension EarmarkError {
    /// Вытеснение (SIGTERM от app) или отмена. Не ошибка записи: попытка не засчитывается,
    /// а exit 75 значит для очереди «повтори позже».
    public static let interrupted = EarmarkError(
        code: "interrupted", message: "transcription interrupted (signal or cancellation)", exitCode: .busy)

    /// Сервер расшифровки недоступен или не тот: виновата среда, а не запись.
    public static func remoteFailed(_ message: String) -> EarmarkError {
        EarmarkError(code: "remote_failed", message: message, exitCode: .unavailable)
    }

    /// Сервер ответил с верным proof, но результата ещё нет (досчитывает или задача пропала): не
    /// недоступность, ждёт только эта запись.
    public static func remotePending(_ message: String) -> EarmarkError {
        EarmarkError(code: "remote_pending", message: message, exitCode: .unavailable)
    }
}
