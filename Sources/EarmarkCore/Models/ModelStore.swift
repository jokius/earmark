// Copyright (c) 2026 Andrew Jones (MIT)
// Copyright (c) 2026 Samat Galimov (MIT)
// Портировано из amanu@fbccc13: Sources/amanu/Transcription/VerifiedModelStore.swift
// (+ WhisperModelStore.swift), урезано до одной модели без in-process fan-out.

import CryptoKit
import Darwin
import Foundation

public enum ModelState: Equatable, Sendable {
    case missing
    case downloading(received: Int64, total: Int64)
    case ready(URL)
    case corrupt(URL)
}

/// Модель whisper в ~/Library/Application Support/earmark/models: загрузка, докачка, проверка, импорт.
///
/// Качать её могут и app (автозагрузка), и `earmark model download` в другом процессе. Поэтому вся
/// загрузка идёт под flock на <dir>/.download.lock: второй ждёт, а потом находит готовую модель.
/// Прерванная загрузка оставляет .partial, и следующая просит у сервера только остаток (Range).
/// Только .partial, сошедшийся по размеру и sha256, переименовывается в модель.
public struct ModelStore: Sendable {
    /// Запас сверх недостающих байт: модель не должна съесть последние мегабайты диска,
    /// на котором идёт запись созвона.
    static let spaceReserve: Int64 = 100_000_000

    /// Чанки чтения для sha256: память постоянна, сколько бы ни весил файл.
    static let hashChunk = 4 << 20

    public let dir: URL
    private let session: URLSession

    public init(dir: URL = EarmarkPaths.modelsDir, session: URLSession = .shared) {
        self.dir = dir
        self.session = session
    }

    public func path(for model: ModelManifest) -> URL { dir.appending(path: model.fileName) }

    func partialPath(for model: ModelManifest) -> URL { dir.appending(path: model.fileName + ".partial") }

    var lockURL: URL { dir.appending(path: ".download.lock") }

    /// verify: false — только размер (мгновенно); true — ещё sha256 (~1–4 с на 1.6 GB).
    public func state(of model: ModelManifest, verify: Bool) throws -> ModelState {
        let final = path(for: model)
        if let size = Self.size(of: final) {
            guard size == model.size else { return .corrupt(final) }
            if verify, try Self.sha256(of: final) != model.sha256 { return .corrupt(final) }
            return .ready(final)
        }
        guard let received = Self.size(of: partialPath(for: model)) else { return .missing }
        // .partial без держателя lock'а — брошенная загрузка: модели нет, следующий download докачает.
        guard let lock = try FileLock.tryAcquire(at: lockURL) else {
            return .downloading(received: received, total: model.size)
        }
        lock.release()
        return .missing
    }

    /// .partial + Range-докачка, FileLock на <dir>/.download.lock, проверка места (недостающее + 100 MB),
    /// размер и sha256, rename, isExcludedFromBackup. Ошибки — EarmarkError: unavailable (нет места,
    /// нет сети), badData (файл не сошёлся), operationFailed (HTTP, диск).
    public func download(
        _ model: ModelManifest, progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lock = try await waitForLock()
        defer { lock.release() }
        // Пока ждали lock, модель мог докачать другой процесс.
        if case .ready(let url) = try state(of: model, verify: true) { return url }

        let partial = partialPath(for: model)
        var have = Self.size(of: partial) ?? 0
        if have >= model.size {
            // Процесс умер на финальном sha256: файл уже весь здесь. На `Range: bytes=size-` CDN
            // ответит 416, поэтому в сеть не ходим — проверяем то, что есть, и качаем заново, только если не сошлось.
            if let final = try install(partial, as: model) { return final }
            try? FileManager.default.removeItem(at: partial)
            have = 0
        }
        try ensureSpace(missing: model.size - have)

        // Каждая попытка идёт заново на /resolve/: подписанная ссылка CDN после редиректа живёт ~1 ч,
        // хранить её нельзя.
        var request = URLRequest(url: model.url)
        if have > 0 { request.setValue("bytes=\(have)-", forHTTPHeaderField: "Range") }
        try await fetch(request, into: partial, have: have, total: model.size, progress: progress)

        let size = Self.size(of: partial) ?? 0
        if size < model.size {
            // Поток кончился без ошибки, но короче файла: .partial годен для докачки.
            throw EarmarkError.operationFailed(
                "download stopped at \(size) of \(model.size) bytes; run it again to resume")
        }
        guard let final = try install(partial, as: model) else {
            try? FileManager.default.removeItem(at: partial)
            throw EarmarkError.badData(
                "downloaded \(model.fileName) failed the size or sha256 check; .partial removed")
        }
        return final
    }

