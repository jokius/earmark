import Foundation

public struct TranscriptPage: Codable, Equatable, Sendable {
    public var text: String
    public var offset: Int
    public var nextOffset: Int?
    public var totalWords: Int

    public init(text: String, offset: Int, nextOffset: Int?, totalWords: Int) {
        self.text = text
        self.offset = offset
        self.nextOffset = nextOffset
        self.totalWords = totalWords
    }
}

public enum TranscriptPaging {
    public static let defaultWords = 200, maxWords = 500

    /// Страница отрендеренного txt по словам (слово — всё между пробелами, «[00:00:05]» тоже слово).
    ///
    /// Текст страницы — срез исходной строки от первого до последнего слова, поэтому переводы строк
    /// между репликами сохраняются. Агент читает транскрипт кусками, не забивая контекст целиком.
    public static func page(_ renderedText: String, offset: Int, words: Int) -> TranscriptPage {
        let tokens = renderedText.split(whereSeparator: \.isWhitespace)
        let count = min(max(words, 1), maxWords)
        let start = min(max(offset, 0), tokens.count)
        let end = min(start + count, tokens.count)
        let text =
            start < end ? String(renderedText[tokens[start].startIndex..<tokens[end - 1].endIndex]) : ""
        return TranscriptPage(
            text: text, offset: start, nextOffset: end < tokens.count ? end : nil, totalWords: tokens.count)
    }
}
