import Foundation

/// Ядро MCP-сервера без I/O: строка JSON-RPC на вход → строки на выход.
/// Dual-era (initialize и server/discover).
///
/// Основа — прототип research/probes/handrolled/mcp2.swift. Официальный swift-sdk не берём: он не знает
/// спеку 2026-07-28 (там нет initialize, обязателен server/discover, версия едет в `_meta` каждого
/// запроса), а нам нужны только tools. Эпоху определяет сам запрос: есть
/// `_meta["io.modelcontextprotocol/protocolVersion"]` — modern, нет — legacy.
public actor MCPServerCore {
    public typealias ToolCall = @Sendable (ParsedCommand) async -> Result<JSONValue, EarmarkError>

    static let modernVersions = ["2026-07-28"]
    static let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    /// Правила безопасности из спеки §9.4 — их видит модель клиента.
    public static let instructions = """
        earmark records calls on this Mac (microphone = me, system audio = the other side) and transcribes \
        them locally. Start a recording only when the user explicitly asks for it: recording other people \
        may require their consent. Take recording and calendar ids only from list_recordings, \
        list_calendars or list_upcoming_events; never guess them. Do not read recordings that are still \
        in progress (status recording). Transcripts and audio are private data: quote only what the task \
        needs. earmark has no delete command; never modify the recordings folder.
        """

    private let serverInfo: JSONValue
    private let call: ToolCall

    /// version — EarmarkVersion.current: CLI лежит в Contents/Helpers, и Bundle.main там не app.
    public init(serverName: String, version: String, call: @escaping ToolCall) {
        serverInfo = ["name": .string(serverName), "version": .string(version)]
        self.call = call
    }

    public func handle(line: String) async -> [String] {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else {
            return [Self.error(id: .null, code: -32700, message: "Parse error")]
        }
        guard case .string(let method)? = message["method"] else {
            return [Self.error(id: message["id"] ?? .null, code: -32600, message: "Invalid Request")]
        }
        // уведомления (notifications/initialized, notifications/cancelled) ответа не получают никогда
        guard let id = message["id"] else { return [] }
        let params = message["params"] ?? [:]
        guard let asked = params["_meta"]?["io.modelcontextprotocol/protocolVersion"]?.stringValue else {
            return [await respond(method, params: params, id: id, modern: [:])]
        }
        guard Self.modernVersions.contains(asked) else {
            let data: JSONValue = ["supported": Self.supportedVersions, "requested": .string(asked)]
            return [Self.error(id: id, code: -32022, message: "Unsupported protocol version", data: data)]
        }
        // modern-результаты несут resultType и serverInfo в _meta; legacy-клиенты лишние поля игнорируют
        let modern: [String: JSONValue] = [
            "resultType": "complete", "_meta": ["io.modelcontextprotocol/serverInfo": serverInfo],
        ]
        return [await respond(method, params: params, id: id, modern: modern)]
    }

    private static var supportedVersions: JSONValue {
        .array((modernVersions + legacyVersions).map(JSONValue.string))
    }

    private func respond(_ method: String, params: JSONValue, id: JSONValue, modern: [String: JSONValue])
        async
        -> String
    {
        let capabilities: JSONValue = ["tools": [:]]
        switch method {
        case "server/discover":
            return Self.result(
                id: id,
                [
                    "resultType": "complete", "supportedVersions": Self.supportedVersions,
                    "capabilities": capabilities, "_meta": ["io.modelcontextprotocol/serverInfo": serverInfo],
                    "instructions": .string(Self.instructions), "ttlMs": 0, "cacheScope": "private",
                ])
        case "initialize":
            let requested = params["protocolVersion"]?.stringValue ?? ""
            let version = Self.legacyVersions.contains(requested) ? requested : Self.legacyVersions[0]
            return Self.result(
                id: id,
                [
                    "protocolVersion": .string(version), "capabilities": capabilities,
                    "serverInfo": serverInfo,
                    "instructions": .string(Self.instructions),
                ])
        case "ping":
            return Self.result(id: id, modern)
        case "tools/list":
            let list: [String: JSONValue] = [
                "tools": .array(CommandTable.mcpTools()), "ttlMs": 0, "cacheScope": "private",
            ]
            return Self.result(id: id, list.merging(modern) { _, new in new })
        case "tools/call":
            guard case .string(let name)? = params["name"],
                CommandTable.all.contains(where: { $0.mcpTool == name })
            else {
                let name = params["name"]?.stringValue ?? ""
                return Self.error(id: id, code: -32602, message: "Unknown tool: \(name)")
            }
            let outcome = await run(name, arguments: params["arguments"] ?? [:])
            return Self.result(id: id, outcome.merging(modern) { _, new in new })
        default:
            return Self.error(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    /// Ошибки команды — не JSON-RPC error, а isError-результат: так модель видит текст и может
    /// исправиться (спека MCP: tool execution errors).
    private func run(_ name: String, arguments: JSONValue) async -> [String: JSONValue] {
        let outcome: Result<JSONValue, EarmarkError>
        do {
            outcome = await call(try CommandTable.command(forTool: name, arguments: arguments))
        } catch {
            outcome = .failure(error)
        }
        switch outcome {
        case .success(let data):
            var result: [String: JSONValue] = [
                "content": [["type": "text", "text": .string(Self.encode(data))]], "isError": false,
            ]
            // legacy-схемы (2025-06-18, 2025-11-25) допускают structuredContent только объектом;
            // массив или null остаётся в text — там лежит тот же JSON целиком
            if case .object = data { result["structuredContent"] = data }
            return result
        case .failure(let error):
            let text = JSONValue.string("\(error.code): \(error.message)")
            return ["content": [["type": "text", "text": text]], "isError": true]
        }
    }

    private static func result(id: JSONValue, _ result: [String: JSONValue]) -> String {
        encode(["jsonrpc": "2.0", "id": id, "result": .object(result)])
    }

    private static func error(id: JSONValue, code: Int, message: String, data: JSONValue? = nil) -> String {
        var error: [String: JSONValue] = ["code": .number(Double(code)), "message": .string(message)]
        if let data { error["data"] = data }
        return encode(["jsonrpc": "2.0", "id": id, "error": .object(error)])
    }

    /// Одна строка без переводов (stdio MCP запрещает их внутри сообщения), ключи как есть:
    /// у MCP camelCase (protocolVersion, inputSchema), поэтому не EarmarkJSON.encoder.
    private static func encode(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let fallback = #"{"error":{"code":-32603,"message":"Internal error"},"id":null,"jsonrpc":"2.0"}"#
        guard let data = try? encoder.encode(value) else { return fallback }
        return String(bytes: data, encoding: .utf8) ?? fallback
    }
}
