import EarmarkCore
import Testing

@Suite("CallApps")
struct CallAppsTests {
    @Test(
        "имя по bundle id и helper-семейству",
        arguments: [
            ("us.zoom.xos", "Zoom"),
            ("us.zoom.CptHost", "Zoom"),
            ("com.microsoft.teams2", "Teams"),
            ("com.microsoft.teams2.modulehost", "Teams"),
            ("com.microsoft.teams", "Teams"),
            ("Cisco-Systems.Spark", "Webex"),
            ("com.tinyspeck.slackmacgap", "Slack"),
            ("com.hnc.Discord", "Discord"),
            ("com.apple.avconferenced", "FaceTime"),
            ("ru.keepcoder.Telegram", "Telegram"),
            ("net.whatsapp.WhatsApp", "WhatsApp"),
            ("com.google.Chrome.helper", "Chrome"),
            ("com.google.Chrome.helper.Renderer", "Chrome"),
            ("org.chromium.Chromium.helper", "Chromium"),
            ("com.microsoft.edgemac.helper", "Edge"),
            ("com.brave.Browser.helper", "Brave"),
            ("company.thebrowser.Browser.helper", "Arc"),
            ("com.apple.WebKit.GPU", "Safari"),
            ("org.mozilla.firefox", "Firefox"),
            ("ru.yandex.desktop.yandex-browser", "Yandex Browser"),
            ("ru.yandex.desktop.yandex-browser.helper", "Yandex Browser"),
        ])
    func displayName(bundleID: String, name: String) {
        #expect(CallApps.displayName(forBundleID: bundleID) == name)
    }

    @Test(
        "незнакомое и похожее по префиксу — без имени",
        arguments: ["com.example.Dialer", "com.google.ChromeRemoteDesktop", ""])
    func unknownHasNoName(bundleID: String) {
        #expect(CallApps.displayName(forBundleID: bundleID) == nil)
    }

    @Test("системные демоны и диктовка не считаются созвоном")
    func ignoresDaemons() {
        #expect(CallApps.isIgnored(bundleID: "com.apple.CoreSpeech"))
        #expect(CallApps.isIgnored(bundleID: "com.apple.corespeechd"))
        #expect(CallApps.isIgnored(bundleID: "com.apple.assistantd"))
        #expect(CallApps.isIgnored(bundleID: "com.prakashjoshipax.VoiceInk"))
        #expect(CallApps.isIgnored(bundleID: "com.hyprnote.stable"))  // чужой рекордер встреч
        #expect(!CallApps.isIgnored(bundleID: "com.apple.avconferenced"))
        #expect(!CallApps.isIgnored(bundleID: "com.example.Dialer"))
    }

    /// Denylist матчится по семейству, как и имена: сам id или его helper по границе точки, без учёта регистра.
    @Test(
        "denylist по helper-семейству",
        arguments: [
            ("com.electron.wispr-flow.helper", true),
            ("COM.ELECTRON.WISPR-FLOW.helper", true),
            ("com.hyprnote.stable.helper", true),
            ("COM.HYPRNOTE.STABLE", true),
            ("com.apple.CoreSpeech.helper", true),
            // похожие без границы точки — чужие приложения
            ("com.electron.wispr-flowx", false),
            ("com.hyprnote.stablex", false),
            ("com.apple.CoreSpeechX", false),
        ])
    func ignoresFamily(bundleID: String, ignored: Bool) {
        #expect(CallApps.isIgnored(bundleID: bundleID) == ignored)
    }

    /// Решение «идёт созвон» по одному HAL-клиенту: denylist, а не allowlist.
    @Test(
        "какой HAL-клиент — признак созвона",
        arguments: [
            (pid: Int32(500), bundleID: "us.zoom.xos", input: true, devices: 1, call: true),
            // незнакомое приложение — тоже созвон
            (pid: 501, bundleID: "com.example.Dialer", input: true, devices: 1, call: true),
            (pid: 502, bundleID: "com.apple.CoreSpeech", input: true, devices: 1, call: false),  // denylist
            // вход без устройства (так выглядит corespeechd)
            (pid: 503, bundleID: "com.example.Daemon", input: true, devices: 0, call: false),
            (pid: 504, bundleID: "us.zoom.xos", input: false, devices: 1, call: false),  // только вывод
            (pid: 99, bundleID: "com.konayre.earmark", input: true, devices: 1, call: false),  // это мы
            // чужой рекордер встреч — не созвон
            (pid: 1, bundleID: "com.hyprnote.stable", input: true, devices: 1, call: false),
            // helper из denylist-семейства — тоже не созвон, а похожий без точки — созвон
            (pid: 2, bundleID: "com.electron.wispr-flow.helper", input: true, devices: 1, call: false),
            (pid: 3, bundleID: "com.hyprnote.stable.helper", input: true, devices: 1, call: false),
            (pid: 4, bundleID: "com.electron.wispr-flowx", input: true, devices: 1, call: true),
        ])
    func callActivity(pid: Int32, bundleID: String, input: Bool, devices: Int, call: Bool) {
        #expect(
            CallApps.isCallActivity(
                pid: pid, ownPID: 99, bundleID: bundleID, isRunningInput: input, inputDeviceCount: devices)
                == call)
    }
}
