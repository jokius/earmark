import EarmarkCore
import Foundation
import os

/// Модель появляется сама (§8.2): когда транскрипция включена, есть что расшифровывать, а модели
/// нет, — качаем через ModelStore (докачка по Range, sha256, общий с CLI lock). Неудача — повтор
/// через 10 минут; записи тем временем ждут в recorded и попыток не тратят.
@MainActor
final class ModelProvisioner {
    private(set) var info = ModelStatusInfo(state: "missing", progress: nil, path: nil)
    /// Текст последней неудачной загрузки — для предупреждения model_download_failed в status.
    private(set) var lastError: String?
    var onReady: (() -> Void)?

    private let store: ModelStore
    private var downloading = false
    private var retryAt: Date?
    private let logger = Logger(subsystem: EarmarkPaths.bundleID, category: "model")

    init(store: ModelStore = ModelStore()) {
        self.store = store
    }

    var isReady: Bool { info.state == "ready" }

    /// Перечитать состояние с диска — то же отображение, что у `earmark model status` (Task 21).
    /// Только stat, без sha256: дёшево звать хоть каждую секунду. Прогресс загрузки — размер .partial
    /// под чужим lock'ом, поэтому так же видна и своя загрузка, и `earmark model download` из CLI,
    /// а модель, импортированная CLI, сразу снимает старую ошибку загрузки.
    func refresh() {
        let state = (try? store.state(of: Models.largeV3Turbo, verify: false)) ?? .missing
        info = ModelStatusInfo(state)
        // Своя загрузка, пока .partial ещё нет (ждём lock, проверяем место), — тоже «качается».
        // ponytail: поверх битой модели (.corrupt) прогресс не виден — state смотрит сначала на неё;
        // нужен — колбэк progress у ModelStore.download.
        if downloading && !isReady && info.state != "downloading" {
            info = ModelStatusInfo(state: "downloading", progress: 0, path: nil)
        }
        if isReady { lastError = nil }
    }

    /// Очередь зовёт это, пока у неё есть работа, а модели нет. Идемпотентно: идущая загрузка
    /// и пауза после неудачи не перезапускаются.
    func ensure(now: Date = .now) {
        guard !downloading else { return }
        refresh()
        if isReady {
            onReady?()
            return
        }
        if let retryAt, now < retryAt { return }
        downloading = true
        refresh()
        let store = store
        // Detached: sha256 полутора гигабайт — секунды CPU, им не место на главном акторе.
        Task.detached(priority: .utility) { [weak self] in
            do {
                let url = try await store.download(Models.largeV3Turbo) { _, _ in
                    // Прогресс refresh() читает по размеру .partial.
                }
                await self?.finished(.success(url))
            } catch {
                await self?.finished(.failure(error))
            }
        }
    }

    private func finished(_ result: Result<URL, any Error>) {
        downloading = false
        refresh()
        switch result {
        case .success(let url):
            logger.notice("model ready: \(url.path, privacy: .public)")
            onReady?()
        case .failure(let error):
            // .partial остаётся для докачки; в status — честное «нет модели», а не «качается».
            // EarmarkError из ModelStore (нет места, нет сети, sha не сошёлся) — LocalizedError:
            // localizedDescription и есть его message.
            lastError = error.localizedDescription
            retryAt = Date().addingTimeInterval(600)
            logger.error("model download failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
