import EarmarkCore
import Foundation

/// `earmark mcp` — stdio MCP-сервер для Codex и других MCP-клиентов (§9.4).
///
/// Протокол целиком в EarmarkCore.MCPServerCore; здесь только ввод-вывод: строки stdin → ядро →
/// строки stdout. Tool исполняют те же обработчики Registry, что и команды CLI, поэтому
/// поведение у них одинаковое по построению, а не по договорённости.
///
/// Подключение к Codex: `codex mcp add earmark -- ~/.local/bin/earmark mcp`. Seatbelt Codex
/// закрывает Unix-сокет для своего шелла, а stdio-MCP запускает вне песочницы — поэтому Codex
/// ходит в earmark только так.
enum MCPCommand {
    static func serve<Lines: AsyncSequence>(
        lines: Lines, context: CLIContext
    ) async -> Int32 where Lines.Element == String {
        // stdout здесь — протокол. Всё, что обработчики пишут «в stdout» (прогресс загрузки
        // модели, транскрипции), уходит в stderr, иначе клиент получил бы мусор вместо JSON-RPC.
        let toolContext = CLIContext(
            ipc: context.ipc, configStore: context.configStore,
            output: Output(stdout: context.output.stderr, stderr: context.output.stderr, prettyStdout: false))
        // Версия — из кода, а не из Info.plist: CLI лежит в Contents/Helpers, и Bundle.main там не app.
        let core = MCPServerCore(serverName: "earmark", version: EarmarkVersion.current) { parsed in
            await dispatch(parsed, toolContext)
        }
        do {
            // ponytail: запросы по одному — клиенты и так ждут ответа перед следующим вызовом.
            // Если клиенту понадобится отменять долгий stop_recording, нужен параллельный разбор.
            for try await line in lines {
                for reply in await core.handle(line: line) {
                    context.output.stdout(reply)
                }
            }
        } catch {
            context.output.stderr("earmark mcp: cannot read stdin: \(error)")
            return ExitCode.operationFailed.rawValue
        }
        // stdin закрыт — клиент ушёл, это штатное завершение.
        return ExitCode.ok.rawValue
    }

    /// Байты stdin → строки JSON-RPC, разделитель только 0x0A (§9.4).
    ///
    /// `AsyncBytes.lines` не годится: он режет ещё и по U+2028, U+2029 и NEL. JSON пускает их
    /// в строках без экранирования, serde_json (Codex) и JSON.stringify их не экранируют —
    /// один запрос развалился бы на куски с Parse error, а клиент ждал бы ответа до таймаута.
    /// CRLF не трогаем: хвостовой \r срезает ядро.
    static func lines<S: AsyncSequence & Sendable>(
        _ bytes: S
    ) -> AsyncThrowingStream<String, any Error> where S.Element == UInt8 {
        AsyncThrowingStream { continuation in
            let task = Task {
                // Битый UTF-8 → U+FFFD, как было у AsyncBytes.lines: строка всё равно дойдёт до ядра
                // и получит ответ, а failable-инициализатору пришлось бы выдумывать запасное значение.
                // swiftlint:disable:next optional_data_string_conversion
                func text(_ bytes: [UInt8]) -> String { String(decoding: bytes, as: UTF8.self) }
                var buffer: [UInt8] = []
                buffer.reserveCapacity(4096)
                do {
                    for try await byte in bytes {
                        if byte == 0x0A {
                            continuation.yield(text(buffer))
                            buffer.removeAll(keepingCapacity: true)
                        } else {
                            buffer.append(byte)
                        }
                    }
                    if !buffer.isEmpty {
                        continuation.yield(text(buffer))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Tool → обработчик команды CLI. Ошибка — Result.failure: ядро превратит её в isError,
    /// чтобы модель увидела текст, а не обрыв JSON-RPC.
    static func dispatch(
        _ parsed: ParsedCommand, _ context: CLIContext
    ) async -> Result<JSONValue, EarmarkError> {
        let command = parsed.path.joined(separator: " ")
        guard let handler = Registry.handlers[command] else {
            return .failure(.unavailable("command \"\(command)\" is not available in this build"))
        }
        do {
            return .success(try await handler(parsed, context))
        } catch {
            return .failure(error)
        }
    }
}
