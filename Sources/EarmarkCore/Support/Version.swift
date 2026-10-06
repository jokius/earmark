/// Версия earmark. Одна на app и CLI: CLI лежит в том же бандле (§3.2), поэтому `meta.app_version`,
/// `status` и MCP `serverInfo` показывают одно число. Должна совпадать с `MARKETING_VERSION`
/// в project.yml — это проверяет `VersionTests`. CLI берёт версию только отсюда: из Contents/Helpers
/// `Bundle.main` — не бандл app, и `CFBundleShortVersionString` там нет.
public enum EarmarkVersion {
    public static let current = "0.1.0"
}
