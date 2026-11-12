@preconcurrency import AVFoundation
import EarmarkCore
import Foundation

/// Склейка записи с предыдущей (спека merge-and-fast-panel.md, п. 7): случайный стоп посреди звонка
/// и тут же новый старт — одна запись, будто стопа не было.
public enum RecordingMerger {
    /// Аудио `id` дописывается в конец `target`, папка `id` исчезает. Возвращает папку target с новой meta.
    ///
    /// Порядок: audio.partial.m4a → проверка длины → fsync и rename поверх audio.m4a target → unlink
    /// audio.m4a у id → транскрипты target → meta target → папка id. Сбой или крэш до rename не меняет
    /// ничего (крэш оставляет audio.partial.m4a, его убирает старт app). После rename звук не теряется:
    /// вторая часть уже в target. Сразу следом у id пропадает audio.m4a, и повтор склейки упирается в
    /// bad_data, а не дописывает вторую часть второй раз. Окно, где повтор её задвоит, — только сбой
    /// самого unlink или крэш между rename и им. Сбой дальше оставляет target со всем звуком, но со старыми транскриптами или meta,
    /// и папку id без звука — ошибка говорит, что именно не доделано.
    ///
    /// ponytail: сырые дорожки (audio.keep_raw_tracks) не склеиваются — mic.caf и system.caf второй
    /// части уходят вместе с её папкой, у target остаются только свои. Склеивать и CAF, если сырые
    /// дорожки понадобятся целиком.
    public static func merge(_ id: String, into target: String, store: RecordingStore)
        throws(EarmarkError) -> RecordingFolder
    {
        let source = try find(id, store)
        let destination = try find(target, store)
        _ = try finishedMeta(source, id: id)
        _ = try finishedMeta(destination, id: target)
        try checkOrder(source, destination, id: id, target: target)
        // На всё время склейки: воркер, стартующий одновременно, получит busy, а не звук без второй
        // части или папку, которая вот-вот исчезнет.
        let targetLock = try RecordingStore.lockRecording(destination.url, id: target, for: "merge")
        defer { targetLock.release() }
        let sourceLock = try RecordingStore.lockRecording(source.url, id: id, for: "merge")
        defer { sourceLock.release() }
        // Снимки find могли устареть, пока брали lock'и (ручной `transcribe --now` дописал meta).
        let current = try store.reload(source, id: id)
        let into = try store.reload(destination, id: target)
        let sourceMeta = try finishedMeta(current, id: id)
        let targetMeta = try finishedMeta(into, id: target)
        try checkOrder(current, into, id: id, target: target)

        let partial = into.url.appendingPathComponent(RecordingFiles.audioPartial)
        do {
            try concatenate(
                [into.url, current.url].map { $0.appendingPathComponent(RecordingFiles.audio) }, into: partial
            )
            try RecordingFinalizer.publishAudio(in: into.url)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            if case .unreadable? = error as? EarmarkAudioError {
                throw .badData("cannot merge \(id) into \(target): \(error.localizedDescription)")
            }
            throw .operationFailed("cannot merge \(id) into \(target): \(error.localizedDescription)")
        }

        // Звук id теперь в target: без своего audio.m4a id больше не склеить (bad_data), и повтор после
        // сбоя ниже не задвоит вторую часть.
        guard unlink(current.url.appendingPathComponent(RecordingFiles.audio).path) == 0 else {
            let reason = String(cString: strerror(errno))
            throw .operationFailed(
                "\(target) has the audio of \(id) appended, but audio.m4a of \(id) was not removed "
                    + "(do not merge \(id) again): \(reason)")
        }
        // Обязательно и до meta: Transcriber берёт готовый канал, если совпали модель и язык, и вторая
        // часть звука молча осталась бы без текста.
        for name in [
            RecordingFiles.transcriptMic, RecordingFiles.transcriptSystem, RecordingFiles.transcript,
            RecordingFiles.transcriptText,
        ] {
            guard unlink(into.url.appendingPathComponent(name).path) == 0 || errno == ENOENT else {
                let reason = String(cString: strerror(errno))
                throw .operationFailed(
                    "\(target) has the audio of \(id) appended, but its \(name) was not removed: \(reason)")
            }
        }
        let merged = mergedMeta(targetMeta, sourceMeta)
        do {
            try store.writeMeta(merged, in: into.url)
        } catch {
            throw .operationFailed(
                "\(target) has the audio of \(id) appended, but its meta.json was not updated: "
                    + error.localizedDescription)
        }
        do {
            try FileManager.default.removeItem(at: current.url)
        } catch {
            throw .operationFailed(
                "\(id) is merged into \(target), but its folder was not removed: \(error.localizedDescription)"
            )
        }
        return RecordingFolder(url: into.url, meta: merged, manifest: nil)
    }

