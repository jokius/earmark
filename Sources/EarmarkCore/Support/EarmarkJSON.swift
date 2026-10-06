import Foundation

/// Единственный источник JSON-кодеров: на диске, в IPC и в выводе CLI ключи одни и те же.
///
/// snake_case — потому что эти ключи читают люди, jq и агенты, а не только Swift. Даты — ISO 8601
/// в UTC: строка из meta.json сравнивается как есть и не зависит от часового пояса читателя.
/// Ключи словарей (`[String: …]`, JSONValue.object) стратегия не трогает, это закреплено тестом:
/// иначе id календарей в config.json превратились бы в «snake_case» из прописных букв.
public enum EarmarkJSON {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        // без экранирования "/" пути в выводе читаются как есть: "/Users/…", а не "\/Users\/…"
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static var prettyEncoder: JSONEncoder {
        let pretty = encoder
        pretty.outputFormatting.insert(.prettyPrinted)
        return pretty
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
