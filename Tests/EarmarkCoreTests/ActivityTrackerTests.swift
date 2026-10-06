import EarmarkCore
import Foundation
import Testing

@Suite("ActivityTracker: сигналы для стоп-правил")
struct ActivityTrackerTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private let loud: Float = 0.1
    private let quiet = ActivityTracker.quietThreshold / 2

    private func time(_ second: Int) -> Date {
        start.addingTimeInterval(TimeInterval(second))
    }

    private func sample(
        _ second: Int, call: Bool, mic: Float = 0.1, system: Float = 0.1, apps: [String] = []
    ) -> ActivitySample {
        ActivitySample(now: time(second), callActive: call, callApps: apps, micRMS: mic, systemRMS: system)
    }

    @Test("до первого сэмпла сигналов нет")
    func initial() {
        let tracker = ActivityTracker(startedAt: start)
        #expect(tracker.signals == StopSignals(now: start, callEverSeen: false, callActive: false))
        #expect(tracker.callAppsSeen.isEmpty)
        #expect(tracker.digitalSilenceSince == nil)
    }

    @Test("callEverSeen защёлкивается; callInactiveSince — первый неактивный сэмпл после активного")
    func callState() {
        var tracker = ActivityTracker(startedAt: start)
        // Каналы громкие (дефолт сэмпла), поэтому отрезков тишины здесь нет.
        let script: [(ActivitySample, StopSignals)] = [
            // Созвона ещё не было — «кончился» не бывает.
            (sample(1, call: false), StopSignals(now: time(1), callEverSeen: false, callActive: false)),
            (sample(2, call: true), StopSignals(now: time(2), callEverSeen: true, callActive: true)),
            (
                sample(3, call: false),
                StopSignals(now: time(3), callEverSeen: true, callActive: false, callInactiveSince: time(3))
            ),
            // Держим начало отрезка, а не последний сэмпл.
            (
                sample(4, call: false),
                StopSignals(now: time(4), callEverSeen: true, callActive: false, callInactiveSince: time(3))
            ),
            // Созвон вернулся — отсчёт сброшен.
            (sample(5, call: true), StopSignals(now: time(5), callEverSeen: true, callActive: true)),
            (
                sample(6, call: false),
                StopSignals(now: time(6), callEverSeen: true, callActive: false, callInactiveSince: time(6))
            ),
        ]
        for (input, expected) in script {
            tracker.ingest(input)
            #expect(tracker.signals == expected)
        }
    }

    @Test("тишина: far-end — по system, оба — по max(mic, system); ровно порог — уже звук")
    func quietRuns() {
        var tracker = ActivityTracker(startedAt: start)
        let edge = ActivityTracker.quietThreshold
        let script: [(ActivitySample, StopSignals)] = [
            (
                sample(1, call: true, mic: loud, system: quiet),
                StopSignals(now: time(1), callEverSeen: true, callActive: true, farEndQuietSince: time(1))
            ),
            (
                sample(2, call: true, mic: quiet, system: quiet),
                StopSignals(
                    now: time(2), callEverSeen: true, callActive: true, farEndQuietSince: time(1),
                    bothQuietSince: time(2))
            ),
            (
                sample(3, call: true, mic: quiet, system: quiet),
                StopSignals(
                    now: time(3), callEverSeen: true, callActive: true, farEndQuietSince: time(1),
                    bothQuietSince: time(2))
            ),
            (
                sample(4, call: true, mic: quiet, system: edge),
                StopSignals(now: time(4), callEverSeen: true, callActive: true)
            ),
            (
                sample(5, call: true, mic: quiet, system: 0),
                StopSignals(
                    now: time(5), callEverSeen: true, callActive: true, farEndQuietSince: time(5),
                    bothQuietSince: time(5))
            ),
            (
                sample(6, call: true, mic: loud, system: 0),
                StopSignals(now: time(6), callEverSeen: true, callActive: true, farEndQuietSince: time(5))
            ),
        ]
        for (input, expected) in script {
            tracker.ingest(input)
            #expect(tracker.signals == expected)
        }
    }

    @Test("тишина пре-ролла до первого созвона не копится в bothQuietSince; после — копится и без созвона")
    func preRollQuiet() {
        var tracker = ActivityTracker(startedAt: start)
        let script: [(ActivitySample, StopSignals)] = [
            (
                sample(1, call: false, mic: quiet, system: quiet),
                StopSignals(now: time(1), callEverSeen: false, callActive: false, farEndQuietSince: time(1))
            ),
            (
                sample(2, call: false, mic: quiet, system: quiet),
                StopSignals(now: time(2), callEverSeen: false, callActive: false, farEndQuietSince: time(1))
            ),
            // Отсчёт — с сэмпла первого созвона, а не с начала тишины.
            (
                sample(3, call: true, mic: quiet, system: quiet),
                StopSignals(
                    now: time(3), callEverSeen: true, callActive: true, farEndQuietSince: time(1),
                    bothQuietSince: time(3))
            ),
            // Созвон уже был: неактивный сэмпл отсчёт не сбрасывает.
            (
                sample(4, call: false, mic: quiet, system: quiet),
                StopSignals(
                    now: time(4), callEverSeen: true, callActive: false, callInactiveSince: time(4),
                    farEndQuietSince: time(1), bothQuietSince: time(3))
            ),
        ]
        for (input, expected) in script {
            tracker.ingest(input)
            #expect(tracker.signals == expected)
        }
    }

    @Test("звонилки — в порядке появления, без дублей")
    func callApps() {
        var tracker = ActivityTracker(startedAt: start)
        tracker.ingest(sample(1, call: true, apps: ["Zoom"]))
        tracker.ingest(sample(2, call: true, apps: ["Chrome", "Zoom"]))
        tracker.ingest(sample(3, call: false))
        tracker.ingest(sample(4, call: true, apps: ["Teams", "Chrome"]))
        #expect(tracker.callAppsSeen == ["Zoom", "Chrome", "Teams"])
    }

    @Test("цифровая тишина собеседников считается только при идущем созвоне")
    func digitalSilence() {
        var tracker = ActivityTracker(startedAt: start)
        let script: [(ActivitySample, Date?)] = [
            (sample(1, call: true, system: 0), time(1)),
            (sample(2, call: true, system: 0), time(1)),
            (sample(3, call: false, system: 0), nil),  // созвона нет — нули ни о чём не говорят
            (sample(4, call: true, system: 0), time(4)),
            (sample(5, call: true, system: quiet), nil),  // тихо, но не ровно ноль — tap живой
        ]
        for (input, expected) in script {
            tracker.ingest(input)
            #expect(tracker.digitalSilenceSince == expected)
        }
    }
}
