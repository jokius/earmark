import Foundation

/// Значение настройки. На диске и в выводе — обычный JSON (true, 60, "auto", ["id"]),
/// а не синтезированная обёртка enum'а вроде {"int":{"_0":60}}: config.json читают и правят руками.
public enum ConfigValue: Codable, Equatable, Sendable {
    case bool(Bool), int(Int), string(String), stringList([String])

    public var jsonValue: JSONValue {
        switch self {
        case .bool(let flag): .bool(flag)
        case .int(let number): .number(Double(number))
        case .string(let text): .string(text)
        case .stringList(let items): .array(items.map(JSONValue.string))
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let flag = try? container.decode(Bool.self) {
            self = .bool(flag)
        } else if let number = try? container.decode(Int.self) {
            self = .int(number)
        } else if let text = try? container.decode(String.self) {
            self = .string(text)
        } else {
            self = .stringList(try container.decode([String].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let flag): try container.encode(flag)
        case .int(let number): try container.encode(number)
        case .string(let text): try container.encode(text)
        case .stringList(let items): try container.encode(items)
        }
    }
}

public enum ConfigValueType: String, Codable, Sendable {
    case bool, int, string, path, stringList = "string_list"
}

/// Строка схемы. Из этой же таблицы собираются `config list`, `help --json` и описания для skill и MCP.
public struct ConfigKeySpec: Sendable {
    public let key: String  // "lead_seconds" или шаблон "calendar.*.lead_seconds"
    public let type: ConfigValueType
    public let defaultValue: ConfigValue?  // nil — ключ не задан (для calendar.*.*)
    public let help: String
    public let range: ClosedRange<Int>?  // для int
}

public enum ConfigError: Error, Equatable, Sendable {
    case unknownKey(String)
    case invalidValue(key: String, reason: String)
}

extension ConfigError: CustomStringConvertible, LocalizedError {
    /// Текст для конверта ошибки CLI: его читают человек и агент, поэтому без Swift-синтаксиса.
    public var description: String {
        switch self {
        case .unknownKey(let key): "unknown config key \"\(key)\"; see `earmark config list`"
        case .invalidValue(let key, let reason): "invalid value for \(key): \(reason)"
        }
    }

    /// Через нетипизированный `throws` (ConfigStore.load) ошибка доходит как `any Error`, и без
    /// LocalizedError `localizedDescription` выдал бы «The operation couldn’t be completed».
    public var errorDescription: String? { description }
}