    /// sha256 + FileManager.copyItem (APFS-клон), затем isExcludedFromBackup.
    public func importFile(at source: URL, as model: ModelManifest) throws -> URL {
        // copyItem копирует симлинк как симлинк, а он сломается, когда чужая папка исчезнет.
        let source = source.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw EarmarkError.notFound("no such file: \(source.path)")
        }
        guard Self.size(of: source) == model.size, try Self.sha256(of: source) == model.sha256 else {
            throw EarmarkError.badData("\(source.path) is not \(model.fileName): size or sha256 mismatch")
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Через временное имя: copyItem не перезаписывает, а rename(2) атомарно подменит битую модель.
        let temp = dir.appending(path: ".\(model.fileName).\(UUID().uuidString).import")
        try FileManager.default.copyItem(at: source, to: temp)  // на APFS — клон за миллисекунды
        let final = path(for: model)
        try Self.move(temp, to: final)
        try Self.excludeFromBackup(final)
        return final
    }

    // MARK: - загрузка

    /// .partial, сошедшийся по размеру и sha256, становится моделью; иначе nil и .partial не тронут.
    private func install(_ partial: URL, as model: ModelManifest) throws -> URL? {
        guard Self.size(of: partial) == model.size, try Self.sha256(of: partial) == model.sha256 else {
            return nil
        }
        let final = path(for: model)
        try Self.move(partial, to: final)
        try Self.excludeFromBackup(final)
        return final
    }

