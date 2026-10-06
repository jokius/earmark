import Foundation
import Testing

@testable import EarmarkCore

@Suite("MCP tools из таблицы команд")
struct MCPToolTableTests {
    @Test("MCP tools: имена из спеки §9.4, аннотации, схемы")
    func tools() throws {
        let tools = CommandTable.mcpTools()
        let byName = Dictionary(
            uniqueKeysWithValues: tools.compactMap { tool in tool["name"]?.stringValue.map { ($0, tool) } })

        #expect(
            tools.compactMap { $0["name"]?.stringValue } == [
                "get_status", "start_recording", "stop_recording", "list_upcoming_events", "list_calendars",
                "set_calendar_enabled", "list_recordings", "get_recording", "get_transcript",
                "transcribe_recording",
                "get_config", "set_config", "reset_config", "doctor",
            ])
        let readOnly = Set(
            tools.filter { $0["annotations"]?["readOnlyHint"] == true }.compactMap { $0["name"]?.stringValue }
        )
        #expect(
            readOnly == [
                "get_status", "list_upcoming_events", "list_calendars", "list_recordings", "get_recording",
                "get_transcript", "get_config", "doctor",
            ])
        for tool in tools {
            #expect(tool["annotations"]?["destructiveHint"] == false)
            #expect(tool["inputSchema"]?["type"] == "object")
            #expect(tool["inputSchema"]?["additionalProperties"] == false)
        }
        #expect(byName["start_recording"]?["annotations"]?["idempotentHint"] == true)
        #expect(byName["stop_recording"]?["annotations"]?["idempotentHint"] == true)

        let calendar = try #require(byName["set_calendar_enabled"]?["inputSchema"])
        #expect(calendar["required"] == ["id", "enabled"])
        #expect(calendar["properties"]?["enabled"]?["type"] == "boolean")
        let recordings = try #require(byName["list_recordings"]?["inputSchema"]?["properties"])
        guard case .object(let properties) = recordings else { return }
        #expect(Set(properties.keys) == ["since", "until", "calendar", "status", "limit"])
        #expect(byName["get_recording"]?["inputSchema"]?["required"] == ["id"])
        #expect(byName["transcribe_recording"]?["inputSchema"]?["properties"]?["now"] == nil)
        #expect(byName["doctor"]?["inputSchema"]?["properties"]?["audio_test"]?["type"] == "boolean")
        #expect(byName["get_config"]?["inputSchema"]?["required"] == nil)
    }

    /// Случай «tool → команда»: структура, а не кортеж из трёх (SwiftLint large_tuple),
    /// и литералы JSON получают тип из параметра.
    struct ToolCase: Sendable, CustomTestStringConvertible {
        let tool: String
        let arguments: JSONValue
        let expected: ParsedCommand
        var testDescription: String { tool }

        init(_ tool: String, _ arguments: JSONValue, _ expected: ParsedCommand) {
            self.tool = tool
            self.arguments = arguments
            self.expected = expected
        }
    }

    @Test(
        "MCP tool → команда CLI",
        arguments: [
            ToolCase("get_status", [:], ParsedCommand(path: ["status"])),
            ToolCase(
                "start_recording", ["title": "Standup"],
                ParsedCommand(path: ["start"], options: ["title": "Standup"])),
            ToolCase(
                "set_calendar_enabled", ["id": "CAL-1", "enabled": true],
                ParsedCommand(path: ["calendars", "enable"], arguments: ["id": "CAL-1"])),
            ToolCase(
                "set_calendar_enabled", ["id": "CAL-1", "enabled": false],
                ParsedCommand(path: ["calendars", "disable"], arguments: ["id": "CAL-1"])),
            ToolCase("get_config", [:], ParsedCommand(path: ["config", "list"])),
            ToolCase(
                "get_config", ["key": "lead_seconds"],
                ParsedCommand(path: ["config", "get"], arguments: ["key": "lead_seconds"])),
            ToolCase(
                "set_config", ["key": "lead_seconds", "value": 30],
                ParsedCommand(path: ["config", "set"], arguments: ["key": "lead_seconds", "value": "30"])),
            ToolCase(
                "reset_config", ["all": true],
                ParsedCommand(path: ["config", "reset"], options: ["all": "true"])),
            ToolCase(
                "list_recordings", ["limit": 5, "status": "recorded"],
                ParsedCommand(path: ["recordings"], options: ["limit": "5", "status": "recorded"])),
            ToolCase(
                "get_transcript", ["id": "20261002-1400-a1b2", "offset": 200],
                ParsedCommand(
                    path: ["transcript"], arguments: ["id": "20261002-1400-a1b2"], options: ["offset": "200"])
            ),
            ToolCase(
                "transcribe_recording", ["id": "20261002-1400-a1b2", "force": true],
                ParsedCommand(
                    path: ["transcribe"], arguments: ["id": "20261002-1400-a1b2"], options: ["force": "true"])
            ),
            ToolCase(
                "doctor", ["audio_test": true],
                ParsedCommand(path: ["doctor"], options: ["audio-test": "true"])),
            ToolCase("doctor", ["audio_test": false], ParsedCommand(path: ["doctor"])),
        ])
    func toolMapping(_ example: ToolCase) throws {
        #expect(
            try CommandTable.command(forTool: example.tool, arguments: example.arguments) == example.expected)
    }

    @Test(
        "кривые аргументы tool'а — invalid_arguments",
        arguments: [
            ("set_calendar_enabled", ["id": "CAL-1"]),
            ("set_calendar_enabled", ["id": "CAL-1", "enabled": "yes"]),
            ("get_recording", [:]),
            ("list_recordings", ["bogus": 1]),
            ("transcribe_recording", ["id": "x", "now": true]),
            ("get_status", "not an object"),
            ("set_config", ["key": ["nested"], "value": "1"]),
        ] as [(String, JSONValue)])
    func rejectsToolArguments(tool: String, arguments: JSONValue) {
        let error = #expect(throws: EarmarkError.self) {
            try CommandTable.command(forTool: tool, arguments: arguments)
        }
        #expect(error?.code == "invalid_arguments")
    }
}
