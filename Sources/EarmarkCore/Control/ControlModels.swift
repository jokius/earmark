import Foundation

// Модели ответов (data в IPC и CLI). Ключи — snake_case через EarmarkJSON, как везде.
// Инициализаторы публичные: эти значения собирает app (другой модуль), а читают CLI и агенты.

public struct StatusData: Codable, Equatable, Sendable {
    public var appRunning: Bool
    public var appVersion: String?  // EarmarkVersion.current (Task 1)
    public var state: String  // "idle" | "recording" | "transcribing"
    public var recording: CurrentRecordingInfo?
    public var next: UpcomingItem?
    public var queue: QueueInfo?
    public var permissions: PermissionsInfo?
    public var model: ModelStatusInfo?
    public var warnings: [String]  // "stale_calendars:<id,…>", "far_end_digital_silence", "model_missing", …

    public init(
        appRunning: Bool, appVersion: String? = nil, state: String, recording: CurrentRecordingInfo? = nil,
        next: UpcomingItem? = nil, queue: QueueInfo? = nil, permissions: PermissionsInfo? = nil,
        model: ModelStatusInfo? = nil, warnings: [String] = []
    ) {
        self.appRunning = appRunning
        self.appVersion = appVersion
        self.state = state
        self.recording = recording
        self.next = next
        self.queue = queue
        self.permissions = permissions
        self.model = model
        self.warnings = warnings
    }
}

public struct CurrentRecordingInfo: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var calendar: CalendarRef?
    public var trigger: RecordingTrigger
    public var startedAt: Date
    public var elapsedSec: Double
    public var callActive: Bool
    public var callApps: [String]
    public var folder: String

    public init(
        id: String, title: String, calendar: CalendarRef?, trigger: RecordingTrigger, startedAt: Date,
        elapsedSec: Double, callActive: Bool, callApps: [String], folder: String
    ) {
        self.id = id
        self.title = title
        self.calendar = calendar
        self.trigger = trigger
        self.startedAt = startedAt
        self.elapsedSec = elapsedSec
        self.callActive = callActive
        self.callApps = callApps
        self.folder = folder
    }
}

public struct QueueInfo: Codable, Equatable, Sendable {
    public var running: String?
    public var pending: Int
    /// Прогресс текущей задачи — для меню и `status` (поля плоские: Control не зависит от Transcript).
    public var channel: String?  // "mic" | "system"
    public var percent: Int?

    public init(running: String?, pending: Int, channel: String? = nil, percent: Int? = nil) {
        self.running = running
        self.pending = pending
        self.channel = channel
        self.percent = percent
    }
}

public struct PermissionsInfo: Codable, Equatable, Sendable {
    public var microphone: String  // granted|denied|not_determined|unknown
    public var audioCapture: String
    public var calendars: String

    public init(microphone: String, audioCapture: String, calendars: String) {
        self.microphone = microphone
        self.audioCapture = audioCapture
        self.calendars = calendars
    }
}

public struct ModelStatusInfo: Codable, Equatable, Sendable {
    public var state: String  // "missing" | "downloading" | "ready" | "corrupt"
    public var progress: Double?  // 0…1 при downloading
    public var path: String?

    public init(state: String, progress: Double? = nil, path: String? = nil) {
        self.state = state
        self.progress = progress
        self.path = path
    }
}

public struct CalendarListItem: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var account: String
    public var enabled: Bool
    public var folder: String

    public init(id: String, title: String, account: String, enabled: Bool, folder: String) {
        self.id = id
        self.title = title
        self.account = account
        self.enabled = enabled
        self.folder = folder
    }
}

public struct DoctorCheck: Codable, Equatable, Sendable {
    public var name: String
    public var ok: Bool
    public var detail: String

    public init(name: String, ok: Bool, detail: String) {
        self.name = name
        self.ok = ok
        self.detail = detail
    }
}

public struct DoctorReport: Codable, Equatable, Sendable {
    public var ready: Bool
    public var checks: [DoctorCheck]

    public init(ready: Bool, checks: [DoctorCheck]) {
        self.ready = ready
        self.checks = checks
    }
}
