// Copyright (c) 2026 Andrew Jones
// Copyright (c) 2026 Samat Galimov
// Портировано из gsamat/amanu@fbccc13: Sources/amanu/RecordingSession.swift (MIT) — порядок
// «meta.json последним, manifest — после него» (stop L221-292) и восстановление по mtime треков
// (recoverInterrupted L421-539).
import EarmarkCore
import Foundation

/// Файловая часть конца записи: закрытые CAF → audio.m4a → meta.json. Без TCC и железа, поэтому
/// проверяется `swift test` на синтетических CAF.
///
/// Порядок — контракт для потребителей: `audio.m4a` появляется только через rename (половинчатого не
/// бывает), `meta.json` пишется после него, manifest удаляется последним из «служебного». Упади
/// процесс на любом шаге — manifest остаётся, и `recover` при следующем старте доделает работу.
public enum RecordingFinalizer {
    /// Закрытые CAF → audio.partial.m4a → rename audio.m4a → meta.json (status .recorded) → удалить
    /// manifest → удалить CAF (если !keepRawTracks). Если StopRules.shouldDiscard — удалить папку
    /// целиком и вернуть nil. В обоих треках ни кадра — meta без audio со статусом ошибки.
    public static func finalize(  // swiftlint:disable:this function_parameter_count
        folder: URL, manifest: RecordingManifest, stopReason: StopReason, endedAt: Date,
        micOffsetMs: Int, callApps: [String], keepRawTracks: Bool, stop: StopConfig,
        store: RecordingStore
    ) throws -> RecordingMeta? {
        let duration = endedAt.timeIntervalSince(manifest.startedAt)
        if StopRules.shouldDiscard(trigger: manifest.trigger, duration: duration, config: stop) {
            try FileManager.default.removeItem(at: folder)
            return nil
        }
        var meta = baseMeta(manifest, endedAt: endedAt, stopReason: stopReason, callApps: callApps)
        do {
            meta.audio = try muxTracks(in: folder, micOffsetMs: micOffsetMs)
        } catch EarmarkAudioError.noAudio {
            markNoAudio(&meta)
        }
        try store.writeMeta(meta, in: folder)
        try store.removeManifest(in: folder)
        if meta.audio != nil, !keepRawTracks { removeTracks(in: folder) }
        return meta
    }

    /// Прерванная запись (manifest есть, pid мёртв): свести то, что есть в CAF; recovered = true,
    /// stopReason = .recovered, endedAt = mtime самого свежего CAF. Нет ни одного CAF с данными — meta с
    /// ошибкой, без audio. Не сводится вовсе — тоже meta с ошибкой, CAF остаются: иначе каждый запуск
    /// упирался бы в ту же папку снова.
    public static func recover(
        folder: URL, manifest: RecordingManifest, keepRawTracks: Bool, store: RecordingStore
    ) throws -> RecordingMeta {
        // Чистый стоп успел записать meta.json, но не удалить manifest — доделываем только уборку.
        if let finished = try store.readMeta(in: folder) {
            try store.removeManifest(in: folder)
            return finished
        }
        let tracks = [RecordingFiles.mic, RecordingFiles.system].map { folder.appendingPathComponent($0) }
        let endedAt =
            tracks.compactMap {
                try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            }
            .max() ?? manifest.startedAt
        var meta = baseMeta(
            manifest, endedAt: max(endedAt, manifest.startedAt), stopReason: .recovered, callApps: [])
        meta.recovered = true
        do {
            // Смещение mic в manifest не хранится; каналы стартуют в одном вызове, расхождение — десятки мс.
            meta.audio = try muxTracks(in: folder, micOffsetMs: 0)
        } catch EarmarkAudioError.noAudio {
            markNoAudio(&meta)
        } catch {
            meta.status = .transcriptionFailed
            meta.transcription.errorKind = "permanent"
            meta.transcription.error = "mux_failed: \(error.localizedDescription)"
        }
        try store.writeMeta(meta, in: folder)
        try store.removeManifest(in: folder)
        if meta.audio != nil, !keepRawTracks { removeTracks(in: folder) }
        return meta
    }

    private static func baseMeta(
        _ manifest: RecordingManifest, endedAt: Date, stopReason: StopReason, callApps: [String]
    ) -> RecordingMeta {
        RecordingMeta(
            id: manifest.id, status: .recorded, trigger: manifest.trigger, title: manifest.title,
            calendar: manifest.calendar, event: manifest.event, startedAt: manifest.startedAt,
            endedAt: endedAt, durationSec: endedAt.timeIntervalSince(manifest.startedAt),
            stopReason: stopReason, callApps: callApps, appVersion: manifest.appVersion)
    }

    /// Без аудио расшифровывать нечего: сразу конечный статус, чтобы очередь не тратила на папку
    /// три попытки с exit 65.
    private static func markNoAudio(_ meta: inout RecordingMeta) {
        meta.status = .transcriptionFailed
        meta.transcription.errorKind = "permanent"
        meta.transcription.error = "no_audio: \(EarmarkAudioError.noAudio.localizedDescription)"
    }

    /// audio.partial.m4a → rename(2) в audio.m4a: rename атомарно заменяет остаток прошлой попытки.
    private static func muxTracks(in folder: URL, micOffsetMs: Int) throws -> AudioInfo {
        let partial = folder.appendingPathComponent(RecordingFiles.audioPartial)
        let audio = folder.appendingPathComponent(RecordingFiles.audio)
        let info = try StereoMuxer.mux(
            mic: folder.appendingPathComponent(RecordingFiles.mic),
            system: folder.appendingPathComponent(RecordingFiles.system), micOffsetMs: micOffsetMs,
            output: partial)
        // F_FULLFSYNC до rename, как в AtomicFile: следом удаляются CAF, и после потери питания rename
        // пережил бы данные — audio.m4a с дырой, второй копии нет. ФС без его поддержки — fsync.
        let fd = open(partial.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else {
            throw EarmarkAudioError.osStatus(operation: "open audio.partial.m4a", status: errno)
        }
        defer { close(fd) }
        guard fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0 else {
            throw EarmarkAudioError.osStatus(operation: "fsync audio.partial.m4a", status: errno)
        }
        guard rename(partial.path, audio.path) == 0 else {
            throw EarmarkAudioError.osStatus(operation: "rename audio.partial.m4a", status: errno)
        }
        return info
    }

    private static func removeTracks(in folder: URL) {
        for name in [RecordingFiles.mic, RecordingFiles.system] {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}
