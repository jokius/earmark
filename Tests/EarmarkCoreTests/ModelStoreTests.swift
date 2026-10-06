import CryptoKit
import EarmarkCore
import Foundation
import Synchronization
import Testing

/// Поддельный HF для одного теста. Свой хост у каждого теста: сьют идёт параллельно,
/// а URLProtocol находит сервер по хосту запроса.
private final class FakeHF: Sendable {
    struct Reply {
        let status: Int
        let body: Data
        /// У 206 настоящий сервер всегда шлёт Content-Range (RFC 9110).
        var contentRange: String?
        /// Тело обрывается после стольких байт: «пропала сеть». Content-Length при этом полный.
        var cutAfter: Int?
    }

    let host = "hf-\(UUID().uuidString.lowercased()).test"
    let blob: Data
    let honorsRange: Bool
    /// Первый ответ обрывается после стольких байт тела: «пропала сеть».
    let cutFirstAfter: Int?
    /// Ответ на любой запрос вместо модели: страница captive portal, кривой 206.
    let fixed: Reply?
    private let log = Mutex<[String?]>([])

    /// Range-заголовки всех запросов по порядку (nil — без Range).
    var ranges: [String?] { log.withLock { $0 } }

    init(blob: Data, honorsRange: Bool = true, cutFirstAfter: Int? = nil, fixed: Reply? = nil) {
        self.blob = blob
        self.honorsRange = honorsRange
        self.cutFirstAfter = cutFirstAfter
        self.fixed = fixed
        FakeHFProtocol.register(self)
    }

    func respond(to request: URLRequest) -> Reply {
        let range = request.value(forHTTPHeaderField: "Range")
        let attempt = log.withLock { log in
            log.append(range)
            return log.count
        }
        if let fixed {
            return fixed
        }
        var reply = Reply(status: 200, body: blob)
        if honorsRange, let range, let from = Int(range.dropFirst("bytes=".count).dropLast()) {
            reply = Reply(
                status: 206, body: blob.subdata(in: from..<blob.count),
                contentRange: "bytes \(from)-\(blob.count - 1)/\(blob.count)")
        }
        if attempt == 1 {
            reply.cutAfter = cutFirstAfter
        }
        return reply
    }

    func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeHFProtocol.self]
        return URLSession(configuration: configuration)
    }

    func manifest(sha256: String? = nil, size: Int64? = nil) throws -> ModelManifest {
        try testManifest(host: host, blob: blob, sha256: sha256, size: size)
    }
}

private final class FakeHFProtocol: URLProtocol, @unchecked Sendable {
    private static let servers = Mutex<[String: FakeHF]>([:])

    static func register(_ server: FakeHF) { servers.withLock { $0[server.host] = server } }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host, let server = Self.servers.withLock({ $0[host] })
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let reply = server.respond(to: request)
        let headers = ["Content-Length": String(reply.body.count), "Content-Range": reply.contentRange]
        guard
            let response = HTTPURLResponse(
                url: url, statusCode: reply.status, httpVersion: nil,
                headerFields: headers.compactMapValues { $0 })
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // Кусками по 64 KB, как настоящая сеть.
        let sent = reply.body.subdata(in: 0..<(reply.cutAfter ?? reply.body.count))
        var offset = 0
        while offset < sent.count {
            let end = min(offset + 65_536, sent.count)
            client?.urlProtocol(self, didLoad: sent.subdata(in: offset..<end))
            offset = end
        }
        if reply.cutAfter != nil {
            // Ошибка сразу за данными: URL Loading System выбрасывает ещё не отданные куски.
            // В живой сети между ними время — здесь его имитирует пауза.
            Thread.sleep(forTimeInterval: 0.5)
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        // Отменять нечего: ответ отдан целиком внутри startLoading.
    }
}

private func hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// 300 KB детерминированного «веса» — несколько сетевых кусков.
private let fakeModel = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })

/// Манифест тестовой «модели»: по умолчанию размер и sha256 настоящие, URL — на поддельный хост.
private func testManifest(
    host: String = "hf.test", blob: Data = fakeModel, sha256: String? = nil, size: Int64? = nil
)
    throws -> ModelManifest
{
    ModelManifest(
        name: "test-model", fileName: "test-model.bin",
        url: try #require(URL(string: "https://\(host)/resolve/0123abcd/test-model.bin")),
        size: size ?? Int64(blob.count), sha256: sha256 ?? hex(blob))
}

private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "earmark-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite("Загрузка и импорт модели")
struct ModelStoreTests {
    private let noProgress: @Sendable (Int64, Int64) -> Void = { _, _ in
        // прогресс в этих тестах не проверяем
    }

    private func partial(_ store: ModelStore, _ manifest: ModelManifest) -> URL {
        URL(fileURLWithPath: store.path(for: manifest).path + ".partial")
    }

