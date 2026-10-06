// Copyright (c) 2024 Guilherme Rambo
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// - Redistributions of source code must retain the above copyright notice, this
//   list of conditions and the following disclaimer.
//
// - Redistributions in binary form must reproduce the above copyright notice,
//   this list of conditions and the following disclaimer in the documentation
//   and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
// FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
// DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
// SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
// CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
// OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//
// Портировано из AudioCap@6f609e8: AudioCap/ProcessTap/AudioRecordingPermission.swift.
// Оставлен только preflight: запрос права делает сам первый старт tap (§10 спеки).

import Foundation

/// Статус права «System Audio Recording» (kTCCServiceAudioCapture).
///
/// Публичного API нет: ни один заголовок macOS 27 SDK этот статус не читает. Поэтому приватный
/// TCCAccessPreflight через dlopen, как в AudioCap и Anarlog. Ответ — про responsible-процесс,
/// то есть про сам Earmark.app, только когда app запущен через LaunchServices. Символ может
/// пропасть в любой версии macOS — тогда `.unknown`, и остаётся тест тоном (AudioSelfTest).
enum TCCPreflight {
    enum Status: String, Sendable {
        case granted, denied, unknown
        case notDetermined = "not_determined"
    }

    static func audioCapture() -> Status {
        guard let preflight else { return .unknown }
        // 0 — разрешено, 1 — запрещено, 2 — не спрашивали (замер на 27.0.1, совпадает с Anarlog).
        switch preflight("kTCCServiceAudioCapture" as CFString, nil) {
        case 0: return .granted
        case 1: return .denied
        case 2: return .notDetermined
        default: return .unknown
        }
    }

    // Int32, а не Int, как у AudioCap: функция возвращает C int, а старшие 32 бита x0 на arm64
    // после такого вызова не определены — Int мог бы прочитать мусор и уйти в .unknown.
    private typealias PreflightFunc = @convention(c) (CFString, CFDictionary?) -> Int32

    private static let preflight: PreflightFunc? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW),
            let symbol = dlsym(handle, "TCCAccessPreflight")
        else { return nil }
        return unsafeBitCast(symbol, to: PreflightFunc.self)
    }()
}
