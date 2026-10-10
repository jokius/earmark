// Copyright (c) 2026 Andrew Jones
// Copyright (c) 2026 Samat Galimov
// SPDX-License-Identifier: MIT
// Портировано из gsamat/amanu@fbccc13: Sources/amanu/Audio/MicRoute.swift (MIT) — правило выбора;
// липкость к текущему микрофону и антидребезг по опросам — наши.

/// Какой микрофон писать: тот, на котором ведёт вход звонилка, а не системный default. Микрофон
/// выбирают в настройках звонилки (Teams, Jitsi), и системный default об этом не знает.
///
/// Чистая логика над уже опрошенным HAL. ID устройств — `AudioObjectID`, но EarmarkCore не импортирует
/// CoreAudio.
public enum MicRoute {
    /// nil — «мнения нет»: звонилка не держит ни одного входа.
    ///
    /// Текущий микрофон выигрывает, пока звонилка его держит: Jitsi в Chrome держит открытыми сразу все
    /// микрофоны ради индикаторов уровня (замер на приёмке: 6 входов у одного процесса), а каждое
    /// переключение — дыра в треке. Дальше default: его пользователь выбрал там, где спрашивали. Иначе
    /// первый: микрофон, в который говорят, лучше default, который никто не выбирал.
    public static func choose(callInputs: [UInt32], current: UInt32?, systemDefault: UInt32?) -> UInt32? {
        if let current, callInputs.contains(current) { return current }
        if let systemDefault, callInputs.contains(systemDefault) { return systemDefault }
        return callInputs.first
    }

    /// Антидребезг переключений: на смену микрофона идём, только когда один и тот же новый выбор пришёл
    /// `polls` опросов подряд (опрос раз в секунду). Маршрут посреди смены отвечает по-разному от
    /// секунды к секунде, а каждый переезд — секунды тишины в треке.
    public struct Settle: Sendable {
        private let polls: Int
        private var candidate: UInt32?
        private var count = 0

        public init(polls: Int = 2) {
            self.polls = polls
        }

        /// true — «переключайся», после него счёт заново. nil или текущий сбрасывают счёт.
        public mutating func observe(_ target: UInt32?, current: UInt32?) -> Bool {
            guard let target, target != current else {
                candidate = nil
                count = 0
                return false
            }
            count = target == candidate ? count + 1 : 1
            candidate = target
            guard count >= polls else { return false }
            candidate = nil
            count = 0
            return true
        }
    }
}