    @Test("свежая загрузка: модель на месте, .partial нет, вне бэкапа; повторный вызов в сеть не ходит")
    func freshDownload() async throws {
        let server = FakeHF(blob: fakeModel)
        let store = ModelStore(dir: try tempDir(), session: server.session())
        let manifest = try server.manifest()
        let last = Mutex<Int64>(0)

        let url = try await store.download(manifest) { received, _ in last.withLock { $0 = received } }

        #expect(url == store.path(for: manifest))
        #expect(try Data(contentsOf: url) == fakeModel)
        #expect(!FileManager.default.fileExists(atPath: partial(store, manifest).path))
        #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(last.withLock { $0 } == Int64(fakeModel.count))
        #expect(server.ranges == [nil])
        #expect(try await store.download(manifest, progress: noProgress) == url)
        #expect(server.ranges == [nil])
    }

    @Test("обрыв посреди загрузки оставляет .partial, следующая попытка докачивает через Range и 206")
    func resumeAfterInterruption() async throws {
        let server = FakeHF(blob: fakeModel, cutFirstAfter: 100_000)
        let store = ModelStore(dir: try tempDir(), session: server.session())
        let manifest = try server.manifest()

        let error = await #expect(throws: EarmarkError.self) {
            try await store.download(manifest, progress: noProgress)
        }
        #expect(error?.code == "unavailable")
        #expect(try store.state(of: manifest, verify: false) == .missing)
        #expect(FileManager.default.contents(atPath: partial(store, manifest).path)?.count == 100_000)

