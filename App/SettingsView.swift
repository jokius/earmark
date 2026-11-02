import EarmarkCore
import SwiftUI

/// Окно Settings: общий язык расшифровки, какие календари пишутся автоматически и их свои языки.
/// Всё — из AppModel, поэтому включение из CLI или агента, новый календарь и выданный доступ
/// видны, пока окно открыто.
///
/// В отличие от Call Reminder, при пустом конфиге ничего не включаем сами: запись звонков
/// по личным календарям без явного выбора недопустима.
struct SettingsView: View {
    let model: AppModel
    // ponytail: включённые календари сверху, но порядок замораживается, пока окно открыто: иначе
    // переключатель уезжал бы из-под курсора. Свежевключённый поднимется при следующем открытии.
    @State private var pinned: [String]?

    var body: some View {
        Form {
            Section {
                LanguageField(
                    model: model, key: "transcription.language", label: "Default languages", prompt: "auto")
            } header: {
                Text("Transcription")
            } footer: {
                Text(
                    """
                    Comma-separated codes like ru, en, az, or auto. Each speech fragment is transcribed \
                    in the most likely of them. Used for recordings without a calendar and for calendars \
                    without their own languages.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                if model.snapshot.permissions?.calendars != "granted" {
                    Text("Earmark has no access to your calendars.").foregroundStyle(.secondary)
                    Button("Grant Permissions…") { Task { _ = await model.requestPermissions() } }
                } else {
                    let calendars = ordered(model.calendarsList())
                    if calendars.isEmpty {
                        Text("No calendars available").foregroundStyle(.secondary)
                    } else {
                        ForEach(calendars, id: \.id) { calendar in
                            // Одна строка формы на календарь: поле языков внутри неё, без разделителя,
                            // иначе оно читается как отдельная настройка соседней строки.
                            VStack(alignment: .leading, spacing: 6) {
                                Toggle(isOn: binding(for: calendar.id)) { CalendarLabel(calendar: calendar) }
                                if calendar.enabled {
                                    LanguageField(
                                        model: model, key: "calendar.\(calendar.id).language",
                                        label: "Languages",
                                        prompt: "Default (\(model.config.transcriptionLanguage))",
                                        spoken: "Languages for \(calendar.title)"
                                    )
                                    .padding(.leading, 20)
                                    .help("Leave empty to use the default languages.")
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("Calendars")
            } footer: {
                Text(
                    """
                    Calendars that are turned on are recorded automatically and get their own Languages \
                    line. Leave it empty to use the default languages.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { pinned = model.config.calendars }
        .onDisappear { pinned = nil }
    }

    /// Включённые — сверху в порядке config.calendars (на момент открытия окна), остальные — как отдаёт EventKit.
    private func ordered(_ all: [CalendarListItem]) -> [CalendarListItem] {
        // `config set calendars a,a` повторов не отсекает, а одинаковый id в ForEach задвоил бы строку.
        var seen = Set<String>()
        let top = (pinned ?? model.config.calendars).filter { seen.insert($0).inserted }
        return top.compactMap { id in all.first { $0.id == id } } + all.filter { !top.contains($0.id) }
    }

    /// Состояние — из конфига, а не из @State: после ошибки записи галочка остаётся фактической.
    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { model.config.calendars.contains(id) },
            set: { model.setCalendar(id, enabled: $0) })
    }
}

/// Названия не уникальны (одинаковый «Calendar» в разных аккаунтах) — различает аккаунт, серым.
/// У email-календарей аккаунт совпадает с названием — не повторяем.
private struct CalendarLabel: View {
    let calendar: CalendarListItem

    var body: some View {
        if calendar.account == calendar.title {
            Text(calendar.title)
        } else {
            Text("\(calendar.title)  \(Text(calendar.account).foregroundStyle(.secondary))")
        }
    }
}

/// Поле языков расшифровки: общий transcription.language или calendar.<id>.language. Правленый текст —
/// черновик пользователя; нетронутый следует за конфигом даже в фокусе, так что `config set` из CLI или агента видно сразу.
/// Сохраняем тем же setConfig, что и CLI: проверка и нормализация одни.
private struct LanguageField: View {
    let model: AppModel
    let key: String
    let label: String
    /// Что действует, пока своего значения нет: унаследованное показываем подсказкой, а не текстом.
    let prompt: String
    /// Для VoiceOver: одинаковые «Languages» у разных календарей иначе не различить.
    var spoken: String?
    @State private var text = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    /// Только явно заданный ключ: унаследованное значение — в prompt, а не в тексте.
    private var stored: String {
        guard case .string(let language)? = model.config.values[key] else { return "" }
        return language
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(label, text: $text, prompt: Text(prompt))
                .accessibilityLabel(spoken ?? label)
                .focused($focused)
                .onSubmit(save)
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { save() }
                }
                // Нетронутый черновик (текст равен прежнему значению) идёт за конфигом и в фокусе:
                // macOS сам ставит фокус в первое поле окна, и старый текст на следующем Return
                // или уходе фокуса молча откатил бы `config set` из CLI.
                .onChange(of: stored, initial: true) { old, new in
                    guard !focused || text == old else { return }
                    text = new
                    error = nil
                }
                // Закрытие окна (красная кнопка, Cmd-W) и снятая галочка календаря не забирают фокус,
                // и сохранение по его потере не срабатывает. Повторной записи нет: save() пропускает
                // текст, равный конфигу.
                .onDisappear(perform: save)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    /// Пусто — сбросить ключ (календарь наследует общий язык, общий возвращается к auto); ошибка
    /// проверки оставляет текст в поле для правки, а конфиг не трогает.
    private func save() {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Return и следующая за ним потеря фокуса не должны дважды переписывать config.json.
        guard raw != stored else {
            error = nil
            return
        }
        do {
            if raw.isEmpty {
                _ = try model.resetConfig(key)
            } else {
                _ = try model.setConfig(key, raw: raw)
            }
            error = nil
            text = stored
        } catch {
            self.error = error.message
        }
    }
}
