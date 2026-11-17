import CryptoKit
import Foundation
import Synchronization

/// Ответ /v1/health сервера whisper на своей машине в LAN (server/).
public struct RemoteWhisperHealth: Codable, Equatable, Sendable {
    public var whisper: String
    public var commit: String
    public var modelSha256: String
    public var vadSha256: String
    public var gpu: String

    public init(whisper: String, commit: String, modelSha256: String, vadSha256: String, gpu: String) {
        self.whisper = whisper
        self.commit = commit
        self.modelSha256 = modelSha256
        self.vadSha256 = vadSha256
        self.gpu = gpu
    }
}

/// Отрезок речи от VAD: сырые сантисекунды whisper (Float).
public struct RemoteVADSpan: Equatable, Sendable {
    public var t0: Float
    public var t1: Float

    public init(t0: Float, t1: Float) {
        self.t0 = t0
        self.t1 = t1
    }
}

/// Сегмент whisper_full: сантисекунды и сырой текст.
public struct RemoteSegment: Equatable, Sendable {
    public var t0: Int64
    public var t1: Int64
    public var text: String

    public init(t0: Int64, t1: Int64, text: String) {
        self.t0 = t0
        self.t1 = t1
        self.text = text
    }
}

extension RemoteSegment: Decodable {}

/// HTTP-клиент сервера whisper (контракт v1, спека remote-whisper). Примитивы whisper — VAD, язык куска,
/// whisper_full; оркестрация списка языков остаётся на маке. Любой сбой — remoteFailed с причиной,
/// отмена через shouldAbort — interrupted.
public struct RemoteWhisperClient: Sendable {
    public struct Timeouts: Equatable, Sendable {
        /// Весь запрос /v1/health.
        public var health: TimeInterval
        /// Тишина (ни байта в обе стороны) на /v1/vad и /v1/language.
        public var request: TimeInterval
        /// Тишина в потоке /v1/full, включая отправку тела и ожидание заголовков.
        public var idle: TimeInterval
        /// /v1/full: прогресс стоит столько, хотя heartbeat идёт.
        public var stall: TimeInterval

        public static let standard = Timeouts(health: 5, request: 120, idle: 30, stall: 600)

        public init(health: TimeInterval, request: TimeInterval, idle: TimeInterval, stall: TimeInterval) {
            self.health = health
            self.request = request
            self.idle = idle
            self.stall = stall
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

    /// Без кэша и cookie; таймаут у каждого запроса свой. Редиректы не выполняются: наш сервер их не шлёт,
    /// а 307/308 переотправили бы Bearer и звук по чужому адресу. 3xx доходит до кода как не-200.
    private static let session = URLSession(
        configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest
        ) async -> URLRequest? { nil }
    }

    /// GET /v1/health?nonce=<свежие 32 случайных байта hex> без Authorization; proof сверяется (CryptoKit HMAC,
    /// за постоянное время). Нет proof / не совпал → remoteFailed с причиной "server did not prove it knows the
    /// token (wrong server or token)". Токен в этом запросе не уходит никак.
    public func health() async throws(EarmarkError) -> RemoteWhisperHealth {
        struct Signed: Decodable { let proof: String? }
        let nonce = SymmetricKey(size: .bits256).withUnsafeBytes {
            $0.map { String(format: "%02x", $0) }.joined()
        }
        let limit = timeouts.health
        let deadline = ContinuousClock.now + .seconds(limit)
        return try await send(
            "v1/health", query: [URLQueryItem(name: "nonce", value: nonce)], silence: limit,
            watch: {
                if ContinuousClock.now >= deadline { throw Cause("timed out after \(Self.seconds(limit)) s") }
            },
            read: { [token] bytes in
                let data = try await Self.collect(bytes)
                // Сначала proof: остальным полям ответа, не доказавшего знание токена, не верим.
                guard let proof = try Self.decode(Signed.self, data).proof.flatMap(Self.unhex),
                    HMAC<SHA256>.isValidAuthenticationCode(
                        proof, authenticating: Data(nonce.utf8), using: SymmetricKey(data: Data(token.utf8)))
                else {
                    throw Cause("server did not prove it knows the token (wrong server or token)")
                }
                return try Self.decode(RemoteWhisperHealth.self, data)
            })
    }

