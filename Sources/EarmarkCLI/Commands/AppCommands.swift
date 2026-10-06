import EarmarkCore
import Foundation

/// Команды, которым нужен работающий app: всё, что трогает TCC, EventKit или идущую запись.
/// CLI здесь — тонкий клиент: собрать params, отправить, вернуть data как есть (§3.1, §9.3).
enum AppCommands {
    /// Обычный ответ app — миллисекунды; 30 с — запас на подвисший EventKit.
    static let defaultTimeout: TimeInterval = 30
    /// stop отвечает после финализации (свести 3 ч записи в AAC — это минуты), а permissions
    /// request — когда человек прокликает системные диалоги.
    static let longTimeout: TimeInterval = 300

    /// status никогда не поднимает app: мёртвый сокет — это ответ, а не ошибка (§9.3).
    static func status(
        _ parsed: ParsedCommand, _ context: CLIContext
    ) async throws(EarmarkError) -> JSONValue {
        do {
            return try await context.ipc.call(
                IPCMethod.status, params: .object([:]), autoLaunch: false, timeout: defaultTimeout)
        } catch {
            guard error.exitCode == ExitCode.appNotRunning.rawValue else { throw error }
            return try encodeJSON(StatusData(appRunning: false, state: "idle"))
        }
    }

    /// Идемпотентно: если запись уже идёт, app вернёт её же (§9.3).
    static func start(
        _ parsed: ParsedCommand, _ context: CLIContext
    ) async throws(EarmarkError) -> JSONValue {
        var params: [String: JSONValue] = [:]
        if let title = parsed.options["title"] { params["title"] = .string(title) }
        return try await send(IPCMethod.recordingStart, .object(params), context)
    }

    /// stop тоже не поднимает app: в закрытом app ничего не пишется — ответ null, как у app без записи.
    /// Поднятый app ещё и начал бы поздней авто-записью идущую встречу: «стоп» стартовал бы запись.
    static func stop(
        _ parsed: ParsedCommand, _ context: CLIContext
    ) async throws(EarmarkError) -> JSONValue {
        do {
            return try await context.ipc.call(
                IPCMethod.recordingStop, params: .object([:]), autoLaunch: false, timeout: longTimeout)
        } catch {
            guard error.exitCode == ExitCode.appNotRunning.rawValue else { throw error }
            return .null
        }
    }

    static func upcoming(
        _ parsed: ParsedCommand, _ context: CLIContext
    ) async throws(EarmarkError) -> JSONValue {
        let hours = try parsed.int("hours", min: 1) ?? 24
        return try await send(IPCMethod.calendarUpcoming, .object(["hours": .number(Double(hours))]), context)
    }

    static func calendars(
        _ parsed: ParsedCommand, _ context: CLIContext
    ) async throws(EarmarkError) -> JSONValue {
        try await send(IPCMethod.calendarList, .object([:]), context)
    }

    static func enableCalendar(
        _ parsed: ParsedCommand, _ context: CLIContext
    ) async throws(EarmarkError) -> JSONValue {
        try await updateCalendars(parsed, context) { ids, id in
            if !ids.contains(id) { ids.append(id) }
        }
    }

    static func disableCalendar(
        _ parsed: ParsedCommand, _ context: CLIContext
    ) async throws(EarmarkError) -> JSONValue {
        try await updateCalendars(parsed, context) { ids, id in ids.removeAll { $0 == id } }
    }

    static func configSet(
        _ parsed: ParsedCommand, _ context: CLIContext
    ) async throws(EarmarkError) -> JSONValue {
        let key = try parsed.argument("key")
        let value = try parsed.argument("value")
        // Значение проверяет app, а не CLI: проверка recordings_dir трогает файловую систему,
        // и из терминала она могла бы вызвать запрос TCC от имени терминала (§7.1).
        return try await send(
            IPCMethod.configSet, .object(["key": .string(key), "value": .string(value)]), context)
    }

