import Foundation

/// Где earmark держит служебные файлы.
///
/// `EARMARK_HOME` читается при каждом обращении, а не один раз при старте: dev-сборка и ручные
/// прогоны CLI живут в своей песочнице, не трогая настоящий конфиг. Тесты переменную не выставляют —
/// Swift Testing гоняет их параллельно, поэтому пути передаются явно: ConfigStore(url:),
/// RecordingStore(root:) и т.п.
public enum EarmarkPaths {
    public static let bundleID = "com.konayre.earmark"

    /// Корень служебных файлов: $EARMARK_HOME или ~/Library/Application Support/earmark.
    public static var supportDir: URL {
        if let home = ProcessInfo.processInfo.environment["EARMARK_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: (home as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/earmark", isDirectory: true)
    }

    public static var configFile: URL { supportDir.appendingPathComponent("config.json") }
    public static var stateFile: URL { supportDir.appendingPathComponent("state.json") }
    public static var socketFile: URL { supportDir.appendingPathComponent("earmark.sock") }
    public static var modelsDir: URL { supportDir.appendingPathComponent("models", isDirectory: true) }

    /// Создаёт supportDir с правами 0700, если его нет.
    ///
    /// Уже существующий каталог тоже дожимаем до 0700: в нём лежит сокет, через который можно
    /// включить запись микрофона, а каталог мог остаться от старой сборки с umask 022.
    public static func ensureSupportDir() throws {
        let dir = supportDir
        let fm = FileManager.default
        try fm.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }
}
