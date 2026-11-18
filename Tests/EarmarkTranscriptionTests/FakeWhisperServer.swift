import CryptoKit
import Darwin
import Foundation
import Synchronization
import Testing

@testable import EarmarkCore

/// Один разобранный HTTP-запрос к поддельному серверу.
struct FakeRequest: Sendable {
    var method: String
    var path: String
    var query: [String: String]
    /// Имена в нижнем регистре.
    var headers: [String: String]
    var body: Data
    /// Номер запроса в журнале сервера (порядок приёма).
    var index = 0

    /// Тип тела без параметров (`; charset=…`), в нижнем регистре; nil — заголовка нет.
    var mediaType: String? {
        headers["content-type"].map {
            String($0.split(separator: ";", omittingEmptySubsequences: false)[0])
                .trimmingCharacters(in: .whitespaces).lowercased()
        }
    }

    /// Тело как little-endian float32 — так клиент шлёт звук каналов.
    var floats: [Float] {
        var bits = [UInt32](repeating: 0, count: body.count / 4)
        _ = bits.withUnsafeMutableBytes { body.copyBytes(to: $0) }
        return bits.map { Float(bitPattern: UInt32(littleEndian: $0)) }
    }
}

/// Соединение с клиентом внутри обработчика. Каждое соединение живёт на своём потоке.
final class FakeConnection: Sendable {
    private let fd: Int32
    private let stopped: @Sendable () -> Bool

    fileprivate init(fd: Int32, stopped: @escaping @Sendable () -> Bool) {
        self.fd = fd
        self.stopped = stopped
    }

    @discardableResult
    func write(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                guard let base = raw.baseAddress else { return true }
                let written = Darwin.send(fd, base + sent, raw.count - sent, 0)
                if written <= 0 { return false }
                sent += written
            }
            return true
        }
    }

    @discardableResult
    func write(_ text: String) -> Bool { write(Data(text.utf8)) }

    /// Полный ответ с Content-Length. Connection: close — каждый запрос на своём соединении.
    func respond(_ status: Int, _ body: String, contentType: String = "application/json") {
        let data = Data(body.utf8)
        write(
            "HTTP/1.1 \(status) \(Self.reason(status))\r\nContent-Type: \(contentType)\r\n"
                + "Content-Length: \(data.count)\r\nConnection: close\r\n\r\n")
        write(data)
    }

    /// «Принял и молчит»: держит соединение, пока клиент его не закроет или тест не остановит сервер.
    func hang() {
        while !stopped(), !peerClosed(waitingMs: 50) { /* ждём закрытия */  }
    }

    private func peerClosed(waitingMs: Int32) -> Bool {
        var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&poller, 1, waitingMs) > 0 else { return false }
        var byte: UInt8 = 0
        let peeked = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        return peeked == 0 || (peeked < 0 && errno != EAGAIN && errno != EWOULDBLOCK)
    }

    private static let reasons = [
        200: "OK", 307: "Temporary Redirect", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
        404: "Not Found", 409: "Conflict", 413: "Content Too Large", 422: "Unprocessable Content",
        503: "Service Unavailable", 507: "Insufficient Storage",
    ]

    private static func reason(_ status: Int) -> String { reasons[status] ?? "Internal Server Error" }
}

/// Минимальный HTTP/1.1-сервер на 127.0.0.1 с эфемерным портом: настоящий TCP для настоящего
/// клиента. Свой экземпляр на каждый тест (Swift Testing гоняет их параллельно).
/// Каждый запрос записывается целиком до вызова обработчика.
final class FakeWhisperServer: Sendable {
    typealias Handler = @Sendable (FakeRequest, FakeConnection) -> Void

    let port: UInt16
    private let listener: Int32
    private let handler: Handler
    private let state = Mutex(State())

    private struct State {
        var requests: [FakeRequest] = []
        var stopped = false
    }

    // swiftlint:disable:next force_unwrapping
    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
    var requests: [FakeRequest] { state.withLock { $0.requests } }

    init(_ handler: @escaping Handler) throws {
        self.handler = handler
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        try #require(fd >= 0, "socket: \(errno)")
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try #require(bound == 0 && listen(fd, 64) == 0, "bind/listen: \(errno)")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        listener = fd
        port = UInt16(bigEndian: address.sin_port)
        Thread { [self] in acceptLoop() }.start()
    }

