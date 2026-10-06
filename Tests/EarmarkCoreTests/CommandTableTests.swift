import Foundation
import Testing

@testable import EarmarkCore

@Suite("Таблица команд: парсер CLI, help --json, MCP tools")
struct CommandTableTests {
    /// Все команды спеки §9.3 — таблица обязана содержать ровно их.
    private let specPaths = [
        "status", "start", "stop", "upcoming", "calendars", "calendars enable", "calendars disable",
        "recordings", "recording", "transcript", "transcribe", "model status", "model download",
        "model import",
        "config list", "config get", "config set", "config reset", "doctor", "permissions request", "mcp",
        "help",
    ]

    @Test(
        "разбор argv: самый длинный путь, позиционные по порядку, --name value, --name=value, флаги",
        arguments: [
            (["status"], ParsedCommand(path: ["status"])),
            (
                ["start", "--title", "Daily sync"],
                ParsedCommand(path: ["start"], options: ["title": "Daily sync"])
            ),
            (
                ["start", "--title=Daily sync"],
                ParsedCommand(path: ["start"], options: ["title": "Daily sync"])
            ),
            (["calendars"], ParsedCommand(path: ["calendars"])),
            (
                ["calendars", "enable", "CAL-1"],
                ParsedCommand(path: ["calendars", "enable"], arguments: ["id": "CAL-1"])
            ),
            (
                ["recordings", "--since", "2026-10-01", "--status", "transcribed", "--limit", "5"],
                ParsedCommand(
                    path: ["recordings"],
                    options: ["since": "2026-10-01", "status": "transcribed", "limit": "5"])
            ),
            (
                ["transcribe", "20261002-1400-a1b2", "--now", "--force"],
                ParsedCommand(
                    path: ["transcribe"], arguments: ["id": "20261002-1400-a1b2"],
                    options: ["now": "true", "force": "true"])
            ),
            (
                ["config", "set", "transcript.label_me", "Я"],
                ParsedCommand(
                    path: ["config", "set"], arguments: ["key": "transcript.label_me", "value": "Я"])
            ),
            (
                ["config", "set", "lead_seconds", "-5"],
                ParsedCommand(path: ["config", "set"], arguments: ["key": "lead_seconds", "value": "-5"])
            ),
            (
                ["config", "set", "transcript.label_them", "--", "--Them--"],
                ParsedCommand(
                    path: ["config", "set"], arguments: ["key": "transcript.label_them", "value": "--Them--"])
            ),
            (
                ["config", "reset", "--all"],
                ParsedCommand(path: ["config", "reset"], options: ["all": "true"])
            ),
            (
                ["config", "reset", "lead_seconds"],
                ParsedCommand(path: ["config", "reset"], arguments: ["key": "lead_seconds"])
            ),
            (["doctor", "--audio-test"], ParsedCommand(path: ["doctor"], options: ["audio-test": "true"])),
            (
                ["model", "import", "/tmp/m.bin"],
                ParsedCommand(path: ["model", "import"], arguments: ["path": "/tmp/m.bin"])
            ),
            (["help", "--json"], ParsedCommand(path: ["help"], options: ["json": "true"])),
            ([], ParsedCommand(path: ["help"])),
            (["--help"], ParsedCommand(path: ["help"])),
        ])
    func parses(argv: [String], expected: ParsedCommand) throws {
        #expect(try CommandTable.parse(argv) == expected)
    }

    @Test(
        "ошибки разбора — invalid_arguments (64) с проблемой и usage",
        arguments: [
            (["nope"], "unknown command \"nope\""),
            (["config"], "earmark config list"),
            (
                ["calendars", "enable"],
                "missing required argument <id>. Usage: earmark calendars enable <id>"
            ),
            (["calendars", "nope"], "earmark calendars enable <id>"),
            (["status", "extra"], "unexpected argument \"extra\""),
            (["start", "--title"], "--title requires a value"),
            (["start", "--bogus"], "unknown option --bogus"),
            (["transcribe", "x", "--force=yes"], "--force does not take a value"),
        ])
    func rejects(argv: [String], fragment: String) {
        let error = #expect(throws: EarmarkError.self) { try CommandTable.parse(argv) }
        #expect(error?.code == "invalid_arguments")
        #expect(error?.exitCode == 64)
        #expect(error?.message.contains(fragment) == true, "\(error?.message ?? "")")
    }

    @Test("help --json описывает каждую команду спеки и ключи конфига")
    func helpCoversEverything() throws {
        let help = CommandTable.helpJSON()
        guard case .array(let commands)? = help["commands"], case .array(let keys)? = help["config_keys"]
        else {
            Issue.record("нет commands или config_keys")
            return
        }

        #expect(commands.compactMap { $0["path"]?.stringValue } == specPaths)
        for command in commands {
            for field in ["path", "summary", "usage", "arguments", "options", "needs_app", "mcp_tool"] {
                #expect(command[field] != nil, "\(command["path"]?.stringValue ?? "?") без \(field)")
            }
        }
        let enable = try #require(commands.first { $0["path"] == "calendars enable" })
        #expect(
            enable["arguments"] == [
                ["name": "id", "help": "Calendar id from `earmark calendars`", "required": true]
            ])
        #expect(enable["mcp_tool"] == "set_calendar_enabled")
        #expect(keys.count == ConfigSchema.all.count)
        #expect(keys.first { $0["key"] == "lead_seconds" }?["range"] == [0, 3600])
    }

    @Test("поднимать app нужно ровно командам из спеки §9.3; status не поднимает никогда")
    func needsApp() {
        let needs = Set(CommandTable.all.filter(\.needsApp).map { $0.path.joined(separator: " ") })
        #expect(
            needs == [
                "start", "stop", "upcoming", "calendars", "calendars enable", "calendars disable",
                "transcribe",
                "config set", "config reset", "doctor", "permissions request",
            ])
    }
}
