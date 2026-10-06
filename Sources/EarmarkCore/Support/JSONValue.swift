import Foundation

/// Произвольный JSON: data в конверте CLI, params в IPC, аргументы и результаты MCP.
///
/// Числа хранятся как Double — так их видит любой JSON-парсер. Целые (exit_code, limit) кодируются
/// без «.0», а `intValue` отдаёт их обратно как Int.
public enum JSONValue: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    /// Через EarmarkJSON.encoder: ключи структур уходят в snake_case — ровно как в выводе CLI.
    public init<T: Encodable>(encoding value: T) throws {
        let data = try EarmarkJSON.encoder.encode(value)
        // обратный разбор — простым декодером: ключи уже в нужном виде, переводить их некуда
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Обратно в тип через EarmarkJSON.decoder (snake_case → camelCase, даты ISO 8601).
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try EarmarkJSON.decoder.decode(type, from: JSONEncoder().encode(self))
    }

    public subscript(key: String) -> JSONValue? {
        guard case .object(let fields) = self else { return nil }
        return fields[key]
    }

    public var stringValue: String? {
        guard case .string(let text) = self else { return nil }
        return text
    }

    /// Только для целых: 3.5 → nil, а не 3 — дробный limit или offset лучше отвергнуть, чем обрезать.
    public var intValue: Int? {
        guard case .number(let number) = self else { return nil }
        return Int(exactly: number)
    }

    public var boolValue: Bool? {
        guard case .bool(let flag) = self else { return nil }
        return flag
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        // JSONDecoder строг: true не читается как число, 1 — как Bool, поэтому порядок проб безопасен
        if container.decodeNil() {
            self = .null
        } else if let flag = try? container.decode(Bool.self) {
            self = .bool(flag)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let text = try? container.decode(String.self) {
            self = .string(text)
        } else if let items = try? container.decode([JSONValue].self) {
            self = .array(items)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let flag): try container.encode(flag)
        case .number(let number): try container.encode(number)
        case .string(let text): try container.encode(text)
        case .array(let items): try container.encode(items)
        case .object(let fields): try container.encode(fields)
        }
    }
}

// Литералы — чтобы конверты, JSON Schema и golden-тесты MCP читались как JSON,
// а не как матрёшка из `.object`.
extension JSONValue: ExpressibleByStringInterpolation, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
