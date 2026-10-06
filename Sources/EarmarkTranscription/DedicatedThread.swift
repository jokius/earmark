// Copyright (c) 2026 Andrew Jones (MIT)
// Copyright (c) 2026 Samat Galimov (MIT)
// Портировано из amanu@fbccc13: Sources/amanu/Transcription/DedicatedThread.swift

import EarmarkCore
import Foundation

/// Блокирующий C-вызов на собственном потоке; ожидание не держит поток кооперативного пула.
///
/// whisper_full блокирует на минуты, а в пуле по потоку на ядро: вызов прямо из async-функции
/// держал бы целое ядро всех задач процесса, включая вывод прогресса.
enum DedicatedThread {
    static func run<T: Sendable>(
        _ name: String, _ work: @escaping @Sendable () throws(EarmarkError) -> T
    ) async throws(EarmarkError) -> T {
        let job = Job(work)
        let result: Result<T, EarmarkError> = await withCheckedContinuation { continuation in
            let thread = Thread { continuation.resume(returning: job.run()) }
            thread.name = "earmark \(name)"
            // QoS не задаём: его выставляет app на весь процесс воркера (.utility, §8.4).
            // Граф ggml строится рекурсивно; 512 KB вторичного потока в пробе хватило,
            // но библиотеку писали не под них — 8 MB берём с запасом, как amanu.
            thread.stackSize = 8 << 20
            thread.start()
        }
        return try result.get()
    }

    /// Работа, которую поток отпускает сразу после выполнения, ещё до resume.
    ///
    /// Иначе блок Thread остаётся последним владельцем захваченного WhisperEngine: deinit и
    /// whisper_free уходят на этот поток и идут параллельно с exit() воркера, а статический
    /// деструктор ggml-metal падает на GGML_ASSERT (замер: exit 134 в 3 из 10 SIGTERM).
    private final class Job<T: Sendable>: @unchecked Sendable {
        private var work: (@Sendable () throws(EarmarkError) -> T)?

        init(_ work: @escaping @Sendable () throws(EarmarkError) -> T) { self.work = work }

        func run() -> Result<T, EarmarkError> {
            guard let work else { return .failure(.operationFailed("DedicatedThread: the work already ran")) }
            self.work = nil
            return Result { () throws(EarmarkError) -> T in try work() }
        }
    }
}
