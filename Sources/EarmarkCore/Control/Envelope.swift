import Foundation

/// JSON-конверт вывода CLI (спека §9.3). Формат — идея из anarlog (apps/cli/src/output.rs, MIT):
/// стабильный schema_version и машинный code ошибки, чтобы агент разбирал ответ, не читая текст.
public enum Envelope {
    public static let schemaVersion = 1

    /// {"schema_version":1,"command":…,"data":…}. `command` — путь команды через пробел
    /// ("calendars enable"), тот же ключ, что в Registry (Task 18).
    public static func success(command: String, data: JSONValue) -> JSONValue {
        ["schema_version": .number(Double(schemaVersion)), "command": .string(command), "data": data]
    }

    /// {"schema_version":1,"error":{"code","message","exit_code"}}
    public static func failure(_ error: EarmarkError) -> JSONValue {
        [
            "schema_version": .number(Double(schemaVersion)),
            "error": [
                "code": .string(error.code), "message": .string(error.message),
                "exit_code": .number(Double(error.exitCode)),
            ],
        ]
    }
}