        let url = try await store.download(manifest, progress: noProgress)
        #expect(try Data(contentsOf: url) == fakeModel)
        #expect(server.ranges == [nil, "bytes=100000-"])
    }

    @Test("сервер не понял Range и прислал 200 — .partial переписывается с нуля")
    func serverIgnoresRange() async throws {
        let server = FakeHF(blob: fakeModel, honorsRange: false)
        let store = ModelStore(dir: try tempDir(), session: server.session())
        let manifest = try server.manifest()
        try Data(repeating: 0xFF, count: 50_000).write(to: partial(store, manifest))

        let url = try await store.download(manifest, progress: noProgress)

        #expect(try Data(contentsOf: url) == fakeModel)
        #expect(server.ranges == ["bytes=50000-"])
    }

    @Test("в .partial уже вся модель — проверка и rename без единого запроса")
    func completePartialSkipsNetwork() async throws {
        let server = FakeHF(blob: fakeModel)
        let store = ModelStore(dir: try tempDir(), session: server.session())
        let manifest = try server.manifest()
        try fakeModel.write(to: partial(store, manifest))

        let url = try await store.download(manifest, progress: noProgress)

        #expect(url == store.path(for: manifest))
        #expect(try Data(contentsOf: url) == fakeModel)
        #expect(!FileManager.default.fileExists(atPath: partial(store, manifest).path))
        #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(server.ranges.isEmpty)
    }

    @Test(".partial полного размера, но чужой — выбрасывается, модель качается с нуля без Range")
    func completePartialWithWrongContent() async throws {
        let server = FakeHF(blob: fakeModel)
        let store = ModelStore(dir: try tempDir(), session: server.session())
        let manifest = try server.manifest()
        try Data(repeating: 0xFF, count: fakeModel.count).write(to: partial(store, manifest))

        let url = try await store.download(manifest, progress: noProgress)

        #expect(try Data(contentsOf: url) == fakeModel)
        #expect(server.ranges == [nil])
    }

    @Test("200 с чужим Content-Length (captive portal) — unavailable (69), .partial не тронут")
    func captivePortalKeepsPartial() async throws {
        let html = Data("<html><body>Sign in to the Wi-Fi</body></html>".utf8)
        let server = FakeHF(blob: fakeModel, fixed: .init(status: 200, body: html))
        let store = ModelStore(dir: try tempDir(), session: server.session())
        let manifest = try server.manifest()
        let head = fakeModel.subdata(in: 0..<50_000)
        try head.write(to: partial(store, manifest))

        let error = await #expect(throws: EarmarkError.self) {
            try await store.download(manifest, progress: noProgress)
        }

        #expect(error?.code == "unavailable")
        #expect(error?.exitCode == 69)
        #expect(FileManager.default.contents(atPath: partial(store, manifest).path) == head)
        #expect(!FileManager.default.fileExists(atPath: store.path(for: manifest).path))
        #expect(server.ranges == ["bytes=50000-"])
    }

    @Test("206 с Content-Length не равным остатку — unavailable (69), .partial не тронут")
    func wrongPartialContentLengthKeepsPartial() async throws {
        // Начало верное, но остаток после 100 000 байт — 200 000, а пришло 100 000.
        let short = fakeModel.subdata(in: 100_000..<200_000)
        let server = FakeHF(
            blob: fakeModel,
            fixed: .init(status: 206, body: short, contentRange: "bytes 100000-199999/300000"))
        let store = ModelStore(dir: try tempDir(), session: server.session())
        let manifest = try server.manifest()
        let head = fakeModel.subdata(in: 0..<100_000)
        try head.write(to: partial(store, manifest))

        let error = await #expect(throws: EarmarkError.self) {
            try await store.download(manifest, progress: noProgress)
        }

        #expect(error?.code == "unavailable")
        #expect(error?.exitCode == 69)
        #expect(FileManager.default.contents(atPath: partial(store, manifest).path) == head)
        #expect(!FileManager.default.fileExists(atPath: store.path(for: manifest).path))
        #expect(server.ranges == ["bytes=100000-"])
    }

    @Test(
        "206 без Content-Range или не с байта докачки — unavailable (69), .partial не тронут",
        arguments: [nil, 50_000] as [Int?])
    func resumeWithoutMatchingContentRange(from: Int?) async throws {
        // Content-Length верный (200 000), решает только Content-Range.
        let start = from ?? 100_000
        let body = fakeModel.subdata(in: start..<start + 200_000)
        let contentRange = from.map { "bytes \($0)-\($0 + 199_999)/300000" }
        let server = FakeHF(
            blob: fakeModel, fixed: .init(status: 206, body: body, contentRange: contentRange))
        let store = ModelStore(dir: try tempDir(), session: server.session())
        let manifest = try server.manifest()
        let head = fakeModel.subdata(in: 0..<100_000)
        try head.write(to: partial(store, manifest))

        let error = await #expect(throws: EarmarkError.self) {
            try await store.download(manifest, progress: noProgress)
        }

        #expect(error?.code == "unavailable")
        #expect(error?.exitCode == 69)
        #expect(FileManager.default.contents(atPath: partial(store, manifest).path) == head)
        #expect(!FileManager.default.fileExists(atPath: store.path(for: manifest).path))
        #expect(server.ranges == ["bytes=100000-"])
    }

    @Test("sha256 не сошёлся — bad_data, нет ни модели, ни .partial")
    func shaMismatch() async throws {
        let server = FakeHF(blob: fakeModel)
        let store = ModelStore(dir: try tempDir(), session: server.session())
        let manifest = try server.manifest(sha256: hex(Data("другой файл".utf8)))

        let error = await #expect(throws: EarmarkError.self) {
            try await store.download(manifest, progress: noProgress)
        }

        #expect(error?.code == "bad_data")
        #expect(!FileManager.default.fileExists(atPath: store.path(for: manifest).path))
        #expect(!FileManager.default.fileExists(atPath: partial(store, manifest).path))
    }

    @Test("места не хватает — unavailable (69), запроса не было")
    func insufficientSpace() async throws {
        let server = FakeHF(blob: fakeModel)
        let store = ModelStore(dir: try tempDir(), session: server.session())
        let manifest = try server.manifest(size: Int64.max / 2)

        let error = await #expect(throws: EarmarkError.self) {
            try await store.download(manifest, progress: noProgress)
        }

        #expect(error?.code == "unavailable")
        #expect(error?.exitCode == 69)
        #expect(server.ranges.isEmpty)
    }

    @Test("импорт: sha256 сошёлся — копия на месте и вне бэкапа; не сошёлся — bad_data и модели нет")
    func importFile() throws {
        let store = ModelStore(dir: try tempDir())
        let manifest = try testManifest()
        let source = try tempDir().appending(path: "from-elsewhere.bin")
        try fakeModel.write(to: source)

        let url = try store.importFile(at: source, as: manifest)
        #expect(try Data(contentsOf: url) == fakeModel)
        #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(try store.state(of: manifest, verify: true) == .ready(url))

        let other = ModelStore(dir: try tempDir())
        let wrong = try tempDir().appending(path: "wrong.bin")
        try Data(repeating: 1, count: fakeModel.count).write(to: wrong)
        let error = #expect(throws: EarmarkError.self) { try other.importFile(at: wrong, as: manifest) }
        #expect(error?.code == "bad_data")
        #expect(!FileManager.default.fileExists(atPath: other.path(for: manifest).path))
    }

    @Test(
        "состояния: missing → downloading (lock у другого) → missing (брошенный .partial) → corrupt → ready")
    func states() throws {
        let store = ModelStore(dir: try tempDir())
        let manifest = try testManifest()
        let final = store.path(for: manifest)
        #expect(try store.state(of: manifest, verify: false) == .missing)

        try Data(count: 1_000).write(to: partial(store, manifest))
        let held = try #require(try FileLock.tryAcquire(at: store.dir.appending(path: ".download.lock")))
        #expect(
            try store.state(of: manifest, verify: false)
                == .downloading(received: 1_000, total: Int64(fakeModel.count)))
        held.release()
        #expect(try store.state(of: manifest, verify: false) == .missing)

        try Data(count: 10).write(to: final)
        #expect(try store.state(of: manifest, verify: false) == .corrupt(final))

        // Размер верный, содержимое нет: без verify — ready, с verify — corrupt.
        try Data(count: fakeModel.count).write(to: final)
        #expect(try store.state(of: manifest, verify: false) == .ready(final))
        #expect(try store.state(of: manifest, verify: true) == .corrupt(final))

        try fakeModel.write(to: final)
        #expect(try store.state(of: manifest, verify: true) == .ready(final))
        let info = ModelStatusInfo(.downloading(received: 25, total: 100))
        #expect(info.state == "downloading" && info.progress == 0.25 && info.path == nil)
    }
}