    /// meta target после склейки: конец и причина стопа — от второй части, звонилки — обеих, расшифровка
    /// заново. Остальное (id, название, календарь, событие, старт, audio) — от target.
    private static func mergedMeta(_ target: RecordingMeta, _ source: RecordingMeta) -> RecordingMeta {
        var merged = target
        merged.endedAt = source.endedAt
        // Длина звука, без паузы между частями: тишину не вставляем.
        merged.durationSec = (target.durationSec ?? 0) + (source.durationSec ?? 0)
        merged.stopReason = source.stopReason
        var seen = Set<String>()
        merged.callApps = (target.callApps + source.callApps).filter { seen.insert($0).inserted }
        merged.recovered = target.recovered || source.recovered
        merged.status = .recorded
        merged.transcription = .init()
        return merged
    }

    private static func find(_ id: String, _ store: RecordingStore) throws(EarmarkError) -> RecordingFolder {
        let found: RecordingFolder?
        do {
            found = try store.find(id: id)
        } catch {
            throw .operationFailed("cannot read recordings: \(error.localizedDescription)")
        }
        guard let found else { throw .notFound("no recording \(id); take ids from `earmark recordings`") }
        return found
    }

    /// meta законченной записи со звуком: manifest — busy (идёт или ждёт восстановления), без звука — bad_data.
    private static func finishedMeta(_ folder: RecordingFolder, id: String) throws(EarmarkError)
        -> RecordingMeta
    {
        guard !folder.isRecording else { throw .busy("recording \(id) is still in progress") }
        guard let meta = folder.meta else { throw .badData("recording \(id) has no meta.json") }
        guard meta.audio != nil, folder.isComplete else { throw .badData("recording \(id) has no audio.m4a") }
        return meta
    }

    /// Склеиваем только в начатую строго раньше: иначе звонки в одном файле шли бы не по порядку.
    private static func checkOrder(
        _ source: RecordingFolder, _ target: RecordingFolder, id: String, target targetID: String
    ) throws(EarmarkError) {
        guard id != targetID, let start = source.meta?.startedAt, let targetStart = target.meta?.startedAt,
            targetStart < start
        else {
            throw .invalidArguments(
                "recording \(id) can be appended only to a recording that started before it, not to \(targetID)"
            )
        }
    }

    /// inputs подряд, без тишины между ними (тишина провоцирует галлюцинации whisper), → output в формате
    /// StereoMuxer. Потоково, блоками по секунде: в памяти не больше блока, сколько бы ни шёл созвон.
    private static func concatenate(_ inputs: [URL], into output: URL) throws {
        func name(_ url: URL) -> String {
            url.deletingLastPathComponent().lastPathComponent + "/" + url.lastPathComponent
        }
        let readers = try inputs.map { url in
            do {
                return try AVAudioFile(forReading: url)
            } catch {
                throw EarmarkAudioError.unreadable(name(url))
            }
        }
        let file = try StereoMuxer.makeOutput(output)
        let block = try StereoMuxer.makeBlock(for: file)
        var total: Int64 = 0
        for (url, reader) in zip(inputs, readers) {
            // Чужой формат AVAudioFile.read не конвертирует, а бросает исключение Objective-C.
            guard reader.processingFormat == file.processingFormat else {
                throw EarmarkAudioError.unreadable(name(url))
            }
            // Конец решает framePosition: чтение ровно на EOF — не «ноль кадров», а ошибка.
            while reader.framePosition < reader.length {
                try reader.read(into: block, frameCount: StereoMuxer.blockFrames)
                guard block.frameLength > 0 else { break }
                try file.write(from: block)
            }
            total += reader.length
        }
        // close() дописывает moov: без него m4a нечитаем.
        file.close()
        try StereoMuxer.verifyLength(of: output, expected: total)
    }
}
