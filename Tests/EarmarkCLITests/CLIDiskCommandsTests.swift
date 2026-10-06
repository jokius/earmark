import EarmarkCore
import Foundation
import Testing

@testable import EarmarkCLI

@Suite("CLI: команды с диска, без app")
struct CLIDiskCommandsTests {
    /// id записей из ответа `earmark recordings …`.
    private func ids(_ harness: CLIHarness, _ argv: [String]) async throws -> [String] {
        let result = try await harness.run(argv)
        #expect(result.code == 0, "\(argv)")
        return result.data?.items.compactMap { $0["id"]?.stringValue } ?? []
    }

    @Test("recordings: фильтры по дате, статусу, календарю и лимит; новые первыми")
    func recordingsFilters() async throws {
        let harness = try CLIHarness()
        try harness.makeRecordings()
        let (idA, idB, idC) = (CLIHarness.idA, CLIHarness.idB, CLIHarness.idC)
        // Даты разнесены на недели: локальная полночь в любом часовом поясе не меняет ответ.
        #expect(try await ids(harness, ["recordings"]) == [idC, idB, idA])
        #expect(try await ids(harness, ["recordings", "--since", "2026-09-15"]) == [idC, idB])
        #expect(try await ids(harness, ["recordings", "--until", "2026-09-15"]) == [idA])
        #expect(try await ids(harness, ["recordings", "--since", "2026-10-01T12:00:00Z"]) == [idC])
        #expect(try await ids(harness, ["recordings", "--status", "transcribed"]) == [idA])
        #expect(try await ids(harness, ["recordings", "--calendar", "cal-personal"]) == [idB])
        #expect(try await ids(harness, ["recordings", "--limit", "1"]) == [idC])
        let invalid = [
            ["recordings", "--status", "done"], ["recordings", "--since", "01.10.2026"],
            ["recordings", "--limit", "0"],
        ]
        for argv in invalid {
            #expect(try await harness.run(argv).code == 64, "\(argv)")
        }
    }

    @Test("recordings: дата в --since/--until — локальные сутки целиком, until включает весь день")
    func recordingsLocalDayBounds() async throws {
        let harness = try CLIHarness()
        // Время собираем в том же локальном поясе, что и CLI: тест проходит в любом часовом поясе.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        func local(_ day: Int, _ hour: Int, _ minute: Int) throws -> String {
            let parts = DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute)
            return try #require(calendar.date(from: parts)).ISO8601Format()
        }
        let (late, early) = ("20260915-2330-dddd", "20260916-0030-eeee")
        try harness.writeRecording(
            "Manual/2026-09-15 23-30 Late", id: late, status: "recorded", calendar: nil,
            startedAt: try local(15, 23, 30))
        try harness.writeRecording(
            "Manual/2026-09-16 00-30 Early", id: early, status: "recorded", calendar: nil,
            startedAt: try local(16, 0, 30))
        #expect(try await ids(harness, ["recordings", "--until", "2026-09-15"]) == [late])
        #expect(try await ids(harness, ["recordings", "--since", "2026-09-16"]) == [early])
        let oneDay = ["recordings", "--since", "2026-09-15", "--until", "2026-09-15"]
        #expect(try await ids(harness, oneDay) == [late])
    }

    @Test("recordings на свежей установке, где папки записей ещё нет: пустой список")
    func recordingsWithoutFolder() async throws {
        let harness = try CLIHarness()
        let result = try await harness.run(["recordings"])
        #expect(result.code == 0)
        #expect(result.data == .array([]))
    }

    @Test("recording: meta + абсолютные пути только существующих файлов; чужой id — not_found")
    func recordingDetails() async throws {
        let harness = try CLIHarness()
        try harness.makeRecordings()
        let result = try await harness.run(["recording", CLIHarness.idA])
        #expect(result.code == 0)
        #expect(result.data?["status"] == .string("transcribed"))
        #expect(result.data?["calendar"]?["title"] == .string("Work"))
        let path = try #require(result.data?["path"]?.stringValue)
        #expect(path.hasSuffix("/Work/2026-09-01 10-00 Daily sync"))
        guard case .object(let files)? = result.data?["files"] else {
            Issue.record("в ответе нет files")
            return
        }
        #expect(Set(files.keys) == [RecordingFiles.audio, RecordingFiles.meta, RecordingFiles.transcript])
        #expect(files[RecordingFiles.audio] == .string(path + "/" + RecordingFiles.audio))

        let missing = try await harness.run(["recording", "20990101-0000-ffff"])
        #expect(missing.code == 2)
        #expect(missing.errorCode == "not_found")
    }

    @Test("transcript txt: подписи из конфига, страницы до конца по next_offset")
    func transcriptPages() async throws {
        let harness = try CLIHarness()
        try harness.setConfig([
            "transcript.label_me": .string("Я"), "transcript.label_them": .string("Собеседники"),
        ])
        try harness.makeRecordings()
        var pages: [String] = []
        var offset = 0
        var total = 0
        while pages.count < 100 {
            let argv = ["transcript", CLIHarness.idA, "--words", "7", "--offset", "\(offset)"]
            let result = try await harness.run(argv)
            #expect(result.code == 0)
            let page = try #require(result.data)
            #expect(page["offset"] == .number(Double(offset)))
            pages.append(try #require(page["text"]?.stringValue))
            total = try #require(page["total_words"]?.intValue)
            guard let next = page["next_offset"]?.intValue else { break }
            #expect(next == offset + 7)
            offset = next
        }
        let joined = pages.joined(separator: " ")
        #expect(joined.split(whereSeparator: \.isWhitespace).count == total)
        #expect(pages.count == (total + 6) / 7)
        #expect(joined.contains("Я:") && joined.contains("Собеседники:"))
    }

    @Test("transcript: страница не больше 500 слов, даже если попросили больше")
    func transcriptPageCap() async throws {
        let harness = try CLIHarness()
        try harness.makeRecordings(transcriptSegments: 150)
        let result = try await harness.run(["transcript", CLIHarness.idA, "--words", "100000"])
        #expect(result.code == 0)
        let text = try #require(result.data?["text"]?.stringValue)
        #expect(text.split(whereSeparator: \.isWhitespace).count == TranscriptPaging.maxWords)
        #expect(result.data?["next_offset"] == .number(Double(TranscriptPaging.maxWords)))
    }

    @Test("transcript json — целиком; лишние опции и чужой формат — 64; нет транскрипта — not_found")
    func transcriptJSONAndErrors() async throws {
        let harness = try CLIHarness()
        try harness.makeRecordings()
        let json = try await harness.run(["transcript", CLIHarness.idA, "--format", "json"])
        #expect(json.code == 0)
        #expect(json.data?["recording_id"] == .string(CLIHarness.idA))
        #expect(json.data?["segments"]?.items.count == 6)
        let pagedJSON = ["transcript", CLIHarness.idA, "--format", "json", "--words", "5"]
        #expect(try await harness.run(pagedJSON).code == 64)
        #expect(try await harness.run(["transcript", CLIHarness.idA, "--format", "xml"]).code == 64)
        let pending = try await harness.run(["transcript", CLIHarness.idB])
        #expect(pending.code == 2)
        #expect(pending.errorCode == "not_found")
    }

    @Test("config get/list читают config.json с диска, без app")
    func configFromDisk() async throws {
        let harness = try CLIHarness()
        try harness.setConfig(["lead_seconds": .int(90)])
        let lead = try await harness.run(["config", "get", "lead_seconds"])
        #expect(lead.code == 0)
        #expect(lead.data?["value"] == .number(90))
        #expect(lead.data?["is_default"] == .bool(false))
        let maxMinutes = try await harness.run(["config", "get", "stop.max_minutes"])
        #expect(maxMinutes.data?["value"] == .number(300))
        #expect(maxMinutes.data?["is_default"] == .bool(true))
        let folder = try await harness.run(["config", "get", "calendar.cal-work.folder"])
        #expect(folder.code == 0)
        #expect(folder.data?["value"] == .null)
        let list = try await harness.run(["config", "list"])
        let keys = list.data?.items.compactMap { $0["key"]?.stringValue } ?? []
        #expect(keys.contains("lead_seconds") && keys.contains("transcript.label_me"))
        let unknown = try await harness.run(["config", "get", "nope"])
        #expect(unknown.code == 64)
    }
}

