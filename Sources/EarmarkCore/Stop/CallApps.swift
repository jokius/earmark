// Copyright (c) 2026 Andrew Jones
// Copyright (c) 2026 Samat Galimov
// Copyright (c) 2023-present Fastrepl, Inc.
// SPDX-License-Identifier: MIT
// Портировано из gsamat/amanu@fbccc13: Sources/amanu/Audio/MicActivityMonitor.swift (MIT) и
// fastrepl/anarlog@87d534a: plugins/detect/src/policy.rs, apps/desktop/src/stt/meeting-apps.ts (MIT) —
// списки bundle id, сверенные с HAL-списком процессов на macOS 27.0.1.
import Foundation

/// Кто из HAL-клиентов считается созвоном и как его назвать.
///
/// Созвон определяется по denylist, а не по allowlist: незнакомая звонилка при allowlist дала бы ложное
/// «созвон кончился» и обрезанную запись. Allowlist известных приложений нужен только для имени в
/// `status` и `meta.call_apps`.
public enum CallApps {
    /// Держат вход без всякого созвона. corespeechd (bundle id `com.apple.CoreSpeech`) на этом Mac держит
    /// IsRunningInput = 1 постоянно — без исключения «созвон» не кончался бы никогда.
    public static let ignoredBundleIDs: Set<String> = [
        "com.apple.CoreSpeech",  // corespeechd: «Привет, Siri»
        "com.apple.corespeechd",
        "com.apple.assistantd",  // Siri
        "com.apple.Siri",
        "com.apple.SiriNCService",
        "com.apple.speech.SpeechRecognitionCore.speechrecognitiond",  // диктовка
        "com.apple.SpeechRecognitionCore.speechrecognitiond",
        "com.apple.universalaccessd",  // управление голосом
        "com.apple.accessibility.heard",  // распознавание звуков
        "com.apple.VoiceMemos",  // диктофон: запись, а не разговор
        // Другой рекордер встреч (Anarlog, бывший Hyprnote): забытый после звонка, он держал бы
        // callActive и не дал бы сработать call_ended, а на время переезда оба app могут работать
        // параллельно. Префикса вендора (`com.anarlog`) в denylist нет, поэтому здесь все сборки из
        // SELF_BUNDLE_IDS (anarlog: crates/detect/src/list/mod.rs).
        "com.anarlog.stable",
        "com.anarlog.staging",
        "com.anarlog.nightly",
        "com.anarlog.dev",
        "com.hyprnote.stable",
        "com.hyprnote.staging",
        "com.hyprnote.nightly",
        "com.hyprnote.dev",
        // Сторонняя диктовка держит микрофон ровно пока говоришь — по таймингу от звонка не отличить.
        "com.electron.wispr-flow",
        "com.seewillow.WillowMac",
        "com.superduper.superwhisper",
        "com.prakashjoshipax.VoiceInk",
        "com.goodsnooze.macwhisper",
        "com.electron.aqua-voice",
    ]

    /// Семейства по префиксу bundle id: микрофон часто держит не само приложение, а helper — Chrome
    /// звонит из `com.google.Chrome.helper`, Safari из `com.apple.WebKit.GPU`, FaceTime из
    /// `com.apple.avconferenced`, Teams из `com.microsoft.teams2.modulehost`.
    private static let families: [(prefix: String, name: String)] = [
        ("us.zoom", "Zoom"),
        ("com.microsoft.teams", "Teams"),
        ("com.microsoft.teams2", "Teams"),
        ("com.cisco.webexmeetingsapp", "Webex"),
        ("com.cisco.webex", "Webex"),
        ("com.webex.meetingmanager", "Webex"),
        ("Cisco-Systems.Spark", "Webex"),
        ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.slack.Slack", "Slack"),
        ("com.hnc.Discord", "Discord"),
        ("com.discordapp.Discord", "Discord"),
        ("com.apple.FaceTime", "FaceTime"),
        ("com.apple.avconferenced", "FaceTime"),
        ("ru.keepcoder.Telegram", "Telegram"),
        ("com.tdesktop.Telegram", "Telegram"),
        ("net.whatsapp.WhatsApp", "WhatsApp"),
        ("desktop.WhatsApp", "WhatsApp"),
        ("com.google.Chrome", "Chrome"),
        ("org.chromium.Chromium", "Chromium"),
        ("com.microsoft.edgemac", "Edge"),
        ("com.brave.Browser", "Brave"),
        ("ru.yandex.desktop.yandex-browser", "Yandex Browser"),
        ("company.thebrowser.Browser", "Arc"),
        ("com.apple.Safari", "Safari"),
        ("com.apple.WebKit", "Safari"),
        ("org.mozilla.firefox", "Firefox"),
    ]

    /// Denylist сверяется по семейству, как и имена: Electron-диктовка (wispr-flow, aqua-voice) держит
    /// микрофон из `.helper`-подпроцесса, и при точном сравнении фраза считалась бы созвоном — callEverSeen
    /// до подключения выключил бы повторяемый no_call, а каждая фраза сбрасывала бы call_ended. Ни один
    /// id из denylist не префикс семейства звонилки, так что созвоны это не глушит.
    public static func isIgnored(bundleID: String) -> Bool {
        ignoredBundleIDs.contains { belongs(bundleID, to: $0) }
    }

    /// Человеческое имя для bundle id или его helper'а; nil — незнакомое приложение (оно всё равно
    /// считается созвоном). Префикс совпадает только по границе точки: `com.google.Chrome` — это и
    /// `com.google.Chrome.helper`, но не `com.google.ChromeRemoteDesktop`.
    public static func displayName(forBundleID bundleID: String) -> String? {
        families.first { belongs(bundleID, to: $0.prefix) }?.name
    }

    /// `bundleID` — это `family` или его подпроцесс по границе точки, без учёта регистра.
    private static func belongs(_ bundleID: String, to family: String) -> Bool {
        let id = bundleID.lowercased()
        let family = family.lowercased()
        return id == family || id.hasPrefix(family + ".")
    }

    /// Считается ли HAL-клиент признаком идущего созвона: не мы сами, вход реально идёт, за ним есть
    /// устройство (у corespeechd список устройств пуст) и клиент не из denylist (с helper'ами).
    public static func isCallActivity(
        pid: Int32, ownPID: Int32, bundleID: String, isRunningInput: Bool, inputDeviceCount: Int
    ) -> Bool {
        pid != ownPID && isRunningInput && inputDeviceCount > 0 && !isIgnored(bundleID: bundleID)
    }
}
