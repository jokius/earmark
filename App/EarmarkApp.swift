import SwiftUI

@main
struct EarmarkApp: App {
    var body: some Scene {
        // Значок в строке меню — весь GUI earmark (§2): настройки живут в CLI.
        MenuBarExtra("earmark", systemImage: "ear") {
            Button("Quit earmark") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}
