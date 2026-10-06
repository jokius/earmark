import EarmarkCore
import Foundation

/// Команды без app: записи и конфиг — обычные файлы, TCC им не нужен (§9.3). Поэтому они
/// работают при выключенном app и в песочнице агента, где сокет закрыт.
enum DiskCommands {
    static func recordings(
        _ parsed: ParsedCommand, _ context: CLIContext
    ) async throws(EarmarkError) -> JSONValue {
        var filter = RecordingFilter(calendarId: parsed.options["calendar"])
        filter.limit = try parsed.int("limit", min: 1)
        if let raw = parsed.options["since"] { filter.since = try parseDate(raw, endOfDay: false) }
        if let raw = parsed.options["until"] { filter.until = try parseDate(raw, endOfDay: true) }
        if let raw = parsed.options["status"] { filter.status = try parseStatus(raw) }
        let store = try recordingStore(context)
        // Свежая установка: папки записей ещё нет — это пустой список, а не ошибка.
        guard FileManager.default.fileExists(atPath: store.root.path) else { return .array([]) }
        var items: [JSONValue] = []
        for folder in try disk("cannot read recordings", { try store.list(filter) }) {
            items.append(.object(try fields(of: folder)))
        }
        return .array(items)
    }

    static func recording(
        _ parsed: ParsedCommand, _ context: CLIContext
    ) async throws(EarmarkError) -> JSONValue {
        let folder = try findFolder(parsed, context)
        var object = try fields(of: folder)
        // Только файлы, которые уже есть: агент берёт путь и читает, а не гадает. CAF во время
        // записи не отдаём — это недописанные дорожки (§9.4: незавершённые записи не читать).
        var names = [RecordingFiles.audio, RecordingFiles.meta, RecordingFiles.transcript]
        names += [RecordingFiles.transcriptText, RecordingFiles.transcriptMic]
        names += [RecordingFiles.transcriptSystem]
        if !folder.isRecording { names += [RecordingFiles.mic, RecordingFiles.system] }
        var files: [String: JSONValue] = [:]
        for name in names {
            let url = folder.url.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { files[name] = .string(url.path) }
        }
        object["files"] = .object(files)
        return .object(object)
    }

    static func transcript(
        _ parsed: ParsedCommand, _ context: CLIContext
    ) async throws(EarmarkError) -> JSONValue {
        let folder = try findFolder(parsed, context)
        let url = folder.url.appendingPathComponent(RecordingFiles.transcript)
        guard FileManager.default.fileExists(atPath: url.path) else {
            let status = folder.status?.rawValue ?? "unknown"
            throw .notFound("no transcript yet: recording status is \(status)")
        }
        let transcript = try disk("cannot read transcript.json") {
            try EarmarkJSON.decoder.decode(Transcript.self, from: Data(contentsOf: url))
        }
        switch parsed.options["format"] ?? "txt" {
        case "txt":
            let config = try context.loadConfig()
            let offset = try parsed.int("offset", min: 0) ?? 0
            // Больше 500 слов за раз не отдаём: одна команда не должна выжечь контекст агента.
            let requested = try parsed.int("words", min: 1) ?? TranscriptPaging.defaultWords
            let words = min(requested, TranscriptPaging.maxWords)
            // Рендерим из transcript.json, а не читаем transcript.txt: подписи из конфига
            // применяются и к старым записям.
            let text = TranscriptRender.text(transcript, labelMe: config.labelMe, labelThem: config.labelThem)
            return try encodeJSON(TranscriptPaging.page(text, offset: offset, words: words))
        case "json":
            // JSON целиком: его читают скрипты (jq), а не модель; страницы для контекста агента — txt.
            guard parsed.options["offset"] == nil, parsed.options["words"] == nil else {
                throw .invalidArguments("--offset and --words work only with --format txt")
            }
            return try encodeJSON(transcript)
        case let format:
            throw .invalidArguments("--format \(format): expected txt or json")
        }
    }

    static func configList(
        _ parsed: ParsedCommand, _ context: CLIContext
    ) async throws(EarmarkError) -> JSONValue {
        try encodeJSON(try context.loadConfig().listing())
    }

    static func configGet(
        _ parsed: ParsedCommand, _ context: CLIContext
    ) async throws(EarmarkError) -> JSONValue {
        let key = try parsed.argument("key")
        let config = try context.loadConfig()
        if let item = config.listing().first(where: { $0.key == key }) { return try encodeJSON(item) }
        // calendar.<id>.* попадают в листинг, только когда заданы; допустимый незаданный ключ — null.
        guard let spec = ConfigSchema.spec(for: key) else {
            throw .invalidArguments("unknown config key \"\(key)\"; see `earmark config list`")
        }
        return .object([
            "key": .string(key), "value": .null, "is_default": .bool(true),
            "type": .string(spec.type.rawValue), "help": .string(spec.help),
        ])
    }

    // MARK: - Общее

    static func recordingStore(_ context: CLIContext) throws(EarmarkError) -> RecordingStore {
        RecordingStore(root: try context.loadConfig().recordingsDir)
    }

    static func findFolder(
        _ parsed: ParsedCommand, _ context: CLIContext
    ) throws(EarmarkError) -> RecordingFolder {
        let id = try parsed.argument("id")
        let store = try recordingStore(context)
        guard FileManager.default.fileExists(atPath: store.root.path),
            let folder = try disk("cannot read recordings", { try store.find(id: id) })
        else {
            throw .notFound("no recording \(id); take ids from `earmark recordings`")
        }
        return folder
    }

    /// Строка списка: meta.json как есть плюс абсолютный путь папки. Пока идёт запись, meta ещё
    /// нет — берём .recording.json. Статус всегда эффективный (RecordingFolder.status): пока есть
    /// manifest, запись идёт, даже если финализация уже написала meta.json. Так же считает --status.
    static func fields(of folder: RecordingFolder) throws(EarmarkError) -> [String: JSONValue] {
        var object: [String: JSONValue] = [:]
        if let meta = folder.meta, case .object(let fields) = try encodeJSON(meta) {
            object = fields
        } else if let manifest = folder.manifest, case .object(let fields) = try encodeJSON(manifest) {
            object = fields
        }
        if let status = folder.status { object["status"] = .string(status.rawValue) }
        object["path"] = .string(folder.url.path)
        return object
    }

    /// --since/--until: дата YYYY-MM-DD в локальном времени (как в имени папки) или полный ISO 8601.
    /// Дата включается целиком: --until 2026-10-02 — это до полуночи на 3-е.
    static func parseDate(
        _ raw: String, endOfDay: Bool, calendar: Calendar = .current
    ) throws(EarmarkError) -> Date {
        let parts = raw.split(separator: "-").compactMap { Int($0) }
        if raw.count == 10, parts.count == 3 {
            let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
            if components.isValidDate(in: calendar), let day = calendar.date(from: components) {
                return endOfDay ? calendar.date(byAdding: .day, value: 1, to: day) ?? day : day
            }
        }
        if let date = try? Date(raw, strategy: .iso8601) { return date }
        throw .invalidArguments("date \(raw): expected YYYY-MM-DD or ISO 8601, e.g. 2026-10-02T10:00:00Z")
    }

    static func parseStatus(_ raw: String) throws(EarmarkError) -> RecordingStatus {
        guard let status = RecordingStatus(rawValue: raw) else {
            throw .invalidArguments(
                "status \(raw): one of recording, recorded, transcribing, transcribed, transcription_failed")
        }
        return status
    }
}
