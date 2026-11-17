import CryptoKit
import Darwin
import EarmarkCore
import Foundation
import Synchronization
import Testing

/// Один разобранный HTTP-запрос к поддельному серверу.
struct FakeRequest: Sendable {
    var method: String
    var path: String
    var query: [String: String]
    /// Имена в нижнем регистре.
    var headers: [String: String]
    var body: Data

    /// Тело как little-endian float32 — так его шлёт клиент по контракту v1.
    var floats: [Float] {
        var bits = [UInt32](repeating: 0, count: body.count / 4)
        _ = bits.withUnsafeMutableBytes { body.copyBytes(to: $0) }
        return bits.map { Float(bitPattern: UInt32(littleEndian: $0)) }
    }
}

/// Соединение с клиентом внутри обработчика. Каждое соединение живёт на своём потоке,
/// поэтому обработчик может спать между строками потока, не трогая пул Swift Concurrency.
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

    /// Заголовки потокового ответа /v1/full: NDJSON, chunked.
    func startStream() {
        write(
            "HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nTransfer-Encoding: chunked\r\n"
                + "Connection: close\r\n\r\n")
    }

    /// Одна строка NDJSON отдельным chunk'ом.
    @discardableResult
    func line(_ json: String) -> Bool { chunk(json + "\n") }

    @discardableResult
    func chunk(_ text: String) -> Bool {
        let data = Data(text.utf8)
        return write(String(data.count, radix: 16) + "\r\n") && write(data) && write("\r\n")
    }

    func endStream() { write("0\r\n\r\n") }

    /// Ждёт, пока клиент закроет соединение. true — закрыл за отведённое время.
    func waitForPeerClose(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !stopped() {
            if peerClosed(waitingMs: 50) { return true }
        }
        return false
    }

    /// «Принял и молчит»: держит соединение, пока клиент его не закроет или тест не остановит сервер.
    func hang() {
        while !stopped(), !peerClosed(waitingMs: 50) { /* ждём закрытия */  }
    }

    /// Пауза между строками потока; true — клиент за это время закрыл соединение.
    func pause(_ seconds: TimeInterval) -> Bool {
        waitForPeerClose(timeout: seconds)
    }

    private func peerClosed(waitingMs: Int32) -> Bool {
        var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&poller, 1, waitingMs) > 0 else { return false }
        var byte: UInt8 = 0
        let peeked = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        return peeked == 0 || (peeked < 0 && errno != EAGAIN && errno != EWOULDBLOCK)
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 413: "Content Too Large"
        default: "Internal Server Error"
        }
    }
}

/// Минимальный HTTP/1.1-сервер на 127.0.0.1 с эфемерным портом: настоящий TCP для настоящего
/// RemoteWhisperClient. Свой экземпляр на каждый тест (Swift Testing гоняет их параллельно).
/// Каждый запрос записывается целиком до вызова обработчика.
final class FakeWhisperServer: Sendable {
    typealias Handler = @Sendable (FakeRequest, FakeConnection) -> Void

    let port: UInt16
    private let listener: Int32
    private let handler: Handler
    /// false — тело запроса не читается вовсе: клиент упирается в буфер сокета на отправке.
    private let readsBody: Bool
    private let state = Mutex(State())

    private struct State {
        var requests: [FakeRequest] = []
        var stopped = false
    }

    // swiftlint:disable:next force_unwrapping
    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
    var requests: [FakeRequest] { state.withLock { $0.requests } }
    func requests(_ path: String) -> [FakeRequest] { requests.filter { $0.path == path } }
    var paths: [String] { requests.map(\.path) }

