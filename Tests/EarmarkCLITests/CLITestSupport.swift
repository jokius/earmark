import EarmarkCore
import Foundation
import Synchronization

@testable import EarmarkCLI

/// Фейковый app для контрактных тестов CLI: настоящий Unix-сокет и accept-цикл на BSD-сокетах
/// в своём потоке. Отвечает заготовленными IPCResponse и запоминает запросы, чтобы тест
/// проверял и что CLI напечатал, и что он отправил app.
final class FakeAppServer: Sendable {
    private let listener: Int32
    private let path: String
    private let respond: @Sendable (IPCRequest) -> IPCResponse
    private let state = Mutex<(requests: [IPCRequest], stopped: Bool)>(([], false))

    init(socket: URL, respond: @escaping @Sendable (IPCRequest) -> IPCResponse) throws {
        path = socket.path
        self.respond = respond
        listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard listener >= 0, bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listener, 8) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    var requests: [IPCRequest] { state.withLock { $0.requests } }

    func stop() { state.withLock { $0.stopped = true } }

    private func acceptLoop() {
        // poll с таймаутом вместо голого accept: stop() завершает поток без close() из чужого потока.
        while !state.withLock({ $0.stopped }) {
            var ready = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&ready, 1, 20) > 0 else { continue }
            let client = accept(listener, nil, nil)
            if client >= 0 { serve(client) }
        }
        close(listener)
        unlink(path)
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        var one: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var line = Data()
        var byte: UInt8 = 0
        while read(client, &byte, 1) == 1, byte != 0x0A { line.append(byte) }
        // Пустая строка — это isAppRunning(): соединились и сразу закрыли.
        guard let request = try? IPCFraming.decode(IPCRequest.self, from: line) else { return }
        state.withLock { $0.requests.append(request) }
        guard let reply = try? IPCFraming.encode(respond(request)) else { return }
        _ = reply.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
    }
}

/// Результат одного запуска CLI: код выхода и разобранные конверты.
struct CLIResult {
    var code: Int32
    var out: JSONValue?
    var err: JSONValue?
    var data: JSONValue? { out?["data"] }
    var errorCode: String? { err?["error"]?["code"]?.stringValue }
}

/// Окружение одного теста: своя временная папка (короткий путь — sun_path всего 104 байта),
/// свой сокет, свой config.json с recordings_dir внутри папки теста и перехват stdout/stderr.
/// Глобального состояния не трогает, поэтому тесты Swift Testing спокойно идут параллельно.
final class CLIHarness: Sendable {
    let dir: URL
    private let captured = Mutex<(out: [String], err: [String])>(([], []))
    private let launches = Mutex(0)
    private let servers = Mutex<[FakeAppServer]>([])

    init() throws {
        let name = "em-\(UUID().uuidString.prefix(8))"
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try setConfig([:])
    }

    deinit {
        servers.withLock { $0.forEach { $0.stop() } }
        try? FileManager.default.removeItem(at: dir)
    }

    var socket: URL { dir.appendingPathComponent("s.sock") }
    var configStore: ConfigStore { ConfigStore(url: dir.appendingPathComponent("config.json")) }
    var recordingsRoot: URL { dir.appendingPathComponent("rec") }
    var launchCount: Int { launches.withLock { $0 } }
    var stdoutLines: [String] { captured.withLock { $0.out } }

    /// config.json теста. recordings_dir всегда внутри папки теста: ни один тест
    /// не должен читать настоящий ~/Earmark.
    func setConfig(_ values: [String: ConfigValue]) throws {
        var all = values
        all["recordings_dir"] = .string(recordingsRoot.path)
        try configStore.save(Config(values: all))
    }

    /// launchApp по умолчанию падает: тест никогда не должен поднять настоящий Earmark.app.
    func context(launchApp: (@Sendable () throws -> Void)? = nil) -> CLIContext {
        let launch = launchApp ?? { throw CocoaError(.featureUnsupported) }
        return CLIContext(
            ipc: IPCClient(
                socket: socket,
                launchApp: { [self] in
                    launches.withLock { $0 += 1 }
                    try launch()
                }),
            configStore: configStore,
            output: Output(
                stdout: { [self] line in captured.withLock { $0.out.append(line) } },
                stderr: { [self] line in captured.withLock { $0.err.append(line) } },
                prettyStdout: false))
    }

    /// Запуск CLI как из шелла: код выхода и последний конверт из stdout и stderr.
    func run(_ argv: [String], launchApp: (@Sendable () throws -> Void)? = nil) async throws -> CLIResult {
        captured.withLock { $0 = ([], []) }
        let code = await EarmarkCLI.run(argv, context: context(launchApp: launchApp))
        let (out, err) = captured.withLock { ($0.out, $0.err) }
        return CLIResult(code: code, out: try out.last.map(Self.parse), err: try err.last.map(Self.parse))
    }

    /// Фейковый app на сокете этого теста; останавливается вместе с harness.
    @discardableResult
    func startApp(_ respond: @escaping @Sendable (IPCRequest) -> IPCResponse) throws -> FakeAppServer {
        let app = try FakeAppServer(socket: socket, respond: respond)
        servers.withLock { $0.append(app) }
        return app
    }

    /// Обычный JSONDecoder без snake_case-стратегии: ключи проверяем такими, какими их видит потребитель.
    static func parse(_ line: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
    }
}

extension JSONValue {
    /// Элементы массива; не массив — пусто. Только для тестов: в контракте JSONValue этого нет.
    var items: [JSONValue] {
        if case .array(let values) = self { return values }
        return []
    }
}
