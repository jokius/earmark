import EarmarkCore
import Foundation

/// Точка входа CLI: argv → разбор по CommandTable → обработчик из Registry → конверт и код выхода.
public enum EarmarkCLI {
    /// argv без имени бинаря → exit code. Пишет конверт в stdout или ошибку в stderr.
    public static func run(_ argv: [String]) async -> Int32 {
        await run(argv, context: CLIContext())
    }

    /// То же с явным контекстом: тесты подставляют свой сокет, конфиг и перехват вывода.
    public static func run(_ argv: [String], context: CLIContext) async -> Int32 {
        let parsed: ParsedCommand
        do {
            // Голый `earmark` парсер отдаёт как help: это первое, что набирает человек или агент.
            parsed = try CommandTable.parse(argv)
        } catch {
            context.output.failure(error)
            return error.exitCode
        }
        let command = parsed.path.joined(separator: " ")
        // stdio-сервер — не команда с одним ответом: конверт не печатаем, stdout целиком его.
        if command == "mcp" {
            return await MCPCommand.serve(
                lines: MCPCommand.lines(FileHandle.standardInput.bytes), context: context)
        }
        do throws(EarmarkError) {
            guard let handler = Registry.handlers[command] else {
                throw EarmarkError.unavailable("command \"\(command)\" is not available in this build")
            }
            let data = try await handler(parsed, context)
            context.output.success(command: command, data: data)
            // doctor — единственная команда «отчёт есть, но не 0»: как у Anarlog, отчёт идёт
            // в stdout, а exit 1 говорит скрипту «не всё готово» (§10).
            if command == "doctor", data["ready"]?.boolValue == false {
                return ExitCode.operationFailed.rawValue
            }
            return ExitCode.ok.rawValue
        } catch {
            context.output.failure(error)
            return error.exitCode
        }
    }
}
