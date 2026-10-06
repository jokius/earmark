import Foundation

/// Методы IPC app ↔ CLI (спека §9.2).
public enum IPCMethod {
    public static let status = "status"
    public static let recordingStart = "recording.start", recordingStop = "recording.stop"
    public static let calendarList = "calendar.list", calendarUpcoming = "calendar.upcoming"
    public static let configSet = "config.set", configReset = "config.reset"
    public static let transcriptionEnqueue = "transcription.enqueue"
    public static let doctor = "doctor", permissionsRequest = "permissions.request", audioTest = "audio.test"
}

/// {"v":1,"method":"…","params":{…}} — одна строка на соединение.
public struct IPCRequest: Codable, Equatable, Sendable {
    // swiftlint:disable:next identifier_name
    public var v: Int = 1  // имя поля — часть протокола (спека §9.2)
    public var method: String
    public var params: JSONValue

    // swiftlint:disable:next identifier_name
    public init(v: Int = 1, method: String, params: JSONValue = [:]) {
        self.v = v
        self.method = method
        self.params = params
    }
}

/// {"ok":true,"data":…} или {"ok":false,"error":{…}}.
///
/// `data: null` при разборе становится nil (так устроен decodeIfPresent) — клиент читает
/// `response.data ?? .null`.
public struct IPCResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var data: JSONValue?
    public var error: EarmarkError?

    public static func success(_ data: JSONValue) -> IPCResponse {
        IPCResponse(ok: true, data: data, error: nil)
    }

    public static func failure(_ error: EarmarkError) -> IPCResponse {
        IPCResponse(ok: false, data: nil, error: error)
    }
}

/// Кадрирование: одна JSON-строка + "\n". Лимит строки 1 MiB.
///
/// Тот же формат, что у stdio MCP (newline-delimited JSON): JSONEncoder без prettyPrinted никогда
/// не пишет перевод строки внутри сообщения, а лимит не даёт кривому клиенту съесть память app.
public enum IPCFraming {
    /// Читающая сторона (IPCServer, IPCClient) обрывает строку, переросшую этот размер. Обе берут
    /// лимит отсюда, а не своим литералом: иначе сервер и клиент разойдутся при первой же правке.
    public static let maxLineBytes = 1 << 20

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        var line = try EarmarkJSON.encoder.encode(value)
        guard line.count < maxLineBytes else { throw EarmarkError.badData("message is larger than 1 MiB") }
        line.append(0x0A)
        return line
    }

    /// Принимает строку без "\n" — так её отдаёт цикл чтения; завершающий "\n" тоже терпит.
    public static func decode<T: Decodable>(_ type: T.Type, from line: Data) throws -> T {
        guard line.count <= maxLineBytes else { throw EarmarkError.badData("line is larger than 1 MiB") }
        let body = line.last == 0x0A ? line.dropLast() : line
        do {
            return try EarmarkJSON.decoder.decode(type, from: body)
        } catch {
            throw EarmarkError.badData("malformed IPC message: \(error.localizedDescription)")
        }
    }
}