    /// Закрывает слушающий сокет; висящие обработчики выходят в течение ~50 мс.
    func stop() {
        state.withLock { $0.stopped = true }
    }

    private var isStopped: Bool { state.withLock { $0.stopped } }

    private func acceptLoop() {
        defer { close(listener) }
        while !isStopped {
            var poller = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, 50) > 0 else { continue }
            let client = accept(listener, nil, nil)
            guard client >= 0 else { continue }
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            Thread { [self] in serve(client) }.start()
        }
    }

    private func serve(_ fd: Int32) {
        defer {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
        let connection = FakeConnection(fd: fd) { [self] in isStopped }
        var reader = Reader(fd: fd, stopped: { [self] in isStopped })
        guard var request = reader.readHead() else { return }
        if request.headers["expect"]?.lowercased() == "100-continue" {
            connection.write("HTTP/1.1 100 Continue\r\n\r\n")
        }
        if let length = request.headers["content-length"].flatMap(Int.init) {
            guard let body = reader.read(count: length) else { return }
            request.body = body
        } else if request.headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            guard let body = reader.readChunked() else { return }
            request.body = body
        }
        state.withLock {
            request.index = $0.requests.count
            $0.requests.append(request)
        }
        handler(request, connection)
    }
}

/// Буферизованное чтение запроса с опросом флага остановки (poll по 50 мс).
private struct Reader {
    let fd: Int32
    let stopped: () -> Bool
    var buffer = Data()

