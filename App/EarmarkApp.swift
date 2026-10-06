import AppKit
import EarmarkCore
import SwiftUI
import os

@main
struct EarmarkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: delegate.model)
        } label: {
            // В статус-айтем из лейбла доходят только Image и Text. Template-«ухо» само
            // подстраивается под светлую и тёмную строку меню, красный значок — см. MenuIcon.
            if delegate.model.showsRecordingIcon {
                Image(nsImage: MenuIcon.recording)
            } else {
                Image(systemName: "ear")
            }
        }
    }
}

/// Значок «идёт запись». .foregroundStyle(.red) и .symbolRenderingMode(.multicolor) в лейбле
/// MenuBarExtra молча превращают символ в template и он рисуется цветом строки меню (замерено на
/// 27.0.1). Цвет переживает только NSImage с isTemplate = false.
enum MenuIcon {
    @MainActor static let recording: NSImage = {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.systemRed]))
        let image =
            NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Earmark is recording")?
            .withSymbolConfiguration(config) ?? NSImage()
        image.isTemplate = false
        return image
    }()
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private let logger = Logger(subsystem: EarmarkPaths.bundleID, category: "app")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // App, поднятый хостом тестов, не должен трогать конфиг, login item и тем более запись.
        guard !TestEnvironment.isRunningTests else {
            logger.notice("test environment: services are not started")
            return
        }
        if let other = Self.otherInstance() {
            logger.notice("another instance is running (pid \(other.processIdentifier)), exiting")
            NSApp.terminate(nil)
            return
        }
        // Вторая линия single instance: сокет отвечает — значит, его держит живой экземпляр.
        guard model.startIPC() else {
            logger.notice("another instance is serving the socket, exiting")
            NSApp.terminate(nil)
            return
        }
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }

    /// Второй экземпляр — второй владелец микрофона, tap и сокета: созвон разъехался бы на две
    /// половинки в двух папках. LaunchServices второй копии по тому же пути не запустит, но сборка
    /// из build/ (`make run`) и копия в /Applications — разные пути с одним bundle id.
    private static func otherInstance() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: EarmarkPaths.bundleID)
            .first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }
    }
}
