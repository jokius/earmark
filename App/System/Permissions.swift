import AVFoundation
import AppKit
import EarmarkCore
import EventKit
import os

/// Три права, без которых запись бессмысленна: микрофон, календари, системный звук.
///
/// Всё это — только в app, запущенном через LaunchServices: TCC судит такие вызовы по
/// responsible-процессу, и из CLI или MCP ответил бы терминал или агент, а не Earmark (§3.1).
@MainActor
final class Permissions {
    /// Ответ на запрос календаря, сделанный в этом процессе. authorizationStatus у EventKit
    /// кэшируется: после гранта в том же процессе он до перезапуска отвечает notDetermined
    /// (замер amanu, 19.08.2026). Свежий ответ есть только у самого запроса.
    private var calendarsAnswer: Bool?
    /// TCCAccessPreflight — XPC в tccd, а status() дёргается раз в секунду ради меню.
    private var audioCaptureCache: (status: String, at: Date)?
    private let logger = Logger(subsystem: EarmarkPaths.bundleID, category: "permissions")

    /// `maxAge: 0` — перечитать статус системного звука прямо сейчас (doctor, после запроса).
    func current(maxAge: TimeInterval = 10) -> PermissionsInfo {
        PermissionsInfo(
            microphone: microphone(), audioCapture: audioCapture(maxAge: maxAge), calendars: calendars())
    }

    /// По очереди показывает системные запросы. Уже отвеченное macOS второй раз не спросит,
    /// поэтому на отказ открываем нужную панель System Settings.
    func request() async -> PermissionsInfo {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        if calendars() == "not_determined" {
            // Тот же store, из которого читает CalendarService: доступ видит только запросивший store.
            calendarsAnswer = await withCheckedContinuation { continuation in
                CalendarService.shared.requestFullAccessToEvents { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
        }
        let audio = audioCapture(maxAge: 0)
        if audio == "not_determined" || audio == "unknown" {
            await requestAudioCapture()
        }
        let result = current(maxAge: 0)
        openSettingsForFirstDenied(result)
        return result
    }

    private func microphone() -> String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "granted"
        case .notDetermined: return "not_determined"
        case .denied, .restricted: return "denied"
        @unknown default: return "unknown"
        }
    }

    private func calendars() -> String {
        if let calendarsAnswer { return calendarsAnswer ? "granted" : "denied" }
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return "granted"
        case .notDetermined: return "not_determined"
        // writeOnly не даёт читать события — для авто-записи это тот же отказ.
        case .denied, .restricted, .writeOnly: return "denied"
        @unknown default: return "unknown"
        }
    }

    private func audioCapture(maxAge: TimeInterval) -> String {
        if let cache = audioCaptureCache, Date().timeIntervalSince(cache.at) < maxAge { return cache.status }
        let status = TCCPreflight.audioCapture().rawValue
        audioCaptureCache = (status, Date())
        return status
    }

    /// Промпт «System Audio Recording» появляется только при первом старте aggregate с tap —
    /// отдельного API запроса нет (§10). Поднимаем настоящий рекордер и сразу убираем.
    private func requestAudioCapture() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("earmark-permission-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try await AudioSelfTest.captureSystemAudio(to: url) {
                // Старт уже дождался ответа на запрос: держать tap дольше незачем.
            }
        } catch {
            logger.error("system audio request: \(error.message, privacy: .public)")
        }
    }

    private func openSettingsForFirstDenied(_ info: PermissionsInfo) {
        let pane: String
        if info.microphone == "denied" {
            pane = "Privacy_Microphone"
        } else if info.calendars == "denied" {
            pane = "Privacy_Calendars"
        } else if info.audioCapture == "denied" {
            // «Screen & System Audio Recording» → «System Audio Recording Only».
            pane = "Privacy_AudioCapture"
        } else {
            return
        }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

extension PermissionsInfo {
    var allGranted: Bool { [microphone, audioCapture, calendars].allSatisfy { $0 == "granted" } }
}
