import CoreAudio
import EarmarkCore
import Foundation
import os

/// Раз в секунду: идёт ли созвон и как громко на обоих каналах → ActivitySample для StopRules.
///
/// Спрашиваем процессы, а не устройство: kAudioDevicePropertyDeviceIsRunningSomewhere держит в 1 наш
/// же захват, и созвон по нему не кончался бы никогда. Слушателям списка процессов не верим: они не
/// срабатывают, когда уже знакомый процесс начинает input (SystemAudioKit), — поэтому опрос.
final class CallActivityMonitor: @unchecked Sendable {
    private static let log = Logger(subsystem: "com.konayre.earmark", category: "calls")

    private let levels: @Sendable () -> (mic: Float, system: Float)
    private let callInputs: @Sendable ([AudioObjectID]) -> Void
    private let queue = DispatchQueue(label: "com.konayre.earmark.call-activity", qos: .utility)
    // Только на `queue`.
    private var timer: DispatchSourceTimer?
    /// Прошлое значение — чтобы писать в лог переходы, а не каждую секунду: по нему разбирают,
    /// почему авто-запись остановилась.
    private var wasActive = false

    /// `callInputs` зовётся на каждом опросе, на очереди монитора: микрофоны, которые держат звонилки
    /// (AudioProcessList.recordableInputs), — по ним MicRecorder идёт за микрофоном звонилки.
    init(
        levels: @escaping @Sendable () -> (mic: Float, system: Float),
        callInputs: @escaping @Sendable ([AudioObjectID]) -> Void
    ) {
        self.levels = levels
        self.callInputs = callInputs
    }

    func start(onSample: @escaping @MainActor (ActivitySample) -> Void) {
        queue.sync {
            timer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in
                guard let sample = self?.sample() else { return }
                Task { @MainActor in onSample(sample) }
            }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    private func sample() -> ActivitySample {
        let own = getpid()
        var apps: [String] = []
        var inputs: [AudioObjectID] = []
        var active = false
        for client in AudioProcessList.clients()
        where CallApps.isCallActivity(
            pid: client.pid, ownPID: own, bundleID: client.bundleID, isRunningInput: client.isRunningInput,
            inputDeviceCount: client.inputDevices.count)
        {
            active = true
            inputs += client.inputDevices
            // Незнакомое приложение — по bundle id; у процессов без бандла остаётся только pid.
            let name =
                CallApps.displayName(forBundleID: client.bundleID)
                ?? (client.bundleID.isEmpty ? "pid:\(client.pid)" : client.bundleID)
            if !apps.contains(name) { apps.append(name) }
        }
        callInputs(AudioProcessList.recordableInputs(inputs))
        if active != wasActive {
            wasActive = active
            let names = apps.joined(separator: ", ")
            Self.log.info(
                "call \(active ? "started" : "ended", privacy: .public): \(names, privacy: .public)")
        }
        let (mic, system) = levels()
        return ActivitySample(now: Date(), callActive: active, callApps: apps, micRMS: mic, systemRMS: system)
    }
}
