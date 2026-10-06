import Foundation

/// Схема конфига (спека §9.1): ключ, тип, дефолт, валидация, help — одна таблица.
public enum ConfigSchema {
    public static let all: [ConfigKeySpec] = [
        spec("auto_record", .bool, .bool(true), "Master switch for automatic recording of calendar events"),
        spec("lead_seconds", .int, .int(60), "Start recording this many seconds before an event", 0...3600),
        spec(
            "recordings_dir", .path, .string("~/Earmark"),
            "Recordings root. Desktop, Documents and Downloads are refused: they are TCC-protected"),
        spec("launch_at_login", .bool, .bool(true), "Start Earmark at login"),
        spec(
            "calendars", .stringList, .stringList([]),
            "Enabled calendar ids, comma-separated or a JSON array; earlier wins when events overlap"),
        spec("calendar.*.lead_seconds", .int, nil, "Per-calendar override of lead_seconds", 0...3600),
        spec(
            "calendar.*.folder", .string, nil,
            "Folder name for this calendar's recordings instead of its title"),
        spec(
            "stop.call_end_seconds", .int, .int(60), "Stop after the call app released the mic this long",
            5...3600),
        spec(
            "stop.after_end_seconds", .int, .int(120), "Grace after the event end before event_over", 0...7200
        ),
        spec("stop.far_end_quiet_seconds", .int, .int(60), "Far end quiet this long after the end", 5...3600),
        spec("stop.silence_minutes", .int, .int(10), "Stop when both channels are silent this long", 1...240),
        spec(
            "stop.join_grace_minutes", .int, .int(10), "Stop if no call started this long after start",
            1...240),
        spec("stop.max_minutes", .int, .int(300), "Hard cap on a recording's length", 1...1440),
        spec(
            "stop.min_keep_seconds", .int, .int(45), "Automatic recordings shorter than this are deleted",
            0...3600),
        spec(
            "audio.keep_raw_tracks", .bool, .bool(false), "Keep mic.caf and system.caf after mixing audio.m4a"
        ),
        spec("transcription.enabled", .bool, .bool(true), "Transcribe recordings locally with whisper"),
        spec(
            "transcription.language", .string, .string("auto"),
            "Whisper language code (ru, en, az, ...) or auto"),
        spec("transcript.label_me", .string, .string("Me"), "Speaker label for the microphone channel"),
        spec("transcript.label_them", .string, .string("Them"), "Speaker label for the system audio channel"),
    ]

    /// Ищет точный ключ или шаблон calendar.<id>.lead_seconds|folder.
    public static func spec(for key: String) -> ConfigKeySpec? {
        // "*" — только в шаблонах: сам шаблон задать нельзя
        guard !key.contains("*") else { return nil }
        let lookup = calendarTemplate(for: key) ?? key
        return all.first { $0.key == lookup }
    }

    /// Разбор строки из CLI в значение по типу + валидация
    /// (range, путь, список через запятую или JSON-массив).
    public static func parse(_ raw: String, for key: String) throws(ConfigError) -> ConfigValue {
        guard let spec = spec(for: key) else { throw .unknownKey(key) }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: ConfigValue
        switch spec.type {
        case .bool:
            switch text.lowercased() {
            case "true", "yes", "on", "1": value = .bool(true)
            case "false", "no", "off", "0": value = .bool(false)
            default: throw .invalidValue(key: key, reason: "expected true/false, yes/no, on/off or 1/0")
            }
        case .int:
            guard let number = Int(text) else { throw .invalidValue(key: key, reason: "expected an integer") }
            value = .int(number)
        case .string, .path:
            value = .string(text)
        case .stringList:
            value = .stringList(try list(text, key: key))
        }
        let checked = try validate(value, spec: spec, key: key)
        // Доступность на запись проверяем только для ввода человека: config.json с отключённым
        // внешним диском должен загружаться, а запись в такой каталог упадёт уже на старте записи.
        if spec.type == .path, case .string(let path) = checked { try checkWritable(path, key: key) }
        return checked
    }

    /// "calendar.<id>.lead_seconds" → "calendar.*.lead_seconds"; nil — не календарный ключ.
    static func calendarTemplate(for key: String) -> String? {
        let prefix = "calendar."
        guard key.hasPrefix(prefix) else { return nil }
        for field in [".lead_seconds", ".folder"] where key.hasSuffix(field) {
            // id между префиксом и полем не пустой: "calendar..folder" — опечатка, а не ключ
            guard key.count > prefix.count + field.count else { return nil }
            return "calendar.*" + field
        }
        return nil
    }

    /// Проверка типа и правил ключа. Её же проходит config.json при загрузке: ручная правка
    /// не должна протащить ".." в имя папки или минуту вместо секунд.
    static func validate(_ value: ConfigValue, spec: ConfigKeySpec, key: String) throws(ConfigError)
        -> ConfigValue
    {
        switch (spec.type, value) {
        case (.bool, .bool), (.stringList, .stringList):
            return value
        case (.int, .int(let number)):
            if let range = spec.range, !range.contains(number) {
                throw .invalidValue(
                    key: key, reason: "must be within \(range.lowerBound)...\(range.upperBound)")
            }
            return value
        case (.path, .string(let path)):
            return .string(try normalizedPath(path, key: key))
        case (.string, .string(let text)):
            try checkString(text, key: key)
            return value
        default:
            throw .invalidValue(key: key, reason: "expected \(spec.type.rawValue)")
        }
    }

    private static func spec(
        _ key: String, _ type: ConfigValueType, _ value: ConfigValue?, _ help: String,
        _ range: ClosedRange<Int>? = nil
    ) -> ConfigKeySpec {
        ConfigKeySpec(key: key, type: type, defaultValue: value, help: help, range: range)
    }

