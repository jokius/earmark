import EarmarkCore
import Foundation
import Synchronization

/// `earmark model status | download | import <path>`. Работают без app: модель — просто файл
/// в Application Support, а flock на загрузке не даёт app и CLI качать её дважды.
enum ModelCommands {
    static let status: CommandHandler = { _, _ in try state(store: ModelStore()) }
    static let download: CommandHandler = { _, context in
        try await fetch(store: ModelStore(), output: context.output)
    }
    static let importModel: CommandHandler = { parsed, _ in
        try copy(parsed.argument("path"), store: ModelStore())
    }

    /// Только размер, без sha256: сверка содержимого стоит 1–4 с, её делают download и import.
    static func state(store: ModelStore) throws(EarmarkError) -> JSONValue {
        let state = try disk("model") { try store.state(of: Models.largeV3Turbo, verify: false) }
        return try encodeJSON(ModelStatusInfo(state))
    }

    /// Прогресс — JSON-строками в stderr: stdout остаётся под итоговый конверт. Не чаще раза на процент,
    /// иначе на 1.6 GB вышли бы десятки тысяч строк.
    static func fetch(store: ModelStore, output: Output) async throws(EarmarkError) -> JSONValue {
        let lastPercent = Mutex(-1)
        let url: URL
        do {
            url = try await store.download(Models.largeV3Turbo) { received, total in
                let percent = Int(received * 100 / max(total, 1))
                let changed = lastPercent.withLock { last in
                    defer { last = percent }
                    return last != percent
                }
                guard changed,
                    let line = try? JSONValue(
                        encoding: ModelStatusInfo(.downloading(received: received, total: total)))
                else { return }
                output.stderr(Output.render(line, pretty: false))
            }
        } catch {
            throw error as? EarmarkError ?? .operationFailed("model download: \(error.localizedDescription)")
        }
        return try encodeJSON(ModelStatusInfo(.ready(url)))
    }

    /// Тильду раскрываем сами: в кавычках ("~/Library/…", как в README) шелл её не трогает.
    static func copy(_ path: String, store: ModelStore) throws(EarmarkError) -> JSONValue {
        let source = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let url = try disk("model import") { try store.importFile(at: source, as: Models.largeV3Turbo) }
        return try encodeJSON(ModelStatusInfo(.ready(url)))
    }
}
