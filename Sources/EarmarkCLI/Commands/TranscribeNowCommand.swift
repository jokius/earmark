import EarmarkCore
import EarmarkTranscription
import Foundation
import Synchronization

/// `earmark transcribe <id> --now [--force]`: воркер, которого app запускает отдельным процессом
/// (§8.3). Тот же вход годится человеку и агенту. Прогресс — JSON-строками в stdout по ходу работы,
/// итоговый конверт — последней строкой; ошибка — конвертом в stderr с кодом выхода из спеки.
enum TranscribeNowCommand {
    /// Что нужно воркеру: папка записи, модель и VAD.
    struct Job {
        let store: RecordingStore
        let folder: RecordingFolder
        let model: URL
        let vad: URL
    }

    static func run(_ parsed: ParsedCommand, _ context: CLIContext) async throws(EarmarkError) -> JSONValue {
        let config: Config
        do throws(EarmarkError) {
            config = try context.loadConfig()
        } catch {
            // Битый или нечитаемый config.json — беда машины, а не записи: unavailable (69), как и нет
            // модели. Задача ещё не захвачена, поэтому meta не тронута и попытка не потрачена.
            throw .unavailable(error.message)
        }
        let job = try locate(
            id: try parsed.argument("id"), config: config, modelStore: ModelStore(),
            vadModel: bundledVADModel())
        // Обработчики сигналов — глобальное состояние процесса, поэтому только когда работа точно будет:
        // CLI-тесты, которые доходят сюда с несуществующей записью, их не ставят.
        let stop = StopSignalFlag.install()
        let output = context.output
        let transcript = try await Transcriber(
            store: job.store, modelPath: job.model, vadModelPath: job.vad, config: config
        ).run(
            folder: job.folder.url, force: parsed.flag("force"),
            progress: { progress in
                // После SIGTERM в stdout ни строки: app при выходе ждёт воркер 2 с и закрывает pipe, а
                // whisper зовёт progress(0) после VAD раньше abort-хука — запись убила бы воркер SIGPIPE'ом
                // до того, как recordFailure вернёт meta, и попытка была бы засчитана.
                guard !stop.isRaised, let line = try? JSONValue(encoding: progress) else { return }
                output.stdout(Output.render(line, pretty: false))
            },
            shouldAbort: { stop.isRaised })
        return try encodeJSON(
            Summary(
                id: job.folder.id ?? "", segments: transcript.segments.count,
                durationSec: job.folder.meta?.durationSec,
                transcript: job.folder.url.appending(path: RecordingFiles.transcript).path))
    }

    /// Папка по id, модель и VAD. Без модели или VAD задачу не захватываем: meta не трогаем,
    /// попытка не тратится, exit 69 — очередь подождёт, пока модель появится.
    /// sha модели здесь не считаем (1–4 с на каждую задачу): в models/ файл попадает только через
    /// download/import, а они его уже проверили.
    static func locate(id: String, config: Config, modelStore: ModelStore, vadModel: URL?)
        throws(EarmarkError) -> Job
    {
        let store = RecordingStore(root: config.recordingsDir)
        let found = try disk("recordings") { try store.find(id: id) }
        guard let folder = found else {
            throw .notFound("recording \(id) not found in \(config.recordingsDir.path)")
        }
        let state = try disk("model") { try modelStore.state(of: Models.largeV3Turbo, verify: false) }
        guard case .ready(let model) = state else {
            throw .unavailable(
                "model \(Models.largeV3Turbo.fileName) is not installed: "
                    + "run earmark model download or earmark model import <path>")
        }
        guard let vadModel, FileManager.default.fileExists(atPath: vadModel.path) else {
            throw .unavailable(
                "\(Models.sileroVAD.fileName) not found in Earmark.app/Contents/Resources "
                    + "or EARMARK_VAD_MODEL")
        }
        return Job(store: store, folder: folder, model: model, vad: vadModel)
    }

    /// Итог для конверта: сам текст читают через `earmark transcript <id>`, здесь — только сводка.
    private struct Summary: Encodable {
        let id: String
        let segments: Int
        let durationSec: Double?
        let transcript: String
    }

    /// VAD лежит в Earmark.app/Contents/Resources, CLI — в Contents/Helpers: от настоящего бинаря
    /// (Bundle.main.executableURL с раскрытыми симлинками — CLI зовут через ~/.local/bin/earmark)
    /// это ../Resources. Ни Bundle.main.url(forResource:), ни CommandLine.arguments[0] не годятся:
    /// resourceURL у CLI — сам Contents/Helpers (замер спайка S2), а при вызове по PATH arguments[0] —
    /// голое "earmark" (проверено). EARMARK_VAD_MODEL — для разработки без бандла.
    static func bundledVADModel() -> URL? {
        if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            let bundled = executable.deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "Resources/\(Models.sileroVAD.fileName)")
            if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        }
        return ProcessInfo.processInfo.environment["EARMARK_VAD_MODEL"].map { URL(fileURLWithPath: $0) }
    }
}

/// SIGTERM (вытеснение от app), SIGINT (Ctrl-C) и SIGHUP (закрыли терминал) → атомарный флаг, который
/// читает abort_callback whisper: все три — отмена, а не крэш, попытка не засчитывается. Сами сигналы
/// игнорируем, а ловим через DispatchSource: в его обработчике можно что угодно (в настоящем signal
/// handler — нет), и процесс не умирает посреди записи transcript-файлов, а выходит штатно с кодом 75.
final class StopSignalFlag: @unchecked Sendable {
    private let raised = Atomic<Bool>(false)
    /// Держим источники живыми всё время процесса; цикл ссылок flag → source → flag намеренный.
    private var sources: [any DispatchSourceSignal] = []

    var isRaised: Bool { raised.load(ordering: .relaxed) }

    static func install() -> StopSignalFlag {
        let flag = StopSignalFlag()
        flag.sources = [SIGTERM, SIGINT, SIGHUP].map { signo in
            let source = DispatchSource.makeSignalSource(signal: signo, queue: .global())
            source.setEventHandler { flag.raised.store(true, ordering: .relaxed) }
            // Источник раньше SIG_IGN: сигнал в этом окне убьёт процесс ещё до захвата задачи
            // (безвредно), а не потеряется.
            source.resume()
            signal(signo, SIG_IGN)
            return source
        }
        return flag
    }
}
