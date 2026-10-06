import EarmarkCore
import Foundation
import Testing

@Suite("StopRules: причины и пороги")
struct StopRulesTests {
    // Событие на час, запись начата за lead 60 с до него. Пороги заданы явно, чтобы тесты правил не
    // зависели от дефолтов схемы (их проверяют тесты конфига).
    static let meetingStart = Date(timeIntervalSince1970: 1_790_000_000)
    static let meetingEnd = meetingStart.addingTimeInterval(3600)
    static let recordingStart = meetingStart.addingTimeInterval(-60)
    static let maxDuration: TimeInterval = 300 * 60

    static let limits: StopConfig = {
        var config = StopConfig.defaults
        config.callEndSeconds = 60
        config.afterEndSeconds = 120
        config.endQuietSeconds = 60
        config.silenceMinutes = 10
        config.joinGraceMinutes = 10
        config.maxMinutes = 300
        config.minKeepSeconds = 45
        return config
    }()

    /// Момент через `seconds` после начала события.
    static func after(_ seconds: TimeInterval) -> Date {
        meetingStart.addingTimeInterval(seconds)
    }

    /// Идёт живой созвон, собеседников слышно: ни одно правило, кроме потолка, не срабатывает.
    static func live(_ now: Date) -> StopSignals {
        StopSignals(now: now, callEverSeen: true, callActive: true)
    }

    /// Все условия стопа выполнены разом — для проверки порядка правил.
    static func everything(_ now: Date) -> StopSignals {
        StopSignals(
            now: now, callEverSeen: true, callActive: false, callInactiveSince: after(600),
            farEndQuietSince: after(600), bothQuietSince: after(600))
    }

    struct RuleCase: Sendable, CustomTestStringConvertible {
        let testDescription: String
        var trigger: RecordingTrigger = .calendar
        var eventStart: Date? = meetingStart
        let signals: StopSignals
        let expected: StopDecision
    }

