import Foundation

// Таблица команд — единый источник для парсера CLI, help --json и MCP tools/list:
// skill и MCP не могут разойтись с CLI, потому что не описывают команды сами.

public struct ArgSpec: Sendable {
    public var name: String
    public var help: String
    public var required: Bool
}

public struct OptionSpec: Sendable {
    public var name: String  // "--since"
    public var help: String
    public var takesValue: Bool  // false → флаг
}

public struct CommandSpec: Sendable {
    public var path: [String]  // ["calendars", "enable"]
    public var summary: String
    public var arguments: [ArgSpec] = []
    public var options: [OptionSpec] = []
    public var needsApp: Bool  // поднимать app, если сокет мёртв
    public var mcpTool: String?  // nil — нет в MCP
    public var readOnly: Bool
}

public struct ParsedCommand: Equatable, Sendable {
    public var path: [String]
    public var arguments: [String: String]
    public var options: [String: String]  // без "--"; флаги → "true"

    public init(path: [String], arguments: [String: String] = [:], options: [String: String] = [:]) {
        self.path = path
        self.arguments = arguments
        self.options = options
    }
}

public enum CommandTable {
    public static let all: [CommandSpec] = [
        CommandSpec(
            path: ["status"],
            summary: "Recorder status; never launches the app, reports app_running false instead",
            needsApp: false, mcpTool: "get_status", readOnly: true),
        CommandSpec(
            path: ["start"],
            summary: "Start a manual recording now; idempotent, returns the running one if any",
            options: [value("--title", "Recording title")],
            needsApp: true, mcpTool: "start_recording", readOnly: false),
        CommandSpec(
            path: ["stop"],
            summary: "Stop the current recording; replies after the audio is finalized; "
                + "never launches the app, returns null when nothing is recording",
            needsApp: false, mcpTool: "stop_recording", readOnly: false),
        CommandSpec(
            path: ["upcoming"], summary: "Calendar events that will be recorded automatically",
            options: [value("--hours", "Look-ahead window in hours (integer, default 24)")],
            needsApp: true, mcpTool: "list_upcoming_events", readOnly: true),
        CommandSpec(
            path: ["calendars"], summary: "Calendars with their enabled flag, account and recordings folder",
            needsApp: true, mcpTool: "list_calendars", readOnly: true),
        CommandSpec(
            path: ["calendars", "enable"], summary: "Record events of this calendar automatically",
            arguments: [calendarID], needsApp: true, mcpTool: "set_calendar_enabled", readOnly: false),
        CommandSpec(
            path: ["calendars", "disable"], summary: "Stop recording events of this calendar",
            arguments: [calendarID], needsApp: true, mcpTool: "set_calendar_enabled", readOnly: false),
        CommandSpec(
            path: ["recordings"], summary: "Recordings, newest first",
            options: [
                value("--since", "Only recordings started at or after this ISO 8601 date or time"),
                value(
                    "--until",
                    "Only recordings started before this ISO 8601 date-time; "
                        + "a date (YYYY-MM-DD) includes the whole day"),
                value("--calendar", "Calendar id"),
                value("--status", "recording, recorded, transcribing, transcribed or transcription_failed"),
                value("--limit", "Maximum number of recordings (integer)"),
            ],
            needsApp: false, mcpTool: "list_recordings", readOnly: true),
        CommandSpec(
            path: ["recording"], summary: "One recording: meta.json plus file paths",
            arguments: [recordingID], needsApp: false, mcpTool: "get_recording", readOnly: true),
        CommandSpec(
            path: ["transcript"], summary: "Transcript in pages of words; continue with next_offset",
            arguments: [recordingID],
            options: [
                value("--offset", "Word offset to start from (integer, default 0)"),
                value("--words", "Words per page (integer, default 200, max 500)"),
                value("--format", "txt (dialogue) or json (segments)"),
            ],
            needsApp: false, mcpTool: "get_transcript", readOnly: true),
        CommandSpec(
            path: ["transcribe"],
            summary: "Queue a recording for transcription in the app; returns its queue position",
            arguments: [recordingID],
            options: [
                flag("--force", "Transcribe again even if transcripts exist"),
                flag("--now", "Transcribe in this process, not in the app queue (the app's worker mode)"),
            ],
            needsApp: true, mcpTool: "transcribe_recording", readOnly: false),
        CommandSpec(
            path: ["model", "status"], summary: "Whisper model state: missing, downloading, ready or corrupt",
            needsApp: false, readOnly: true),
        CommandSpec(
            path: ["model", "download"], summary: "Download and verify the whisper model (about 1.6 GB)",
            needsApp: false, readOnly: false),
        CommandSpec(
            path: ["model", "import"],
            summary: "Copy an existing ggml-large-v3-turbo.bin after checking its sha256",
            arguments: [ArgSpec(name: "path", help: "Path to the model file", required: true)],
            needsApp: false, readOnly: false),
        CommandSpec(
            path: ["config", "list"], summary: "All config keys with effective values, defaults and help",
            needsApp: false, mcpTool: "get_config", readOnly: true),
        CommandSpec(
            path: ["config", "get"], summary: "One config key",
            arguments: [configKey(required: true)], needsApp: false, mcpTool: "get_config", readOnly: true),
        CommandSpec(
            path: ["config", "set"], summary: "Validate a config value and apply it immediately",
            arguments: [
                configKey(required: true),
                ArgSpec(
                    name: "value", help: "New value; lists: comma-separated or a JSON array", required: true),
            ],
            needsApp: true, mcpTool: "set_config", readOnly: false),
        CommandSpec(
            path: ["config", "reset"], summary: "Reset a config key to its default, or every key with --all",
            arguments: [configKey(required: false)], options: [flag("--all", "Reset every key")],
            needsApp: true, mcpTool: "reset_config", readOnly: false),
        CommandSpec(
            path: ["doctor"],
            summary: "Check app, permissions, calendars, folders, model; exit 1 if not ready",
            options: [
                flag("--audio-test", "Also play a short quiet tone and check that system audio hears it")
            ],
            needsApp: true, mcpTool: "doctor", readOnly: true),
        CommandSpec(
            path: ["permissions", "request"], summary: "Ask the app to show the system permission prompts",
            needsApp: true, readOnly: false),
        CommandSpec(path: ["mcp"], summary: "Run the stdio MCP server", needsApp: false, readOnly: false),
        CommandSpec(
            path: ["help"], summary: "Command list; --json for the machine-readable schema",
            options: [flag("--json", "Machine-readable output")], needsApp: false, readOnly: true),
    ]

