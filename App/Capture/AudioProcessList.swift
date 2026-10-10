// Copyright (c) 2026 Andrew Jones
// Copyright (c) 2026 Samat Galimov
// SPDX-License-Identifier: MIT
// Портировано из gsamat/amanu@fbccc13: Sources/amanu/Audio/AudioProcesses.swift (MIT).
import CoreAudio
import Foundation

/// Обёртки HAL над списком аудио-процессов. Читаются без TCC и без старта IO (замер на 27.0.1).
enum AudioProcessList {
    struct Client: Equatable, Sendable {
        let pid: pid_t
        /// Пустая строка у процессов без бандла (CLI-утилиты, часть демонов).
        let bundleID: String
        let isRunningInput: Bool
        /// Устройства, на которых процесс ведёт input, как их отдаёт HAL. У corespeechd пусто при
        /// IsRunningInput = 1.
        let inputDevices: [AudioObjectID]
    }

    /// Все HAL-клиенты, включая нас самих: отсеивает вызывающий (CallApps.isCallActivity).
    static func clients() -> [Client] {
        let processes = objects(
            AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
        return processes.compactMap { object in
            guard let pid = uint32(object, kAudioProcessPropertyPID) else { return nil }
            let inputs = objects(object, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput)
            return Client(
                pid: pid_t(bitPattern: pid), bundleID: string(object, kAudioProcessPropertyBundleID) ?? "",
                isRunningInput: uint32(object, kAudioProcessPropertyIsRunningInput) == 1,
                inputDevices: inputs)
        }
    }

    /// Наш process object — его исключает глобальный tap. nil, пока процесс не стал HAL-клиентом:
    /// TranslatePIDToProcessObject отдаёт kAudioObjectUnknown (тогда tap пишет и наш звук — earmark
    /// во время записи ничего не играет, так что это безвредно).
    static func ownProcessObject() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size,
            &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    /// Текущий default input; nil, если входов нет вовсе.
    static func defaultInputDevice() -> AudioObjectID? {
        uint32(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice)
            .flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
    }

    /// Микрофоны, которые можно записать, из устройств процесса. Голосовая обработка (VPIO) отдаёт приватный
    /// агрегат — раскрываем его до активных под-устройств. Выход в списке бывает (duplex), но без входных
    /// стримов он не микрофон. Порядок сохраняется, дубли убираются.
    static func recordableInputs(_ devices: [AudioObjectID]) -> [AudioObjectID] {
        var seen = Set<AudioObjectID>()
        return devices.flatMap { device in
            uint32(device, kAudioObjectPropertyClass) == kAudioAggregateDeviceClassID
                ? objects(device, kAudioAggregateDevicePropertyActiveSubDeviceList) : [device]
        }
        .filter { device in
            !objects(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput).isEmpty
                && seen.insert(device).inserted
        }
    }

    /// Имя устройства для логов.
    static func deviceName(_ device: AudioObjectID) -> String? {
        string(device, kAudioObjectPropertyName)
    }

    private static func objects(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    /// CFString по правилу create: строка приходит retained, отпускает её takeRetainedValue.
    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else {
            return nil
        }
        let string = value.takeRetainedValue() as String
        return string.isEmpty ? nil : string
    }
}