    static let cases: [RuleCase] = [
        RuleCase(testDescription: "идёт созвон — пишем", signals: live(after(600)), expected: .keep),
        RuleCase(
            testDescription: "max_duration ровно на пороге",
            signals: live(recordingStart.addingTimeInterval(maxDuration)), expected: .stop(.maxDuration)),
        RuleCase(
            testDescription: "max_duration за секунду до",
            signals: live(recordingStart.addingTimeInterval(maxDuration - 1)), expected: .keep),
        RuleCase(
            testDescription: "call_ended ровно через call_end_seconds",
            signals: StopSignals(
                now: after(660), callEverSeen: true, callActive: false, callInactiveSince: after(600)),
            expected: .stop(.callEnded)),
        RuleCase(
            testDescription: "call_ended за секунду до",
            signals: StopSignals(
                now: after(659), callEverSeen: true, callActive: false, callInactiveSince: after(600)),
            expected: .keep),
        // Звонилка держит микрофон после конца события: callActive так и остаётся true.
        RuleCase(
            testDescription: "event_over: end + after_end, оба канала тихи end_quiet",
            signals: StopSignals(
                now: after(3720), callEverSeen: true, callActive: true, farEndQuietSince: after(3660),
                bothQuietSince: after(3660)),
            expected: .stop(.eventOver)),
        RuleCase(
            testDescription: "event_over: за секунду до end + after_end",
            signals: StopSignals(
                now: after(3719), callEverSeen: true, callActive: true, farEndQuietSince: after(3600),
                bothQuietSince: after(3600)),
            expected: .keep),
        RuleCase(
            testDescription: "event_over: оба канала тихи на секунду меньше, хотя собеседники молчат давно",
            signals: StopSignals(
                now: after(3720), callEverSeen: true, callActive: true, farEndQuietSince: after(3600),
                bothQuietSince: after(3661)),
            expected: .keep),
        // Затянувшееся демо: собеседники молча слушают, пользователь говорит.
        RuleCase(
            testDescription: "event_over: собеседники молчат, но микрофон звучит — пишем",
            signals: StopSignals(
                now: after(7200), callEverSeen: true, callActive: true, farEndQuietSince: after(3600)),
            expected: .keep),
        RuleCase(
            testDescription: "event_over: собеседников слышно — встреча затянулась, пишем",
            signals: live(after(7200)), expected: .keep),
        RuleCase(
            testDescription: "no_call ровно через join_grace от начала события",
            signals: StopSignals(now: after(600), callEverSeen: false, callActive: false),
            expected: .stop(.noCall)),
        RuleCase(
            testDescription: "no_call за секунду до: пре-ролл не в счёт",
            signals: StopSignals(now: after(599), callEverSeen: false, callActive: false), expected: .keep),
        RuleCase(
            testDescription: "no_call без события — от начала записи", eventStart: nil,
            signals: StopSignals(
                now: recordingStart.addingTimeInterval(600), callEverSeen: false, callActive: false),
            expected: .stop(.noCall)),
        RuleCase(
            testDescription: "no_call без события — за секунду до", eventStart: nil,
            signals: StopSignals(
                now: recordingStart.addingTimeInterval(599), callEverSeen: false, callActive: false),
            expected: .keep),
        RuleCase(
            testDescription: "silence ровно silence_minutes",
            signals: StopSignals(
                now: after(1800), callEverSeen: true, callActive: true, bothQuietSince: after(1200)),
            expected: .stop(.silence)),
        RuleCase(
            testDescription: "silence за секунду до",
            signals: StopSignals(
                now: after(1799), callEverSeen: true, callActive: true, bothQuietSince: after(1200)),
            expected: .keep),
        RuleCase(
            testDescription: "silence до первого созвона молчит — это случай no_call",
            signals: StopSignals(
                now: after(599), callEverSeen: false, callActive: false, bothQuietSince: recordingStart),
            expected: .keep),
        RuleCase(
            testDescription: "порядок: max_duration раньше остальных",
            signals: everything(recordingStart.addingTimeInterval(maxDuration)), expected: .stop(.maxDuration)
        ),
        RuleCase(
            testDescription: "порядок: call_ended раньше event_over и silence",
            signals: everything(after(3720)), expected: .stop(.callEnded)),
        RuleCase(
            testDescription: "порядок: event_over раньше silence",
            signals: StopSignals(
                now: after(3720), callEverSeen: true, callActive: true, farEndQuietSince: after(600),
                bothQuietSince: after(600)),
            expected: .stop(.eventOver)),
        RuleCase(
            testDescription: "ручная: созвон кончился, событие прошло, тишина — пишем дальше",
            trigger: .manual,
            signals: everything(after(7200)), expected: .keep),
        RuleCase(
            testDescription: "ручная: созвона не было вовсе — пишем дальше", trigger: .manual,
            signals: StopSignals(now: after(3600), callEverSeen: false, callActive: false), expected: .keep),
        RuleCase(
            testDescription: "ручная: max_duration", trigger: .manual,
            signals: live(recordingStart.addingTimeInterval(maxDuration)), expected: .stop(.maxDuration)),
    ]

    @Test("evaluate", arguments: cases)
    func evaluate(_ testCase: RuleCase) {
        let decision = StopRules.evaluate(
            trigger: testCase.trigger, startedAt: Self.recordingStart, eventStart: testCase.eventStart,
            eventEnd: Self.meetingEnd, signals: testCase.signals, config: Self.limits)
        #expect(decision == testCase.expected)
    }
}

// Вложены в StopRulesTests, чтобы делить с ним фикстуры события и пороги без глобалов в таргете.
extension StopRulesTests {
    @Suite("StopRules: сценарии сэмплов")
    struct StopScenarioTests {
        /// Отрезок сценария: `seconds` сэмплов раз в секунду в одном состоянии.
        private struct Span {
            var seconds: Int
            var call: Bool
            var mic: Float = 0.1
            var system: Float = 0.1
        }

        /// Как RecordingSession.ingest: сэмпл — в трекер, затем правила. Первый стоп и его момент в
        /// секундах от начала события; nil — запись пережила весь сценарий.
        private func firstStop(from offset: Int, _ spans: [Span]) -> (reason: StopReason, at: Int)? {
            var tracker = ActivityTracker(startedAt: recordingStart)
            var second = offset
            for span in spans {
                for _ in 0..<span.seconds {
                    tracker.ingest(
                        ActivitySample(
                            now: after(TimeInterval(second)), callActive: span.call,
                            callApps: span.call ? ["Zoom"] : [], micRMS: span.mic, systemRMS: span.system))
                    let decision = StopRules.evaluate(
                        trigger: .calendar, startedAt: recordingStart, eventStart: meetingStart,
                        eventEnd: meetingEnd, signals: tracker.signals, config: limits)
                    if case .stop(let reason) = decision { return (reason, second) }
                    second += 1
                }
            }
            return nil
        }