    /// argv без имени бинаря. Путь — самый длинный совпавший префикс, дальше позиционные аргументы
    /// по порядку, "--name value", "--name=value" и флаги. "--" отключает разбор опций до конца.
    public static func parse(_ argv: [String]) throws(EarmarkError) -> ParsedCommand {
        if argv.isEmpty || argv == ["--help"] || argv == ["-h"] { return ParsedCommand(path: ["help"]) }
        guard let spec = longestMatch(argv) else { throw unknownCommand(argv) }
        var parsed = ParsedCommand(path: spec.path)
        var positionals: [String] = []
        var rest = argv.dropFirst(spec.path.count)[...]
        while let token = rest.popFirst() {
            if token == "--" {
                positionals += rest
                break
            }
            if token.hasPrefix("--") {
                let (name, value) = try option(token, rest: &rest, spec)
                parsed.options[name] = value
            } else {
                // отрицательные числа и "-" — значения: `config set lead_seconds -5` дойдёт до валидации
                positionals.append(token)
            }
        }
        parsed.arguments = try bind(positionals, spec)
        return parsed
    }

    /// {commands:[{path, summary, usage, arguments, options, needs_app, mcp_tool}], config_keys:[…]}.
    /// Ключи конфига — тоже отсюда: агент узнаёт всю схему одной командой.
    public static func helpJSON() -> JSONValue {
        let commands: [JSONValue] = all.map { spec in
            [
                "path": .string(spec.path.joined(separator: " ")),
                "summary": .string(spec.summary),
                "usage": .string(usage(spec)),
                "arguments": .array(
                    spec.arguments.map {
                        ["name": .string($0.name), "help": .string($0.help), "required": .bool($0.required)]
                    }),
                "options": .array(
                    spec.options.map {
                        [
                            "name": .string($0.name), "help": .string($0.help),
                            "takes_value": .bool($0.takesValue),
                        ]
                    }),
                "needs_app": .bool(spec.needsApp),
                "mcp_tool": spec.mcpTool.map(JSONValue.string) ?? .null,
            ]
        }
        let configKeys: [JSONValue] = ConfigSchema.all.map { spec in
            let range: JSONValue =
                spec.range.map { [.number(Double($0.lowerBound)), .number(Double($0.upperBound))] } ?? .null
            return [
                "key": .string(spec.key), "type": .string(spec.type.rawValue),
                "default": spec.defaultValue?.jsonValue ?? .null, "range": range, "help": .string(spec.help),
            ]
        }
        return ["commands": .array(commands), "config_keys": .array(configKeys)]
    }

