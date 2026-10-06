// swift-tools-version: 6.4
import PackageDescription

// Логика без TCC и железа живёт здесь и тестируется `swift test` без запуска приложения (§3.1 п.4).
// App и CLI собирает xcodegen (project.yml): им нужны бандл, Info.plist, entitlements и подпись,
// которых у SwiftPM-исполняемых нет.
//
// ApproachableConcurrency, который `swift package init` в 6.4 добавляет сам, не включаем:
// с ним nonisolated async-функции остаются на акторе вызывающего, а app рассчитывает, что тяжёлая
// работа (финализация записи, IPC) уходит с MainActor. Семантика пакета и Xcode-таргетов одна.

// Официальный XCFramework whisper.cpp. b5130 — тот же коммит, что v1.9.4: у стабильного тега нет
// ассетов. Паритет с эталонной связкой доказан именно для этого zip (§8.1), сменить его — значит
// доказывать заново (WhisperRuntimeTests ловит подмену по версии).
let whisperRelease = "https://github.com/ggml-org/whisper.cpp/releases/download/b5130"

let package = Package(
    name: "Earmark",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "EarmarkCore", targets: ["EarmarkCore"]),
        .library(name: "EarmarkAudio", targets: ["EarmarkAudio"]),
        .library(name: "EarmarkTranscription", targets: ["EarmarkTranscription"]),
        .library(name: "EarmarkCLI", targets: ["EarmarkCLI"]),
    ],
    targets: [
        .target(name: "EarmarkCore"),
        .target(name: "EarmarkAudio", dependencies: ["EarmarkCore"]),
        .target(name: "EarmarkTranscription", dependencies: ["EarmarkCore", "EarmarkAudio", "whisper"]),
        .target(
            name: "EarmarkCLI",
            dependencies: ["EarmarkCore", "EarmarkAudio", "EarmarkTranscription"]
        ),
        .binaryTarget(
            name: "whisper",
            url: "\(whisperRelease)/whisper-b5130-xcframework.zip",
            checksum: "033a43b0174e8cf9b366f72e4a428cdcf126f93ad1c87d3fa119a96bed6f231a"
        ),
        .testTarget(name: "EarmarkCoreTests", dependencies: ["EarmarkCore"]),
        .testTarget(name: "EarmarkAudioTests", dependencies: ["EarmarkAudio"]),
        .testTarget(name: "EarmarkTranscriptionTests", dependencies: ["EarmarkTranscription"]),
        .testTarget(name: "EarmarkCLITests", dependencies: ["EarmarkCLI"]),
    ],
    swiftLanguageModes: [.v6]
)
