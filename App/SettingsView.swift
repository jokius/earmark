import EarmarkCore
import SwiftUI

/// Окно Settings: какие календари пишутся автоматически и на каких языках они расшифровываются.
/// Всё — из AppModel, поэтому включение из CLI или агента, новый календарь и выданный доступ
/// видны, пока окно открыто.
///
/// В отличие от Call Reminder, при пустом конфиге ничего не включаем сами: запись звонков
/// по личным календарям без явного выбора недопустима.
struct SettingsView: View {
    let model: AppModel

    var body: some View {
        Form {
            Section("Calendars") {
                if model.snapshot.permissions?.calendars != "granted" {
                    Text("Earmark has no access to your calendars.").foregroundStyle(.secondary)
                    Button("Grant Permissions…") { Task { _ = await model.requestPermissions() } }
                } else {
                    let calendars = model.calendarsList()
                    if calendars.isEmpty {
                        Text("No calendars available").foregroundStyle(.secondary)
                    } else {
                        ForEach(calendars, id: \.id) { calendar in
                            // Названия не уникальны (одинаковый «Calendar» в разных аккаунтах) — с аккаунтом.
                            Toggle(
                                "\(calendar.title)  ·  \(calendar.account)", isOn: binding(for: calendar.id))
                            if calendar.enabled {
                                CalendarLanguageField(model: model, calendarID: calendar.id)
                            }
                        }
                        Text(
                            """
                            Only checked calendars are recorded automatically.
                            Languages: comma-separated codes like ru, en, az — each speech fragment \
                            is transcribed in the most likely of them. Empty uses the default.
                            """
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Состояние — из конфига, а не из @State: после ошибки записи галочка остаётся фактической.
    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { model.config.calendars.contains(id) },
            set: { model.setCalendar(id, enabled: $0) })
    }
}

/// Языки расшифровки календаря (calendar.<id>.language). Правленый текст — черновик пользователя;
/// нетронутый следует за конфигом даже в фокусе, так что `config set` из CLI или агента видно сразу.
/// Сохраняем тем же setConfig, что и CLI: проверка и нормализация одни.
private struct CalendarLanguageField: View {
    let model: AppModel
    let calendarID: String
    @State private var text = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    private var key: String { "calendar.\(calendarID).language" }

    /// Только свой ключ календаря: глобальное значение — в placeholder, а не в тексте.
    private var stored: String {
        guard case .string(let language)? = model.config.values[key] else { return "" }
        return language
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Languages", text: $text, prompt: Text(model.config.transcriptionLanguage))
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

    /// Пусто — сбросить свой ключ (действует глобальный язык); ошибка проверки оставляет текст
    /// в поле для правки, а конфиг не трогает.
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
