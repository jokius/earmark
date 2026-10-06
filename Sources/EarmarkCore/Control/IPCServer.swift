import Foundation

/// IPC-сервер app на Unix-сокете (§9.2): одно соединение — одна JSON-строка запроса и одна строка
/// ответа, после ответа соединение закрывается.
///
/// Голые BSD-сокеты и GCD, а не NWListener. NWListener рапортует `.ready`, даже когда файла сокета
/// нет, а `bind(2)` честно возвращает ошибку. Ещё на сыром fd есть `getsockopt(LOCAL_PEERPID)`:
/// pid клиента нужен в журнале стартов и стопов записи.
///
/// Живёт в EarmarkCore, а не в app: протухший сокет, второй экземпляр, лимит строки и таймаут —
/// хрупкое поведение, которое сверху не видно, и его проверяют тесты без запуска app.
public final class IPCServer: @unchecked Sendable {
    /// Запрос и pid клиента (-1, если ядро его не отдало) → ответ.
    public typealias Handler = @Sendable (IPCRequest, pid_t) async -> IPCResponse

    private let path: String
    private let maxLineBytes: Int
    private let readTimeout: TimeInterval
    private let handler: Handler
    private let acceptQueue = DispatchQueue(label: "com.konayre.earmark.ipc.accept")
    // @unchecked Sendable: source трогают только start() и stop(), а их зовёт владелец с одного
    // потока. Обработчики соединений получают свои fd по значению и общего состояния не имеют.
    private var source: DispatchSourceRead?

    public init(
        socket: URL, maxLineBytes: Int = IPCFraming.maxLineBytes, readTimeout: TimeInterval = 5,
        handler: @escaping Handler
    ) {
        path = socket.path
        self.maxLineBytes = maxLineBytes
        self.readTimeout = readTimeout
        self.handler = handler
    }

    /// Начинает слушать. `busy` — сокет уже обслуживает другой процесс (второй экземпляр app);
    /// `operation_failed` — путь слишком длинный или bind/listen не удались.
    public func start() throws(EarmarkError) {
        // sun_path — 104 байта вместе с нулём. Длиннее путь ядро молча обрезало бы, и сокет
        // оказался бы не там, где его ищет CLI.
        let limit = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1
        guard path.utf8.count <= limit else {
            throw .operationFailed("socket path is \(path.utf8.count) bytes, limit is \(limit): \(path)")
        }
        if Self.canConnect(path) {
            throw .busy("another earmark instance is serving \(path)")
        }
        // connect не прошёл — файл остался от упавшего app (ECONNREFUSED) или его нет (ENOENT).
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw .operationFailed("socket(): \(Self.errnoText())") }
        // CLOEXEC: иначе слушающий сокет унаследовали бы воркер транскрипции и afplay, и после
        // смерти app сокет продолжал бы «жить» в чужом процессе.
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let bound = Self.withAddress(path) { bind(fd, $0, $1) } ?? -1
        guard bound == 0 else {
            let text = Self.errnoText()
            close(fd)
            throw .operationFailed("bind \(path): \(text)")
        }
        // Каталог и так 0700; права на сам сокет — второй замок на той же двери.
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else {
            let text = Self.errnoText()
            close(fd)
            unlink(path)
            throw .operationFailed("listen \(path): \(text)")
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptPending(on: fd) }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    /// Перестаёт слушать и удаляет файл сокета: CLI сразу увидит ENOENT, а не протухший сокет.
    public func stop() {
        guard let source else { return }
        source.cancel()
        self.source = nil
        unlink(path)
    }

    // MARK: - соединения

    private func acceptPending(on listener: Int32) {
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                return  // EAGAIN: очередь пуста
            }
            Self.configure(client)
            // Чтение блокирующее (с дедлайном) — уводим его с очереди accept, чтобы медленный
            // клиент не задерживал остальных.
            DispatchQueue.global(qos: .userInitiated).async { [self] in serve(client) }
        }
    }

    private func serve(_ fd: Int32) {
        let peer = Self.peerPID(fd)
        let line: Data
        switch readLine(fd) {
        case .line(let data):
            line = data
        case .tooLong:
            send(.failure(.invalidArguments("request exceeds \(maxLineBytes) bytes")), to: fd)
            close(fd)
            return
        case .failed:
            close(fd)  // таймаут, обрыв или пустое соединение (так проверяет живость второй экземпляр)
            return
        }
        Task {
            let response = await respond(to: line, peer: peer)
            // Запись тоже блокирующая (SO_SNDTIMEO) — не держим ею поток кооперативного пула.
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                send(response, to: fd)
                close(fd)
            }
        }
    }

    private func respond(to line: Data, peer: pid_t) async -> IPCResponse {
        let request: IPCRequest
        do {
            request = try IPCFraming.decode(IPCRequest.self, from: line)
        } catch {
            // IPCFraming бросает EarmarkError со своим текстом; localizedDescription у него —
            // безликое «The operation couldn’t be completed».
            let reason =
                (error as? EarmarkError)?.message ?? "malformed request: \(error.localizedDescription)"
            return .failure(.invalidArguments(reason))
        }
        guard request.v == 1 else {
            return .failure(.invalidArguments("unsupported protocol version \(request.v)"))
        }
        return await handler(request, peer)
    }

    private enum ReadResult { case line(Data), tooLong, failed }

    /// Строка до "\n" с общим дедлайном на всё чтение, а не на каждый read: клиент, который шлёт
    /// по байту, не должен держать соединение вечно.
    private func readLine(_ fd: Int32) -> ReadResult {
        let deadline = Date().addingTimeInterval(readTimeout)
        var line = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return .failed }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, Int32(remaining * 1000) + 1)
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0 else { return .failed }
            let count = read(fd, &chunk, chunk.count)
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count > 0 else { return line.isEmpty ? .failed : .line(line) }
            if let newline = chunk[0..<count].firstIndex(of: 0x0A) {
                line.append(contentsOf: chunk[0..<newline])
                return line.count > maxLineBytes ? .tooLong : .line(line)
            }
            line.append(contentsOf: chunk[0..<count])
            if line.count > maxLineBytes { return .tooLong }
        }
    }

    private func send(_ response: IPCResponse, to fd: Int32) {
        guard let data = try? IPCFraming.encode(response) else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = write(fd, base + offset, raw.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { return }  // клиент ушёл или SO_SNDTIMEO
                offset += written
            }
        }
    }

    // MARK: - сокетные мелочи

    /// Принятый сокет: блокирующий (accept на Darwin наследует O_NONBLOCK слушающего), без SIGPIPE
    /// при записи в закрытый клиентом сокет, с таймаутом записи и CLOEXEC.
    private static func configure(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    /// pid процесса на том конце; -1, если ядро не ответило.
    static func peerPID(_ fd: Int32) -> pid_t {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        return getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0 ? pid : -1
    }

    /// Живой сервер на этом пути есть, если к нему можно подключиться.
    static func canConnect(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return withAddress(path) { connect(fd, $0, $1) } == 0
    }

    /// sockaddr_un для пути; nil, если путь не помещается в sun_path.
    static func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T? {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    private static func errnoText() -> String { String(cString: strerror(errno)) }
}
