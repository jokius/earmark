#if DEBUG
import AppKit
@preconcurrency import AVFoundation
import EarmarkAudio
import SwiftUI
import os

/// Временные пункты меню для ручной проверки SystemAudioRecorder (Task 10). Task 13 удаляет файл.
struct DebugSystemCaptureMenu: View {
    var body: some View {
        Button("Debug: record system 10 s") { DebugSystemCapture.record(seconds: 10, stallAt: nil) }
        Button("Debug: record system 90 s, stall at 10 s") {
            DebugSystemCapture.record(seconds: 90, stallAt: 10)
        }
    }
}

@MainActor
enum DebugSystemCapture {
    private static let log = Logger(subsystem: "com.konayre.earmark", category: "debug")

    /// ~/Earmark/Debug/system-<время>.caf, по окончании — показать в Finder.
    static func record(seconds: Int, stallAt: Int?) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Earmark/Debug")
        let url = dir.appendingPathComponent("system-\(Int(Date().timeIntervalSince1970)).caf")
        let recorder = SystemAudioRecorder()
        let writer: CAFWriter
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1) else {
                return
            }
            writer = try CAFWriter(url: url, format: format)
            try recorder.start(writer: writer)
        } catch {
            log.error("debug system capture: \(error.localizedDescription, privacy: .public)")
            return
        }
        Task { @MainActor in
            if let stallAt {
                try? await Task.sleep(for: .seconds(stallAt))
                recorder.simulateStall()
                try? await Task.sleep(for: .seconds(seconds - stallAt))
            } else {
                try? await Task.sleep(for: .seconds(seconds))
            }
            recorder.stop()
            try? writer.close()
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
#endif