    // MARK: - внутреннее

    static let calendarID = ArgSpec(name: "id", help: "Calendar id from `earmark calendars`", required: true)
    static let recordingID = ArgSpec(
        name: "id", help: "Recording id from `earmark recordings`", required: true)

    static func configKey(required: Bool) -> ArgSpec {
        ArgSpec(name: "key", help: "Config key from `earmark config list`", required: required)
    }

    static func value(_ name: String, _ help: String) -> OptionSpec {
        OptionSpec(name: name, help: help, takesValue: true)
    }

    static func flag(_ name: String, _ help: String) -> OptionSpec {
        OptionSpec(name: name, help: help, takesValue: false)
    }

    /// "earmark config reset [<key>] [--all]".
    static func usage(_ spec: CommandSpec) -> String {
        let arguments = spec.arguments.map { $0.required ? "<\($0.name)>" : "[<\($0.name)>]" }
        let options = spec.options.map { $0.takesValue ? "[\($0.name) <value>]" : "[\($0.name)]" }
        return (["earmark"] + spec.path + arguments + options).joined(separator: " ")
    }

    private static func longestMatch(_ argv: [String]) -> CommandSpec? {
        all.filter { argv.starts(with: $0.path) }.max { $0.path.count < $1.path.count }
    }

    /// "--name value", "--name=value" или флаг → (имя без "--", значение; у флага "true").
    private static func option(_ token: String, rest: inout ArraySlice<String>, _ spec: CommandSpec)
        throws(EarmarkError) -> (String, String)
    {
        let body = token.dropFirst(2)
        let name = String(body.prefix { $0 != "=" })
        let inline: String? = body.contains("=") ? String(body.drop { $0 != "=" }.dropFirst()) : nil
        guard let option = spec.options.first(where: { $0.name == "--" + name }) else {
            throw usageError("unknown option --\(name)", spec)
        }
        guard option.takesValue else {
            guard inline == nil else { throw usageError("--\(name) does not take a value", spec) }
            return (name, "true")
        }
        guard let value = inline ?? rest.popFirst() else {
            throw usageError("--\(name) requires a value", spec)
        }
        return (name, value)
    }

    /// Позиционные значения → аргументы команды по порядку.
    private static func bind(_ positionals: [String], _ spec: CommandSpec)
        throws(EarmarkError) -> [String: String]
    {
        guard positionals.count <= spec.arguments.count else {
            throw usageError("unexpected argument \"\(positionals[spec.arguments.count])\"", spec)
        }
        var arguments: [String: String] = [:]
        for (index, arg) in spec.arguments.enumerated() {
            if index < positionals.count {
                arguments[arg.name] = positionals[index]
            } else if arg.required {
                throw usageError("missing required argument <\(arg.name)>", spec)
            }
        }
        return arguments
    }

