import Foundation

/// App, поднятый хостом XCTest или Swift Testing, не должен запускать сервисы: у Call Reminder
/// тесты поднимали живой планировщик, а у рекордера это была бы настоящая запись рядом со встречей.
enum TestEnvironment {
    static let isRunningTests: Bool = {
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil {
            return true
        }
        // Хостовые тесты Swift Testing под Xcode идут через тот же раннер XCTest: класс уже загружен.
        return NSClassFromString("XCTestCase") != nil
    }()
}
