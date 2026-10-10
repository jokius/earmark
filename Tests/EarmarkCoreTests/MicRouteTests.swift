import EarmarkCore
import Testing

@Suite("MicRoute")
struct MicRouteTests {
    /// Порядок правил: пусто → nil; текущий липкий; системный default; первый вход звонилки.
    @Test(
        "какой микрофон писать",
        arguments: [
            // звонилка не держит входов — мнения нет, даже при текущем и default
            (inputs: [UInt32](), current: UInt32?(1), systemDefault: UInt32?(2), expected: UInt32?.none),
            ([], nil, nil, nil),
            // текущий среди входов — остаёмся на нём, даже если default тоже там (Jitsi держит все входы)
            ([5, 1, 2], 1, 2, 1),
            ([1], 1, nil, 1),
            // текущего нет среди входов — идём на системный default
            ([5, 2], 1, 2, 2),
            ([5, 2], nil, 2, 2),
            // ни текущего, ни default — первый вход звонилки
            ([7, 5], 1, 2, 7),
            ([7, 5], nil, nil, 7),
            ([7, 5], 1, nil, 7),
            // дубликаты на результат не влияют
            ([7, 7, 5, 5], 5, 2, 5),
            ([7, 7, 2, 2], 1, 2, 2),
            ([7, 7, 5], nil, nil, 7),
        ])
    func choose(inputs: [UInt32], current: UInt32?, systemDefault: UInt32?, expected: UInt32?) {
        #expect(
            MicRoute.choose(callInputs: inputs, current: current, systemDefault: systemDefault) == expected)
    }

    /// Серия опросов подряд. Прямо в #expect observe не зовём: макрос заворачивает вызов метода в замыкание
    /// над неизменяемой копией, и mutating-метод там не компилируется.
    private func observe(_ settle: inout MicRoute.Settle, _ targets: [UInt32?], current: UInt32?) -> [Bool] {
        targets.map { settle.observe($0, current: current) }
    }

    @Test("Settle: один и тот же новый выбор два опроса подряд — переключайся")
    func settlesAfterTwoPolls() {
        var settle = MicRoute.Settle(polls: 2)
        let moves = observe(&settle, [5, 5], current: 1)
        #expect(moves == [false, true])
    }

    @Test("Settle: polls по умолчанию — 2")
    func defaultPolls() {
        var settle = MicRoute.Settle()
        let moves = observe(&settle, [5, 5], current: 1)
        #expect(moves == [false, true])
    }

    @Test("Settle: другой выбор начинает счёт заново")
    func newTargetRestarts() {
        var settle = MicRoute.Settle(polls: 2)
        let moves = observe(&settle, [5, 7, 7], current: 1)
        #expect(moves == [false, false, true])
    }

    @Test("Settle: возврат к текущему сбрасывает счёт")
    func currentResets() {
        var settle = MicRoute.Settle(polls: 2)
        let moves = observe(&settle, [5, 1, 5, 5], current: 1)
        #expect(moves == [false, false, false, true])
    }

    @Test("Settle: nil сбрасывает счёт")
    func nilResets() {
        var settle = MicRoute.Settle(polls: 2)
        let moves = observe(&settle, [5, nil, 5, 5], current: 1)
        #expect(moves == [false, false, false, true])
    }

    @Test("Settle: после true счёт с нуля")
    func resetsAfterSwitch() {
        var settle = MicRoute.Settle(polls: 2)
        let moves = observe(&settle, [5, 5, 5, 5], current: 1)
        #expect(moves == [false, true, false, true])
    }

    @Test("Settle: target, равный current, и nil никогда не дают true")
    func neverSwitchesToCurrentOrNil() {
        var settle = MicRoute.Settle(polls: 2)
        let moves = observe(&settle, [1, nil, 1, nil, 1, nil, 1, nil], current: 1)
        #expect(moves == Array(repeating: false, count: 8))
        var fromNone = MicRoute.Settle(polls: 2)
        let idle = observe(&fromNone, [nil, nil, nil], current: nil)
        #expect(idle == [false, false, false])
        // без текущего любой конкретный выбор — новый
        let first = observe(&fromNone, [5, 5], current: nil)
        #expect(first == [false, true])
    }

    @Test("Settle: polls задаёт длину серии")
    func customPolls() {
        var settle = MicRoute.Settle(polls: 3)
        let moves = observe(&settle, [5, 5, 5], current: 1)
        #expect(moves == [false, false, true])
    }
}
