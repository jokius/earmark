// Из Call Reminder (MIT, тот же автор): Sources/Settings.swift, enum LaunchAtLogin.
import ServiceManagement

/// Автозапуск при входе. Для `.mainApp` отдельный helper-бандл не нужен.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Пользователь выключил автозапуск руками в System Settings.
    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            guard service.status != .enabled else { return }
            try service.register()
        } else {
            // Именно такой guard: при .notFound unregister() бросает ошибку.
            guard service.status == .enabled || service.status == .requiresApproval else { return }
            try service.unregister()
        }
    }

    static func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
