// Порт прототипа research/probes/uds/client.swift (свой код из ресёрча earmark).
import EarmarkCore
import Foundation

/// Клиент Unix-сокета app: одно соединение — одна JSON-строка запроса и одна строка ответа (§9.2).
///
/// Блокирующий BSD-сокет, а не NWConnection: CLI делает ровно один запрос, и прямые
/// connect/write/read короче очередей с колбэками. Блокирующая часть уходит в GCD, чтобы
/// не держать поток пула Swift Concurrency до 300 с, пока app финализирует запись.
public struct IPCClient: Sendable {
    let socketURL: URL
    private let launchApp: @Sendable () throws -> Void

    public init(
        socket: URL = EarmarkPaths.socketFile,
        launchApp: @escaping @Sendable () throws -> Void = IPCClient.openApp
    ) {
        socketURL = socket
        self.launchApp = launchApp
    }

    /// Запрос к app. Мёртвый сокет при `autoLaunch` — поднять app и ждать сокет до 5 с,
    /// без `autoLaunch` — сразу app_not_running.
    public func call(
        _ method: String, params: JSONValue, autoLaunch: Bool, timeout: TimeInterval
    ) async throws(EarmarkError) -> JSONValue {
        typealias Reply = Result<JSONValue, EarmarkError>
        let reply: Reply = await withCheckedContinuation { done in
            DispatchQueue.global(qos: .userInitiated).async {
                done.resume(
                    returning: Reply { () throws(EarmarkError) -> JSONValue in
                        try exchange(method, params: params, autoLaunch: autoLaunch, timeout: timeout)
                    })
            }
        }
        return try reply.get()
    }

    /// Отвечает ли app на сокете — без запроса и без автозапуска.
    public func isAppRunning() -> Bool {
        guard let fd = try? connect() else { return false }
        close(fd)
        return true
    }