    private static func unknownCommand(_ argv: [String]) -> EarmarkError {
        // "earmark config" без подкоманды — подсказываем, какие есть
        let family = all.filter { $0.path.first == argv.first }.map(usage)
        guard family.isEmpty else {
            return .invalidArguments(
                "incomplete command \"\(argv[0])\"; use one of: " + family.joined(separator: " | "))
        }
        return .invalidArguments("unknown command \"\(argv[0])\"; run `earmark help --json` for the list")
    }

    private static func usageError(_ problem: String, _ spec: CommandSpec) -> EarmarkError {
        let subcommands = all.filter { $0.path.count > spec.path.count && $0.path.starts(with: spec.path) }
        let also =
            subcommands.isEmpty ? "" : "; subcommands: " + subcommands.map(usage).joined(separator: " | ")
        return .invalidArguments("\(problem). Usage: \(usage(spec))\(also)")
    }

    // MARK: - MCP

    /// Опции, которых нет в MCP: агент ставит транскрипцию только в очередь app,
    /// а транскрипция в своём процессе — режим воркера самого app.
    static let mcpHiddenOptions: Set<String> = ["--now"]

    /// name, description, inputSchema, annotations. Порядок детерминирован (как в таблице):
    /// клиенты кэшируют список, а модели — промпт.
    public static func mcpTools() -> [JSONValue] {
        var seen: Set<String> = []
        return all.compactMap { spec in
            guard let name = spec.mcpTool, seen.insert(name).inserted else { return nil }
            return [
                "name": .string(name),
                "description": .string(toolDescription(name, spec)),
                "inputSchema": inputSchema(name, spec),
                "annotations": [
                    "readOnlyHint": .bool(spec.readOnly),
                    "destructiveHint": false,
                    // повторный старт возвращает идущую запись, повторный стоп — no-op; очередь — нет
                    "idempotentHint": .bool(name != "transcribe_recording"),
                    "openWorldHint": false,
                ],
            ]
        }
    }

