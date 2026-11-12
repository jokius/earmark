import AppKit
import EarmarkCore
import SwiftUI

/// Открытый вопрос «какой проект?» по ручной записи — от стопа до ответа.
struct ProjectQuestion: Equatable {
    let id: String
    let title: String
    let startedAt: Date
    /// Момент стопа: панель показывается раньше, чем сведение напишет meta.
    let endedAt: Date
    /// Где запись сейчас: календарь, угаданный по событию, или nil — Manual. Это выделенная кнопка,
    /// и крестик оставляет запись здесь.
    let calendar: CalendarRef?
    /// Запись, к которой можно приклеить эту («Attach to previous»); nil — кнопки нет.
    var mergeTarget: RecordingMeta?
    /// Выбор, который ждёт конца сведения или применяется прямо сейчас («Saving…»).
    var pending: ProjectAnswer?
    /// Почему не вышло: красный текст, кнопки снова активны.
    var error: String?
}

enum ProjectAnswer: Equatable {
    /// В календарь по id; nil — Manual.
    case move(String?)
    /// Приклеить к mergeTarget.
    case merge
}

/// Вопрос «какой проект?» после каждой ручной записи: по плавающей панели на запись.
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

    func show(_ question: ProjectQuestion, calendars: [CalendarListItem]) {
        guard let model, panels[question.id] == nil else { return }
        let hosting = FirstClickHostingView(
            rootView: ProjectQuestionView(question: question, calendars: calendars, model: model))
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
        panels[question.id] = (panel, slot)
        panel.orderFrontRegardless()
    }

    func close(_ id: String) {
        panels.removeValue(forKey: id)?.panel.close()
    }

    /// Пока выбор сохраняется, крестик погашен: ответ уже дан, и закрытие его не отменяет.
    func setSaving(_ id: String, _ saving: Bool) {
        panels[id]?.panel.standardWindowButton(.closeButton)?.isEnabled = !saving
    }

    /// Крестик — оставить запись, где лежит. Программный close() сюда не заходит.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let id = panels.first(where: { $0.value.panel === sender })?.key,
            let entry = panels.removeValue(forKey: id)
        else { return true }
        // Без записи в panels close(id) из модели — no-op: окно закроет сам крестик.
        guard model?.closeProjectQuestion(id: id) ?? true else {
            panels[id] = entry
            return false
        }
        return true
    }
}

/// Кнопки срабатывают с первого клика: app не активен, и без этого первый клик ушёл бы на окно.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct ProjectQuestionView: View {
    /// Снимок на момент стопа; живое состояние (ожидание, ошибка) — в model.projectQuestions.
    let question: ProjectQuestion
    /// Включённые календари в порядке config.calendars; на кнопке — имя папки, как на диске.
    let calendars: [CalendarListItem]
    let model: AppModel

    var body: some View {
        let live = model.projectQuestions.first { $0.id == question.id } ?? question
        VStack(alignment: .leading, spacing: 8) {
            Text("Which project is this call for?").font(.headline)
            Text(summary).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(calendars, id: \.id) { calendar in
                    choice(calendar.folder, .move(calendar.id), live: live)
                }
                choice("Manual", .move(nil), live: live)
                // Внизу и отдельно: склейку не отменить.
                if let target = live.mergeTarget {
                    Divider().padding(.vertical, 4)
                    choice("Attach to previous", .merge, live: live)
                    Text(caption(target)).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .disabled(live.pending != nil)
            // Панель остаётся: можно выбрать другое или закрыть.
            if let error = live.error { Text(error).font(.caption).foregroundStyle(.red) }
            Text(live.pending == nil ? "Close to keep the highlighted choice." : "Saving…")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 300, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Выделена кнопка с галочкой: выбор, который сейчас сохраняется, иначе текущее положение записи.
    /// Остальные места — пустой кружок. Склейка — действие, а не место: у неё своя иконка.
    private func choice(_ title: String, _ answer: ProjectAnswer, live: ProjectQuestion) -> some View {
        let highlighted = live.pending.map { $0 == answer } ?? (answer == .move(question.calendar?.id))
        let icon =
            answer == .merge ? "arrow.uturn.backward" : highlighted ? "checkmark.circle.fill" : "circle"
        return Button {
            model.answerProject(id: question.id, answer)
        } label: {
            Label(title, systemImage: icon)
        }
        .buttonStyle(ChoiceButtonStyle(highlighted: highlighted))
    }

    /// "<title> · <start time> · <N min>" — чтобы узнать звонок, когда панелей несколько.
    private var summary: String {
        let minutes = max(1, Int((question.endedAt.timeIntervalSince(question.startedAt) / 60).rounded()))
        return "\(question.title) · \(Self.time(question.startedAt)) · \(minutes) min"
    }

    /// "<title> · <start>–<end>" записи, к которой приклеится эта.
    private func caption(_ target: RecordingMeta) -> String {
        "\(target.title) · \(Self.time(target.startedAt))–\(Self.time(target.endedAt ?? target.startedAt))"
    }

    private static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

/// Кнопка варианта, нарисованная SwiftUI. Системные стили не годятся: панель никогда не ключевая, app не
/// активен, и .borderedProminent рисуется без акцента — выделенную кнопку не отличить от прочих.
private struct ChoiceButtonStyle: ButtonStyle {
    let highlighted: Bool

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, highlighted: highlighted)
    }

    /// isEnabled (кнопки гаснут на «Saving…») из окружения читает только вьюха, не сам стиль.
    private struct Face: View {
        let configuration: ButtonStyleConfiguration
        let highlighted: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .foregroundStyle(highlighted ? Color.white : Color.primary)
                .background(
                    highlighted
                        ? Color.accentColor : Color.secondary.opacity(configuration.isPressed ? 0.3 : 0.15),
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .opacity(isEnabled ? 1 : 0.5)
        }
    }
}
