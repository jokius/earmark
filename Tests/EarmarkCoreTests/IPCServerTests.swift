import Foundation
import Testing

@testable import EarmarkCore

/// Хрупкое низкоуровневое поведение сокета, которого не видно ни из CLI-тестов с фейковым
/// сервером, ни из меню: протухший файл, второй экземпляр, лимит строки, дедлайн чтения.
@Suite struct IPCServerTests {
    /// Свежий каталог на тест. Временный каталог macOS — ~48 байт, с подкаталогом и именем
    /// сокета остаёмся в пределах 104 байт sun_path.
    private func socketURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("eipc-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("s.sock")
    }

    /// Минимальный клиент: connect → байты → всё, что пришло до EOF. Чтение до EOF и есть
    /// проверка «ответ записан, соединение закрыто»; SO_RCVTIMEO не даёт тесту зависнуть.
    private func exchange(_ socket: URL, _ payload: Data?) throws -> Data {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(fd >= 0)
        defer { close(fd) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let connected = IPCServer.withAddress(socket.path) { connect(fd, $0, $1) }
        try #require(connected == 0)
        if let payload {
            _ = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        }
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            received.append(contentsOf: buffer[0..<count])
        }
        return received
    }

    private func request(_ method: String) throws -> Data {
        try IPCFraming.encode(IPCRequest(method: method, params: .object([:])))
    }

    /// Последний pid, с которым звали обработчик.
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var pids: [pid_t] = []
        func record(_ pid: pid_t) { lock.withLock { pids.append(pid) } }
        var all: [pid_t] { lock.withLock { pids } }
    }

    private func echoServer(
        _ socket: URL, calls: Calls = Calls(), maxLineBytes: Int = IPCFraming.maxLineBytes,
        readTimeout: TimeInterval = 5
    ) -> IPCServer {
        IPCServer(socket: socket, maxLineBytes: maxLineBytes, readTimeout: readTimeout) { request, pid in
            calls.record(pid)
            return .success(.string("pong:\(request.method)"))
        }
    }

    @Test func answersOneRequestAndClosesWithPeerPID() throws {
        let socket = try socketURL()
        let calls = Calls()
        let server = echoServer(socket, calls: calls)
        try server.start()
        defer { server.stop() }

        let reply = try exchange(socket, try request("status"))

        #expect(reply.last == 0x0A)
        let response = try IPCFraming.decode(IPCResponse.self, from: reply.dropLast())
        #expect(response == .success(.string("pong:status")))
        // Клиент — сам тестовый процесс, и LOCAL_PEERPID обязан вернуть именно его.
        #expect(calls.all == [getpid()])
    }

    @Test func secondInstanceOnSamePathIsBusy() throws {
        let socket = try socketURL()
        let first = echoServer(socket)
        try first.start()
        defer { first.stop() }

        let error = #expect(throws: EarmarkError.self) { try echoServer(socket).start() }

        #expect(error?.code == "busy")
        // Неудачный старт второго не должен ломать первый: файл сокета на месте и отвечает.
        let reply = try exchange(socket, try request("status"))
        #expect(try IPCFraming.decode(IPCResponse.self, from: reply.dropLast()).ok)
    }

    @Test func staleSocketFileIsReplaced() throws {
        let socket = try socketURL()
        // Остаток упавшего app: файл сокета есть, слушателя нет (connect → ECONNREFUSED).
        let orphan = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        let bound = IPCServer.withAddress(socket.path) { bind(orphan, $0, $1) }
        try #require(bound == 0)
        close(orphan)
        #expect(FileManager.default.fileExists(atPath: socket.path))

        let server = echoServer(socket)
        try server.start()
        defer { server.stop() }

        let reply = try exchange(socket, try request("status"))
        #expect(try IPCFraming.decode(IPCResponse.self, from: reply.dropLast()).ok)
    }

    @Test func tooLongSocketPathIsRejected() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            String(repeating: "x", count: 80))
        let error = #expect(throws: EarmarkError.self) {
            try echoServer(dir.appendingPathComponent("earmark.sock")).start()
        }
        #expect(error?.code == "operation_failed")
    }

    @Test(arguments: [
        Data(repeating: 0x61, count: 2048) + Data([0x0A]),  // длиннее лимита
        Data("not json\n".utf8),  // не JSON
        Data("{\"v\":2,\"method\":\"status\",\"params\":{}}\n".utf8),  // чужая версия протокола
    ])
    func badRequestGetsInvalidArgumentsWithoutReachingHandler(_ payload: Data) throws {
        let socket = try socketURL()
        let calls = Calls()
        let server = echoServer(socket, calls: calls, maxLineBytes: 1024)
        try server.start()
        defer { server.stop() }

        let reply = try exchange(socket, payload)

        let response = try IPCFraming.decode(IPCResponse.self, from: reply.dropLast())
        #expect(response.ok == false)
        #expect(response.error?.code == "invalid_arguments")
        #expect(calls.all.isEmpty)
    }

    @Test func silentClientIsDroppedAfterDeadline() throws {
        let socket = try socketURL()
        let calls = Calls()
        let server = echoServer(socket, calls: calls, readTimeout: 0.2)
        try server.start()
        defer { server.stop() }

        let started = Date()
        let reply = try exchange(socket, nil)

        #expect(reply.isEmpty)
        #expect(Date().timeIntervalSince(started) < 2)
        #expect(calls.all.isEmpty)
    }
}