    /// health + сверка: commit == whisperCommit, model_sha256 == Models.largeV3Turbo.sha256,
    /// vad_sha256 == Models.sileroVAD.sha256. Несовпадение → ошибка с текстом, что именно не сошлось.
    public func checkCompatible() async throws(EarmarkError) -> RemoteWhisperHealth {
        let health = try await health()
        let mismatches = [
            ("commit", health.commit, Self.whisperCommit),
            ("model_sha256", health.modelSha256, Models.largeV3Turbo.sha256),
            ("vad_sha256", health.vadSha256, Models.sileroVAD.sha256),
        ].filter { $0.1 != $0.2 }.map { "\($0.0) \($0.1) != \($0.2)" }
        guard mismatches.isEmpty else {
            throw .remoteFailed(
                "\(baseURL.absoluteString): incompatible server: " + mismatches.joined(separator: ", "))
        }
        return health
    }

    /// shouldAbort — как у full: опрос не реже раза в 200 мс всё время запроса, включая отправку тела;
    /// true → запрос отменяется, бросается interrupted.
    public func vad(
        _ samples: ArraySlice<Float>, threads: Int32, shouldAbort: @escaping @Sendable () -> Bool = { false }
    ) async throws(EarmarkError) -> [RemoteVADSpan] {
        struct Response: Decodable { let spans: [[Double]] }
        return try await send(
            "v1/vad", query: [Self.threads(threads)], body: samples, silence: timeouts.request,
            shouldAbort: shouldAbort,
            read: { bytes in
                // Double, а не Float: число — кратчайшая запись double, в который сервер расширил float,
                // и обратное сужение даёт ровно исходный float.
                try Self.decode(Response.self, try await Self.collect(bytes)).spans.map { pair in
                    guard pair.count == 2 else { throw Cause("malformed response: a VAD span is not a pair") }
                    return RemoteVADSpan(t0: Float(pair[0]), t1: Float(pair[1]))
                }
            })
    }

    public func language(
        _ samples: ArraySlice<Float>, threads: Int32, shouldAbort: @escaping @Sendable () -> Bool = { false }
    ) async throws(EarmarkError) -> [String: Float] {
        struct Response: Decodable { let probs: [String: Double] }
        return try await send(
            "v1/language", query: [Self.threads(threads)], body: samples, silence: timeouts.request,
            shouldAbort: shouldAbort,
            read: { bytes in
                try Self.decode(Response.self, try await Self.collect(bytes)).probs.mapValues { Float($0) }
            })
    }

    /// progress — только при смене значения. shouldAbort опрашивается не реже раза в 200 мс всё время
    /// запроса (включая отправку тела); true → запрос отменяется, бросается EarmarkError.interrupted.
    public func full(
        _ samples: ArraySlice<Float>, language: String, threads: Int32,
        progress: @escaping @Sendable (Int) -> Void, shouldAbort: @escaping @Sendable () -> Bool
    ) async throws(EarmarkError) -> [RemoteSegment] {
        struct Line: Decodable {
            let progress: Int?
            let segments: [RemoteSegment]?
            let error: String?
        }
        let watch = ProgressWatch()
        let stall = timeouts.stall
        return try await send(
            "v1/full", query: [URLQueryItem(name: "language", value: language), Self.threads(threads)],
            body: samples, silence: timeouts.idle, shouldAbort: shouldAbort,
            watch: {
                if watch.stalled(for: stall) {
                    throw Cause("stalled: no progress for \(Self.seconds(stall)) s")
                }
            },
            read: { bytes in
                watch.start()
                for try await line in bytes.lines where !line.allSatisfy(\.isWhitespace) {
                    // Текст строки в ошибку не кладём: там может быть расшифровка, а ошибка уходит в лог.
                    guard let message = try? EarmarkJSON.decoder.decode(Line.self, from: Data(line.utf8))
                    else {
                        throw Cause("malformed stream line")
                    }
                    if let error = message.error { throw Cause("server error: \(error)") }
                    if let segments = message.segments { return segments }
                    guard let percent = message.progress else {
                        throw Cause("malformed stream line: no progress, segments or error")
                    }
                    if watch.update(percent) { progress(percent) }
                }
                throw Cause("stream ended without a result")
            })
    }

    // MARK: - транспорт

    /// Причина сбоя без адреса: send допишет, какой запрос не удался.
    private struct Cause: Error {
        let text: String
        init(_ text: String) { self.text = text }
    }

