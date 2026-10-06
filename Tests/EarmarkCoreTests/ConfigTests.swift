import Foundation
import Testing

@testable import EarmarkCore

@Suite("Config: дефолты, set/reset, listing")
struct ConfigTests {
    @Test("пустой конфиг отдаёт дефолты спеки §9.1 через аксессоры")
    func defaults() {
        let config = Config()

        #expect(config.autoRecord)
        #expect(config.leadSeconds == 60)
        #expect(config.leadSeconds(forCalendar: "CAL-1") == 60)
        #expect(
            config.recordingsDir.path == FileManager.default.homeDirectoryForCurrentUser.path + "/Earmark")
        #expect(config.launchAtLogin)
        #expect(config.calendars.isEmpty)
        #expect(config.folderOverride(forCalendar: "CAL-1") == nil)
        #expect(
            config.stop
                == StopConfig(
                    callEndSeconds: 60, afterEndSeconds: 120, farEndQuietSeconds: 60, silenceMinutes: 10,
                    joinGraceMinutes: 10, maxMinutes: 300, minKeepSeconds: 45))
        #expect(StopConfig.defaults == config.stop)
        #expect(!config.keepRawTracks)
        #expect(config.transcriptionEnabled)
        #expect(config.transcriptionLanguage == "auto")
        #expect(config.labelMe == "Me")
        #expect(config.labelThem == "Them")
    }

    @Test("set возвращает старое и новое эффективное значение; calendar-ключ без значения — old nil")
    func setReturnsOldAndNew() throws {
        var config = Config()

        let first = try config.set("lead_seconds", raw: "30")
        #expect(first.old == .int(60))
        #expect(first.new == .int(30))
        let second = try config.set("lead_seconds", raw: "45")
        #expect(second.old == .int(30))

        let calendar = try config.set("calendar.CAL-1.lead_seconds", raw: "10")
        #expect(calendar.old == nil)
        #expect(config.leadSeconds(forCalendar: "CAL-1") == 10)
        #expect(config.leadSeconds(forCalendar: "CAL-2") == 45)

        try config.set("calendar.CAL-1.folder", raw: "Calls")
        try config.set("calendars", raw: "CAL-2,CAL-1")
        #expect(config.folderOverride(forCalendar: "CAL-1") == "Calls")
        #expect(config.calendars == ["CAL-2", "CAL-1"])
    }

    @Test("set(value:) проверяет тип и правила так же, как разбор строки")
    func setValueValidates() throws {
        var config = Config()
        #expect(throws: ConfigError.self) { try config.set("lead_seconds", value: .string("30")) }
        #expect(throws: ConfigError.self) { try config.set("auto_record", value: .int(1)) }
        #expect(throws: ConfigError.self) { try config.set("calendar.CAL-1.folder", value: .string("../x")) }
        #expect(throws: ConfigError.unknownKey("nope")) { try config.set("nope", value: .bool(true)) }
        #expect(config == Config())
    }

    @Test("reset возвращает дефолт, resetAll — всё; неизвестный ключ — unknownKey")
    func resets() throws {
        var config = Config()
        try config.set("lead_seconds", raw: "30")
        try config.set("calendar.CAL-1.folder", raw: "Calls")

        try config.reset("lead_seconds")
        #expect(config.leadSeconds == 60)
        try config.reset("calendar.CAL-2.folder")  // не задан — no-op
        #expect(throws: ConfigError.unknownKey("nope")) { try config.reset("nope") }

        config.resetAll()
        #expect(config.values.isEmpty)
    }

    @Test("listing: каждый ключ схемы с флагом isDefault, заданные calendar.* — сразу за шаблоном")
    func listing() throws {
        var config = Config()
        try config.set("lead_seconds", raw: "30")
        try config.set("calendar.CAL-2.folder", raw: "Two")
        try config.set("calendar.CAL-1.folder", raw: "One")

        let items = config.listing()
        let keys = items.map(\.key)

        #expect(Set(ConfigSchema.all.map(\.key)).isSubset(of: Set(keys)))
        #expect(items.count == ConfigSchema.all.count + 2)
        let template = try #require(keys.firstIndex(of: "calendar.*.folder"))
        #expect(
            Array(keys[template...].prefix(3)) == [
                "calendar.*.folder", "calendar.CAL-1.folder", "calendar.CAL-2.folder",
            ])

        let lead = try #require(items.first { $0.key == "lead_seconds" })
        #expect(lead.value == 30)
        #expect(!lead.isDefault)
        #expect(lead.type == .int)
        let auto = try #require(items.first { $0.key == "auto_record" })
        #expect(auto.value == true)
        #expect(auto.isDefault)
        #expect(items.first { $0.key == "calendar.*.folder" }?.value == .null)
        #expect(items.first { $0.key == "calendar.CAL-1.folder" }?.value == "One")
    }
}

@Suite("ConfigStore: config.json на диске")
struct ConfigStoreTests {
    /// Свежий каталог на каждый тест: Swift Testing гоняет тесты параллельно.
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("earmark-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("нет файла — дефолты")
    func missingFile() throws {
        let store = ConfigStore(url: try makeTempDir().appendingPathComponent("config.json"))
        #expect(try store.load() == Config())
    }

    @Test("save → load возвращает тот же конфиг, каталог создаётся")
    func roundTrip() throws {
        let store = ConfigStore(url: try makeTempDir().appendingPathComponent("nested/config.json"))
        var config = Config()
        try config.set("auto_record", raw: "off")
        try config.set("calendars", raw: "CAL-1,CAL-2")
        try config.set("calendar.CAL-1.folder", raw: "Calls")

        try store.save(config)

        #expect(try store.load() == config)
    }

    @Test("на диске — ровно те ключи, что показывает CLI, и обычные JSON-значения")
    func diskFormat() throws {
        let url = try makeTempDir().appendingPathComponent("config.json")
        var config = Config()
        try config.set("stop.call_end_seconds", raw: "90")
        try config.set("calendar.6A1F-XyZ.folder", raw: "Calls")

        try ConfigStore(url: url).save(config)

        let raw = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(Set(raw.keys) == ["stop.call_end_seconds", "calendar.6A1F-XyZ.folder"])
        #expect(raw["stop.call_end_seconds"] as? Int == 90)
        #expect(raw["calendar.6A1F-XyZ.folder"] as? String == "Calls")
    }

    @Test(
        "ручная правка с неизвестным ключом или кривым значением — ошибка загрузки",
        arguments: [
            #"{"lead_seconds": "soon"}"#, #"{"lead_seconds": 99999}"#, #"{"colour": "red"}"#, "{not json",
        ])
    func invalidFile(text: String) throws {
        let url = try makeTempDir().appendingPathComponent("config.json")
        try Data(text.utf8).write(to: url)
        #expect(throws: (any Error).self) { try ConfigStore(url: url).load() }
    }
}
