import Foundation

public enum TranscriptRender {
    /// transcript.txt: «[hh:mm:ss] <подпись>: текст», время от начала записи.
    ///
    /// Соседние реплики одного говорящего с паузой ≤ joinGapMs склеиваются в одну строку:
    /// whisper режет речь на куски по 2–10 с, и без склейки диалог читается как телеграф.
    public static func text(
        _ transcript: Transcript, labelMe: String, labelThem: String, joinGapMs: Int = 1500
    ) -> String {
        var turns: [Turn] = []
        for segment in transcript.segments {
            if let last = turns.last, last.speaker == segment.speaker, segment.startMs - last.end <= joinGapMs
            {
                turns[turns.count - 1].end = max(last.end, segment.endMs)
                turns[turns.count - 1].text.append(segment.text)
            } else {
                turns.append(
                    Turn(
                        start: segment.startMs, end: segment.endMs, speaker: segment.speaker,
                        text: [segment.text]))
            }
        }
        return turns.map { turn in
            let seconds = turn.start / 1000
            let stamp = String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            let label = turn.speaker == .me ? labelMe : labelThem
            return "[\(stamp)] \(label): \(turn.text.joined(separator: " "))\n"
        }.joined()
    }

    /// Реплика: подряд идущие сегменты одного говорящего.
    private struct Turn {
        var start: Int
        var end: Int
        var speaker: Speaker
        var text: [String]
    }
}