    init(readsBody: Bool = true, _ handler: @escaping Handler) throws {
        self.handler = handler
        self.readsBody = readsBody
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
        guard let head = reader.readHead() else { return }
        var request = head
        if readsBody {
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
        }
        state.withLock { $0.requests.append(request) }
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

/// Сценарии поддельного whisper-сервера по контракту v1.
enum FakeWhisper {
    static let token = "test-token-0123"

    /// Короткие таймауты: зависания и застои в тестах укладываются в 1–3 с.
    static let fast = RemoteWhisperClient.Timeouts(health: 1, request: 1, idle: 1, stall: 1.5)

    static func client(_ server: FakeWhisperServer, timeouts: RemoteWhisperClient.Timeouts = fast)
        -> RemoteWhisperClient
    {
        RemoteWhisperClient(baseURL: server.baseURL, token: token, timeouts: timeouts)
    }

    /// Что сервер кладёт в поле proof рукопожатия /v1/health.
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

    /// Ответ /v1/health на этот запрос. Proof считается по nonce из query (нет nonce — по пустой строке:
    /// формат nonce проверяют тесты клиента, а не фейк).
    static func health(
        for request: FakeRequest, proof: Proof = .valid, commit: String = RemoteWhisperClient.whisperCommit,
        model: String = Models.largeV3Turbo.sha256, vad: String = Models.sileroVAD.sha256,
        gpu: String = "Test GPU 24 GB"
    ) -> String {
        let nonce = request.query["nonce"] ?? ""
        let value: String? =
            switch proof {
            case .valid: hmac(nonce)
            case .replayed: hmac(String(repeating: "ab", count: 32))
            case .otherToken: hmac(nonce, key: "someone-elses-token")
            case .missing: nil
            case .empty: ""
            }
        let field = value.map { #","proof":"\#($0)""# } ?? ""
        return #"{"whisper":"1.9.4","commit":"\#(commit)","model_sha256":"\#(model)","vad_sha256":"\#(vad)","#
            + #""gpu":"\#(gpu)"\#(field)}"#
    }

    /// Число так, как его печатает nlohmann для float, приведённого к double: кратчайшее round-trip.
    static func number(_ value: Float) -> String { "\(Double(value))" }

    static func spans(_ pairs: [(Float, Float)]) -> String {
        #"{"spans":["# + pairs.map { "[\(number($0.0)),\(number($0.1))]" }.joined(separator: ",") + "]}"
    }

    static func probs(_ map: [String: Float]) -> String {
        #"{"probs":{"# + map.map { #""\#($0.key)":\#(number($0.value))"# }.joined(separator: ",") + "}}"
    }

    // swiftlint:disable:next large_tuple
    static func segments(_ items: [(Int64, Int64, String)]) -> String {
        let encoded = items.map { item -> String in
            let text =
                (try? JSONEncoder().encode(item.2)).flatMap { String(bytes: $0, encoding: .utf8) } ?? #""""#
            return #"{"t0":\#(item.0),"t1":\#(item.1),"text":\#(text)}"#
        }
        return #"{"segments":["# + encoded.joined(separator: ",") + "]}"
    }

    /// Обычный /v1/full: прогресс 0 → 50 → 100, затем строка с сегментами.
    static func stream(_ connection: FakeConnection, segments final: String) {
        connection.startStream()
        for percent in [0, 50, 100] {
            connection.line(#"{"progress":\#(percent)}"#)
        }
        connection.line(final)
        connection.endStream()
    }

    /// Совместимый сервер, доказывающий знание токена: health по умолчанию, остальное — из замыканий.
    static func server(
        health: @escaping @Sendable (FakeRequest) -> String = { health(for: $0) },
        vad: @escaping @Sendable (FakeRequest) -> String = { _ in #"{"spans":[]}"# },
        language: @escaping @Sendable (FakeRequest) -> String = { _ in #"{"probs":{}}"# },
        full: @escaping @Sendable (FakeRequest) -> String = { _ in #"{"segments":[]}"# }
    ) throws -> FakeWhisperServer {
        try FakeWhisperServer { request, connection in
            switch request.path {
            case "/v1/health": connection.respond(200, health(request))
            case "/v1/vad": connection.respond(200, vad(request))
            case "/v1/language": connection.respond(200, language(request))
            case "/v1/full": stream(connection, segments: full(request))
            default: connection.respond(404, #"{"error":"not found"}"#)
            }
        }
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
}

/// Little-endian float32 байты — эталон тела запроса.
func littleEndianBytes(_ samples: some Collection<Float>) -> Data {
    var data = Data(capacity: samples.count * 4)
    for sample in samples {
        let bits = sample.bitPattern.littleEndian
        withUnsafeBytes(of: bits) { data.append(contentsOf: $0) }
    }
    return data
}

/// Флаг «пора отменить», который тест взводит из другого потока.
final class AbortFlag: Sendable {
    private let value = Mutex(false)
    func raise() { value.withLock { $0 = true } }
    var isRaised: Bool { value.withLock { $0 } }

    /// Взводится сам через `seconds`.
    static func after(_ seconds: TimeInterval) -> AbortFlag {
        let flag = AbortFlag()
        let start = Date()
        Thread {
            Thread.sleep(until: start.addingTimeInterval(seconds))
            flag.raise()
        }.start()
        return flag
    }
}

/// Значения прогресса по порядку.
final class ProgressLog: Sendable {
    private let values = Mutex<[Int]>([])
    func append(_ value: Int) { values.withLock { $0.append(value) } }
    var all: [Int] { values.withLock { $0 } }
}
