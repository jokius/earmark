import AppKit
import EarmarkCore
import SwiftUI

/// Меню в строке меню. Всё состояние — из `model.snapshot`, действия — методы AppModel: у меню
/// и у IPC одна точка входа.
struct MenuContent: View {
    let model: AppModel

    var body: some View {
        if model.isRecording {
            Button("Stop recording") { Task { _ = try? await model.stopRecording() } }
        } else {
            Button("Start recording") { _ = try? model.startManual(title: nil) }
        }
        Divider()
        Text(Self.statusLine(model.snapshot))
        if let next = model.snapshot.next {
            Text("Next: \(next.start.formatted(date: .omitted, time: .shortened)) \(next.title)")
        }
        ForEach(model.snapshot.warnings, id: \.self) { warning in
            Text("Warning: \(warning)")
        }
        if let permissions = model.snapshot.permissions, !permissions.allGranted {
            Divider()
            Button("Grant Permissions…") { Task { _ = await model.requestPermissions() } }
            Text(
                "Microphone: \(permissions.microphone) · Calendars: \(permissions.calendars) · "
                    + "System audio: \(permissions.audioCapture)")
        }

        Divider()

        Button("Open Recordings Folder") { model.openRecordingsFolder() }
        #if DEBUG
        // Ручные проверки до появления IPC; результат — в `/usr/bin/log stream`, категория audio-test.
        Menu("Debug") {
            Button("Run Audio Self-Test (plays a short quiet tone)") {
                Task { _ = try? await model.audioTest() }
            }
            Divider()
            ForEach(model.calendarsList(), id: \.id) { item in
                Toggle(
                    "\(item.title) — \(item.account)",
                    isOn: Binding(
                        get: { item.enabled }, set: { model.debugSetCalendar(item.id, enabled: $0) }))
            }
            Button("Reset Enabled Calendars") { _ = try? model.resetConfig("calendars") }
        }
        #endif

        Divider()

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
