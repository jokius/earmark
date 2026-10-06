import Foundation
import Testing

@testable import EarmarkCore

@Suite("JSONValue: произвольный JSON туда и обратно")
struct JSONValueTests {
    private struct Sample: Codable, Equatable {
        var recordingId: String
        var startedAt: Date
        var byCalendar: [String: Int]
    }

    /// Обёртка как у IPCRequest: ключ поля структуры стратегия переводит, ключи внутри JSONValue — нет.
    private struct Wrapper: Codable, Equatable {
        var requestParams: JSONValue
    }

    @Test("разбирает все виды значений и кодирует целые без .0")
    func roundTrip() throws {
        let text = #"{"a":null,"b":true,"c":64,"d":1.5,"e":"x","f":[1,"y"],"g":{"h":false}}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))

        let expected: JSONValue = [
            "a": .null, "b": true, "c": 64, "d": 1.5, "e": "x", "f": [1, "y"], "g": ["h": false],
        ]
        #expect(value == expected)
        let encoded = try EarmarkJSON.encoder.encode(value)
        #expect(String(bytes: encoded, encoding: .utf8) == text)
    }

    @Test("аксессоры: intValue только для целых, остальные — только для своего типа")
    func accessors() {
        let value: JSONValue = ["n": 3, "f": 3.5, "s": "x", "b": true]
        #expect(value["n"]?.intValue == 3)
        #expect(value["f"]?.intValue == nil)
        #expect(value["s"]?.stringValue == "x")
        #expect(value["b"]?.boolValue == true)
        #expect(value["s"]?.intValue == nil)
        #expect(value["missing"] == nil)
        #expect(JSONValue.string("x")["key"] == nil)
    }

    @Test("init(encoding:) даёт snake_case и ISO 8601, ключи словарей не трогает; decode — обратно")
    func encodingUsesEarmarkJSON() throws {
        let sample = Sample(
            recordingId: "20261002-1400-a1b2", startedAt: Date(timeIntervalSince1970: 1_790_938_800),
            byCalendar: ["CAL-Upper": 1, "lead_seconds": 2])

        let value = try JSONValue(encoding: sample)

        #expect(
            value == [
                "recording_id": "20261002-1400-a1b2", "started_at": "2026-10-02T11:00:00Z",
                "by_calendar": ["CAL-Upper": 1, "lead_seconds": 2],
            ])
        #expect(try value.decode(Sample.self) == sample)
    }

    @Test("ключи внутри JSONValue переживают EarmarkJSON в обе стороны: и camelCase, и snake_case")
    func objectKeysSurviveStrategies() throws {
        let params: JSONValue = [
            "inputSchema": ["additionalProperties": false], "audio_test": true,
            "items": [["protocolVersion": "2025-06-18", "lead_seconds": 60]],
        ]

        let data = try EarmarkJSON.encoder.encode(Wrapper(requestParams: params))

        // на проводе: поле структуры — snake_case, всё внутри JSONValue — как было
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == ["request_params": params])
        #expect(try EarmarkJSON.decoder.decode(Wrapper.self, from: data) == Wrapper(requestParams: params))
    }
}
