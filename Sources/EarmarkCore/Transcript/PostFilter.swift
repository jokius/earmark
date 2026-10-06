import Foundation

/// Фильтр галлюцинаций whisper — перенос эталонного фильтра рабочей связки, по сегменту на строку.
///
/// На тишине и музыке whisper выдаёт заученные хвосты субтитров («Продолжение следует…»)
/// и зацикленные повторы. Логика эталона сохранена; отличие одно — фразы ищем в свёрнутом
/// тексте (TextNormalize), а не в lowercased(): иначе «İzlədiyiniz…» с заглавной İ проскакивало.
public enum PostFilter {
    public static let junkPhrases: [String] = [
        "продолжение следует",
        "субтитры",
        "редактор субтитров",
        "izlədiyiniz üçün təşəkkür edirəm",
        "təşəkkür edirəm",
        "thanks for watching",
        "thank you for watching",
        "подписывайтесь на канал",
        "ставьте лайк",
    ]

    private static let foldedJunk = junkPhrases.map(TextNormalize.fold)

    /// 4+ одинаковых слова подряд (без учёта регистра) → одно. ICU, как и re эталона,
    /// сравнивает обратную ссылку \1 без учёта регистра: «Да да ДА да» схлопывается.
    private static let repeats: NSRegularExpression = {
        do {
            return try NSRegularExpression(pattern: #"\b(\w+)(\s+\1\b){3,}"#, options: [.caseInsensitive])
        } catch {
            preconditionFailure("repeat regex does not compile: \(error)")
        }
    }()

    /// Выкинуть пустые, с junk-фразой и вырожденные сегменты; в остальных схлопнуть повторы.
    /// Таймстемпы выживших сегментов не трогаем.
    public static func apply(_ segments: [RawSegment]) -> [RawSegment] {
        segments.compactMap { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let folded = TextNormalize.fold(text)
            guard !text.isEmpty, !foldedJunk.contains(where: { folded.contains($0) }), !isDegenerate(folded)
            else {
                return nil
            }
            var kept = segment
            kept.text = repeats.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1")
            return kept
        }
    }

    /// Не меньше 6 слов, не больше 2 разных, и каждое в среднем повторено больше 5 раз —
    /// «да да да да да да». Слова — по пробелам, как split() эталона: «да,» и «да» разные.
    private static func isDegenerate(_ folded: String) -> Bool {
        let words = folded.split(whereSeparator: \.isWhitespace)
        guard words.count >= 6 else { return false }
        let unique = Set(words).count
        return unique <= 2 && Double(words.count) / Double(unique) > 5
    }
}
