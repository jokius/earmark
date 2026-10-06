import Foundation

/// Раскладка записей на диске (спека §7): `<root>/<папка календаря>/<дата время название>/`.
///
/// Индекса нет: состояние каждой записи лежит в её папке (meta.json, .recording.json), а сотни
/// папок обходятся мгновенно. Поэтому app, CLI и воркер транскрипции видят одно и то же без IPC.
public struct RecordingStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    // MARK: - meta.json и .recording.json

    public func writeManifest(_ manifest: RecordingManifest, in dir: URL) throws {
        try AtomicFile.write(
            EarmarkJSON.prettyEncoder.encode(manifest),
            to: dir.appendingPathComponent(RecordingFiles.manifest))
    }

    /// Идемпотентно: повторная финализация после крэша не должна падать на уже удалённом manifest.
    public func removeManifest(in dir: URL) throws {
        let path = dir.appendingPathComponent(RecordingFiles.manifest).path
        guard unlink(path) == 0 || errno == ENOENT else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    public func readManifest(in dir: URL) throws -> RecordingManifest? {
        try read(RecordingManifest.self, from: dir.appendingPathComponent(RecordingFiles.manifest))
    }

    public func readMeta(in dir: URL) throws -> RecordingMeta? {
        try read(RecordingMeta.self, from: dir.appendingPathComponent(RecordingFiles.meta))
    }

    public func writeMeta(_ meta: RecordingMeta, in dir: URL) throws {
        try AtomicFile.write(
            EarmarkJSON.prettyEncoder.encode(meta), to: dir.appendingPathComponent(RecordingFiles.meta))
    }

    /// Прочитать → изменить → записать атомарно. Межпроцессной блокировки здесь нет: воркер
    /// транскрипции меняет meta только под .transcribe.lock, app — до постановки в очередь.
    @discardableResult
    public func updateMeta(in dir: URL, _ body: (inout RecordingMeta) throws -> Void) throws -> RecordingMeta
    {
        guard var meta = try readMeta(in: dir) else {
            throw CocoaError(
                .fileNoSuchFile,
                userInfo: [NSFilePathErrorKey: dir.appendingPathComponent(RecordingFiles.meta).path])
        }
        try body(&meta)
        try writeMeta(meta, in: dir)
        return meta
    }

    /// Нет файла — nil; битый JSON — ошибка: молча считать его «нет записи» значило бы потерять запись.
    private func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try EarmarkJSON.decoder.decode(type, from: Data(contentsOf: url))
    }

    // MARK: - Раскладка

    /// "YYYYMMDD-HHMM-xxxx" в локальном времени старта; xxxx — 4 hex из random.
    public static func makeID(startedAt: Date, timeZone: TimeZone = .current, random: UInt16) -> String {
        let hex = String(random, radix: 16)
        return stamp(startedAt, "yyyyMMdd-HHmm", timeZone) + "-"
            + String(repeating: "0", count: 4 - hex.count) + hex
    }

    /// Безопасное имя: без / : \ управляющих, без ведущих точек, схлопнутые пробелы, ≤ 80 символов,
    /// пустое → "Untitled".
    ///
    /// Название события присылает кто угодно, кто может позвать на встречу, поэтому оно враждебно:
    /// "/" и ".." не должны вывести запись из каталога, переводы строк и bidi-override — испортить
    /// имя. Кроме 80 графем режем и по байтам: лимит имени в APFS — 255 байт UTF-8, а 80 эмодзи-семей
    /// весят 2000.
    public static func sanitize(_ name: String) -> String {
        let scalars = name.precomposedStringWithCanonicalMapping.unicodeScalars.map {
            scalar -> Unicode.Scalar in
            let bidiControl =
                (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value)
            let unsafe = scalar == "/" || scalar == ":" || scalar == "\\" || bidiControl
            return unsafe || scalar.properties.generalCategory == .control ? " " : scalar
        }
        var result = String(String.UnicodeScalarView(scalars))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        // без ведущих точек имя не может стать "." или ".." и не прячется в Finder. Режем по
        // скалярам, а не по графемам: ".\u{0307}" — одна графема, но байт '.' в начале остаётся,
        // и папка стала бы скрытой, а list() её пропускает. Пробелы — по CharacterSet.whitespaces:
        // он шире Unicode White_Space (в нём U+200B), split его не видит, и обрезка в конце
        // превращала "\u{200B}.." в ".."
        let spaces = CharacterSet.whitespaces
        while let first = result.unicodeScalars.first, first == "." || spaces.contains(first) {
            result.unicodeScalars.removeFirst()
        }
        // дальше режем только с конца: начало имени, очищенное выше, больше не меняется
        if result.count > 80 { result = String(result.prefix(80)) }
        while result.utf8.count > 200 {
            result.removeLast()
        }
        while let last = result.unicodeScalars.last, spaces.contains(last) {
            result.unicodeScalars.removeLast()
        }
        return result.isEmpty ? "Untitled" : result
    }

    /// Имя папки календаря: override ?? sanitize(title); если в `allCalendars` есть другой календарь
    /// с тем же санитизированным названием — "Title (Account)".
    ///
    /// Названия сравниваем без учёта регистра: APFS по умолчанию такой же, и «Work» с «work»
    /// иначе молча слились бы в одну папку.
    public static func calendarFolderName(
        for calendar: CalendarInfo, override: String?, allCalendars: [CalendarInfo]
    ) -> String {
        if let override, !override.isEmpty { return sanitize(override) }
        let title = sanitize(calendar.title)
        let clash = allCalendars.contains {
            $0.id != calendar.id
                && sanitize($0.title).compare(title, options: .caseInsensitive) == .orderedSame
        }
        return clash ? sanitize("\(calendar.title) (\(calendar.account))") : title
    }

    /// <root>/<calendarFolder ?? "Manual">/<"yyyy-MM-dd HH-mm " + sanitize(title)>[ (n)];
    /// создаёт каталоги (root — 0700).
    ///
    /// Коллизию решает сам mkdir(2): он атомарен, так что две записи с одним названием в одну
    /// минуту (re-arm, быстрый ручной рестарт) получают разные папки без гонки «проверил — создал».
    public func createRecordingFolder(
        calendarFolder: String?, title: String, startedAt: Date, timeZone: TimeZone = .current
    ) throws -> URL {
        let fm = FileManager.default
        // в записях чужие голоса: новый корень — только для владельца; уже существующий
        // не трогаем, его выбрал пользователь
        try fm.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // sanitize и здесь: папка календаря могла прийти из config.json в обход валидации
        let parent = root.appendingPathComponent(
            Self.sanitize(calendarFolder ?? RecordingFiles.manualFolder), isDirectory: true)
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let base = Self.stamp(startedAt, "yyyy-MM-dd HH-mm", timeZone) + " " + Self.sanitize(title)
        for attempt in 1...999 {
            let folder = parent.appendingPathComponent(
                attempt == 1 ? base : "\(base) (\(attempt))", isDirectory: true)
            if mkdir(folder.path, 0o755) == 0 { return folder }
            guard errno == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        throw POSIXError(.EEXIST)
    }

    /// Даты в именах — в григорианском календаре и POSIX-локали: иначе на Mac с буддийским
    /// календарём или арабскими цифрами id и папки разъехались бы с документацией.
    private static func stamp(_ date: Date, _ format: String, _ timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    // MARK: - Обход

    /// Все папки записей (два уровня под root), новые первыми, с фильтром.
    ///
    /// Папка записи — та, где есть meta.json или .recording.json. Папку с битым JSON пропускаем:
    /// одна испорченная запись не должна прятать все остальные из `earmark recordings`.
    /// since включительно, until — нет: `--since 2026-10-02 --until 2026-10-03` — ровно сутки.
    /// calendarId сверяем и с manifest: идущая запись тоже принадлежит своему календарю.
    public func list(_ filter: RecordingFilter = .init()) throws -> [RecordingFolder] {
        var found: [(folder: RecordingFolder, startedAt: Date)] = []
        for group in try Self.subdirectories(of: root) {
            // нечитаемая папка календаря (EACCES) не должна ронять весь обход: на list() стоят
            // очередь транскрипции и восстановление после крэша
            for dir in (try? Self.subdirectories(of: group)) ?? [] {
                let manifest = try? readManifest(in: dir)
                let meta = try? readMeta(in: dir)
                guard let startedAt = meta?.startedAt ?? manifest?.startedAt else { continue }
                let folder = RecordingFolder(url: dir, meta: meta, manifest: manifest)
                guard Self.matches(folder, startedAt: startedAt, filter) else { continue }
                found.append((folder, startedAt))
            }
        }
        let newestFirst = found.sorted {
            $0.startedAt != $1.startedAt
                ? $0.startedAt > $1.startedAt : $0.folder.url.path > $1.folder.url.path
        }
        .map(\.folder)
        guard let limit = filter.limit else { return newestFirst }
        return Array(newestFirst.prefix(max(0, limit)))
    }

    public func find(id: String) throws -> RecordingFolder? {
        try list().first { $0.meta?.id == id || $0.manifest?.id == id }
    }

    /// Папки с manifest, чей pid мёртв по `isAlive`.
    public func interrupted(isAlive: (Int32) -> Bool) throws -> [RecordingFolder] {
        try list().filter { folder in folder.manifest.map { !isAlive($0.pid) } ?? false }
    }

    /// status == .recorded или (status == .transcribing и lock свободен); старые первыми.
    ///
    /// `transcribing` при свободном lock'е — протухшая задача: ядро снимает flock со смертью воркера,
    /// поэтому pid не нужен. Проверяем захватом и сразу отпускаем.
    public func pendingTranscription() throws -> [RecordingFolder] {
        let pending = try list().filter { folder in
            switch folder.status {
            case .recorded: true
            case .transcribing: Self.transcribeLockIsFree(in: folder.url)
            default: false
            }
        }
        return Array(pending.reversed())
    }

    private static func subdirectories(of url: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try FileManager.default
            .contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            )
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    private static func matches(_ folder: RecordingFolder, startedAt: Date, _ filter: RecordingFilter) -> Bool
    {
        if let since = filter.since, startedAt < since { return false }
        if let until = filter.until, startedAt >= until { return false }
        if let calendarId = filter.calendarId,
            (folder.meta?.calendar?.id ?? folder.manifest?.calendar?.id) != calendarId
        {
            return false
        }
        if let status = filter.status, folder.status != status { return false }
        return true
    }

    private static func transcribeLockIsFree(in dir: URL) -> Bool {
        guard
            let lock = try? FileLock.tryAcquire(at: dir.appendingPathComponent(RecordingFiles.transcribeLock))
        else { return false }
        lock.release()
        return true
    }
}