    /// JSON-массив строк или значения через запятую; пробелы по краям и пустые элементы выкидываем.
    private static func list(_ text: String, key: String) throws(ConfigError) -> [String] {
        let items: [String]
        if text.hasPrefix("[") {
            guard let decoded = try? JSONDecoder().decode([String].self, from: Data(text.utf8)) else {
                throw .invalidValue(
                    key: key, reason: "expected a JSON array of strings or comma-separated values")
            }
            items = decoded
        } else {
            items = text.split(separator: ",").map(String.init)
        }
        return items.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func checkString(_ text: String, key: String) throws(ConfigError) {
        let hasControl = text.unicodeScalars.contains { $0.properties.generalCategory == .control }
        switch key {
        case "transcription.language":
            guard text == "auto" || text.wholeMatch(of: /[a-z]{2,3}/) != nil else {
                throw .invalidValue(key: key, reason: "expected auto or a 2-3 letter lowercase language code")
            }
        case "transcript.label_me", "transcript.label_them":
            guard !text.isEmpty, !hasControl else {
                throw .invalidValue(key: key, reason: "expected a non-empty single-line label")
            }
        default:
            guard calendarTemplate(for: key) == "calendar.*.folder" else { return }
            // одно имя папки внутри recordings_dir: без "/" и без выхода наружу через ".."
            guard !text.isEmpty, !text.contains("/"), !text.contains(":"), !text.hasPrefix("."), !hasControl
            else {
                throw .invalidValue(
                    key: key,
                    reason: "expected a folder name without \"/\" or \":\" that does not start with \".\"")
            }
        }
    }

    /// ~ раскрыт, путь абсолютный и нормализованный. Desktop, Documents и Downloads (и всё внутри)
    /// запрещены: потребители, запущенные из терминала или Orca, получат TCC-промпт от чужого имени
    /// или тихий отказ. Проверяем и сам путь, и реальный после симлинков — ~/Rec → ~/Documents
    /// не должен проходить, даже если конечного каталога ещё нет.
    private static func normalizedPath(_ raw: String, key: String) throws(ConfigError) -> String {
        let expanded = (raw as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            throw .invalidValue(key: key, reason: "expected an absolute path or a path starting with ~")
        }
        // isDirectory: true — иначе URL сам сделает stat, чтобы узнать, каталог ли это. А `standardized`,
        // а не standardizedFileURL: тот при «..» раскрывает путь через ФС и зашёл бы в защищённую папку
        // раньше лексической проверки.
        let path = URL(fileURLWithPath: expanded, isDirectory: true).standardized.path
        try rejectProtected(path, key: key)
        try rejectProtectedTarget(path, key: key)
        return path
    }

    /// Идёт от корня по одному компоненту и раскрывает симлинки чтением (readlink), а не stat цели:
    /// stat и resolvingSymlinksInPath пропускают висячую ссылку, а каталог в ~/Downloads, куда она
    /// смотрит, пользователь создаст после первой ошибки mkdir. Каждый промежуточный путь
    /// проверяется до обращения к нему, так что внутрь защищённой папки не заглядываем вовсе.
    /// Несуществующий компонент дописывается как есть: recordings_dir создаётся при первой записи.
    private static func rejectProtectedTarget(_ path: String, key: String) throws(ConfigError) {
        var resolved = "/"
        var pending = path.split(separator: "/").map(String.init)
        var hops = 0
        while !pending.isEmpty {
            let component = pending.removeFirst()
            if component == "." { continue }
            // resolved уже без ссылок, поэтому ".." из цели ссылки поднимается по реальному родителю
            if component == ".." {
                resolved = (resolved as NSString).deletingLastPathComponent
                continue
            }
            let next = (resolved as NSString).appendingPathComponent(component)
            try rejectProtected(next, key: key)
            // не ссылка (каталог, файл) или ещё не существует — дальше от него
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: next) else {
                resolved = next
                continue
            }
            hops += 1
            // как MAXSYMLINKS в ядре: петля loopA ↔ loopB не должна вешать проверку
            guard hops <= 32 else {
                throw .invalidValue(key: key, reason: "too many levels of symbolic links")
            }
            // относительная цель — от реального родителя ссылки: лексический врёт из-за /var → /private/var
            if target.hasPrefix("/") { resolved = "/" }
            pending = target.split(separator: "/").map(String.init) + pending
        }
    }

    /// Desktop, Documents, Downloads и всё внутри; без учёта регистра — APFS по умолчанию такой же.
    private static func rejectProtected(_ path: String, key: String) throws(ConfigError) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // /System/Volumes/Data/Users — тот же /Users через firmlink, а его readlink не видит
        let dataVolume = "/system/volumes/data"
        var candidate = path.lowercased()
        if candidate.hasPrefix(dataVolume + "/") { candidate.removeFirst(dataVolume.count) }
        for folder in ["Desktop", "Documents", "Downloads"] {
            let protected = (home as NSString).appendingPathComponent(folder).lowercased()
            if candidate == protected || candidate.hasPrefix(protected + "/") {
                throw .invalidValue(
                    key: key,
                    reason:
                        "~/\(folder) is a TCC-protected folder; tools started from a terminal cannot read it")
            }
        }
    }

    /// Ближайший существующий предок должен быть каталогом, доступным на запись: сам каталог
    /// записей создаётся при первой записи.
    private static func checkWritable(_ path: String, key: String) throws(ConfigError) {
        let fm = FileManager.default
        var probe = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        while !fm.fileExists(atPath: probe.path, isDirectory: &isDirectory) {
            probe.deleteLastPathComponent()
        }
        guard isDirectory.boolValue, fm.isWritableFile(atPath: probe.path) else {
            throw .invalidValue(key: key, reason: "\(probe.path) is not a writable directory")
        }
    }
}
