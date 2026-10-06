import whisper

/// Какой whisper.cpp загрузился в процесс. Любой вызов фреймворка заодно доказывает, что dyld нашёл
/// его по @rpath: у CLI это `Contents/Frameworks` бандла, у `swift test` — каталог сборки.
public enum WhisperRuntime {
    /// Версия whisper.cpp из самого фреймворка — для дымового теста. В fingerprint транскрипта она
    /// не входит: там литерал `whisper-b5130|…` (Task 22). Статическая строка — в отличие от
    /// `whisper_print_system_info()`, не поднимает Metal.
    public static var version: String { String(cString: whisper_version()) }
}
