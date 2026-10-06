import Foundation

/// Имена файлов внутри папки записи (спека §7.1) — одни на app, CLI и воркер транскрипции.
public enum RecordingFiles {
    public static let manifest = ".recording.json", transcribeLock = ".transcribe.lock"
    public static let mic = "mic.caf", system = "system.caf"
    // .partial стоит перед расширением: AVAudioFile выбирает контейнер по расширению
    public static let audio = "audio.m4a", audioPartial = "audio.partial.m4a"
    public static let meta = "meta.json"
    public static let transcriptMic = "transcript.mic.json", transcriptSystem = "transcript.system.json"
    public static let transcript = "transcript.json", transcriptText = "transcript.txt"
    public static let manualFolder = "Manual"
}

/// Папка записи, как её видно с диска.
public struct RecordingFolder: Equatable, Sendable {
    public let url: URL
    public let meta: RecordingMeta?
    public let manifest: RecordingManifest?

    public var isRecording: Bool { manifest != nil }

    /// audio.m4a появляется только через rename, поэтому его наличие и есть «запись завершена».
    public var isComplete: Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(RecordingFiles.audio).path)
    }

    public var id: String? { meta?.id ?? manifest?.id }

    /// Эффективный статус: пока есть manifest, запись идёт, что бы ни лежало в meta.json —
    /// финализация пишет meta раньше, чем удаляет manifest.
    public var status: RecordingStatus? { manifest != nil ? .recording : meta?.status }
}

public struct RecordingFilter: Equatable, Sendable {
    public var since: Date?
    public var until: Date?
    public var calendarId: String?
    public var status: RecordingStatus?
    public var limit: Int?

    public init(
        since: Date? = nil, until: Date? = nil, calendarId: String? = nil, status: RecordingStatus? = nil,
        limit: Int? = nil
    ) {
        self.since = since
        self.until = until
        self.calendarId = calendarId
        self.status = status
        self.limit = limit
    }
}
