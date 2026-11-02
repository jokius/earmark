import Foundation

/// Значение transcription.language и calendar.<id>.language: auto, один код или список кодов.
public enum TranscriptionLanguage: Equatable, Sendable {
    case auto
    case single(String)
    case multi([String])

    /// Регистр, пробелы и повторы прощаем: " RU , en,en" — тот же список, что "ru,en".
    /// auto в списке не имеет смысла (список и есть выбор из языков), поэтому это ошибка.
    public init?(_ raw: String) {
        var codes: [String] = []
        for item in raw.split(separator: ",") {
            let code = item.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !code.isEmpty && !codes.contains(code) { codes.append(code) }
        }
        if codes == ["auto"] {
            self = .auto
            return
        }
        guard !codes.isEmpty, codes.allSatisfy(Self.whisperCodes.contains) else { return nil }
        self = codes.count == 1 ? .single(codes[0]) : .multi(codes)
    }

    /// Каноническая форма: так значение хранится в конфиге и в meta/transcript.
    public var raw: String {
        switch self {
        case .auto: "auto"
        case .single(let code): code
        case .multi(let codes): codes.joined(separator: ",")
        }
    }

    /// Коды g_lang из whisper.cpp: другой код whisper не примет, а опечатка вроде "aze" должна
    /// падать на `config set`, а не на транскрипции через час.
    public static let whisperCodes: Set<String> = [
        "en", "zh", "de", "es", "ru", "ko", "fr", "ja", "pt", "tr", "pl", "ca", "nl", "ar", "sv", "it", "id",
        "hi", "fi", "vi", "he", "uk", "el", "ms", "cs", "ro", "da", "hu", "ta", "no", "th", "ur", "hr", "bg",
        "lt", "la", "mi", "ml", "cy", "sk", "te", "fa", "lv", "bn", "sr", "az", "sl", "kn", "et", "mk", "br",
        "eu", "is", "hy", "ne", "mn", "bs", "kk", "sq", "sw", "gl", "mr", "pa", "si", "km", "sn", "yo", "so",
        "af", "oc", "ka", "be", "tg", "sd", "gu", "am", "yi", "lo", "uz", "fo", "ht", "ps", "tk", "nn", "mt",
        "sa", "lb", "my", "bo", "tl", "mg", "as", "tt", "haw", "ln", "ha", "ba", "jw", "su", "yue",
    ]
}