    /// Поднимает app через LaunchServices. Бинарь app напрямую не запускаем никогда:
    /// TCC приписал бы микрофон и календарь терминалу или агенту, из которого позвали CLI (§3.1).
    public static func openApp() throws {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", "-b", EarmarkPaths.bundleID]
        // Потоки CLI ребёнку не отдаём: в `earmark mcp` stdin — это протокол, а stderr агент
        // парсит как JSON, и текст open («LSCopyApplicationURLsForBundleIdentifier() failed…»,
        // когда app не установлен) сломал бы его. Stderr ловим и кладём в текст ошибки.
        let stderr = Pipe()
        open.standardInput = FileHandle.nullDevice
        open.standardOutput = FileHandle.nullDevice
        open.standardError = stderr
        try open.run()
        // Читаем до EOF раньше waitUntilExit: так open не встанет на полном буфере pipe.
        let output = stderr.fileHandleForReading.readDataToEndOfFile()
        open.waitUntilExit()
        guard open.terminationStatus == 0 else {
            let detail = (String(bytes: output, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw EarmarkError.appNotRunning(
                "open -b \(EarmarkPaths.bundleID) exited with code \(open.terminationStatus): "
                    + (detail.isEmpty ? "is Earmark.app installed?" : detail))
        }
    }

    // MARK: - Блокирующая часть, работает на потоке GCD

    private func exchange(
        _ method: String, params: JSONValue, autoLaunch: Bool, timeout: TimeInterval
    ) throws(EarmarkError) -> JSONValue {
        let fd = try connectLaunchingIfNeeded(autoLaunch)
        defer { close(fd) }
        setTimeout(fd, timeout)
        let request: Data
        do {
            request = try IPCFraming.encode(IPCRequest(method: method, params: params))
        } catch {
            throw .operationFailed("cannot encode the \(method) request: \(Self.reason(error))")
        }
        try send(request, to: fd)
        let line = try receiveLine(from: fd, method: method, timeout: timeout)
        let response: IPCResponse
        do {
            response = try IPCFraming.decode(IPCResponse.self, from: line)
        } catch {
            throw .badData("app reply to \(method) is not valid IPC: \(Self.reason(error))")
        }
        guard response.ok else {
            throw response.error ?? .operationFailed("app replied ok=false without an error")
        }
        return response.data ?? .null
    }

    private func connectLaunchingIfNeeded(_ autoLaunch: Bool) throws(EarmarkError) -> Int32 {
        if let fd = try connect() { return fd }
        guard autoLaunch else {
            throw .appNotRunning("Earmark is not running: nothing answers on \(socketURL.path)")
        }
        do {
            try launchApp()
        } catch {
            throw .appNotRunning("cannot launch Earmark: \(Self.reason(error))")
        }
        // Сокет появляется не сразу после open: app восстанавливает прерванные записи
        // и поднимает сервисы. 5 с с шагом 200 мс — обещание спеки; дольше — что-то сломано.
        let deadline = Date().addingTimeInterval(5)
        repeat {
            usleep(200_000)
            if let fd = try connect() { return fd }
        } while Date() < deadline
        throw .appNotRunning("Earmark was launched, but \(socketURL.path) did not answer within 5 s")
    }

    /// connect(2) к сокету app; nil — app не запущен: ENOENT (файла нет) или ECONNREFUSED
    /// (файл остался от упавшего app). Остальные ошибки — не про «выключен», их бросаем.
    private func connect() throws(EarmarkError) -> Int32? {
        let path = Array(socketURL.path.utf8)
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        // sun_path — 104 байта вместе с нулём; слишком длинный путь connect не объяснил бы внятно.
        guard path.count < capacity else {
            throw .operationFailed("socket path is longer than \(capacity - 1) bytes: \(socketURL.path)")
        }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path)
            buffer[path.count] = 0
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw .operationFailed("socket(): \(Self.lastError())") }
        let status = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard status == 0 else {
            let code = errno
            close(fd)
            switch code {
            case ENOENT, ECONNREFUSED:
                return nil
            case EPERM, EACCES:
                // Так выглядит seatbelt Codex: AF_UNIX из его шелла запрещён (§9.4).
                throw .permissionDenied(
                    "no access to \(socketURL.path); inside an agent sandbox use earmark mcp instead")
            default:
                throw .operationFailed("connect(): \(String(cString: strerror(code)))")
            }
        }
        // Без SO_NOSIGPIPE запись в сокет, который app уже закрыл, убила бы CLI сигналом
        // вместо внятной ошибки.
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    /// Таймаут на каждое чтение и запись: зависший app не должен вешать CLI и агента навсегда.
    private func setTimeout(_ fd: Int32, _ timeout: TimeInterval) {
        let seconds = timeout.rounded(.down)
        var value = timeval(tv_sec: Int(seconds), tv_usec: Int32((timeout - seconds) * 1_000_000))
        let size = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, size)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, size)
    }

    private func send(_ data: Data, to fd: Int32) throws(EarmarkError) {
        var sent = 0
        while sent < data.count {
            let written = data.withUnsafeBytes { bytes in
                write(fd, bytes.baseAddress?.advanced(by: sent), bytes.count - sent)
            }
            if written > 0 {
                sent += written
            } else if written < 0, errno == EINTR {
                continue
            } else {
                throw .operationFailed("cannot send the request: \(Self.lastError())")
            }
        }
    }

    /// Одна строка ответа. Больше IPCFraming.maxLineBytes (1 MiB) не читаем — тот же лимит, что
    /// у сервера (§9.2): такой ответ — сломанный app, а не данные.
    private func receiveLine(
        from fd: Int32, method: String, timeout: TimeInterval
    ) throws(EarmarkError) -> Data {
        let capacity = 64 * 1024
        var chunk = [UInt8](repeating: 0, count: capacity)
        var line = Data()
        while true {
            let count = read(fd, &chunk, capacity)
            if count > 0 {
                if let newline = chunk[..<count].firstIndex(of: 0x0A) {
                    line.append(contentsOf: chunk[..<newline])
                    return line
                }
                line.append(contentsOf: chunk[..<count])
                guard line.count <= IPCFraming.maxLineBytes else {
                    throw .badData("app reply to \(method) is larger than 1 MiB")
                }
            } else if count == 0 {
                // app закрыл соединение, не дописав "\n": отдаём что есть, разбор решит.
                guard !line.isEmpty else {
                    throw .operationFailed("app closed the connection without answering \(method)")
                }
                return line
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN {
                throw .busy("app did not answer \(method) within \(Int(timeout)) s")
            } else {
                throw .operationFailed("cannot read the reply to \(method): \(Self.lastError())")
            }
        }
    }

    private static func lastError() -> String { String(cString: strerror(errno)) }

    /// Причина без обёртки: у EarmarkError — только message, иначе описание системы.
    private static func reason(_ error: any Error) -> String {
        (error as? EarmarkError)?.message ?? error.localizedDescription
    }
}
