import EarmarkCore
import Foundation
import Testing

@testable import EarmarkCLI

/// Golden-диалоги MCP обеих эпох (§9.4) через настоящий stdio-цикл и настоящий Registry:
/// фейковый app на сокете, временное хранилище записей, разобранный stdout.
@Suite("earmark mcp: диалоги обеих эпох")
struct MCPCommandTests {
    /// _meta запроса эпохи 2026-07-28: версия протокола едет в каждом запросе, handshake нет.
    private var modern: JSONValue {
        .object(["io.modelcontextprotocol/protocolVersion": .string("2026-07-28")])
    }

    /// Одна JSON-RPC строка запроса; id nil — уведомление. Обычный JSONEncoder, без snake_case:
    /// ключи протокола (protocolVersion, _meta) должны уйти ровно такими.
    private func rpc(_ id: Int?, _ method: String, _ params: JSONValue? = nil) -> String {
        var object: [String: JSONValue] = ["jsonrpc": .string("2.0"), "method": .string(method)]
        if let id { object["id"] = .number(Double(id)) }
        if let params { object["params"] = params }
        let data = (try? JSONEncoder().encode(JSONValue.object(object))) ?? Data()
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    private func call(
        _ id: Int, _ tool: String, _ arguments: [String: JSONValue], meta: JSONValue? = nil
    ) -> String {
        var params: [String: JSONValue] = ["name": .string(tool), "arguments": .object(arguments)]
        if let meta { params["_meta"] = meta }
        return rpc(id, "tools/call", .object(params))
    }

    /// Прогоняет строки через stdio-цикл до EOF; возвращает разобранные строки stdout.
    private func converse(_ lines: [String], _ harness: CLIHarness) async throws -> [JSONValue] {
        let input = AsyncStream<String> { continuation in
            lines.forEach { continuation.yield($0) }
            continuation.finish()
        }
        #expect(await MCPCommand.serve(lines: input, context: harness.context()) == 0)
        return try harness.stdoutLines.map(CLIHarness.parse)
    }

    /// data вызова tool — из текстовой копии в content[0]: именно её читает модель.
    private func toolData(_ reply: JSONValue) throws -> JSONValue {
        let text = try #require(reply["result"]?["content"]?.items.first?["text"]?.stringValue)
        return try CLIHarness.parse(text)
    }

    @Test("легаси-эпоха: initialize → уведомление → tools/list → tools/call get_status")
    func legacyEra() async throws {
        let harness = try CLIHarness()
        let status: JSONValue = .object([
            "app_running": .bool(true), "state": .string("idle"), "warnings": .array([]),
        ])
        let app = try harness.startApp { _ in .success(status) }
        let initialize: JSONValue = .object([
            "protocolVersion": .string("2025-06-18"), "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("golden"), "version": .string("1")]),
        ])
        let replies = try await converse(
            [
                rpc(1, "initialize", initialize), rpc(nil, "notifications/initialized"), rpc(2, "tools/list"),
                call(3, "get_status", [:]),
            ], harness)

        // На уведомление ответа нет: три запроса — три строки, и каждая из них — JSON-RPC.
        #expect(replies.map { $0["id"] } == [.number(1), .number(2), .number(3)])
        #expect(replies.allSatisfy { $0["jsonrpc"] == .string("2.0") })
        #expect(replies[0]["result"]?["protocolVersion"] == .string("2025-06-18"))
        #expect(replies[0]["result"]?["serverInfo"]?["name"] == .string("earmark"))
        // Версия — EarmarkVersion, а не Info.plist: у CLI в Contents/Helpers Bundle.main — не app.
        #expect(replies[0]["result"]?["serverInfo"]?["version"] == .string(EarmarkVersion.current))
        let listed = replies[1]["result"]?["tools"]?.items.compactMap { $0["name"]?.stringValue } ?? []
        let table = CommandTable.mcpTools().compactMap { $0["name"]?.stringValue }
        #expect(Set(listed) == Set(table))
        #expect(replies[2]["result"]?["isError"] == .bool(false))
        #expect(try toolData(replies[2]) == status)
        #expect(app.requests.map(\.method) == [IPCMethod.status])
    }

    @Test("эпоха 2026-07-28: server/discover → tools/call list_recordings по временному хранилищу")
    func modernEra() async throws {
        let harness = try CLIHarness()
        try harness.makeRecordings()
        let replies = try await converse(
            [
                rpc(1, "server/discover", .object(["_meta": modern])),
                call(2, "list_recordings", ["status": .string("transcribed")], meta: modern),
            ], harness)
        #expect(replies.map { $0["id"] } == [.number(1), .number(2)])
        let versions = replies[0]["result"]?["supportedVersions"]?.items ?? []
        #expect(versions.contains(.string("2026-07-28")))
        #expect(replies[1]["result"]?["isError"] == .bool(false))
        #expect(try toolData(replies[1]).items.compactMap { $0["id"]?.stringValue } == [CLIHarness.idA])
    }

    @Test("ошибка tool — isError с текстом «code: message», а не JSON-RPC error")
    func toolErrorIsVisible() async throws {
        let harness = try CLIHarness()
        try harness.makeRecordings()
        let initialize: JSONValue = .object(["protocolVersion": .string("2025-06-18")])
        let replies = try await converse(
            [
                rpc(1, "initialize", initialize),
                call(2, "get_recording", ["id": .string("20990101-0000-ffff")]),
                call(3, "start_recording", [:]),
            ], harness)
        #expect(replies.count == 3)
        // Модель видит машинный код ошибки первым словом — по нему она и решает, что делать дальше.
        for (reply, code) in zip(replies.dropFirst(), ["not_found", "app_not_running"]) {
            #expect(reply["error"] == nil)
            #expect(reply["result"]?["isError"] == .bool(true))
            let text = reply["result"]?["content"]?.items.first?["text"]?.stringValue ?? ""
            #expect(text.hasPrefix(code + ": "), "\(text)")
        }
        // start_recording без app: поднять его не удалось (в тестах launchApp падает) — это тоже isError.
        #expect(harness.launchCount == 1)
    }

    /// Байты stdin по одному: так строка гарантированно приходит частями, как из настоящего пайпа.
    private func bytes(_ text: String) -> AsyncStream<UInt8> {
        AsyncStream { continuation in
            text.utf8.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }

    private func lines(_ text: String) async throws -> [String] {
        try await MCPCommand.lines(bytes(text)).reduce(into: []) { $0.append($1) }
    }

    @Test("кадрирование stdin только по LF: U+2028 внутри аргумента не рвёт запрос на две строки")
    func framingSplitsOnlyOnLineFeed() async throws {
        let harness = try CLIHarness()
        try harness.makeRecordings()
        let request = call(7, "get_recording", ["id": .string("x\u{2028}y")])
        // В строке сырой U+2028, а не эскейп  : JSON его разрешает, а Foundation-шный lines режет.
        try #require(request.contains("\u{2028}"))
        let input = MCPCommand.lines(bytes(request + "\n"))
        #expect(await MCPCommand.serve(lines: input, context: harness.context()) == 0)
        let replies = try harness.stdoutLines.map(CLIHarness.parse)
        // Одна строка запроса — один ответ, и это ответ на сам запрос, а не два -32700 на обрывки.
        #expect(replies.count == 1)
        let reply = try #require(replies.first)
        #expect(reply["id"] == .number(7))
        #expect(reply["error"] == nil)
        #expect(reply["result"]?["isError"] == .bool(true))
        let text = reply["result"]?["content"]?.items.first?["text"]?.stringValue ?? ""
        #expect(text.hasPrefix("not_found: "), "\(text)")
    }

    @Test("lines: режет только по LF, хвост без LF — строка, пустой ввод — ничего")
    func linesSplitOnlyOnLineFeed() async throws {
        #expect(try await lines("").isEmpty)
        // NEL, U+2029 и одиночный CR — часть строки; кириллица собирается из байтов целой.
        let mixed = try await lines("a\u{85}b\nc\u{2029}d\re\nпривет")
        #expect(mixed == ["a\u{85}b", "c\u{2029}d\re", "привет"])
        // CRLF: «\r» может остаться в строке — его срезает ядро, но LF режет всегда.
        let crlf = try await lines("x\r\ny\r\n").map { $0.trimmingCharacters(in: .newlines) }
        #expect(crlf == ["x", "y"])
    }
}
