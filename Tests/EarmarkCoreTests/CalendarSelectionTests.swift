import EarmarkCore
import Testing

@Suite("CalendarSelection: включение и выключение календаря в списке calendars")
struct CalendarSelectionTests {
    @Test("включение нового id — в конец, порядок остальных сохранён")
    func enableMissingAppends() {
        #expect(CalendarSelection.toggled(["b", "a", "c"], id: "d", enabled: true) == ["b", "a", "c", "d"])
    }

    @Test("включение уже включённого id — список без изменений, без дубля и с прежней позицией")
    func enablePresentKeepsList() {
        #expect(CalendarSelection.toggled(["a", "b", "c"], id: "a", enabled: true) == ["a", "b", "c"])
        #expect(CalendarSelection.toggled(["a", "b", "c"], id: "b", enabled: true) == ["a", "b", "c"])
    }

    @Test("выключение убирает все вхождения id, порядок остальных сохранён")
    func disableRemovesAllOccurrences() {
        #expect(CalendarSelection.toggled(["c", "a", "b"], id: "a", enabled: false) == ["c", "b"])
        #expect(CalendarSelection.toggled(["a", "c", "a", "b", "a"], id: "a", enabled: false) == ["c", "b"])
    }

    @Test("выключение отсутствующего id — список без изменений")
    func disableMissingKeepsList() {
        #expect(CalendarSelection.toggled(["a", "b"], id: "c", enabled: false) == ["a", "b"])
    }

    @Test("пустой список: включение даёт [id], выключение — пустой список")
    func emptyList() {
        #expect(CalendarSelection.toggled([], id: "a", enabled: true) == ["a"])
        #expect(CalendarSelection.toggled([], id: "a", enabled: false).isEmpty)
    }

    // id — непрозрачная строка EventKit: «Cal» и «cal» или « cal» — разные календари.
    @Test("сравнение id точное: регистр различается, пробелы не обрезаются")
    func exactComparison() {
        #expect(CalendarSelection.toggled(["cal"], id: "Cal", enabled: true) == ["cal", "Cal"])
        #expect(CalendarSelection.toggled(["cal"], id: " cal", enabled: true) == ["cal", " cal"])
        #expect(CalendarSelection.toggled(["cal", "Cal"], id: "Cal", enabled: false) == ["cal"])
        let padded = [" cal", "cal", "cal "]
        #expect(CalendarSelection.toggled(padded, id: "cal", enabled: false) == [" cal", "cal "])
    }

    @Test("пустая строка — обычный id")
    func emptyStringIsOrdinaryID() {
        #expect(CalendarSelection.toggled(["a"], id: "", enabled: true) == ["a", ""])
        #expect(CalendarSelection.toggled(["", "a"], id: "", enabled: true) == ["", "a"])
        #expect(CalendarSelection.toggled(["", "a", ""], id: "", enabled: false) == ["a"])
    }

    @Test("вход не мутируется: исходный список после вызова прежний")
    func inputIsNotMutated() {
        let ids = ["a", "b", "a"]
        let enabled = CalendarSelection.toggled(ids, id: "c", enabled: true)
        let disabled = CalendarSelection.toggled(ids, id: "a", enabled: false)
        #expect(enabled == ["a", "b", "a", "c"])
        #expect(disabled == ["b"])
        #expect(ids == ["a", "b", "a"])
    }
}
