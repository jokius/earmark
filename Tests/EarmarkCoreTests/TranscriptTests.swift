import EarmarkCore
import Foundation
import Testing

@Suite("Формат transcript.json")
struct TranscriptFormatTests {
    @Test("ключи snake_case и состав полей как в спеке §8.6")
    func jsonShape() throws {
        let transcript = Transcript(
            recordingId: "20261002-1400-a1b2", model: "ggml-large-v3-turbo", language: "ru",
            segments: [
                TranscriptSegment(startMs: 5120, endMs: 8900, channel: .mic, speaker: .me, text: "Привет")
            ])
        let json = try #require(String(data: try EarmarkJSON.encoder.encode(transcript), encoding: .utf8))
        #expect(
            json == #"{"language":"ru","model":"ggml-large-v3-turbo","recording_id":"20261002-1400-a1b2","#
                + #""schema_version":1,"segments":[{"channel":"mic","end_ms":8900,"speaker":"me","#
                + #""start_ms":5120,"text":"Привет"}]}"#)
        #expect(try EarmarkJSON.decoder.decode(Transcript.self, from: Data(json.utf8)) == transcript)
    }
}

@Suite("Пост-фильтр галлюцинаций")
struct PostFilterTests {
    private func texts(_ lines: [String]) -> [String] {
        PostFilter.apply(
            lines.enumerated().map { RawSegment(startMs: $0 * 1000, endMs: $0 * 1000 + 900, text: $1) }
        )
        .map(\.text)
    }

    @Test(
        "junk-фразы выбрасываются на ru/az/en при любом регистре",
        arguments: [
            "Продолжение следует...",
            "СУБТИТРЫ сделал Alice",
            "Редактор субтитров Bob",
            "Thanks for watching!",
            "THANK YOU FOR WATCHING",
            "Подписывайтесь на канал и ставьте лайк",
            "İzlədiyiniz üçün təşəkkür edirəm",
            "TƏŞƏKKÜR EDİRƏM",
        ])
    func junk(_ line: String) {
        #expect(texts([line]).isEmpty)
    }

    @Test("обычная речь проходит, пробелы по краям срезаются")
    func speechKept() {
        #expect(
            texts(["  Давайте обсудим бюджет. ", "Bu gün iclası başlayaq"])
                == ["Давайте обсудим бюджет.", "Bu gün iclası başlayaq"])
    }

    @Test("пустые и пробельные сегменты выбрасываются")
    func emptyDropped() {
        #expect(texts(["", "   ", "\n"]).isEmpty)
    }

    @Test("вырожденные: ≥6 слов, ≤2 разных, повтор >5×")
    func degenerate() {
        #expect(texts(["да да да да да да"]).isEmpty)
        #expect(texts(["Да нет да нет да нет да нет да нет да нет"]).isEmpty)
        // 6 слов и 2 разных — повтор всего 3×: это речь, а не зацикливание.
        #expect(texts(["да нет да нет да нет"]) == ["да нет да нет да нет"])
    }

    @Test("4+ повтора слова подряд схлопываются в одно, 3 — остаются")
    func repeatsCollapsed() {
        #expect(texts(["ну да да да да, конечно"]) == ["ну да, конечно"])
        #expect(texts(["Да да ДА да"]) == ["Да"])
        #expect(texts(["да да да"]) == ["да да да"])
        #expect(texts(["раз раз раз раз два два два два"]) == ["раз два"])
    }

    @Test("таймстемпы выживших сегментов не меняются, выброшенные исчезают")
    func timestampsPreserved() {
        let input = [
            RawSegment(startMs: 0, endMs: 1200, text: "привет"),
            RawSegment(startMs: 1200, endMs: 2400, text: "Субтитры"),
            RawSegment(startMs: 2400, endMs: 3100, text: "пока пока пока пока"),
        ]
        #expect(
            PostFilter.apply(input) == [
                RawSegment(startMs: 0, endMs: 1200, text: "привет"),
                RawSegment(startMs: 2400, endMs: 3100, text: "пока"),
            ])
    }

    @Test("слова сравниваются со свёрнутыми регистром и диакритикой")
    func normalizeWords() {
        #expect(
            TextNormalize.words("Bu gün, İclası başlayaq!") == TextNormalize.words("bu gun iclası baslayaq"))
        #expect(TextNormalize.words("Ёлка — ЁЛКА!") == ["елка", "елка"])
    }
}

@Suite("Слияние каналов")
struct TranscriptMergeTests {
    private func channel(_ ch: Channel, _ segments: [(Int, String)]) -> ChannelTranscript {
        ChannelTranscript(
            channel: ch, model: "m", language: "ru", fingerprint: "f",
            segments: segments.map { RawSegment(startMs: $0.0, endMs: $0.0 + 500, text: $0.1) })
    }

