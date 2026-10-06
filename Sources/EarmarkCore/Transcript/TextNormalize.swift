import Foundation

public enum TextNormalize {
    /// Слова для сравнения текстов: регистр и диакритика свёрнуты, остаются только буквы и цифры.
    ///
    /// Почему folding, а не lowercased(): «İ».lowercased() даёт «i» + U+0307, и азербайджанское
    /// «İclası» перестаёт совпадать с «iclası». folding за один проход снимает и эту точку,
    /// и разницу «ё»/«е», и регистр.
    public static func words(_ text: String) -> [String] {
        fold(text).split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// Свёртка без разбиения на слова — для поиска фраз подстрокой.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