    /// Один запрос. Тишину (ни байта в обе стороны, включая отправку тела) дольше `silence` режет сам
    /// URLSession. Сторож раз в 50 мс спрашивает `shouldAbort` (true → interrupted) и зовёт `watch`
    /// (общий срок, застой); бросил — группа отменяет запрос, URLSession закрывает соединение.
    /// Любая другая отмена (задачу вызывающего отменили) — remoteFailed: пусть сработает фолбэк.
    private func send<T: Sendable>(
        _ path: String, query: [URLQueryItem], body: ArraySlice<Float>? = nil, silence: TimeInterval,
        shouldAbort: @escaping @Sendable () -> Bool = { false },
        watch: @escaping @Sendable () throws -> Void = { /* кроме shouldAbort сторожить нечего */  },
        read: @escaping @Sendable (URLSession.AsyncBytes) async throws -> T
    ) async throws(EarmarkError) -> T {
        let endpoint = baseURL.appending(path: path)
        var draft = URLRequest(url: endpoint.appending(queryItems: query), timeoutInterval: silence)
        if let body {
            // Токен — только вместе с аудио (vad, language, full); health его не несёт: сервер, ещё не
            // доказавший знание токена, может оказаться чужим устройством под тем же именем.
            draft.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            draft.httpMethod = "POST"
            draft.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            // Float в памяти мака (arm64, x86_64) — уже little-endian float32, как требует контракт.
            // ponytail: тело копируется целиком (5 ч канала — 1.15 GB); httpBodyStream, если станет тесно.
            draft.httpBody = body.withUnsafeBufferPointer { Data(buffer: $0) }
        }
        let request = draft
        do {
            return try await withThrowingTaskGroup(of: T?.self) { group in
                group.addTask {
                    let (bytes, response) = try await Self.session.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else {
                        throw Cause(Self.httpFailure(status, try await Self.collect(bytes)))
                    }
                    return try await read(bytes)
                }
                group.addTask {
                    while true {
                        try await Task.sleep(for: .milliseconds(50))
                        if shouldAbort() { throw EarmarkError.interrupted }
                        try watch()
                    }
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
            throw .remoteFailed("\(endpoint.absoluteString): \(Self.describe(error, silence: silence))")
        }
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

    /// "HTTP 401 unauthorized": текст — поле error из JSON сервера, если он есть.
    private static func httpFailure(_ status: Int, _ body: Data) -> String {
        struct Failure: Decodable { let error: String }
        guard let failure = try? JSONDecoder().decode(Failure.self, from: body) else {
            return "HTTP \(status)"
        }
        return "HTTP \(status) \(failure.error)"
    }

    /// Ответы без потока — килобайты (спаны VAD 5-часового канала — сотни KB). Чужое устройство в сети,
    /// которое на health льёт бесконечное тело, не должно раздуть память app или воркера.
    private static let maxBody = 16 << 20

    private static func collect(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            guard data.count < maxBody else { throw Cause("response too large") }
            data.append(byte)
        }
        return data
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        guard let value = try? EarmarkJSON.decoder.decode(T.self, from: data) else {
            throw Cause("malformed response")
        }
        return value
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

    private static func threads(_ threads: Int32) -> URLQueryItem {
        URLQueryItem(name: "threads", value: String(threads))
    }

    /// 600 → "600", 0.3 → "0.3".
    private static func seconds(_ value: TimeInterval) -> String { String(format: "%g", value) }
}

/// Последний процент /v1/full и когда он сменился. До заголовков ответа часы стоят: отправку тела
/// и ожидание ответа сторожит idle, а не stall.
private final class ProgressWatch: Sendable {
    private let state = Mutex<(percent: Int?, since: ContinuousClock.Instant?)>((nil, nil))

    func start() { state.withLock { $0.since = ContinuousClock.now } }

    /// true — значение сменилось.
    func update(_ percent: Int) -> Bool {
        state.withLock { state in
            guard state.percent != percent else { return false }
            state = (percent, ContinuousClock.now)
            return true
        }
    }

    func stalled(for limit: TimeInterval) -> Bool {
        state.withLock { state in
            guard let since = state.since else { return false }
            return ContinuousClock.now - since >= .seconds(limit)
        }
    }
}

public enum RemoteTranscription {
    /// nil — режим выключен; .failure — включён, но не настроен (нет url, нет/пустой/открытый токен).
    public static func client(config: Config, supportDir: URL) -> Result<RemoteWhisperClient, EarmarkError>? {
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
        return .success(RemoteWhisperClient(baseURL: url, token: token))
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

    /// Любой сбой удалённого сервера whisper: виновата среда, а не запись.
    public static func remoteFailed(_ message: String) -> EarmarkError {
        EarmarkError(code: "remote_failed", message: message, exitCode: .unavailable)
    }
}
