import EarmarkCore
import EarmarkTranscription
import Foundation

/// Точка входа CLI. Вся логика здесь, а не в CLI/main.swift, чтобы её проверял `swift test`.
public enum EarmarkCLI {
    /// argv без имени бинаря → exit code. Каркас: команд пока нет, есть только `help`.
    public static func run(_ argv: [String]) async -> Int32 {
        // Спайк S2 (Task 3): скрытая команда до разбора таблицы команд. Task 18 переписывает run()
        // уже без неё: S2 к тому времени закрыт.
        if argv.first == "_whisper-probe" {
            return WhisperProbe.run(Array(argv.dropFirst()))
        }
        if argv.isEmpty || argv == ["help"] {
            let data: [String: Any] = ["version": EarmarkVersion.current]
            emit(["schema_version": 1, "command": "help", "data": data], to: .standardOutput)
            return 0
        }
        // Конверт ошибки §9.3 — в stderr и с кодом 64: агент отличает «не так позвал» от сбоя.
        let error: [String: Any] = [
            "code": "invalid_arguments",
            "message": "unknown command: \(argv.joined(separator: " "))",
            "exit_code": 64,
        ]
        emit(["schema_version": 1, "error": error], to: .standardError)
        return 64
    }

    private static func emit(_ object: [String: Any], to handle: FileHandle) {
        // JSONSerialization, а не интерполяция: аргументы приходят от агента, и кавычка в них
        // сломала бы JSON. sortedKeys — вывод стабилен и сравним в тестах.
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return
        }
        handle.write(data + Data("\n".utf8))
    }
}
