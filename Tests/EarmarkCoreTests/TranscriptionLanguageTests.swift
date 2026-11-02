import EarmarkCore
import Testing

@Suite("TranscriptionLanguage: auto, один код или список")
struct TranscriptionLanguageTests {
    @Test(
        "разбор: обрезка пробелов, нижний регистр, пустые выкинуты, повторы схлопнуты с порядком пользователя",
        arguments: [
            ("auto", TranscriptionLanguage.auto),
            ("Auto", .auto),
            (" AUTO ", .auto),
            ("auto,", .auto),
            ("ru", .single("ru")),
            (" RU ", .single("ru")),
            ("ru,ru", .single("ru")),
            (",ru,,", .single("ru")),
            ("haw", .single("haw")),
            ("yue", .single("yue")),
            (" RU , en,az,en", .multi(["ru", "en", "az"])),
            ("en,ru", .multi(["en", "ru"])),
            ("ru,,EN", .multi(["ru", "en"])),
            ("az,tr", .multi(["az", "tr"])),
        ])
    func parses(raw: String, expected: TranscriptionLanguage) {
        #expect(TranscriptionLanguage(raw) == expected)
    }

    @Test(
        "невалидное — nil: auto вместе с кодами, коды не из whisper, пустая строка и одни разделители",
        arguments: [
            "auto,ru", "ru,auto", "ru,AUTO", "aze", "english", "r u", "russian", "r", "ru,xx", "ru;en", "",
            " ", ",", " , , ",
        ])
    func rejects(raw: String) {
        #expect(TranscriptionLanguage(raw) == nil)
    }

    @Test("raw — каноническая строка без пробелов")
    func canonicalRaw() {
        #expect(TranscriptionLanguage.auto.raw == "auto")
        #expect(TranscriptionLanguage.single("ru").raw == "ru")
        #expect(TranscriptionLanguage.multi(["ru", "en", "az"]).raw == "ru,en,az")
        #expect(TranscriptionLanguage(" RU , en,az,en")?.raw == "ru,en,az")
    }

    @Test(
        "разбор raw возвращает то же значение",
        arguments: [
            TranscriptionLanguage.auto, .single("ru"), .single("haw"), .multi(["ru", "en", "az"]),
            .multi(["en", "ru"]),
        ])
    func roundTrip(language: TranscriptionLanguage) {
        #expect(TranscriptionLanguage(language.raw) == language)
    }

    @Test("whisperCodes — ровно 100 кодов whisper.cpp, и каждый из них разбирается в single")
    func whisperCodes() {
        let expected: Set<String> = [
            "en", "zh", "de", "es", "ru", "ko", "fr", "ja", "pt", "tr", "pl", "ca", "nl", "ar", "sv", "it",
            "id", "hi", "fi", "vi", "he", "uk", "el", "ms", "cs", "ro", "da", "hu", "ta", "no", "th", "ur",
            "hr", "bg", "lt", "la", "mi", "ml", "cy", "sk", "te", "fa", "lv", "bn", "sr", "az", "sl", "kn",
            "et", "mk", "br", "eu", "is", "hy", "ne", "mn", "bs", "kk", "sq", "sw", "gl", "mr", "pa", "si",
            "km", "sn", "yo", "so", "af", "oc", "ka", "be", "tg", "sd", "gu", "am", "yi", "lo", "uz", "fo",
            "ht", "ps", "tk", "nn", "mt", "sa", "lb", "my", "bo", "tl", "mg", "as", "tt", "haw", "ln", "ha",
            "ba", "jw", "su", "yue",
        ]
        #expect(expected.count == 100)
        #expect(TranscriptionLanguage.whisperCodes == expected)
        for code in expected {
            #expect(TranscriptionLanguage(code) == .single(code), "\(code)")
        }
    }
}
