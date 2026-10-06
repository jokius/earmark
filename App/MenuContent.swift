import AppKit
import EarmarkCore
import SwiftUI

/// Меню в строке меню. Всё состояние — из `model.snapshot`, действия — методы AppModel: у меню
/// и у IPC одна точка входа.
struct MenuContent: View {
    let model: AppModel

    var body: some View {
        Text(Self.statusLine(model.snapshot))
        ForEach(model.snapshot.warnings, id: \.self) { warning in
            Text("Warning: \(warning)")
        }

        Divider()

        Button("Open Recordings Folder") { model.openRecordingsFolder() }

        Divider()

        #if DEBUG
        DebugSystemCaptureMenu()
        #endif
        Button("Quit Earmark") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    static func statusLine(_ status: StatusData) -> String {
        if let recording = status.recording {
            return "Recording: \(recording.title) · \(elapsed(recording.elapsedSec))"
        }
        return "Idle"
    }

    static func elapsed(_ seconds: Double) -> String {
        let duration = Duration.seconds(Int(seconds))
        return seconds >= 3600
            ? duration.formatted(.time(pattern: .hourMinuteSecond))
            : duration.formatted(.time(pattern: .minuteSecond))
    }
}
