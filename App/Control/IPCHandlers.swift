import EarmarkCore
import os

/// IPC-метод → действие AppModel (§9.2). Параметры — snake_case-ключи объекта `params`:
///
/// | метод | params | data ответа |
/// |---|---|---|
/// | status | — | StatusData |
/// | recording.start | `title?` | CurrentRecordingInfo |
/// | recording.stop | — | RecordingMeta или null (discard) |
/// | calendar.list | — | [CalendarListItem] |
/// | calendar.upcoming | `hours?` (1…168, по умолчанию 24) | [UpcomingItem] |
/// | config.set | `key`, `value` (строка, как из CLI) | `{key, old, new}` |
/// | config.reset | `key` или `all: true` | `{key, old, new}` или `{all: true}` |
/// | transcription.enqueue | `id`, `force?` | `{queued, position}` |
/// | doctor | `audio_test?` | DoctorReport |
/// | permissions.request | — | PermissionsInfo |
/// | audio.test | — | DoctorCheck |
///
/// Неизвестный метод — invalid_arguments; метод, которого app пока не умеет, — unavailable.
@MainActor
enum IPCHandlers {
    private static let logger = Logger(subsystem: EarmarkPaths.bundleID, category: "ipc")

    static func handle(_ request: IPCRequest, peer: pid_t, model: AppModel) async -> IPCResponse {
        // Старт и стоп записи из CLI или агента — действия с последствиями для приватности:
        // кто попросил, остаётся в журнале (§9.2).
        if request.method == IPCMethod.recordingStart || request.method == IPCMethod.recordingStop {
            logger.notice("\(request.method, privacy: .public) from pid \(peer, privacy: .public)")
        }
        do {
            return .success(try await dispatch(request.method, request.params, model: model))
        } catch {
            return .failure(error)
        }
    }

    // Плоская таблица методов: switch читается проще словаря замыканий, отсюда и «сложность».
    // swiftlint:disable:next cyclomatic_complexity
    private static func dispatch(_ method: String, _ params: JSONValue, model: AppModel)
        async throws(EarmarkError) -> JSONValue
    {
        switch method {
        case IPCMethod.status:
            return try encode(model.status())
        case IPCMethod.recordingStart:
            return try encode(try model.startManual(title: params["title"]?.stringValue))
        case IPCMethod.recordingStop:
            return try encode(try await model.stopRecording())
        case IPCMethod.calendarList:
            return try encode(model.calendarsList())
        case IPCMethod.calendarUpcoming:
            return try encode(model.upcoming(hours: try hours(params)))
        case IPCMethod.configSet:
            return try model.setConfig(try string(params, "key"), raw: try string(params, "value"))
        case IPCMethod.configReset:
            // Сброс всего — только явным all: true: пустые params от сломанного клиента не должны
            // стирать настройки.
            if params["all"]?.boolValue == true { return try model.resetConfig(nil) }
            return try model.resetConfig(try string(params, "key"))
        case IPCMethod.transcriptionEnqueue:
            throw EarmarkError.unavailable("transcription queue is not available yet")
        case IPCMethod.doctor:
            return try encode(await model.doctor(audioTest: params["audio_test"]?.boolValue ?? false))
        case IPCMethod.permissionsRequest:
            return try encode(await model.requestPermissions())
        case IPCMethod.audioTest:
            return try encode(try await model.audioTest())
        default:
            throw EarmarkError.invalidArguments("unknown method: \(method)")
        }
    }

    private static func string(_ params: JSONValue, _ key: String) throws(EarmarkError) -> String {
        guard let value = params[key]?.stringValue else {
            throw EarmarkError.invalidArguments("missing string param \"\(key)\"")
        }
        return value
    }

    private static func hours(_ params: JSONValue) throws(EarmarkError) -> Int {
        guard let raw = params["hours"], raw != .null else { return 24 }
        guard let hours = raw.intValue, (1...168).contains(hours) else {
            throw EarmarkError.invalidArguments("hours must be an integer in 1…168")
        }
        return hours
    }

    private static func encode<T: Encodable>(_ value: T) throws(EarmarkError) -> JSONValue {
        do {
            return try JSONValue(encoding: value)
        } catch {
            throw EarmarkError.operationFailed("cannot encode response: \(error.localizedDescription)")
        }
    }
}
