import Foundation

public enum TranscriptMerge {
    /// mic → .me, system → .them; сортировка по startMs, при равенстве mic первым.
    ///
    /// Простая сортировка корректна, потому что оба канала уже на одной шкале: сведение
    /// учло mic_offset_ms, а whisper после VAD вернул таймстемпы на исходное время.
    public static func merge(mic: ChannelTranscript?, system: ChannelTranscript?) -> [TranscriptSegment] {
        let me = (mic?.segments ?? []).map {
            TranscriptSegment(
                startMs: $0.startMs, endMs: $0.endMs, channel: .mic, speaker: .me, text: $0.text)
        }
        let them = (system?.segments ?? []).map {
            TranscriptSegment(
                startMs: $0.startMs, endMs: $0.endMs, channel: .system, speaker: .them, text: $0.text)
        }
        // Индекс в ключе — стабильность внутри канала: sort() стабильность не обещает.
        return (me + them).enumerated()
            .sorted { lhs, rhs in
                (lhs.element.startMs, lhs.element.channel == .mic ? 0 : 1, lhs.offset)
                    < (rhs.element.startMs, rhs.element.channel == .mic ? 0 : 1, rhs.offset)
            }
            .map(\.element)
    }
}