    @Test("сортировка по startMs, mic → me, system → them")
    func ordering() {
        let merged = TranscriptMerge.merge(
            mic: channel(.mic, [(3000, "я второй"), (9000, "я последний")]),
            system: channel(.system, [(1000, "они первые"), (5000, "они третьи")]))
        #expect(merged.map(\.text) == ["они первые", "я второй", "они третьи", "я последний"])
        #expect(merged.map(\.speaker) == [.them, .me, .them, .me])
        #expect(merged.map(\.channel) == [.system, .mic, .system, .mic])
    }

    @Test("при равном startMs mic идёт первым, порядок внутри канала сохраняется")
    func ties() {
        let merged = TranscriptMerge.merge(
            mic: channel(.mic, [(2000, "m1"), (2000, "m2")]),
            system: channel(.system, [(2000, "s1")]))
        #expect(merged.map(\.text) == ["m1", "m2", "s1"])
    }

    @Test("отсутствующий канал — просто нет его сегментов")
    func missingChannel() {
        #expect(TranscriptMerge.merge(mic: nil, system: channel(.system, [(0, "s")])).map(\.text) == ["s"])
        #expect(TranscriptMerge.merge(mic: nil, system: nil).isEmpty)
    }
}

@Suite("Рендер transcript.txt")
struct TranscriptRenderTests {
    private func segment(_ start: Int, _ end: Int, _ speaker: Speaker, _ text: String) -> TranscriptSegment {
        TranscriptSegment(
            startMs: start, endMs: end, channel: speaker == .me ? .mic : .system, speaker: speaker,
            text: text)
    }

    private func render(_ segments: [TranscriptSegment]) -> String {
        TranscriptRender.text(
            Transcript(recordingId: "r", model: "m", language: "ru", segments: segments),
            labelMe: "Я", labelThem: "Собеседники")
    }

    @Test("подписи из параметров, время от начала записи, перевод строки в конце")
    func labels() {
        #expect(
            render([segment(5_120, 8_900, .me, "Привет."), segment(11_000, 12_000, .them, "Здравствуйте.")])
                == "[00:00:05] Я: Привет.\n[00:00:11] Собеседники: Здравствуйте.\n")
    }

    @Test("часы считаются от startMs: 1 ч 2 мин 5 с")
    func hours() {
        #expect(render([segment(3_725_400, 3_726_000, .them, "Итак.")]) == "[01:02:05] Собеседники: Итак.\n")
    }

    @Test("реплики одного говорящего склеиваются при паузе ≤ 1.5 с включительно")
    func joining() {
        let text = render([
            segment(0, 1_000, .me, "Раз."),
            segment(2_500, 3_000, .me, "Два."),  // пауза ровно 1500 мс — склеиваем
            segment(4_501, 5_000, .me, "Три."),  // пауза 1501 мс — новая строка
            segment(5_200, 6_000, .them, "Четыре."),
        ])
        #expect(text == "[00:00:00] Я: Раз. Два.\n[00:00:04] Я: Три.\n[00:00:05] Собеседники: Четыре.\n")
    }

    @Test("пустой транскрипт — пустая строка")
    func empty() {
        #expect(render([]).isEmpty)
    }
}

@Suite("Страницы транскрипта")
struct TranscriptPagingTests {
    private let text = "[00:00:01] Я: раз два\n[00:00:05] Собеседники: три\n"  // 7 слов

    @Test("первая страница сохраняет переводы строк и даёт next_offset")
    func firstPage() {
        let page = TranscriptPaging.page(text, offset: 0, words: 5)
        #expect(
            page
                == TranscriptPage(
                    text: "[00:00:01] Я: раз два\n[00:00:05]", offset: 0, nextOffset: 5, totalWords: 7))
    }

    @Test("последняя страница — next_offset nil")
    func lastPage() {
        #expect(
            TranscriptPaging.page(text, offset: 5, words: 5)
                == TranscriptPage(text: "Собеседники: три", offset: 5, nextOffset: nil, totalWords: 7))
    }

    @Test("offset за концом — пустой текст; отрицательный offset — с начала")
    func offsetBounds() {
        #expect(
            TranscriptPaging.page(text, offset: 99, words: 5)
                == TranscriptPage(text: "", offset: 7, nextOffset: nil, totalWords: 7))
        #expect(TranscriptPaging.page(text, offset: -3, words: 1).text == "[00:00:01]")
    }

    @Test("words зажимается в 1…500")
    func wordsClamped() {
        let long = Array(repeating: "слово", count: 600).joined(separator: " ")
        #expect(TranscriptPaging.page(long, offset: 0, words: 0).nextOffset == 1)
        #expect(TranscriptPaging.page(long, offset: 0, words: 10_000).nextOffset == 500)
    }
}
