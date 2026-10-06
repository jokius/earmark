import Foundation
import Testing

@testable import EarmarkCore

@Suite("Ошибки, конверт CLI, IPC-протокол")
struct ControlProtocolTests {
    private func json(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    @Test(
        "фабрики ошибок дают код и exit code из спеки §9.3",
        arguments: [
            (EarmarkError.operationFailed("m"), "operation_failed", Int32(1)),
            (.notFound("m"), "not_found", 2),
            (.appNotRunning("m"), "app_not_running", 3),
            (.permissionDenied("m"), "permission_denied", 4),
            (.invalidArguments("m"), "invalid_arguments", 64),
            (.badData("m"), "bad_data", 65),
            (.unavailable("m"), "unavailable", 69),
            (.busy("m"), "busy", 75),
        ])
    func errorFactories(error: EarmarkError, code: String, exitCode: Int32) {
        #expect(error.code == code)
        #expect(error.exitCode == exitCode)
        #expect(error.message == "m")
        // Через нетипизированный throws app и CLI печатают localizedDescription — это тот же message.
        #expect(error.localizedDescription == "m")
    }

    @Test("конверт успеха и ошибки; объект ошибки совпадает с Codable-формой EarmarkError")
    func envelopes() throws {
        #expect(
            Envelope.success(command: "recordings", data: ["a", 1])
                == ["schema_version": 1, "command": "recordings", "data": ["a", 1]])

        let error = EarmarkError.notFound("recording 20261002-1400-a1b2 not found")
        let failure = Envelope.failure(error)
        #expect(
            failure
                == [
                    "schema_version": 1,
                    "error": [
                        "code": "not_found", "message": "recording 20261002-1400-a1b2 not found",
                        "exit_code": 2,
                    ],
                ])
        #expect(failure["error"] == (try JSONValue(encoding: error)))
    }

    @Test("запрос и ответ IPC: формат строки из спеки §9.2")
    func ipcShapes() throws {
        let request = IPCRequest(method: IPCMethod.recordingStart, params: ["title": "Standup"])
        #expect(
            try json(IPCFraming.encode(request)) == [
                "v": 1, "method": "recording.start", "params": ["title": "Standup"],
            ])

        #expect(
            try json(IPCFraming.encode(IPCResponse.success(["state": "idle"]))) == [
                "ok": true, "data": ["state": "idle"],
            ])
        #expect(
            try json(IPCFraming.encode(IPCResponse.failure(.busy("queue is busy"))))
                == ["ok": false, "error": ["code": "busy", "message": "queue is busy", "exit_code": 75]])
    }

    @Test("кадр — одна строка с \\n в конце даже для текста с переводами строк; разбор с \\n и без")
    func framing() throws {
        let request = IPCRequest(
            method: IPCMethod.configSet, params: ["key": "transcript.label_me", "value": "a\nb"])

        let line = try IPCFraming.encode(request)

        #expect(line.last == 0x0A)
        #expect(line.dropLast().contains(0x0A) == false)
        #expect(try IPCFraming.decode(IPCRequest.self, from: line) == request)
        #expect(try IPCFraming.decode(IPCRequest.self, from: line.dropLast()) == request)
    }

    @Test("строка больше 1 MiB и мусор — bad_data")
    func framingLimits() {
        let huge = Data(repeating: 0x20, count: IPCFraming.maxLineBytes + 1)
        #expect(throws: EarmarkError.self) { try IPCFraming.decode(IPCRequest.self, from: huge) }
        #expect(throws: EarmarkError.self) {
            try IPCFraming.decode(IPCRequest.self, from: Data("{nope".utf8))
        }
        let bulky = IPCRequest(
            method: IPCMethod.configSet, params: .string(String(repeating: "x", count: 1 << 20)))
        #expect(throws: EarmarkError.self) { try IPCFraming.encode(bulky) }
        do {
            _ = try IPCFraming.decode(IPCRequest.self, from: huge)
        } catch let error as EarmarkError {
            #expect(error.code == "bad_data")
        } catch {
            Issue.record("ожидали EarmarkError, получили \(error)")
        }
    }

    @Test("модели ответов: snake_case-ключи, которые читают CLI и агенты")
    func statusKeys() throws {
        let start = Date(timeIntervalSince1970: 1_790_938_800)
        let status = StatusData(
            appRunning: true, appVersion: "0.1.0", state: "recording",
            recording: CurrentRecordingInfo(
                id: "20261002-1400-a1b2", title: "Daily sync",
                calendar: CalendarRef(id: "cal-1", title: "Work"),
                trigger: .calendar, startedAt: start, elapsedSec: 12.5, callActive: true, callApps: ["Zoom"],
                folder: "/Users/alice/Earmark/Work/2026-10-02 14-00 Daily sync"),
            next: UpcomingItem(
                eventId: "evt-2", title: "Retro", calendar: CalendarRef(id: "cal-1", title: "Work"),
                start: start,
                end: start.addingTimeInterval(1800), recordAt: start.addingTimeInterval(-60)),
            queue: QueueInfo(running: nil, pending: 2),
            permissions: PermissionsInfo(
                microphone: "granted", audioCapture: "unknown", calendars: "granted"),
            model: ModelStatusInfo(state: "downloading", progress: 0.5),
            warnings: ["model_missing"])

        let value = try JSONValue(encoding: status)

        #expect(value["app_running"] == true)
        #expect(value["recording"]?["elapsed_sec"] == 12.5)
        #expect(value["recording"]?["call_apps"] == ["Zoom"])
        #expect(value["recording"]?["started_at"] == "2026-10-02T11:00:00Z")
        #expect(value["next"]?["record_at"] == "2026-10-02T10:59:00Z")
        #expect(value["next"]?["event_id"] == "evt-2")
        #expect(value["permissions"]?["audio_capture"] == "unknown")
        #expect(value["queue"] == ["pending": 2])
        #expect(try value.decode(StatusData.self) == status)
    }
}
