import EarmarkCore
import Foundation

/// Куда CLI пишет ответ. Вывод всегда JSON: успех — конверт в stdout, ошибка — в stderr (§9.3).
///
/// Писатели — замыкания, а не FileHandle: тесты ловят конверт без запуска процесса,
/// а `earmark mcp` подменяет «stdout» обработчиков на stderr, потому что его stdout — протокол.
public struct Output: Sendable {
    /// Получают одну законченную строку без "\n"; перевод строки добавляет сам писатель.
    public let stdout: @Sendable (String) -> Void
    public let stderr: @Sendable (String) -> Void
    /// Отступы — только для человека за терминалом; скрипт и агент читают компактную строку.
    public let prettyStdout: Bool

    public init(
        stdout: @escaping @Sendable (String) -> Void, stderr: @escaping @Sendable (String) -> Void,
        prettyStdout: Bool
    ) {
        self.stdout = stdout
        self.stderr = stderr
        self.prettyStdout = prettyStdout
    }

    /// FileHandle пишет прямо через write(2), без буфера stdio: строка уходит сразу. Для MCP
    /// это обязательно — клиент ждёт ответ построчно, а print() в пайпе копил бы вывод до выхода.
    public static let standard = Output(
        stdout: { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) },
        stderr: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) },
        prettyStdout: isatty(STDOUT_FILENO) == 1
    )

    public func success(command: String, data: JSONValue) {
        stdout(Self.render(Envelope.success(command: command, data: data), pretty: prettyStdout))
    }

    public func failure(_ error: EarmarkError) {
        stderr(Self.render(Envelope.failure(error), pretty: false))
    }

    /// Компактная (или красивая) JSON-строка. JSONValue кодируется всегда; запасной ответ нужен,
    /// чтобы невозможный сбой кодера не стал пустым выводом, который скрипт принял бы за успех.
    static func render(_ value: JSONValue, pretty: Bool) -> String {
        let encoder = pretty ? EarmarkJSON.prettyEncoder : EarmarkJSON.encoder
        guard let data = try? encoder.encode(value), let line = String(bytes: data, encoding: .utf8) else {
            return #"{"error":{"code":"operation_failed","exit_code":1},"schema_version":1}"#
        }
        return line
    }
}
