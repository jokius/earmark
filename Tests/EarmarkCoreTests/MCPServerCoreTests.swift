import Foundation
import Testing

@testable import EarmarkCore

@Suite("MCP: dual-era golden-сценарии")
struct MCPServerCoreTests {
    /// Что сервер передал наружу — вместо настоящего CLI.
    private actor CallLog {
        var commands: [ParsedCommand] = []
        func record(_ command: ParsedCommand) { commands.append(command) }
    }

    /// Golden-сценарий: строки на вход, ожидаемые ответы как JSON. Сравнение структурное — порядок
    /// ключей и запись чисел не важны, важны имена полей и значения.
    private func play(
        _ script: [(input: String, expected: [JSONValue])], log: CallLog = CallLog()
    ) async throws {
        let server = MCPServerCore(serverName: "earmark", version: "0.1.0") { command in
            await log.record(command)
            switch command.path {
            case ["status"]: return .success(["state": "idle", "app_running": true])
            case ["recordings"]: return .success([["id": "20261002-1400-a1b2"]])
            default: return .failure(.appNotRunning("Earmark.app did not start within 5 s"))
            }
        }
        for step in script {
            let output = await server.handle(line: step.input)
            let decoded = try output.map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
            #expect(decoded == step.expected, "\(step.input)")
            #expect(output.allSatisfy { !$0.contains("\n") })
        }
    }

    private let serverInfo: JSONValue = ["name": "earmark", "version": "0.1.0"]
    private let modernMeta = #""_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}"#
    private let statusText = #"{"app_running":true,"state":"idle"}"#