    private mutating func fill() -> Bool {
        while !stopped() {
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, 50) > 0 else { continue }
            var chunk = [UInt8](repeating: 0, count: 65_536)
            let received = recv(fd, &chunk, chunk.count, 0)
            if received <= 0 { return false }
            buffer.append(contentsOf: chunk[0..<received])
            return true
        }
        return false
    }

    mutating func readLine() -> String? {
        while true {
            if let range = buffer.range(of: Data("\r\n".utf8)) {
                // swiftlint:disable:next optional_data_string_conversion
                let line = String(decoding: buffer[buffer.startIndex..<range.lowerBound], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                return line
            }
            guard fill() else { return nil }
        }
    }

    mutating func read(count: Int) -> Data? {
        while buffer.count < count {
            guard fill() else { return nil }
        }
        let data = Data(buffer.prefix(count))
        buffer.removeFirst(count)
        return data
    }

    mutating func readChunked() -> Data? {
        var body = Data()
        while true {
            guard let sizeLine = readLine(),
                let size = Int(sizeLine.split(separator: ";").first ?? "", radix: 16)
            else { return nil }
            if size == 0 {
                while let trailer = readLine(), !trailer.isEmpty { /* пропускаем трейлеры */  }
                return body
            }
            guard let data = read(count: size), readLine() != nil else { return nil }
            body.append(data)
        }
    }

    mutating func readHead() -> FakeRequest? {
        guard let requestLine = readLine() else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        while let line = readLine() {
            if line.isEmpty { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
        }
        let components = URLComponents(string: String(parts[1]))
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return FakeRequest(
            method: String(parts[0]), path: components?.path ?? String(parts[1]), query: query,
            headers: headers, body: Data())
    }
}

// MARK: - Протокол v2

/// Сегмент результата задачи на поддельном сервере (время от начала канала, мс).
struct FakeSegment: Sendable, Equatable {
    var startMs: Int
    var endMs: Int
    var text: String
    var language = "ru"
}

/// Задача на поддельном сервере v2: то, что отдаёт GET /v2/jobs/{id}, плюс принятый звук и сценарий.
struct FakeJob: Sendable {
    /// Шаг жизни задачи: каждый GET задачи в queued/running применяет следующий шаг до ответа.
    enum Step: Sendable, Equatable {
        /// Ещё в очереди.
        case queued
        case running(Int)
        case done
        case failed(String)
        /// Задача пропала с сервера: этот GET уже отвечает 404.
        case vanish
    }

    var state: String
    var progress = 0
    var lengths: [Int] = [0, 0]
    /// Принятые PUT сэмплы каналов (у посеянной без звука задачи — пусто, длины — только в lengths).
    var samples: [[Float]] = [[], []]
    var languages: String?
    var source = "m4a"
    var error: String?
    /// Сегменты каналов [mic, system], которые задача отдаст в done.
    var result: [[FakeSegment]] = [[], []]
    /// Что будет с задачей на следующих GET; submit кладёт сюда FakeJobServer.Settings.afterSubmit.
    var steps: [Step] = []

    mutating func advance() {
        guard state == "queued" || state == "running", !steps.isEmpty else { return }
        switch steps.removeFirst() {
        case .queued:
            state = "queued"
        case .running(let percent):
            state = "running"
            progress = percent
        case .done:
            state = "done"
            progress = 100
        case .failed(let message):
            state = "failed"
            error = message
        case .vanish:
            state = "vanished"
        }
    }
}

/// Поддельный earmark-whisper-server по контракту v2: задачи в памяти, их состояния, 404/409/401,
/// сбои по сценарию и журнал запросов. Проверяет Bearer на /v2/jobs* так же, как настоящий.
final class FakeJobServer: Sendable {
    enum Endpoint: Sendable, Hashable { case health, job, upload, submit, delete }

    /// Ответ по сценарию вместо обычной обработки: следующий запрос к эндпоинту получает его.
    enum Scripted: Sendable {
        /// Ответ с этим кодом и телом как есть.
        case status(Int, String)
        /// 409 с состоянием задачи после правки (задачи нет — она создаётся в receiving, как при PUT).
        /// Второй аргумент — канал запроса PUT (у остальных эндпоинтов -1).
        case conflict(@Sendable (inout FakeJob, Int) -> Void)
        /// Сырой HTTP-ответ целиком (редирект и т. п.).
        case raw(String)
        /// Принял запрос и молчит.
        case hang
        /// Закрыл соединение, ничего не ответив.
        case drop

        /// 409 по задаче как она есть.
        static let conflictAsIs = Scripted.conflict { _, _ in /* задача как есть */ }
    }

    struct Settings: Sendable {
        var proof = FakeWhisper.Proof.valid
        var commit = RemoteTranscriptionClient.whisperCommit
        var vadSha256 = Models.sileroVAD.sha256
        /// Имя файла модели, как его отдаёт настоящий сервер.
        var model = "ggml-large-v3-turbo.bin"
        var modelSha256 = Models.largeV3Turbo.sha256
        /// Шаги задачи после submit: по умолчанию первый же GET видит done.
        var afterSubmit: [FakeJob.Step] = [.done]
        /// Результат, который получит задача, поставленная submit.
        var result: [[FakeSegment]] = [[], []]
    }

    private let book: JobBook
    private let http: FakeWhisperServer

    init(_ configure: (inout Settings) -> Void = { _ in /* настройки по умолчанию */ }) throws {
        let book = JobBook()
        book.state.withLock { configure(&$0.settings) }
        self.book = book
        http = try FakeWhisperServer { request, connection in book.handle(request, connection) }
    }

    var baseURL: URL { http.baseURL }
    func stop() { http.stop() }
    var requests: [FakeRequest] { http.requests }

    /// Журнал коротко: health, get, put<канал>@<offset>, submit, delete.
    var calls: [String] { requests.map(Self.describe) }

    func configure(_ change: (inout Settings) -> Void) { book.state.withLock { change(&$0.settings) } }
    func job(_ id: String) -> FakeJob? { book.state.withLock { $0.jobs[id] } }
    /// Задача как есть или, если её уже удалили, — какой она была перед последним DELETE.
    func lastSeen(_ id: String) -> FakeJob? { book.state.withLock { $0.jobs[id] ?? $0.deleted[id] } }
    func seed(_ id: String, _ job: FakeJob) { book.state.withLock { $0.jobs[id] = job } }
    func update(_ id: String, _ change: (inout FakeJob) -> Void) {
        book.state.withLock { state in
            guard var job = state.jobs[id] else { return }
            change(&job)
            state.jobs[id] = job
        }
    }

    /// Следующие запросы к эндпоинту получат эти ответы по очереди, затем — обычная обработка.
    func script(_ endpoint: Endpoint, _ replies: Scripted...) {
        book.state.withLock { $0.scripts[endpoint, default: []].append(contentsOf: replies) }
    }

    /// Номера в `calls` запросов, получивших ответ по сценарию, в порядке ответа: запросы параллельны,
    /// и «следующий к эндпоинту» по журналу не всегда тот, кому достался сценарий.
    var scriptedAt: [Int] { book.state.withLock { $0.scriptedAt } }

    /// PUT канала по порядку.
    func uploads(channel: Int) -> [FakeRequest] {
        requests.filter { JobBook.route($0)?.endpoint == .upload && JobBook.route($0)?.channel == channel }
    }

    /// Тела submit по порядку.
    var submits: [(languages: String, lengths: [Int])] {
        requests.filter { JobBook.route($0)?.endpoint == .submit }.compactMap { request in
            guard let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                let languages = body["languages"] as? String, let lengths = body["lengths"] as? [Int]
            else { return nil }
            return (languages: languages, lengths: lengths)
        }
    }

    static func describe(_ request: FakeRequest) -> String {
        guard let route = JobBook.route(request) else { return "\(request.method) \(request.path)" }
        switch route.endpoint {
        case .health: return "health"
        case .job: return "get"
        case .upload: return "put\(route.channel ?? -1)@\(request.query["offset"] ?? "?")"
        case .submit: return "submit"
        case .delete: return "delete"
        }
    }
}

/// Состояние и логика поддельного сервера; отдельный класс — чтобы обработчик HTTP не держал self.
private final class JobBook: Sendable {
    struct State {
        var settings = FakeJobServer.Settings()
        var jobs: [String: FakeJob] = [:]
        var deleted: [String: FakeJob] = [:]
        var scripts: [FakeJobServer.Endpoint: [FakeJobServer.Scripted]] = [:]
        var scriptedAt: [Int] = []
    }

    struct Route {
        var endpoint: FakeJobServer.Endpoint
        var id = ""
        var channel: Int?
    }

    enum Reply: Sendable {
        case respond(Int, String)
        case raw(String)
        case hang
        case drop
    }

    let state = Mutex(State())

    static func route(_ request: FakeRequest) -> Route? {
        let parts = request.path.split(separator: "/").map(String.init)
        guard parts.count >= 2, parts[0] == "v2" else { return nil }
        if parts.count == 2, parts[1] == "health", request.method == "GET" { return Route(endpoint: .health) }
        guard parts[1] == "jobs", parts.count >= 3 else { return nil }
        let id = parts[2]
        switch (request.method, parts.count) {
        case ("GET", 3): return Route(endpoint: .job, id: id)
        case ("DELETE", 3): return Route(endpoint: .delete, id: id)
        case ("POST", 4) where parts[3] == "submit": return Route(endpoint: .submit, id: id)
        case ("PUT", 5) where parts[3] == "channels":
            return Route(endpoint: .upload, id: id, channel: Int(parts[4]) ?? -1)
        default: return nil
        }
    }

    func handle(_ request: FakeRequest, _ connection: FakeConnection) {
        let reply: Reply = state.withLock { state in
            guard let route = Self.route(request) else { return .respond(404, Self.error("not found")) }
            if let scripted = state.scripts[route.endpoint]?.first {
                state.scripts[route.endpoint]?.removeFirst()
                state.scriptedAt.append(request.index)
                return Self.play(scripted, route, &state)
            }
            return Self.serve(request, route, &state)
        }
        switch reply {
        case .respond(let status, let body): connection.respond(status, body)
        case .raw(let text): connection.write(text)
        case .hang: connection.hang()
        case .drop: break
        }
    }

    private static func play(_ scripted: FakeJobServer.Scripted, _ route: Route, _ state: inout State)
        -> Reply
    {
        switch scripted {
        case .status(let status, let body): return .respond(status, body)
        case .raw(let text): return .raw(text)
        case .hang: return .hang
        case .drop: return .drop
        case .conflict(let change):
            var job = state.jobs[route.id] ?? FakeJob(state: "receiving")
            change(&job, route.channel ?? -1)
            state.jobs[route.id] = job
            return .respond(409, conflict(job))
        }
    }

    private static func serve(_ request: FakeRequest, _ route: Route, _ state: inout State) -> Reply {
        if route.endpoint == .health { return health(request, state.settings) }
        guard request.headers["authorization"] == "Bearer \(FakeWhisper.token)" else {
            return .respond(401, error("unauthorized"))
        }
        guard route.id.wholeMatch(of: /[0-9a-z-]{1,64}/) != nil else { return .respond(400, error("bad id")) }
        switch route.endpoint {
        case .health: return health(request, state.settings)
        case .job: return job(route, &state)
        case .upload: return upload(request, route, &state)
        case .submit: return submit(request, route, &state)
        case .delete:
            guard let job = state.jobs.removeValue(forKey: route.id) else {
                return .respond(404, error("no such job"))
            }
            state.deleted[route.id] = job
            return .respond(200, "{}")
        }
    }

    private static func job(_ route: Route, _ state: inout State) -> Reply {
        guard var job = state.jobs[route.id] else { return .respond(404, error("no such job")) }
        job.advance()
        guard job.state != "vanished" else {
            state.jobs.removeValue(forKey: route.id)
            return .respond(404, error("no such job"))
        }
        state.jobs[route.id] = job
        return .respond(200, body(job, state.settings))
    }

    private static func upload(_ request: FakeRequest, _ route: Route, _ state: inout State) -> Reply {
        guard let channel = route.channel, (0...1).contains(channel),
            let offset = request.query["offset"].flatMap(Int.init), offset >= 0, request.body.count % 4 == 0
        else { return .respond(400, error("bad upload")) }
        var job =
            state.jobs[route.id] ?? FakeJob(state: "receiving", source: request.query["source"] ?? "m4a")
        if job.state == "receiving", job.lengths == [0, 0], offset == 0, let source = request.query["source"]
        {
            job.source = source
        }
        state.jobs[route.id] = job
        guard job.state == "receiving", offset == job.lengths[channel] else {
            return .respond(409, conflict(job))
        }
        let samples = request.floats
        job.samples[channel] += samples
        job.lengths[channel] += samples.count
        state.jobs[route.id] = job
        return .respond(200, json(["lengths": job.lengths]))
    }

    private static func submit(_ request: FakeRequest, _ route: Route, _ state: inout State) -> Reply {
        guard var job = state.jobs[route.id] else { return .respond(404, error("no such job")) }
        guard let fields = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
            let languages = fields["languages"] as? String, let lengths = fields["lengths"] as? [Int],
            lengths.count == 2
        else { return .respond(400, error("bad submit")) }
        switch job.state {
        case "receiving", "failed":
            guard lengths == job.lengths else { return .respond(409, conflict(job)) }
            job.state = "queued"
            job.progress = 0
            job.error = nil
            job.languages = languages
            job.steps = state.settings.afterSubmit
            job.result = state.settings.result
        default:
            guard lengths == job.lengths, languages == job.languages else {
                return .respond(409, conflict(job))
            }
        }
        state.jobs[route.id] = job
        return .respond(200, body(job, state.settings))
    }

    private static func health(_ request: FakeRequest, _ settings: FakeJobServer.Settings) -> Reply {
        guard request.body.isEmpty else { return .respond(401, error("unauthorized")) }
        let nonce = request.query["nonce"] ?? ""
        guard nonce.wholeMatch(of: /[0-9a-fA-F]{64}/) != nil else {
            return .respond(400, error("nonce must be 64 hex characters"))
        }
        var fields: [String: Any] = [
            "whisper": "1.9.4", "commit": settings.commit, "model": settings.model,
            "model_sha256": settings.modelSha256, "vad_sha256": settings.vadSha256, "gpu": "Test GPU 24 GB",
        ]
        switch settings.proof {
        case .valid: fields["proof"] = FakeWhisper.hmac(nonce)
        case .replayed: fields["proof"] = FakeWhisper.hmac(String(repeating: "ab", count: 32))
        case .otherToken: fields["proof"] = FakeWhisper.hmac(nonce, key: "someone-elses-token")
        case .missing: break
        case .empty: fields["proof"] = ""
        }
        return .respond(200, json(fields))
    }

    static func body(_ job: FakeJob, _ settings: FakeJobServer.Settings) -> String {
        var fields: [String: Any] = [
            "state": job.state, "progress": job.progress, "lengths": job.lengths,
            "languages": nullable(job.languages), "source": job.source, "error": nullable(job.error),
        ]
        if job.state == "done" {
            fields["model"] = settings.model
            fields["model_sha256"] = settings.modelSha256
            fields["channels"] = job.result.map { channel in
                [
                    "segments": channel.map {
                        [
                            "start_ms": $0.startMs, "end_ms": $0.endMs, "text": $0.text,
                            "language": $0.language,
                        ]
                    }
                ]
            }
        }
        return json(fields)
    }

    static func conflict(_ job: FakeJob) -> String {
        json([
            "error": "conflict", "state": job.state, "lengths": job.lengths,
            "languages": nullable(job.languages),
        ])
    }

    static func error(_ text: String) -> String { json(["error": text]) }

    private static func nullable(_ value: String?) -> Any {
        if let value { return value }
        return NSNull()
    }

    static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

/// Клиент и общие вещи для тестов удалённого сервера.
enum FakeWhisper {
    static let token = "test-token-0123"

    /// Короткие таймауты: зависания в тестах укладываются в 1–3 с.
    static let fast = RemoteTranscriptionClient.Timeouts(health: 1, request: 1)

    static func client(
        _ server: FakeJobServer, token: String = token, timeouts: RemoteTranscriptionClient.Timeouts = fast
    ) -> RemoteTranscriptionClient {
        RemoteTranscriptionClient(baseURL: server.baseURL, token: token, timeouts: timeouts)
    }

    /// Что сервер кладёт в поле proof ответа /v2/health.
    enum Proof: Sendable, CaseIterable {
        /// HMAC-SHA256(токен, nonce этого запроса) — сервер знает токен.
        case valid
        /// Proof чужого рукопожатия: тот же токен, другой nonce (записали и проигрывают).
        case replayed
        /// Nonce этого запроса, но другой токен.
        case otherToken
        /// Поля proof нет.
        case missing
        /// proof — пустая строка.
        case empty

        /// Всё, что не доказывает знание токена.
        static let forged: [Proof] = [.replayed, .otherToken, .missing, .empty]
    }

    /// Lowercase hex HMAC-SHA256(key: байты ключа в UTF-8, message: байты строки nonce как пришла).
    static func hmac(_ nonce: String, key: String = token) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(nonce.utf8), using: SymmetricKey(data: Data(key.utf8)))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// Порт, на котором точно никто не слушает: забронировать и сразу закрыть. Держать привязанный сокет без
    /// listen нельзя: macOS молча роняет SYN на такой порт, и connect висит до таймаута вместо refused.
    static func deadURL() throws -> URL {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try #require(bound == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        // swiftlint:disable:next force_unwrapping
        return URL(string: "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))")!
    }

    /// Редирект на тот же путь у другого сервера.
    static func redirect(to target: URL, path: String) -> FakeJobServer.Scripted {
        .raw(
            "HTTP/1.1 307 Temporary Redirect\r\nLocation: \(target.absoluteString)\(path)\r\n"
                + "Content-Length: 0\r\nConnection: close\r\n\r\n")
    }
}

/// Little-endian float32 байты — эталон тела PUT.
func littleEndianBytes(_ samples: some Collection<Float>) -> Data {
    var data = Data(capacity: samples.count * 4)
    for sample in samples {
        let bits = sample.bitPattern.littleEndian
        withUnsafeBytes(of: bits) { data.append(contentsOf: $0) }
    }
    return data
}

/// Флаг «пора отменить», который тест взводит из другого потока; помнит, когда взведён.
final class AbortFlag: Sendable {
    private let moment = Mutex<Date?>(nil)
    func raise() { moment.withLock { $0 = $0 ?? Date() } }
    var isRaised: Bool { raisedAt != nil }
    var raisedAt: Date? { moment.withLock { $0 } }

    /// Взводится сам через `seconds`.
    static func after(_ seconds: TimeInterval) -> AbortFlag {
        after(seconds, once: { true })
    }

    /// Взводится через `seconds` после того, как `condition` стало истинным (опрос раз в 10 мс, не дольше 30 с).
    static func after(_ seconds: TimeInterval, once condition: @escaping @Sendable () -> Bool) -> AbortFlag {
        let flag = AbortFlag()
        Thread {
            let deadline = Date().addingTimeInterval(30)
            while !condition() {
                guard Date() < deadline else { return }
                Thread.sleep(forTimeInterval: 0.01)
            }
            Thread.sleep(forTimeInterval: seconds)
            flag.raise()
        }.start()
        return flag
    }
}