    /// tryAcquire в цикле, а не блокирующий flock: чужая загрузка идёт минутами, и всё это
    /// время держать поток кооперативного пула нельзя. Отмена задачи прерывает ожидание.
    private func waitForLock() async throws -> FileLock {
        while true {
            if let lock = try FileLock.tryAcquire(at: lockURL) { return lock }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    private func ensureSpace(missing: Int64) throws {
        let need = missing + Self.spaceReserve
        let free = try dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        guard let free, free < need else { return }
        throw EarmarkError.unavailable(
            "not enough disk space for the model: need \(need.formatted(.byteCount(style: .file))), "
                + "free \(free.formatted(.byteCount(style: .file)))")
    }

    /// Ответ пишется в .partial чанками по мере прихода. 206 на Range — дописываем хвост,
    /// любой другой 2xx — сервер прислал файл целиком, начинаем .partial заново.
    ///
    /// Не URLSession.bytes(for:): побайтовая итерация AsyncBytes — ~8 MB/s даже в release (замер),
    /// 1.6 GB шли бы минутами при живом CDN. Делегат задачи отдаёт данные кусками, как пришли.
    private func fetch(
        _ request: URLRequest, into partial: URL, have: Int64, total: Int64,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        var handle: FileHandle?
        defer { try? handle?.close() }
        var received: Int64 = 0
        do {
            for try await event in Self.events(session, request) {
                switch event {
                case .response(let response):
                    let opened = try Self.open(partial, for: response, have: have, total: total)
                    handle = opened.handle
                    received = opened.offset
                case .data(let chunk):
                    guard let handle else { continue }
                    try handle.write(contentsOf: chunk)
                    received += Int64(chunk.count)
                    progress(received, total)
                }
            }
            // Отмена задачи не бросает из цикла: поток просто кончается. Без проверки отмена выглядела бы
            // как обрыв («download stopped at…»); .partial остаётся для докачки в любом случае.
            try Task.checkCancellation()
            // F_FULLFSYNC, как в AtomicFile: иначе после потери питания rename переживёт данные, и модель
            // верного размера окажется с дырой. ФС без его поддержки отвечают ошибкой — тогда fsync.
            if let fd = handle?.fileDescriptor, fcntl(fd, F_FULLFSYNC) != 0, fsync(fd) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch let error as EarmarkError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            // Записанное остаётся в .partial: следующая попытка продолжит с этого байта.
            throw EarmarkError.unavailable("network: \(error.localizedDescription)")
        }
    }

    /// Куда писать тело: на 206 в ответ на Range — в конец .partial, на любой другой 2xx — с нуля.
    private static func open(_ partial: URL, for response: HTTPURLResponse, have: Int64, total: Int64)
        throws -> (handle: FileHandle, offset: Int64)
    {
        let host = response.url?.host ?? "?"
        let append = response.statusCode == 206 && have > 0
        guard append || (200..<300).contains(response.statusCode) else {
            // 416: полный .partial до сети не доходит (см. download), значит файл на сервере короче нашего
            // недокачанного — докачивать нечего, следующая попытка начнёт заново.
            if response.statusCode == 416 { try? FileManager.default.removeItem(at: partial) }
            throw EarmarkError.operationFailed("HTTP \(response.statusCode) from \(host)")
        }
        // Тело сверяется до того, как тронуть .partial: captive portal или прокси отвечают 2xx со своей
        // страницей, и она затёрла бы гигабайт докачанного. Длина -1 (не объявлена, chunked) проходит:
        // лишнее или недостающее поймает сверка размера и sha256 в конце.
        if append, response.value(forHTTPHeaderField: "Content-Range")?.hasPrefix("bytes \(have)-") != true {
            throw EarmarkError.unavailable(
                "HTTP 206 from \(host) does not resume at byte \(have); .partial kept")
        }
        let length = response.expectedContentLength
        let expected = append ? total - have : total
        guard length == -1 || length == expected else {
            throw EarmarkError.unavailable(
                "\(host) answered with \(length) bytes instead of \(expected) "
                    + "(captive portal or proxy?); .partial kept")
        }
        if !FileManager.default.fileExists(atPath: partial.path) {
            FileManager.default.createFile(atPath: partial.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: partial)
        if append { try handle.seekToEnd() } else { try handle.truncate(atOffset: 0) }
        return (handle, append ? have : 0)
    }

    private enum Event: Sendable {
        case response(HTTPURLResponse)
        case data(Data)
    }

    /// Ответ и куски тела задачи — асинхронным потоком. Делегат вешается на саму задачу
    /// (URLSessionTask.delegate), поэтому годится любая сессия, в том числе .shared и тестовая.
    private static func events(_ session: URLSession, _ request: URLRequest) -> AsyncThrowingStream<
        Event, Error
    > {
        let (stream, continuation) = AsyncThrowingStream<Event, Error>.makeStream()
        let task = session.dataTask(with: request)
        task.delegate = StreamDelegate(continuation)
        continuation.onTermination = { _ in task.cancel() }
        task.resume()
        return stream
    }

    private final class StreamDelegate: NSObject, URLSessionDataDelegate, Sendable {
        let continuation: AsyncThrowingStream<Event, Error>.Continuation

        init(_ continuation: AsyncThrowingStream<Event, Error>.Continuation) {
            self.continuation = continuation
        }

        func urlSession(
            _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
            completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
        ) {
            if let http = response as? HTTPURLResponse { continuation.yield(.response(http)) }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            continuation.yield(.data(data))
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            // Уже полученные куски поток отдаст раньше ошибки — они успеют лечь в .partial.
            continuation.finish(throwing: error)
        }
    }

    // MARK: - файлы

    static func size(of url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    /// Потоковый sha256: память постоянна. autoreleasepool обязателен — read(upToCount:) отдаёт
    /// autoreleased NSData, и без пула хеш 1.6 GB поднимал RSS до ~900 MB (замер), с пулом — 11 MB.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var more = true
        while more {
            more = try autoreleasepool { () throws -> Bool in
                guard let chunk = try handle.read(upToCount: hashChunk), !chunk.isEmpty else { return false }
                hasher.update(data: chunk)
                return true
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// rename(2): атомарно подменяет старый файл, в отличие от FileManager.moveItem.
    private static func move(_ source: URL, to destination: URL) throws {
        guard rename(source.path, destination.path) == 0 else {
            let reason = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: source)
            throw EarmarkError.operationFailed("rename \(source.lastPathComponent): \(reason)")
        }
    }

    /// 1.6 GB модели в Time Machine — пустая трата: её можно скачать заново.
    private static func excludeFromBackup(_ url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
}

extension ModelStatusInfo {
    /// Одно отображение состояния модели для status, doctor и `earmark model status`.
    public init(_ state: ModelState) {
        switch state {
        case .missing:
            self.init(state: "missing", progress: nil, path: nil)
        case .downloading(let received, let total):
            self.init(
                state: "downloading", progress: total > 0 ? Double(received) / Double(total) : 0, path: nil)
        case .ready(let url):
            self.init(state: "ready", progress: nil, path: url.path)
        case .corrupt(let url):
            self.init(state: "corrupt", progress: nil, path: url.path)
        }
    }
}