extension CLIHarness {
    static let idA = "20260901-1000-aaaa"
    static let idB = "20261001-1000-bbbb"
    static let idC = "20261001-1500-cccc"

    /// Три записи на разные даты: A — Work, расшифрована (с транскриптом); B — Personal, ждёт;
    /// C — ручная, ждёт. meta.json и transcript.json пишутся сырым JSON: это и есть контракт
    /// формата на диске между app и CLI.
    func makeRecordings(transcriptSegments: Int = 6) throws {
        let folderA = try writeRecording(
            "Work/2026-09-01 10-00 Daily sync", id: Self.idA, status: "transcribed",
            calendar: #"{"id":"cal-work","title":"Work"}"#, startedAt: "2026-09-01T10:00:00Z")
        try writeTranscript(in: folderA, id: Self.idA, segments: transcriptSegments)
        try writeRecording(
            "Personal/2026-10-01 10-00 Daily sync", id: Self.idB, status: "recorded",
            calendar: #"{"id":"cal-personal","title":"Personal"}"#, startedAt: "2026-10-01T10:00:00Z")
        try writeRecording(
            "Manual/2026-10-01 15-00 Daily sync", id: Self.idC, status: "recorded", calendar: nil,
            startedAt: "2026-10-01T15:00:00Z")
    }

    @discardableResult
    fileprivate func writeRecording(
        _ folder: String, id: String, status: String, calendar: String?, startedAt: String
    ) throws -> URL {
        let url = recordingsRoot.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let trigger = calendar == nil ? "manual" : "calendar"
        let calendarField = calendar.map { #""calendar":\#($0),"# } ?? ""
        let meta = """
            {"schema_version":1,"id":"\(id)","status":"\(status)","trigger":"\(trigger)",
            "title":"Daily sync",\(calendarField)"started_at":"\(startedAt)","call_apps":[],
            "recovered":false,"transcription":{"attempts":0},"app_version":"0.1.0"}
            """
        try Data(meta.utf8).write(to: url.appendingPathComponent(RecordingFiles.meta))
        try Data().write(to: url.appendingPathComponent(RecordingFiles.audio))
        return url
    }

    /// Реплики по очереди «я / собеседники», по 5 слов, с паузой 2 с — склейка их не объединит.
    private func writeTranscript(in folder: URL, id: String, segments: Int) throws {
        let items = (0..<segments).map { index in
            let mine = index.isMultiple(of: 2)
            return """
                {"start_ms":\(index * 4000),"end_ms":\(index * 4000 + 2000),
                "channel":"\(mine ? "mic" : "system")","speaker":"\(mine ? "me" : "them")",
                "text":"реплика номер \(index) про план"}
                """
        }
        let transcript = """
            {"schema_version":1,"recording_id":"\(id)","model":"ggml-large-v3-turbo","language":"ru",
            "segments":[\(items.joined(separator: ","))]}
            """
        try Data(transcript.utf8).write(to: folder.appendingPathComponent(RecordingFiles.transcript))
    }
}
