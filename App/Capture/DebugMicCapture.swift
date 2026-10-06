#if DEBUG
import AppKit
@preconcurrency import AVFoundation
import EarmarkAudio
import EarmarkCore
import SwiftUI
import os

/// Временный пункт меню для ручной проверки MicRecorder (Task 11). Task 13 удаляет файл.
struct DebugMicCaptureMenu: View {
    var body: some View {
        Button("Debug: record mic 60 s") { DebugMicCapture.record(seconds: 60) }
    }
}

@MainActor
enum DebugMicCapture {
    private static let log = Logger(subsystem: EarmarkPaths.bundleID, category: "debug")

    /// ~/Earmark/Debug/mic-<время>.caf, по окончании — показать в Finder.
    static func record(seconds: Int) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Earmark/Debug")
        let url = dir.appendingPathComponent("mic-\(Int(Date().timeIntervalSince1970)).caf")
        let recorder = MicRecorder()
        let writer: CAFWriter
        do {
            // 0700: в файле голос (§7.1).
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1) else {
                return
            }
            writer = try CAFWriter(url: url, format: format)
            try recorder.start(writer: writer)
        } catch {
            log.error("debug mic capture: \(error.localizedDescription, privacy: .public)")
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            recorder.stop()
            try? writer.close()
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
#endif