    @Test("legacy: initialize → initialized → ping → tools/list → tools/call → ошибки")
    func legacySession() async throws {
        let log = CallLog()
        try await play(
            [
                (
                    #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#,
                    [
                        [
                            "jsonrpc": "2.0", "id": 1,
                            "result": [
                                "protocolVersion": "2025-06-18", "capabilities": ["tools": [:]],
                                "serverInfo": serverInfo, "instructions": .string(MCPServerCore.instructions),
                            ],
                        ]
                    ]
                ),
                (#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, []),
                (#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#, [["jsonrpc": "2.0", "id": 2, "result": [:]]]),
                (
                    #"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#,
                    [
                        [
                            "jsonrpc": "2.0", "id": 3,
                            "result": [
                                "tools": .array(CommandTable.mcpTools()), "ttlMs": 0, "cacheScope": "private",
                            ],
                        ]
                    ]
                ),
                (
                    #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_status","arguments":{}}}"#,
                    [
                        [
                            "jsonrpc": "2.0", "id": 4,
                            "result": [
                                "content": [["type": "text", "text": .string(statusText)]],
                                "structuredContent": ["state": "idle", "app_running": true], "isError": false,
                            ],
                        ]
                    ]
                ),
                (
                    #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"list_recordings","arguments":{"limit":1}}}"#,
                    [
                        [
                            "jsonrpc": "2.0", "id": 5,
                            "result": [
                                "content": [["type": "text", "text": #"[{"id":"20261002-1400-a1b2"}]"#]],
                                "isError": false,
                            ],
                        ]
                    ]
                ),
                (
                    #"{"jsonrpc":"2.0","id":"s","method":"tools/call","params":{"name":"set_calendar_enabled","arguments":{"id":"CAL-1","enabled":false}}}"#,
                    [
                        [
                            "jsonrpc": "2.0", "id": "s",
                            "result": [
                                "content": [
                                    [
                                        "type": "text",
                                        "text": "app_not_running: Earmark.app did not start within 5 s",
                                    ]
                                ],
                                "isError": true,
                            ],
                        ]
                    ]
                ),
                (
                    #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"get_recording","arguments":{}}}"#,
                    [
                        [
                            "jsonrpc": "2.0", "id": 6,
                            "result": [
                                "content": [
                                    [
                                        "type": "text",
                                        "text":
                                            #"invalid_arguments: get_recording: missing required argument "id""#,
                                    ]
                                ],
                                "isError": true,
                            ],
                        ]
                    ]
                ),
                (
                    #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"delete_everything"}}"#,
                    [
                        [
                            "jsonrpc": "2.0", "id": 7,
                            "error": ["code": -32602, "message": "Unknown tool: delete_everything"],
                        ]
                    ]
                ),
                (
                    #"{"jsonrpc":"2.0","id":8,"method":"resources/list"}"#,
                    [
                        [
                            "jsonrpc": "2.0", "id": 8,
                            "error": ["code": -32601, "message": "Method not found: resources/list"],
                        ]
                    ]
                ),
                (
                    "{not json",
                    [["jsonrpc": "2.0", "id": .null, "error": ["code": -32700, "message": "Parse error"]]]
                ),
                (
                    #"{"jsonrpc":"2.0","id":9}"#,
                    [["jsonrpc": "2.0", "id": 9, "error": ["code": -32600, "message": "Invalid Request"]]]
                ),
                ("", []),
            ], log: log)

        #expect(
            await log.commands == [
                ParsedCommand(path: ["status"]), ParsedCommand(path: ["recordings"], options: ["limit": "1"]),
                ParsedCommand(path: ["calendars", "disable"], arguments: ["id": "CAL-1"]),
            ])
    }

    @Test("legacy: незнакомая версия в initialize — последняя из поддерживаемых")
    func legacyVersionFallback() async throws {
        try await play([
            (
                #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#,
                [
                    [
                        "jsonrpc": "2.0", "id": 1,
                        "result": [
                            "protocolVersion": "2025-11-25", "capabilities": ["tools": [:]],
                            "serverInfo": serverInfo,
                            "instructions": .string(MCPServerCore.instructions),
                        ],
                    ]
                ]
            )
        ])
    }

    @Test("modern 2026-07-28: server/discover, версия в _meta, resultType и кэш-подсказки")
    func modernSession() async throws {
        let modern: [String: JSONValue] = [
            "resultType": "complete", "_meta": ["io.modelcontextprotocol/serverInfo": serverInfo],
        ]
        try await play([
            (
                #"{"jsonrpc":"2.0","id":"d1","method":"server/discover","params":{\#(modernMeta)}}"#,
                [
                    [
                        "jsonrpc": "2.0", "id": "d1",
                        "result": [
                            "resultType": "complete",
                            "supportedVersions": [
                                "2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05",
                            ],
                            "capabilities": ["tools": [:]],
                            "_meta": ["io.modelcontextprotocol/serverInfo": serverInfo],
                            "instructions": .string(MCPServerCore.instructions), "ttlMs": 0,
                            "cacheScope": "private",
                        ],
                    ]
                ]
            ),
            (
                #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{\#(modernMeta)}}"#,
                [
                    [
                        "jsonrpc": "2.0", "id": 2,
                        "result": .object(
                            modern.merging([
                                "tools": .array(CommandTable.mcpTools()), "ttlMs": 0, "cacheScope": "private",
                            ]) { $1 }),
                    ]
                ]
            ),
            (
                #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_status","arguments":{},\#(modernMeta)}}"#,
                [
                    [
                        "jsonrpc": "2.0", "id": 3,
                        "result": .object(
                            modern.merging([
                                "content": [["type": "text", "text": .string(statusText)]],
                                "structuredContent": ["state": "idle", "app_running": true], "isError": false,
                            ]) { $1 }),
                    ]
                ]
            ),
            (
                #"{"jsonrpc":"2.0","id":4,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2027-01-01"}}}"#,
                [
                    [
                        "jsonrpc": "2.0", "id": 4,
                        "error": [
                            "code": -32022, "message": "Unsupported protocol version",
                            "data": [
                                "supported": [
                                    "2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05",
                                ],
                                "requested": "2027-01-01",
                            ],
                        ],
                    ]
                ]
            ),
            (#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":3}}"#, []),
        ])
    }
}
