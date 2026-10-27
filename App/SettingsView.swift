import EarmarkCore
import SwiftUI

/// Окно Settings: какие календари пишутся автоматически. Всё — из AppModel, поэтому включение
/// из CLI или агента, новый календарь и выданный доступ видны, пока окно открыто.
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
                        }
                        Text("Only checked calendars are recorded automatically.")
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
