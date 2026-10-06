import Foundation

/// Пороги стоп-правил (спека §6) одной структурой — StopRules получает их без знания о ключах конфига.
public struct StopConfig: Equatable, Sendable {
    public var callEndSeconds: Int  // 60
    public var afterEndSeconds: Int  // 120
    public var endQuietSeconds: Int  // 60
    public var silenceMinutes: Int  // 10
    public var joinGraceMinutes: Int  // 10
    public var maxMinutes: Int  // 300
    public var minKeepSeconds: Int  // 45

    /// Из дефолтов схемы, а не второй копией чисел: значения живут в одном месте.
    public static let defaults = Config().stop
}

/// Конфиг earmark. Хранит только явно заданные ключи: `config list` показывает, что пользователь
/// менял сам, а новый дефолт в следующей версии доезжает до тех, кто его не трогал.
public struct Config: Equatable, Sendable {
    /// Только явно заданные ключи; остальное — дефолты схемы.
    public private(set) var values: [String: ConfigValue]

    public init(values: [String: ConfigValue] = [:]) {
        self.values = values
    }

    /// Явное или дефолт; nil для незаданного calendar.*.*.
    public func value(for key: String) -> ConfigValue? {
        values[key] ?? ConfigSchema.spec(for: key)?.defaultValue
    }

    public var autoRecord: Bool { bool("auto_record") }
    public var leadSeconds: Int { int("lead_seconds") }

    /// calendar.<id>.lead_seconds ?? leadSeconds.
    public func leadSeconds(forCalendar id: String) -> Int {
        if case .int(let seconds)? = values["calendar.\(id).lead_seconds"] { return seconds }
        return leadSeconds
    }

    /// ~ раскрыт.
    public var recordingsDir: URL {
        URL(fileURLWithPath: (string("recordings_dir") as NSString).expandingTildeInPath, isDirectory: true)
    }

    public var launchAtLogin: Bool { bool("launch_at_login") }

    /// Порядок = приоритет при перекрытиях.
    public var calendars: [String] {
        guard case .stringList(let ids)? = value(for: "calendars") else {
            preconditionFailure("config schema: calendars is not a string list")
        }
        return ids
    }

    public func folderOverride(forCalendar id: String) -> String? {
        guard case .string(let folder)? = values["calendar.\(id).folder"] else { return nil }
        return folder
    }

    public var stop: StopConfig {
        StopConfig(
            callEndSeconds: int("stop.call_end_seconds"),
            afterEndSeconds: int("stop.after_end_seconds"),
            endQuietSeconds: int("stop.end_quiet_seconds"),
            silenceMinutes: int("stop.silence_minutes"),
            joinGraceMinutes: int("stop.join_grace_minutes"),
            maxMinutes: int("stop.max_minutes"),
            minKeepSeconds: int("stop.min_keep_seconds"))
    }

    public var keepRawTracks: Bool { bool("audio.keep_raw_tracks") }
    public var transcriptionEnabled: Bool { bool("transcription.enabled") }
    /// "auto" или код whisper.
    public var transcriptionLanguage: String { string("transcription.language") }
    public var labelMe: String { string("transcript.label_me") }
    public var labelThem: String { string("transcript.label_them") }

    /// Возвращает (старое, новое) эффективное значение.
    @discardableResult
    public mutating func set(_ key: String, raw: String) throws(ConfigError) -> (
        old: ConfigValue?, new: ConfigValue
    ) {
        assign(try ConfigSchema.parse(raw, for: key), to: key)
    }

    @discardableResult
    public mutating func set(_ key: String, value: ConfigValue) throws(ConfigError) -> (
        old: ConfigValue?, new: ConfigValue
    ) {
        guard let spec = ConfigSchema.spec(for: key) else { throw .unknownKey(key) }
        return assign(try ConfigSchema.validate(value, spec: spec, key: key), to: key)
    }

    public mutating func reset(_ key: String) throws(ConfigError) {
        guard ConfigSchema.spec(for: key) != nil else { throw .unknownKey(key) }
        values[key] = nil
    }

    public mutating func resetAll() {
        values = [:]
    }

    /// Плоский список всех ключей схемы с эффективными значениями (+ заданные calendar.*.*).
    ///
    /// Шаблоны calendar.*.* тоже в списке (value = null): так агент из `config list` узнаёт,
    /// что такие ключи вообще есть. Заданные calendar.<id>.* идут сразу за своим шаблоном.
    public func listing() -> [ConfigListingItem] {
        ConfigSchema.all.flatMap { spec -> [ConfigListingItem] in
            guard spec.key.contains("*") else {
                let item = ConfigListingItem(
                    key: spec.key, value: value(for: spec.key)?.jsonValue ?? .null,
                    isDefault: values[spec.key] == nil, type: spec.type, help: spec.help)
                return [item]
            }
            let template = ConfigListingItem(
                key: spec.key, value: .null, isDefault: true, type: spec.type, help: spec.help)
            let explicit = values.keys
                .filter { ConfigSchema.calendarTemplate(for: $0) == spec.key }
                .sorted()
                .map { key in
                    ConfigListingItem(
                        key: key, value: values[key]?.jsonValue ?? .null, isDefault: false, type: spec.type,
                        help: spec.help)
                }
            return [template] + explicit
        }
    }

    private mutating func assign(_ value: ConfigValue, to key: String) -> (
        old: ConfigValue?, new: ConfigValue
    ) {
        let old = self.value(for: key)
        values[key] = value
        return (old, value)
    }

    // Тип значения гарантирован: set проверяет его по схеме, а у всех не-шаблонных ключей есть дефолт.
    // Падение здесь — расхождение схемы и аксессора, его ловит тест дефолтов. Текст падения уходит
    // в stderr, поэтому он английский (D40).
    private func bool(_ key: String) -> Bool {
        guard case .bool(let flag)? = value(for: key) else {
            preconditionFailure("config schema: \(key) is not bool")
        }
        return flag
    }

    private func int(_ key: String) -> Int {
        guard case .int(let number)? = value(for: key) else {
            preconditionFailure("config schema: \(key) is not int")
        }
        return number
    }

    private func string(_ key: String) -> String {
        guard case .string(let text)? = value(for: key) else {
            preconditionFailure("config schema: \(key) is not string")
        }
        return text
    }
}

public struct ConfigListingItem: Codable, Equatable, Sendable {
    public let key: String
    public let value: JSONValue
    public let isDefault: Bool
    public let type: ConfigValueType
    public let help: String
}
