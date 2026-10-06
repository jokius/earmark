import Foundation

/// config.json. Пишет только app (единственный writer, спека §3.1), CLI читает для `config list|get`.
public struct ConfigStore: Sendable {
    private let url: URL

    public init(url: URL = EarmarkPaths.configFile) {
        self.url = url
    }

    /// Нет файла → Config(). Каждое значение проходит ту же валидацию, что `config set`:
    /// ручная правка с неизвестным ключом или кривым значением — ошибка, а не тихий дефолт.
    public func load() throws -> Config {
        guard FileManager.default.fileExists(atPath: url.path) else { return Config() }
        let stored = try EarmarkJSON.decoder.decode([String: ConfigValue].self, from: Data(contentsOf: url))
        var config = Config()
        for (key, value) in stored {
            try config.set(key, value: value)
        }
        return config
    }

    /// AtomicFile; ключи — ровно как в `config list` (стратегия snake_case словарные ключи не трогает).
    public func save(_ config: Config) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try AtomicFile.write(EarmarkJSON.prettyEncoder.encode(config.values), to: url)
    }
}
