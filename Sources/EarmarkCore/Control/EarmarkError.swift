import Foundation

/// Коды выхода CLI (спека §9.3). 64/65/69/75 — из sysexits.h: так их понимают shell-скрипты
/// и Orca `--precheck`, а usage-ошибка не путается с not_found = 2.
public enum ExitCode: Int32, Sendable {
    case ok = 0, operationFailed = 1, notFound = 2, appNotRunning = 3, permissionDenied = 4
    case invalidArguments = 64, badData = 65, unavailable = 69, busy = 75
}

/// Ошибка, которую видят человек и агент: машинный code, текст и код выхода.
/// Одна и та же в ответе IPC, в stderr CLI и в isError-результате MCP.
public struct EarmarkError: Error, Codable, Equatable, Sendable {
    public var code: String  // "not_found", "invalid_arguments", "app_not_running", "busy", ...
    public var message: String
    public var exitCode: Int32

    public init(code: String, message: String, exitCode: ExitCode) {
        self.code = code
        self.message = message
        self.exitCode = exitCode.rawValue
    }

    public static func notFound(_ message: String) -> EarmarkError {
        EarmarkError(code: "not_found", message: message, exitCode: .notFound)
    }

    public static func invalidArguments(_ message: String) -> EarmarkError {
        EarmarkError(code: "invalid_arguments", message: message, exitCode: .invalidArguments)
    }

    public static func appNotRunning(_ message: String) -> EarmarkError {
        EarmarkError(code: "app_not_running", message: message, exitCode: .appNotRunning)
    }

    public static func operationFailed(_ message: String) -> EarmarkError {
        EarmarkError(code: "operation_failed", message: message, exitCode: .operationFailed)
    }

    public static func permissionDenied(_ message: String) -> EarmarkError {
        EarmarkError(code: "permission_denied", message: message, exitCode: .permissionDenied)
    }

    public static func badData(_ message: String) -> EarmarkError {
        EarmarkError(code: "bad_data", message: message, exitCode: .badData)
    }

    public static func unavailable(_ message: String) -> EarmarkError {
        EarmarkError(code: "unavailable", message: message, exitCode: .unavailable)
    }

    public static func busy(_ message: String) -> EarmarkError {
        EarmarkError(code: "busy", message: message, exitCode: .busy)
    }
}

/// Ошибка, прошедшая через нетипизированный `throws` (ModelStore, async-задачи app), печатается
/// через localizedDescription. Без этого вместо message было бы «The operation couldn’t be completed».
extension EarmarkError: LocalizedError {
    public var errorDescription: String? { message }
}