        @Test("блип короче call_end_seconds не останавливает, настоящий конец созвона — останавливает")
        func blipThenEnd() {
            let stop = firstStop(
                from: 0,
                [
                    Span(seconds: 1200, call: true), Span(seconds: 30, call: false),
                    Span(seconds: 1170, call: true), Span(seconds: 120, call: false),
                ])
            #expect(stop?.reason == .callEnded)
            #expect(stop?.at == 2460)  // 60 с после начала последнего неактивного отрезка (2400)
        }

        @Test("неактивность сбрасывается, когда созвон вернулся")
        func inactivityResets() {
            let stop = firstStop(
                from: 0,
                [
                    Span(seconds: 600, call: true),
                    Span(seconds: 59, call: false), Span(seconds: 1, call: true),
                    Span(seconds: 59, call: false), Span(seconds: 1, call: true),
                ])
            #expect(stop == nil)
        }

        @Test("звонилка держит микрофон после события: event_over, когда затихли оба канала")
        func appHoldsMicAfterEvent() {
            let stop = firstStop(
                from: 0, [Span(seconds: 3600, call: true), Span(seconds: 600, call: true, mic: 0, system: 0)])
            #expect(stop?.reason == .eventOver)
            #expect(stop?.at == 3720)
        }

        @Test("демо затянулось: собеседники молча слушают — пишем; замолчали все — event_over")
        func overrunningDemo() {
            let stop = firstStop(
                from: 0,
                [
                    Span(seconds: 3600, call: true), Span(seconds: 1800, call: true, system: 0),
                    Span(seconds: 600, call: true, mic: 0, system: 0),
                ])
            #expect(stop?.reason == .eventOver)
            #expect(stop?.at == 5460)  // оба канала тихи с 5400
        }

        @Test("опоздавший после тихого пре-ролла: тишина до созвона не копится в silence")
        func lateJoinerAfterQuietPreRoll() {
            // Без D18 bothQuietSince шёл бы с −60 с, и silence сработал бы на 540-й секунде, сразу с созвоном.
            let stop = firstStop(
                from: -60,
                [
                    Span(seconds: 600, call: false, mic: 0, system: 0),
                    Span(seconds: 2, call: true, mic: 0, system: 0),
                    Span(seconds: 1800, call: true),
                ])
            #expect(stop == nil)
        }

        @Test("никто не подключился, оба канала тихие: no_call (re-arm), а не silence")
        func nobodyJoined() {
            // Пре-ролл с −60 с: тишина копится с начала записи, и silence (10 мин от записи) опередил бы
            // no_call (10 мин от события) ровно на lead.
            let stop = firstStop(from: -60, [Span(seconds: 900, call: false, mic: 0, system: 0)])
            #expect(stop?.reason == .noCall)
            #expect(stop?.at == 600)
        }

        @Test("созвон идёт, но все молчат: silence-страховка")
        func silentCall() {
            let stop = firstStop(
                from: 0, [Span(seconds: 30, call: true), Span(seconds: 700, call: true, mic: 0, system: 0)])
            #expect(stop?.reason == .silence)
            #expect(stop?.at == 630)
        }
    }

    @Suite("StopRules: что делать после стопа")
    struct StopAftermathTests {
        @Test(
            "discard: авто-запись короче min_keep_seconds удаляется целиком",
            arguments: [(44.9, true), (45, false), (3600, false)] as [(TimeInterval, Bool)])
        func discardAuto(duration: TimeInterval, expected: Bool) {
            #expect(
                StopRules.shouldDiscard(trigger: .calendar, duration: duration, config: limits) == expected)
        }

        @Test("discard: ручную запись не удаляем, даже секундную")
        func discardManual() {
            #expect(!StopRules.shouldDiscard(trigger: .manual, duration: 1, config: limits))
        }

        @Test(
            "re-arm только после no_call и sleep",
            arguments: [
                (StopReason.noCall, true), (.sleep, true), (.callEnded, false), (.eventOver, false),
                (.silence, false), (.maxDuration, false), (.nextEvent, false), (.manual, false),
                (.recovered, false),
            ] as [(StopReason, Bool)])
        func rearmable(reason: StopReason, expected: Bool) {
            #expect(StopRules.isRearmable(reason) == expected)
        }
    }
}
