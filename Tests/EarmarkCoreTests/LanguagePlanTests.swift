import EarmarkCore
import Testing

/// Отрезки (start, end) в мс — короче, чем SpeechSpan(startMs:endMs:) в каждой строке ожиданий.
private func spans(_ pairs: [(Int, Int)]) -> [SpeechSpan] {
    pairs.map { SpeechSpan(startMs: $0.0, endMs: $0.1) }
}

@Suite("LanguagePlan.chunks: отрезки VAD → куски для определения языка")
struct LanguagePlanChunksTests {
    @Test("пустой вход — пустой выход")
    func empty() {
        #expect(LanguagePlan.chunks([]).isEmpty)
    }

    @Test("пауза меньше maxGapMs склеивает, ровно maxGapMs уже нет (дефолт 1000)")
    func gapBoundary() {
        #expect(LanguagePlan.chunks(spans([(0, 1_000), (1_999, 3_000)])) == spans([(0, 3_000)]))
        #expect(
            LanguagePlan.chunks(spans([(0, 1_000), (2_000, 3_000)])) == spans([(0, 1_000), (2_000, 3_000)]))
    }

    @Test("пауза меряется от конца текущего куска, а не от конца его первого отрезка")
    func gapFromChunkEnd() {
        #expect(
            LanguagePlan.chunks(spans([(0, 1_000), (1_800, 2_500), (3_300, 4_000)])) == spans([(0, 4_000)]))
    }

    @Test("длина объединения ровно maxChunkMs склеивается, на 1 мс больше — новый кусок (дефолт 30 000)")
    func lengthBoundary() {
        #expect(LanguagePlan.chunks(spans([(0, 10_000), (10_500, 30_000)])) == spans([(0, 30_000)]))
        #expect(
            LanguagePlan.chunks(spans([(0, 10_000), (10_500, 30_001)]))
                == spans([(0, 10_000), (10_500, 30_001)]))
    }

    @Test("новый кусок считает длину от своего начала")
    func restartAfterLimit() {
        let speech = spans([
            (0, 10_000), (10_500, 20_000), (20_500, 29_000), (29_500, 35_000), (35_500, 40_000),
        ])
        #expect(LanguagePlan.chunks(speech) == spans([(0, 29_000), (29_500, 40_000)]))
    }

    @Test("отрезок длиннее maxChunkMs остаётся целым отдельным куском")
    func longSpanKeptWhole() {
        #expect(LanguagePlan.chunks(spans([(0, 45_000)])) == spans([(0, 45_000)]))
        #expect(
            LanguagePlan.chunks(spans([(500, 1_000), (1_200, 45_000), (45_100, 46_000)]))
                == spans([(500, 1_000), (1_200, 45_000), (45_100, 46_000)]))
    }

    @Test("maxGapMs и maxChunkMs берутся из параметров")
    func customLimits() {
        // С дефолтами всё это один кусок (0, 7400): паузы < 1 с, длина < 30 с.
        let speech = spans([(0, 1_000), (1_150, 2_000), (2_300, 3_000), (3_100, 7_400)])
        #expect(LanguagePlan.chunks(speech) == spans([(0, 7_400)]))
        #expect(
            LanguagePlan.chunks(speech, maxGapMs: 200, maxChunkMs: 5_000)
                == spans([(0, 2_000), (2_300, 3_000), (3_100, 7_400)]))
    }
}

@Suite("LanguagePlan.pick: язык куска из разрешённых")
struct LanguagePlanPickTests {
    @Test("aliases: азербайджанскому засчитывается турецкий")
    func aliases() {
        #expect(LanguagePlan.aliases == ["az": ["tr"]])
    }

    @Test("побеждает максимальная вероятность среди разрешённых, порядок allowed не важен")
    func maximum() {
        let probabilities: [String: Float] = ["ru": 0.6, "en": 0.3]
        #expect(LanguagePlan.pick(probabilities, allowed: ["ru", "en"]) == "ru")
        #expect(LanguagePlan.pick(probabilities, allowed: ["en", "ru"]) == "ru")
    }

