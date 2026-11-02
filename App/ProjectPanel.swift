import AppKit
import EarmarkCore
import SwiftUI

/// Вопрос «какой проект?» после ручной записи вне событий: по плавающей панели на запись.
///
/// Панель не отбирает фокус: человек к этому моменту часто уже в следующем созвоне или показывает
/// экран. Поэтому .nonactivatingPanel и orderFrontRegardless(), а NSApp.activate и makeKey* — никогда.
/// Ответ — через AppModel: он же закрывает панель, когда на вопрос ответили из CLI.
@MainActor
final class ProjectPanels: NSObject, NSWindowDelegate {
    private weak var model: AppModel?
    /// Панель записи и её ступенька лесенки. Ступенька — наименьшая свободная, а не число открытых:
    /// иначе после ответа на раннюю панель новая легла бы ровно поверх ещё открытой.
    private var panels: [String: (panel: NSPanel, slot: Int)] = [:]

    init(model: AppModel) {
        self.model = model
    }

    func show(_ meta: RecordingMeta, calendars: [CalendarListItem]) {
        guard let model, panels[meta.id] == nil else { return }
        let hosting = FirstClickHostingView(
            rootView: ProjectQuestion(meta: meta, calendars: calendars, model: model))
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Earmark"
        panel.contentView = hosting
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Клик по кнопке не делает панель ключевой: иначе она забирала бы набор текста у созвона.
        panel.becomesKeyOnlyIfNeeded = true
        panel.delegate = self
        // Звонилка часто во весь экран, на своём Space: без этого панель висела бы на другом столе.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // В демонстрацию экрана следующего созвона не должны попасть имена других проектов. Это
        // просьба, а не гарантия: приложение захвата экрана вправе её игнорировать.
        panel.sharingType = .none
        var slot = 0
        while panels.values.contains(where: { $0.slot == slot }) { slot += 1 }
        // Лесенкой от правого верхнего угла: панели записей подряд не закрывают друг друга.
        if let frame = NSScreen.main?.visibleFrame {
            let step = CGFloat(slot) * 24
            panel.setFrameTopLeftPoint(
                NSPoint(x: frame.maxX - panel.frame.width - 16 - step, y: frame.maxY - 16 - step))
        }
        panels[meta.id] = (panel, slot)
        panel.orderFrontRegardless()
    }

    func close(_ id: String) {
        panels.removeValue(forKey: id)?.panel.close()
    }

    /// Крестик — тот же ответ, что «Keep in Manual». Программный close() сюда не заходит.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let id = panels.first(where: { $0.value.panel === sender })?.key else { return true }
        panels[id] = nil
        model?.keepInManual(id: id)
        return true
    }
}

/// Кнопки срабатывают с первого клика: app не активен, и без этого первый клик ушёл бы на окно.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct ProjectQuestion: View {
    let meta: RecordingMeta
    /// Включённые календари в порядке config.calendars; на кнопке — имя папки, как на диске.
    let calendars: [CalendarListItem]
    let model: AppModel
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Which project is this call for?").font(.headline)
            Text(summary).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            ForEach(calendars, id: \.id) { calendar in
                Button {
                    move(to: calendar.id)
                } label: {
                    Text(calendar.folder).frame(maxWidth: .infinity)
                }
            }
            Button {
                model.keepInManual(id: meta.id)
            } label: {
                Text("Keep in Manual").frame(maxWidth: .infinity)
            }
            // Панель остаётся: можно выбрать другой календарь или оставить запись в Manual.
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .padding(16)
        .frame(width: 300, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// "<title> · <start time> · <N min>" — чтобы узнать звонок, когда панелей несколько.
    private var summary: String {
        let seconds = meta.durationSec ?? meta.endedAt.map { $0.timeIntervalSince(meta.startedAt) } ?? 0
        let minutes = max(1, Int((seconds / 60).rounded()))
        let start = meta.startedAt.formatted(date: .omitted, time: .shortened)
        return "\(meta.title) · \(start) · \(minutes) min"
    }

    private func move(to calendarID: String) {
        do {
            _ = try model.moveRecording(id: meta.id, calendarID: calendarID)
        } catch {
            self.error = error.message
        }
    }
}
