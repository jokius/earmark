import Foundation

// meta.json (спека §7.2, schema_version 1) и .recording.json. Ключи на диске получаются из имён
// свойств через snake_case EarmarkJSON — переименование свойства ломает внешних читателей,
// поэтому формат закреплён golden-тестом.

public enum RecordingStatus: String, Codable, Sendable {
    case recording, recorded, transcribing, transcribed
    case transcriptionFailed = "transcription_failed"
}

public struct AudioInfo: Codable, Equatable, Sendable {
    public var file: String  // "audio.m4a"
    public var codec: String  // "aac"
    public var sampleRate: Int  // 48000
    public var channels: [String]  // ["mic", "system"]
    /// > 0 — mic начался позже system на столько миллисекунд.
    public var micOffsetMs: Int

    public init(file: String, codec: String, sampleRate: Int, channels: [String], micOffsetMs: Int) {
        self.file = file
        self.codec = codec
        self.sampleRate = sampleRate
        self.channels = channels
        self.micOffsetMs = micOffsetMs
    }
}

public struct TranscriptionState: Codable, Equatable, Sendable {
    public var attempts: Int = 0
    public var errorKind: String?  // "permanent" | "environmental" | "retryable"
    public var error: String?
    public var fingerprint: String?
    public var language: String?

    public init(
        attempts: Int = 0, errorKind: String? = nil, error: String? = nil, fingerprint: String? = nil,
        language: String? = nil
    ) {
        self.attempts = attempts
        self.errorKind = errorKind
        self.error = error
        self.fingerprint = fingerprint
        self.language = language
    }
}

public struct RecordingMeta: Codable, Equatable, Sendable {
    public var schemaVersion: Int = 1
    public var id: String
    public var status: RecordingStatus
    public var trigger: RecordingTrigger
    public var title: String
    public var calendar: CalendarRef?
    public var event: EventRef?
    public var startedAt: Date
    public var endedAt: Date?
    public var durationSec: Double?
    public var stopReason: StopReason?
    public var callApps: [String] = []
    public var audio: AudioInfo?
    public var recovered: Bool = false
    public var transcription: TranscriptionState = .init()
    /// EarmarkVersion.current (Task 1) — единственный источник версии.
    public var appVersion: String

    public init(
        schemaVersion: Int = 1, id: String, status: RecordingStatus, trigger: RecordingTrigger, title: String,
        calendar: CalendarRef? = nil, event: EventRef? = nil, startedAt: Date, endedAt: Date? = nil,
        durationSec: Double? = nil, stopReason: StopReason? = nil, callApps: [String] = [],
        audio: AudioInfo? = nil,
        recovered: Bool = false, transcription: TranscriptionState = .init(), appVersion: String
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.status = status
        self.trigger = trigger
        self.title = title
        self.calendar = calendar
        self.event = event
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSec = durationSec
        self.stopReason = stopReason
        self.callApps = callApps
        self.audio = audio
        self.recovered = recovered
        self.transcription = transcription
        self.appVersion = appVersion
    }
}

/// .recording.json — существует только пока идёт запись.
///
/// Кроме pid и времени старта (спека §4.3) хранит всё, что нужно восстановлению собрать meta.json
/// после крэша: id, название, календарь и событие.
public struct RecordingManifest: Codable, Equatable, Sendable {
    public var pid: Int32
    public var startedAt: Date
    public var appVersion: String  // EarmarkVersion.current (Task 1)
    public var id: String
    public var trigger: RecordingTrigger
    public var title: String
    public var calendar: CalendarRef?
    public var event: EventRef?

    public init(
        pid: Int32, startedAt: Date, appVersion: String, id: String, trigger: RecordingTrigger, title: String,
        calendar: CalendarRef? = nil, event: EventRef? = nil
    ) {
        self.pid = pid
        self.startedAt = startedAt
        self.appVersion = appVersion
        self.id = id
        self.trigger = trigger
        self.title = title
        self.calendar = calendar
        self.event = event
    }
}