    @Test("языки вне списка не выигрывают, даже самые вероятные")
    func outsideIgnored() {
        #expect(LanguagePlan.pick(["de": 0.9, "en": 0.05, "ru": 0.04], allowed: ["ru", "en"]) == "en")
    }

    @Test("турецкий, которого нет в списке, прибавляется азербайджанскому")
    func aliasCounted() {
        // Случай с реального созвона: az ≈ 0.002, а речь ушла в tr.
        #expect(LanguagePlan.pick(["tr": 0.5, "en": 0.3, "az": 0.002], allowed: ["ru", "en", "az"]) == "az")
        // Сумма, а не максимум: по отдельности и tr, и az меньше en.
        #expect(LanguagePlan.pick(["tr": 0.2, "az": 0.15, "en": 0.3], allowed: ["en", "az"]) == "az")
    }

    @Test("разрешённый пользователем турецкий считается отдельно и не прибавляется азербайджанскому")
    func aliasNotCountedWhenAllowed() {
        #expect(
            LanguagePlan.pick(["tr": 0.5, "en": 0.3, "az": 0.002], allowed: ["ru", "en", "az", "tr"]) == "tr")
        #expect(LanguagePlan.pick(["tr": 0.5, "az": 0.1], allowed: ["az", "tr"]) == "tr")
    }

    @Test("при равенстве — тот, что раньше в allowed, включая равенство через алиас")
    func ties() {
        #expect(LanguagePlan.pick(["ru": 0.25, "en": 0.25], allowed: ["en", "ru"]) == "en")
        #expect(LanguagePlan.pick(["ru": 0.25, "en": 0.25], allowed: ["ru", "en"]) == "ru")
        // 0.25 + 0.25 представимо точно: равенство настоящее, а не ошибка округления.
        #expect(LanguagePlan.pick(["az": 0.25, "tr": 0.25, "en": 0.5], allowed: ["en", "az"]) == "en")
        #expect(LanguagePlan.pick(["az": 0.25, "tr": 0.25, "en": 0.5], allowed: ["az", "en"]) == "az")
    }

    @Test("пустой словарь или ни одного разрешённого в нём — первый из allowed")
    func noData() {
        #expect(LanguagePlan.pick([:], allowed: ["en", "ru"]) == "en")
        #expect(LanguagePlan.pick(["de": 0.9], allowed: ["ru", "en"]) == "ru")
        #expect(LanguagePlan.pick(["de": 0.9], allowed: ["az"]) == "az")
    }
}

@Suite("LanguagePlan.runs: подряд идущие куски одного языка → один прогон")
struct LanguagePlanRunsTests {
    @Test("пустой вход — пустой выход")
    func empty() {
        #expect(LanguagePlan.runs([], languages: []).isEmpty)
    }

    @Test("один кусок — один прогон с его границами")
    func single() {
        #expect(
            LanguagePlan.runs(spans([(300, 900)]), languages: ["ru"])
                == [LanguageRun(startMs: 300, endMs: 900, language: "ru")])
    }

    @Test("склеиваются только соседние куски одного языка: от начала первого до конца последнего")
    func mergesNeighboursOnly() {
        let chunks = spans([(0, 1_000), (1_500, 3_000), (4_000, 5_000), (5_500, 6_000), (7_000, 8_000)])
        #expect(
            LanguagePlan.runs(chunks, languages: ["ru", "ru", "en", "ru", "ru"]) == [
                LanguageRun(startMs: 0, endMs: 3_000, language: "ru"),
                LanguageRun(startMs: 4_000, endMs: 5_000, language: "en"),
                LanguageRun(startMs: 5_500, endMs: 8_000, language: "ru"),
            ])
    }

    @Test("все куски одного языка — один прогон на весь канал")
    func allSame() {
        let chunks = spans([(100, 200), (5_000, 6_000), (40_000, 41_000)])
        #expect(
            LanguagePlan.runs(chunks, languages: ["az", "az", "az"])
                == [LanguageRun(startMs: 100, endMs: 41_000, language: "az")])
    }
}