    static func configReset(
        _ parsed: ParsedCommand, _ context: CLIContext
    ) async throws(EarmarkError) -> JSONValue {
        let params: [String: JSONValue]
        switch (parsed.arguments["key"], parsed.flag("all")) {
        case (let key?, false): params = ["key": .string(key)]
        case (nil, true): params = ["all": .bool(true)]
        default: throw .invalidArguments("config reset: pass either <key> or --all")
        }
        return try await send(IPCMethod.configReset, .object(params), context)
    }

    /// Отчёт app плюс проверки, которые видны только из CLI.
    static func doctor(
        _ parsed: ParsedCommand, _ context: CLIContext
    ) async throws(EarmarkError) -> JSONValue {
        let params: JSONValue = .object(["audio_test": .bool(parsed.flag("audio-test"))])
        let data = try await send(IPCMethod.doctor, params, context)
        var report = try decodeJSON(DoctorReport.self, from: data)
        let local = localChecks(executable: Bundle.main.executableURL)
        report.checks += local
        report.ready = report.ready && local.allSatisfy(\.ok)
        return try encodeJSON(report)
    }

    /// whisper.framework линкуется только в CLI (§3.2), поэтому app не видит, на месте ли он.
    /// Ищем там же, где его найдёт dyld: @executable_path/../Frameworks от настоящего бинаря
    /// (Contents/Helpers/earmark → Contents/Frameworks), симлинк ~/.local/bin/earmark раскрываем.
    /// Проверки модели и VAD делает doctor самого app (§10).
    static func localChecks(executable: URL?) -> [DoctorCheck] {
        guard let executable else {
            return [
                DoctorCheck(name: "whisper_framework", ok: false, detail: "cannot locate the earmark binary")
            ]
        }
        let framework = executable.resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Frameworks/whisper.framework")
        let found = FileManager.default.fileExists(atPath: framework.path)
        let detail = found ? framework.path : "\(framework.path) is missing; reinstall with make install"
        return [DoctorCheck(name: "whisper_framework", ok: found, detail: detail)]
    }

    static func requestPermissions(
        _ parsed: ParsedCommand, _ context: CLIContext
    ) async throws(EarmarkError) -> JSONValue {
        try await send(IPCMethod.permissionsRequest, .object([:]), context, timeout: longTimeout)
    }

    /// Очередь app сразу отвечает позицией; сама транскрипция идёт потом, отдельным процессом.
    static func enqueueTranscription(
        _ parsed: ParsedCommand, _ context: CLIContext
    ) async throws(EarmarkError) -> JSONValue {
        let id = try parsed.argument("id")
        let params: JSONValue = .object(["id": .string(id), "force": .bool(parsed.flag("force"))])
        return try await send(IPCMethod.transcriptionEnqueue, params, context)
    }

    /// enable/disable — это `config set calendars` с новым списком, своих IPC-методов у них нет.
    /// Список берём с диска: app — единственный писатель config.json и пишет его атомарно,
    /// так что на диске то же, что у app в памяти. Порядок сохраняем — он задаёт приоритет
    /// календаря при одновременных событиях (§5 п.3), поэтому новый id встаёт в конец.
    private static func updateCalendars(
        _ parsed: ParsedCommand, _ context: CLIContext, _ change: (inout [String], String) -> Void
    ) async throws(EarmarkError) -> JSONValue {
        let id = try parsed.argument("id")
        var ids = try context.loadConfig().calendars
        change(&ids, id)
        // JSON-массив, а не список через запятую: id календаря — непрозрачная строка EventKit.
        let value = Output.render(.array(ids.map(JSONValue.string)), pretty: false)
        return try await send(
            IPCMethod.configSet, .object(["key": .string("calendars"), "value": .string(value)]), context)
    }

    /// Все команды app, кроме status и stop, поднимают app, если сокет мёртв (§9.3).
    private static func send(
        _ method: String, _ params: JSONValue, _ context: CLIContext, timeout: TimeInterval = defaultTimeout
    ) async throws(EarmarkError) -> JSONValue {
        try await context.ipc.call(method, params: params, autoLaunch: true, timeout: timeout)
    }
}
