// Copyright (c) 2026 Andrew Jones
// Copyright (c) 2026 Samat Galimov
// SPDX-License-Identifier: MIT
// Портировано из amanu@fbccc13: Sources/amanu/Meetings/AutoRecordController.swift
// (состояние, которое читает evaluateStop: micIdleSince, lastSystemSoundAt, micTakenDuringSession).
import Foundation

/// Сэмпл раз в секунду от CallActivityMonitor (app): идёт ли созвон и насколько громко на каналах.
public struct ActivitySample: Equatable, Sendable {
    public var now: Date
    public var callActive: Bool
    /// Человеческие имена звонилок, держащих input, — для meta.call_apps.
    public var callApps: [String]
    /// Линейный RMS за последнюю секунду, 0…1.
    public var micRMS: Float
    public var systemRMS: Float

    public init(now: Date, callActive: Bool, callApps: [String], micRMS: Float, systemRMS: Float) {
        self.now = now
        self.callActive = callActive
        self.callApps = callApps
        self.micRMS = micRMS
        self.systemRMS = systemRMS
    }
}

/// Всё, что стоп-правилам нужно знать о ходе записи, уже сжатое в «с какого момента».
public struct StopSignals: Equatable, Sendable {
    public var now: Date
    public var callEverSeen: Bool
    public var callActive: Bool
    /// nil, пока созвон активен или ещё не был виден.
    public var callInactiveSince: Date?
    /// systemRMS ниже порога с этого момента; nil, пока собеседников слышно.
    public var farEndQuietSince: Date?
    /// Оба канала ниже порога с этого момента, но не раньше первого созвона: тишина пре-ролла
    /// не копится (D18), иначе опоздавший к созвону ловил бы silence в первые же секунды.
    public var bothQuietSince: Date?

    public init(
        now: Date, callEverSeen: Bool, callActive: Bool, callInactiveSince: Date? = nil,
        farEndQuietSince: Date? = nil, bothQuietSince: Date? = nil
    ) {
        self.now = now
        self.callEverSeen = callEverSeen
        self.callActive = callActive
        self.callInactiveSince = callInactiveSince
        self.farEndQuietSince = farEndQuietSince
        self.bothQuietSince = bothQuietSince
    }
}

/// Копит сэмплы одной записи в StopSignals.
///
/// В amanu те же сигналы жили полями контроллера и сессии и читались прямо внутри evaluateStop.
/// Здесь они собраны в одну чистую структуру, чтобы стоп-правила проверялись сценарием из сэмплов,
/// без звука и таймера: именно в них авто-запись либо обрывается рано, либо не кончается никогда,
/// и ни то ни другое не устроить нарочно на живой записи.
public struct ActivityTracker: Sendable {
    /// ≈ −60 dBFS: ниже — тишина.
    public static let quietThreshold: Float = 0.001

    public private(set) var signals: StopSignals
    /// Звонилки за всю запись в порядке появления, без дублей, — для meta.call_apps.
    public private(set) var callAppsSeen: [String] = []
    /// С какого момента канал собеседников при идущем созвоне отдаёт ровно нули. Так выглядят
    /// неавторизованный tap и баг нулевых буферов; отличить их от немого созвона нельзя, поэтому
    /// это только предупреждение far_end_digital_silence в status, а не причина стопа.
    public private(set) var digitalSilenceSince: Date?

    public init(startedAt: Date) {
        signals = StopSignals(now: startedAt, callEverSeen: false, callActive: false)
    }

    public mutating func ingest(_ sample: ActivitySample) {
        let now = sample.now
        signals.now = now
        signals.callActive = sample.callActive
        if sample.callActive {
            signals.callEverSeen = true
            signals.callInactiveSince = nil
        } else if signals.callEverSeen, signals.callInactiveSince == nil {
            // Первый неактивный сэмпл после активного. Пока созвона не было, «кончился» не бывает:
            // это случай правила no_call, а не call_ended.
            signals.callInactiveSince = now
        }

        // Отрезки тишины держат свой первый момент и обнуляются первым же громким сэмплом.
        let quiet = Self.quietThreshold
        let farEndQuiet = sample.systemRMS < quiet
        // До первого созвона запись ограничивает no_call (rearmable). Тишина пре-ролла, засчитанная
        // сюда, дала бы silence (не rearmable) сразу после позднего подключения к тихому началу.
        let bothQuiet = signals.callEverSeen && farEndQuiet && sample.micRMS < quiet
        signals.farEndQuietSince = farEndQuiet ? (signals.farEndQuietSince ?? now) : nil
        signals.bothQuietSince = bothQuiet ? (signals.bothQuietSince ?? now) : nil
        let digitalSilence = sample.callActive && sample.systemRMS == 0
        digitalSilenceSince = digitalSilence ? (digitalSilenceSince ?? now) : nil

        for app in sample.callApps where !callAppsSeen.contains(app) {
            callAppsSeen.append(app)
        }
    }
}
