import Foundation
import Testing

@testable import EarmarkCore

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("earmark-remote-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite("Конфиг удалённого распознавания: transcription.remote.*")
struct RemoteTranscriptionConfigTests {
    @Test("по умолчанию режим выключен, URL не задан")
    func defaults() {
        let config = Config()
        #expect(!config.remoteTranscriptionEnabled)
        #expect(config.remoteTranscriptionURL == nil)
    }

    @Test(
        "разбор значений: bool для enabled; URL http/https хранится без хвостового /, пустая строка допустима",
        arguments: [
            ("transcription.remote.enabled", "true", ConfigValue.bool(true)),
            ("transcription.remote.enabled", "off", .bool(false)),
            ("transcription.remote.url", "", .string("")),
            ("transcription.remote.url", "http://gpu-box.local:8178", .string("http://gpu-box.local:8178")),
            ("transcription.remote.url", "http://gpu-box.local:8178/", .string("http://gpu-box.local:8178")),
            ("transcription.remote.url", "https://gpu-box.local", .string("https://gpu-box.local")),
            ("transcription.remote.url", "http://10.0.0.5:8178/", .string("http://10.0.0.5:8178")),
            (
                "transcription.remote.url", "http://gpu-box.local/whisper/",
                .string("http://gpu-box.local/whisper")
            ),
        ])
    func parses(key: String, raw: String, expected: ConfigValue) throws {
        #expect(try ConfigSchema.parse(raw, for: key) == expected)
    }

    @Test(
        "невалидный URL — invalidValue с этим ключом",
        arguments: [
            "gpu-box.local:8178", "ftp://gpu-box.local", "file:///tmp/x", "http://", "http:///v1",
            "http://gpu-box.local:8178?x=1", "http://gpu-box.local#top", "http://user@gpu-box.local",
            "http://user:secret@gpu-box.local:8178", "not a url",
        ])
    func rejects(raw: String) {
        let error = #expect(throws: ConfigError.self) {
            try ConfigSchema.parse(raw, for: "transcription.remote.url")
        }
        guard case .invalidValue(let key, let reason)? = error else {
            Issue.record("ожидали invalidValue, получили \(String(describing: error))")
            return
        }
        #expect(key == "transcription.remote.url")
        #expect(!reason.isEmpty)
    }

    @Test("config set: каноническая форма в значении и аксессорах, old — прежнее эффективное")
    func setAndAccessors() throws {
        var config = Config()

        let url = try config.set("transcription.remote.url", raw: "http://gpu-box.local:8178/")
        #expect(url.old == .string(""))
        #expect(url.new == .string("http://gpu-box.local:8178"))
        let enabled = try config.set("transcription.remote.enabled", raw: "on")
        #expect(enabled.old == .bool(false))
        #expect(enabled.new == .bool(true))

        #expect(config.remoteTranscriptionEnabled)
        #expect(config.remoteTranscriptionURL == URL(string: "http://gpu-box.local:8178"))

        try config.set("transcription.remote.url", raw: "")
        #expect(config.remoteTranscriptionURL == nil)
        #expect(throws: ConfigError.self) {
            try config.set("transcription.remote.url", value: .string("ftp://x"))
        }
        #expect(throws: ConfigError.self) {
            try config.set("transcription.remote.enabled", value: .string("yes"))
        }
    }

    @Test("config.json: URL с хвостовым / загружается в каноническом виде")
    func loadCanonical() throws {
        let url = try makeTempDir().appendingPathComponent("config.json")
        let text =
            #"{"transcription.remote.enabled": true, "transcription.remote.url": "http://gpu-box.local:8178/"}"#
        try Data(text.utf8).write(to: url)

        let config = try ConfigStore(url: url).load()

        #expect(config.remoteTranscriptionEnabled)
        #expect(config.remoteTranscriptionURL?.absoluteString == "http://gpu-box.local:8178")
    }

    @Test(
        "config.json с кривым URL — ошибка загрузки",
        arguments: [
            #"{"transcription.remote.url": "ftp://gpu-box.local"}"#,
            #"{"transcription.remote.url": "http://gpu-box.local?x=1"}"#,
            #"{"transcription.remote.url": "http://u:p@gpu-box.local"}"#,
        ])
    func loadRejects(text: String) throws {
        let url = try makeTempDir().appendingPathComponent("config.json")
        try Data(text.utf8).write(to: url)
        #expect(throws: (any Error).self) { try ConfigStore(url: url).load() }
    }

    @Test("listing: оба ключа с дефолтами и типами")
    func listing() throws {
        let items = Config().listing()

        let enabled = try #require(items.first { $0.key == "transcription.remote.enabled" })
        #expect(enabled.value == false)
        #expect(enabled.isDefault)
        #expect(enabled.type == .bool)
        let url = try #require(items.first { $0.key == "transcription.remote.url" })
        #expect(url.value == .string(""))
        #expect(url.isDefault)
        #expect(url.type == .string)
    }

    @Test(
        "help --json: тексты ключей удалённого распознавания",
        arguments: [
            (
                "transcription.remote.enabled",
                "Transcribe on your own whisper server on the LAN instead of this Mac; when it is unreachable, recordings wait for it"
            ),
            ("transcription.remote.url", "Base URL of the whisper server, e.g. http://gpu-box.local:8178"),
        ])
    func help(key: String, help: String) throws {
        guard case .array(let keys)? = CommandTable.helpJSON()["config_keys"] else {
            Issue.record("нет config_keys")
            return
        }
        let entry = try #require(keys.first { $0["key"] == .string(key) }, "нет \(key) в config_keys")
        guard case .object(let fields) = entry else {
            Issue.record("\(key): не объект")
            return
        }
        #expect(fields.values.contains(.string(help)), "\(key): нет help «\(help)»")
    }
}

