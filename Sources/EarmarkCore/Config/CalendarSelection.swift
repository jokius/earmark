/// Ключ `calendars` в config.json: какие календари пишутся автоматически. Порядок — приоритет
/// при одновременных событиях (§5 п.3). Одно правило на окно Settings и CLI `calendars enable/disable`.
public enum CalendarSelection {
    /// Список после включения или выключения одного календаря. Новый id встаёт в конец, уже
    /// включённый остаётся на своём месте: иначе повторный enable менял бы приоритет.
    public static func toggled(_ ids: [String], id: String, enabled: Bool) -> [String] {
        guard enabled else { return ids.filter { $0 != id } }
        return ids.contains(id) ? ids : ids + [id]
    }
}
