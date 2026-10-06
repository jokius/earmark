import Foundation

/// Один файл модели, зафиксированный ревизией HF, размером и sha256.
///
/// По /resolve/<ревизия>/ HF всегда отдаёт ровно этот файл, а размер и sha256 после загрузки
/// доказывают, что на диске он, а не обрывок или подмена.
public struct ModelManifest: Equatable, Sendable {
    public var name: String
    public var fileName: String
    public var url: URL
    public var size: Int64
    public var sha256: String

    public init(name: String, fileName: String, url: URL, size: Int64, sha256: String) {
        self.name = name
        self.fileName = fileName
        self.url = url
        self.size = size
        self.sha256 = sha256
    }
}

public enum Models {
    /// f16 large-v3-turbo — та же модель, на которой отлажена эталонная связка (§8.1).
    public static let largeV3Turbo = ModelManifest(
        name: "ggml-large-v3-turbo",
        fileName: "ggml-large-v3-turbo.bin",
        url: pinned(
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/"
                + "5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo.bin"),
        size: 1_624_555_275,
        sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69")

    /// Silero VAD v5.1.2 лежит в бандле app; манифест нужен doctor'у, чтобы проверить файл.
    /// На v6.2.0 того же размера без A/B на живых созвонах не переходим.
    public static let sileroVAD = ModelManifest(
        name: "ggml-silero-v5.1.2",
        fileName: "ggml-silero-v5.1.2.bin",
        url: pinned(
            "https://huggingface.co/ggml-org/whisper-vad/resolve/"
                + "9ffd54a1e1ee413ddf265af9913beaf518d1639b/ggml-silero-v5.1.2.bin"),
        size: 885_098,
        sha256: "29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf")

    /// Литерал URL манифеста: кривой — ошибка программиста, падаем сразу и с текстом.
    private static func pinned(_ string: String) -> URL {
        guard let url = URL(string: string) else { preconditionFailure("bad manifest URL: \(string)") }
        return url
    }
}
