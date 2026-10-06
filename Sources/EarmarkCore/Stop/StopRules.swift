// Copyright (c) 2026 Andrew Jones
// Copyright (c) 2026 Samat Galimov
// SPDX-License-Identifier: MIT
// Портировано из amanu@fbccc13: Sources/amanu/Meetings/AutoRecordController.swift
// (evaluateStop, shouldDiscard).
import Foundation

public enum StopDecision: Equatable, Sendable {
    case keep
    case stop(StopReason)
}

/// Когда останавливать запись (§6 спеки): порт evaluateStop и shouldDiscard из amanu,
/// все пороги — из конфига.
///
/// Остановка нарочно неторопливая: лишние минуты тишины стоят мегабайты, ранний стоп стоит встречи.
/// Правила проверяются по порядку, первое сработавшее и есть причина.
public enum StopRules {
    /// Авто-запись (calendar): max_duration, call_ended, event_over, no_call, silence.
    /// Ручная — только max_duration: нажал кнопку — сам и решаешь, когда хватит.
    /// Шесть параметров — цена чистоты: всё на входе, поэтому правила проверяются таблицей.
    public static func evaluate(  // swiftlint:disable:this function_parameter_count
        trigger: RecordingTrigger, startedAt: Date, eventStart: Date?, eventEnd: Date?,
        signals: StopSignals, config: StopConfig
    ) -> StopDecision {
        let now = signals.now
        // Момент `since` был не меньше `seconds` назад; nil — момента не было вовсе.
        func lasted(since: Date?, _ seconds: Int) -> Bool {
            guard let since else { return false }
            return now.timeIntervalSince(since) >= TimeInterval(seconds)
        }

        // Потолок для любой записи, ручной тоже: страховка от звонилки, которая не отпускает микрофон
        // никогда (без него у предшественника amanu вышло три записи на 15 часов за ночь).
        if lasted(since: startedAt, config.maxMinutes * 60) { return .stop(.maxDuration) }
        guard trigger == .calendar else { return .keep }

        // Созвон был и кончился. Ждём call_end_seconds подряд: при смене устройства посреди созвона
        // (AirPods, другой input) звонилка отпускает микрофон на секунду-другую, и это не конец.
        if signals.callEverSeen, !signals.callActive,
            lasted(since: signals.callInactiveSince, config.callEndSeconds)
        {
            return .stop(.callEnded)
        }
        // Событие кончилось, а звонилка всё держит микрофон: стоп, когда затихли оба канала.
        // Тишины одних собеседников мало: затянувшееся демо, где они молча слушают, обрывалось бы.
        if let eventEnd, now >= eventEnd.addingTimeInterval(TimeInterval(config.afterEndSeconds)),
            lasted(since: signals.bothQuietSince, config.endQuietSeconds)
        {
            return .stop(.eventOver)
        }
        // К созвону так и не подключились. Отсчёт от начала события, а не записи: пре-ролл —
        // не опоздание. Причина rearmable: пришёл позже — запишем заново.
        if !signals.callEverSeen, lasted(since: eventStart ?? startedAt, config.joinGraceMinutes * 60) {
            return .stop(.noCall)
        }
        // Оба канала молчат — страховка от звонилки, которая держит микрофон после созвона. Только
        // после того, как созвон был виден (D18): до него запись ограничивает no_call, который
        // rearmable, а silence — нет. Трекер и тишину копит лишь с первого созвона, иначе опоздавший
        // к тихому началу созвона ловил бы silence сразу; проверка здесь — на сигналы не из трекера.
        if signals.callEverSeen, lasted(since: signals.bothQuietSince, config.silenceMinutes * 60) {
            return .stop(.silence)
        }
        return .keep
    }

    /// Авто-запись короче min_keep_seconds удаляется целиком: это быстрое переключение (next_event,
    /// сон) или поздний старт без созвона, встречи там нет. Ручную запись не удаляем никогда.
    ///
    /// ponytail: в amanu из длительности вычиталась тишина, которую правило ждало перед стопом
    /// (иначе discard по call_ended недостижим: запись длится не меньше call_end_seconds). Здесь
    /// discard ловит только быстрые переключения, как и задумано спекой; ловить «зашёл на 19 секунд» —
    /// добавить причину в сигнатуру и вычитать её ожидание.
    public static func shouldDiscard(
        trigger: RecordingTrigger, duration: TimeInterval, config: StopConfig
    ) -> Bool {
        trigger == .calendar && duration < TimeInterval(config.minKeepSeconds)
    }

    /// После каких причин событие можно начать снова (re-arm, §5 п.5): no_call — опоздал к созвону,
    /// sleep — Mac уснул посреди встречи. Остальные значат «встреча кончилась», «так решил
    /// пользователь» или «запись восстановлена после выхода из app или крэша» (recovered).
    /// Switch без default: новая причина заставит решить явно.
    public static func isRearmable(_ reason: StopReason) -> Bool {
        switch reason {
        case .noCall, .sleep:
            true
        case .callEnded, .eventOver, .silence, .maxDuration, .nextEvent, .manual, .recovered:
            false
        }
    }
}
