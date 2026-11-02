import Foundation

public struct SpeechSpan: Equatable, Sendable {
    public var startMs: Int
    public var endMs: Int

    public init(startMs: Int, endMs: Int) {
        self.startMs = startMs
        self.endMs = endMs
    }
}

public struct LanguageRun: Equatable, Sendable {
    public var startMs: Int
    public var endMs: Int
    public var language: String

    public init(startMs: Int, endMs: Int, language: String) {
        self.startMs = startMs
        self.endMs = endMs
        self.language = language
    }
}

/// Язык по кускам речи для списка языков: куски → язык куска → прогоны одного языка.
public enum LanguagePlan {
    /// Азербайджанскую речь whisper определяет как турецкий (p до ~0.6), а az получает ~0.002:
    /// без алиаса такой кусок уходил английскому и переводился на английский.
    public static let aliases: [String: [String]] = ["az": ["tr"]]

    /// Склеивает отрезки VAD в куски до maxChunkMs: определение языка видит окно в 30 с, а на
    /// обрывке в полсекунды ошибается чаще.
    public static func chunks(_ speech: [SpeechSpan], maxGapMs: Int = 1000, maxChunkMs: Int = 30_000)
        -> [SpeechSpan]
    {
        var result: [SpeechSpan] = []
        for span in speech {
            if let last = result.last, span.startMs - last.endMs < maxGapMs,
                span.endMs - last.startMs <= maxChunkMs
            {
                result[result.count - 1].endMs = span.endMs
            } else {
                result.append(span)
            }
        }
        return result
    }

    /// Самый вероятный язык из allowed; вероятность алиаса засчитывается, только если пользователь
    /// не разрешил его сам. Равенство — в пользу более раннего в allowed.
    public static func pick(_ probabilities: [String: Float], allowed: [String]) -> String {
        func score(_ language: String) -> Float {
            let borrowed = (aliases[language] ?? []).filter { !allowed.contains($0) }
            return ([language] + borrowed).reduce(0) { $0 + (probabilities[$1] ?? 0) }
        }
        var best = allowed[0]
        var bestScore = score(best)
        for language in allowed.dropFirst() {
            let candidate = score(language)
            if candidate > bestScore {
                best = language
                bestScore = candidate
            }
        }
        return best
    }

    /// Соседние куски одного языка — один whisper_full: меньше вызовов и контекст внутри прогона.
    public static func runs(_ chunks: [SpeechSpan], languages: [String]) -> [LanguageRun] {
        var result: [LanguageRun] = []
        for (chunk, language) in zip(chunks, languages) {
            if result.last?.language == language {
                result[result.count - 1].endMs = chunk.endMs
            } else {
                result.append(LanguageRun(startMs: chunk.startMs, endMs: chunk.endMs, language: language))
            }
        }
        return result
    }
}
