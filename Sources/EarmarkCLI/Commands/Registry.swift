import EarmarkCore
import Foundation

/// Обработчик команды: данные для конверта или ошибка.
public typealias CommandHandler =
    @Sendable (ParsedCommand, CLIContext) async throws(EarmarkError) -> JSONValue

/// Всё внешнее, что нужно обработчику. По умолчанию — настоящие сокет, config.json и stdout;
/// тесты подставляют свои, поэтому ни один тест не трогает EARMARK_HOME.
public struct CLIContext: Sendable {
    public var ipc: IPCClient
    public var configStore: ConfigStore
    public var output: Output

    public init(ipc: IPCClient = .init(), configStore: ConfigStore = .init(), output: Output = .standard) {
        self.ipc = ipc
        self.configStore = configStore
        self.output = output
    }
}

/// Путь команды → обработчик. Таблица команд (разбор, help, MCP) живёт в EarmarkCore.CommandTable,
/// здесь только исполнение. Команда из таблицы без обработчика отвечает unavailable: так
/// `model …` и `mcp` видны в help ещё до того, как их соберут.
public enum Registry {
    /// Ключ — путь команды, склеенный пробелом ("calendars enable").
    public static var handlers: [String: CommandHandler] {
        [
            "help": { _, _ in CommandTable.helpJSON() },
            "status": AppCommands.status,
            "start": AppCommands.start,
            "stop": AppCommands.stop,
            "upcoming": AppCommands.upcoming,
            "calendars": AppCommands.calendars,
            "calendars enable": AppCommands.enableCalendar,
            "calendars disable": AppCommands.disableCalendar,
            "config set": AppCommands.configSet,
            "config reset": AppCommands.configReset,
            "doctor": AppCommands.doctor,
            "permissions request": AppCommands.requestPermissions,
            "transcribe": transcribe,
            "recordings": DiskCommands.recordings,
            "recording": DiskCommands.recording,
            "transcript": DiskCommands.transcript,
            "config list": DiskCommands.configList,
            "config get": DiskCommands.configGet,
        ]
    }

    /// `transcribe <id>` ставит запись в очередь app; с `--now` работа идёт в этом процессе —
    /// так app запускает воркер транскрипции, и app для этого не нужен.
    static let transcribe: CommandHandler = { parsed, context in
        if parsed.flag("now") {
            return try await transcribeNow(parsed, context)
        }
        return try await AppCommands.enqueueTranscription(parsed, context)
    }

    /// Воркер транскрипции. Пока whisper не подключён — честный отказ, а не тихая очередь.
    static let transcribeNow: CommandHandler = { _, _ in
        throw EarmarkError.unavailable("transcribe --now is not available in this build")
    }
}

extension ParsedCommand {
    /// Обязательный аргумент. Парсер его уже проверил — страховка для команд, собранных
    /// не из argv (MCP tool → ParsedCommand).
    func argument(_ name: String) throws(EarmarkError) -> String {
        guard let value = arguments[name], !value.isEmpty else {
            throw .invalidArguments("missing required argument <\(name)>")
        }
        return value
    }

    func flag(_ name: String) -> Bool { options[name] == "true" }

    /// Целое из опции. Не число или меньше `min` — invalid_arguments (exit 64), а не тихий дефолт:
    /// агент должен узнать, что его --limit не применился.
    func int(_ name: String, min: Int) throws(EarmarkError) -> Int? {
        guard let raw = options[name] else { return nil }
        guard let value = Int(raw), value >= min else {
            throw .invalidArguments("--\(name) \(raw): expected an integer >= \(min)")
        }
        return value
    }
}

extension CLIContext {
    /// config.json с диска. Читать его безопасно кому угодно: пишет только app, и атомарно.
    func loadConfig() throws(EarmarkError) -> Config {
        try disk("cannot read config.json") { try configStore.load() }
    }
}

/// Ошибки файловых API → коды CLI: битый или невалидный файл на диске — bad_data (65),
/// остальное — operation_failed.
func disk<T>(_ what: String, _ body: () throws -> T) throws(EarmarkError) -> T {
    do {
        return try body()
    } catch let error as EarmarkError {
        throw error
    } catch let error as DecodingError {
        throw .badData("\(what): the file is corrupt (\(error))")
    } catch let error as ConfigError {
        // ConfigStore.load проверяет значения схемой: ручная правка с чужим ключом — тоже битые данные
        throw .badData("\(what): \(error)")
    } catch {
        throw .operationFailed("\(what): \(error.localizedDescription)")
    }
}

/// Кодирование в JSONValue и обратно. Сбой — это несовпадение типов: либо баг earmark,
/// либо app другой версии прислал не то, поэтому bad_data.
func encodeJSON<T: Encodable>(_ value: T) throws(EarmarkError) -> JSONValue {
    do {
        return try JSONValue(encoding: value)
    } catch {
        throw .badData("cannot encode \(T.self) as JSON: \(error)")
    }
}

func decodeJSON<T: Decodable>(_ type: T.Type, from value: JSONValue) throws(EarmarkError) -> T {
    do {
        return try value.decode(type)
    } catch {
        throw .badData("app reply is not a valid \(T.self): \(error)")
    }
}