@Suite("RemoteTranscription.client: конфиг + токен-файл → клиент")
struct RemoteTranscriptionClientTests {
    private static let url = "http://gpu-box.local:8178"

    private func enabled(url: String = url) -> Config {
        Config(values: [
            "transcription.remote.enabled": .bool(true), "transcription.remote.url": .string(url),
        ])
    }

    /// supportDir с remote-token: содержимое и права.
    private func supportDir(token: String?, mode: Int = 0o600) throws -> URL {
        let dir = try makeTempDir()
        if let token {
            let file = dir.appending(path: "remote-token")
            try Data(token.utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
        }
        return dir
    }

    @Test("EarmarkPaths.remoteTokenFile — <supportDir>/remote-token")
    func tokenFilePath() {
        #expect(
            EarmarkPaths.remoteTokenFile.standardizedFileURL.path
                == EarmarkPaths.supportDir.appending(path: "remote-token").standardizedFileURL.path)
    }

    @Test("режим выключен — nil, даже если URL и токен на месте")
    func disabled() throws {
        let dir = try supportDir(token: "secret")
        #expect(RemoteTranscription.client(config: Config(), supportDir: dir) == nil)
        let urlOnly = Config(values: ["transcription.remote.url": .string(Self.url)])
        #expect(RemoteTranscription.client(config: urlOnly, supportDir: dir) == nil)
    }

    @Test("включён, токен 0600 — клиент на URL из конфига")
    func configured() throws {
        let result = RemoteTranscription.client(
            config: enabled(url: "http://gpu-box.local:8178/"), supportDir: try supportDir(token: "secret\n"))

        guard case .success(let client)? = result else {
            Issue.record("ожидали .success, получили \(String(describing: result))")
            return
        }
        #expect(client.baseURL.absoluteString == "http://gpu-box.local:8178")
    }

    @Test("токен только для чтения владельцем (0400) тоже годится")
    func readOnlyToken() throws {
        let result = RemoteTranscription.client(
            config: enabled(), supportDir: try supportDir(token: "secret", mode: 0o400))
        guard case .success? = result else {
            Issue.record("ожидали .success, получили \(String(describing: result))")
            return
        }
    }

    @Test("включён, но URL пустой — failure")
    func emptyURL() throws {
        let result = RemoteTranscription.client(
            config: enabled(url: ""), supportDir: try supportDir(token: "secret"))
        guard case .failure? = result else {
            Issue.record("ожидали .failure, получили \(String(describing: result))")
            return
        }
    }

    @Test("нет файла токена или он пустой — failure", arguments: [nil, ""] as [String?])
    func missingOrEmptyToken(token: String?) throws {
        let result = RemoteTranscription.client(config: enabled(), supportDir: try supportDir(token: token))
        guard case .failure? = result else {
            Issue.record("ожидали .failure, получили \(String(describing: result))")
            return
        }
    }

    @Test("токен из одних пробелов и переводов строк — failure")
    func blankToken() throws {
        let result = RemoteTranscription.client(
            config: enabled(), supportDir: try supportDir(token: "  \n\n"))
        guard case .failure? = result else {
            Issue.record("ожидали .failure, получили \(String(describing: result))")
            return
        }
    }

    @Test(
        "токен читаем группой или всеми — failure «remote-token must be chmod 600»",
        arguments: [0o644, 0o640, 0o604, 0o660])
    func openToken(mode: Int) throws {
        let result = RemoteTranscription.client(
            config: enabled(), supportDir: try supportDir(token: "secret", mode: mode))
        guard case .failure(let error)? = result else {
            Issue.record("ожидали .failure, получили \(String(describing: result))")
            return
        }
        #expect(error.message.contains("chmod 600"), "\(error)")
    }
}
