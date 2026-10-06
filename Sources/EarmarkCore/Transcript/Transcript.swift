import Foundation

/// Канал записи. Порядок совпадает с индексом канала в audio.m4a: 0 — мой микрофон (L),
/// 1 — системный звук, то есть собеседники (R).
public enum Channel: String, Codable, Sendable { case mic, system }

/// Ключ говорящего в JSON стабилен. Человеческие подписи («Я», «Собеседники») живут только в txt
/// и берутся из конфига: их можно сменить без повторной транскрипции.
public enum Speaker: String, Codable, Sendable { case me, them }

/// Сегмент whisper одного канала. Время — от начала записи в миллисекундах: после VAD whisper.cpp
/// сам пересчитывает таймстемпы на исходную шкалу, поэтому каналы сливаются простой сортировкой.
public struct RawSegment: Codable, Equatable, Sendable {
    public var startMs: Int
    public var endMs: Int
    public var text: String

    public init(startMs: Int, endMs: Int, text: String) {
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
    }
}

/// transcript.<ch>.json — сегменты одного канала после пост-фильтра. Лежат отдельно, чтобы
/// повторное слияние не требовало новой транскрипции, а воркер, упавший на втором канале,
/// не терял первый.
public struct ChannelTranscript: Codable, Equatable, Sendable {
    public var schemaVersion: Int = 1
    public var channel: Channel
    public var model: String
    public var language: String
    /// Версия whisper.cpp + начало sha модели + версия параметров. Не совпал с текущим —
    /// канал считается заново.
    public var fingerprint: String
    public var segments: [RawSegment]

    public init(
        schemaVersion: Int = 1, channel: Channel, model: String, language: String, fingerprint: String,
        segments: [RawSegment]
    ) {
        self.schemaVersion = schemaVersion
        self.channel = channel
        self.model = model
        self.language = language
        self.fingerprint = fingerprint
        self.segments = segments
    }
}

public struct TranscriptSegment: Codable, Equatable, Sendable {
    public var startMs: Int
    public var endMs: Int
    public var channel: Channel
    public var speaker: Speaker
    public var text: String

    public init(startMs: Int, endMs: Int, channel: Channel, speaker: Speaker, text: String) {
        self.startMs = startMs
        self.endMs = endMs
        self.channel = channel
        self.speaker = speaker
        self.text = text
    }
}

/// transcript.json — итог записи. Его появление (через rename) и есть сигнал «расшифровка готова».
public struct Transcript: Codable, Equatable, Sendable {
    public var schemaVersion: Int = 1
    public var recordingId: String
    public var model: String
    public var language: String
    public var segments: [TranscriptSegment]

    public init(
        schemaVersion: Int = 1, recordingId: String, model: String, language: String,
        segments: [TranscriptSegment]
    ) {
        self.schemaVersion = schemaVersion
        self.recordingId = recordingId
        self.model = model
        self.language = language
        self.segments = segments
    }
}

/// Строка прогресса воркера `earmark transcribe --now` в stdout. Живёт в Core, а не рядом с движком:
/// app разбирает её, не линкуя EarmarkTranscription (whisper.framework в процессе app быть не должно).
public struct TranscribeProgress: Codable, Equatable, Sendable {
    public var channel: Channel
    public var percent: Int

    public init(channel: Channel, percent: Int) {
        self.channel = channel
        self.percent = percent
    }
}