    /// MCP tool → ParsedCommand (аргументы tool'а → arguments/options команды).
    public static func command(forTool name: String, arguments: JSONValue) throws(EarmarkError)
        -> ParsedCommand
    {
        let input: [String: JSONValue]
        switch arguments {
        case .object(let fields): input = fields
        case .null: input = [:]
        default: throw .invalidArguments("\(name): arguments must be an object")
        }
        switch name {
        case "set_calendar_enabled":
            // один tool на две команды: так агенту не нужно знать про пару enable/disable
            try rejectUnknown(input, allowed: ["id", "enabled"], tool: name)
            guard let id = try scalar(input["id"], "id", tool: name),
                let enabled = input["enabled"]?.boolValue
            else {
                throw .invalidArguments(#"set_calendar_enabled: expected {"id": string, "enabled": boolean}"#)
            }
            return ParsedCommand(path: ["calendars", enabled ? "enable" : "disable"], arguments: ["id": id])
        case "get_config":
            try rejectUnknown(input, allowed: ["key"], tool: name)
            guard let key = try scalar(input["key"], "key", tool: name) else {
                return ParsedCommand(path: ["config", "list"])
            }
            return ParsedCommand(path: ["config", "get"], arguments: ["key": key])
        default:
            guard let spec = all.first(where: { $0.mcpTool == name }) else {
                throw .notFound("unknown tool \(name)")
            }
            return try mapped(spec, input, tool: name)
        }
    }

    /// Обычный tool: аргументы по именам, опции — по имени без "--" (дефис → подчёркивание).
    private static func mapped(_ spec: CommandSpec, _ input: [String: JSONValue], tool: String)
        throws(EarmarkError) -> ParsedCommand
    {
        let options = spec.options.filter { !mcpHiddenOptions.contains($0.name) }
        let allowed = Set(spec.arguments.map(\.name) + options.map { mcpName($0.name) })
        try rejectUnknown(input, allowed: allowed, tool: tool)
        var parsed = ParsedCommand(path: spec.path)
        for arg in spec.arguments {
            parsed.arguments[arg.name] = try scalar(input[arg.name], arg.name, tool: tool)
            if arg.required, parsed.arguments[arg.name] == nil {
                throw .invalidArguments("\(tool): missing required argument \"\(arg.name)\"")
            }
        }
        for option in options {
            let key = mcpName(option.name)
            let cliName = String(option.name.dropFirst(2))
            if option.takesValue {
                parsed.options[cliName] = try scalar(input[key], key, tool: tool)
            } else if let flag = input[key], flag != .null {
                guard let on = flag.boolValue else {
                    throw .invalidArguments("\(tool): \"\(key)\" must be a boolean")
                }
                if on { parsed.options[cliName] = "true" }
            }
        }
        return parsed
    }

    private static func toolDescription(_ name: String, _ spec: CommandSpec) -> String {
        switch name {
        case "set_calendar_enabled":
            "Enable or disable automatic recording for a calendar (id from list_calendars)"
        case "get_config": "Read config: every key with value, default flag and help, or one key"
        default: spec.summary
        }
    }

    /// JSON Schema (draft 2020-12): аргументы и опции со значением — строки (CLI всё равно принимает
    /// строку, а числа и bool приводит command(forTool:)), флаги — boolean.
    private static func inputSchema(_ name: String, _ spec: CommandSpec) -> JSONValue {
        var properties: [String: JSONValue] = [:]
        var required: [String] = []
        switch name {
        case "set_calendar_enabled":
            properties["id"] = property("string", "Calendar id from list_calendars")
            properties["enabled"] = property(
                "boolean", "true to record its events automatically, false to stop")
            required = ["id", "enabled"]
        case "get_config":
            properties["key"] = property("string", "Config key; omit to list every key")
        default:
            for arg in spec.arguments {
                properties[arg.name] = property("string", arg.help)
                if arg.required { required.append(arg.name) }
            }
            for option in spec.options where !mcpHiddenOptions.contains(option.name) {
                properties[mcpName(option.name)] = property(
                    option.takesValue ? "string" : "boolean", option.help)
            }
        }
        var schema: [String: JSONValue] = [
            "type": "object", "properties": .object(properties), "additionalProperties": false,
        ]
        if !required.isEmpty { schema["required"] = .array(required.map(JSONValue.string)) }
        return .object(schema)
    }

    private static func property(_ type: String, _ description: String) -> JSONValue {
        ["type": .string(type), "description": .string(description)]
    }

    /// "--audio-test" → "audio_test": имена свойств MCP — идентификаторы, дефис в них неудобен моделям.
    private static func mcpName(_ option: String) -> String {
        String(option.dropFirst(2)).replacingOccurrences(of: "-", with: "_")
    }

    private static func rejectUnknown(_ input: [String: JSONValue], allowed: Set<String>, tool: String)
        throws(EarmarkError)
    {
        if let unknown = input.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw .invalidArguments("\(tool): unknown argument \"\(unknown)\"")
        }
    }

    /// Скаляр как строка CLI: агенты присылают limit числом, а enabled — bool. null и отсутствие — nil.
    private static func scalar(_ value: JSONValue?, _ key: String, tool: String) throws(EarmarkError)
        -> String?
    {
        switch value {
        case nil, .null?: return nil
        case .string(let text)?: return text
        case .bool(let flag)?: return flag ? "true" : "false"
        case .number(let number)?: return Int(exactly: number).map(String.init) ?? String(number)
        default: throw .invalidArguments("\(tool): \"\(key)\" must be a string, number or boolean")
        }
    }
}
