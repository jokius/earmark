import Foundation

extension RecordingMeta {
    /// Ручная запись вне событий календаря, остановленная не восстановлением: app спрашивает проект.
    /// Восстановленную после сбоя не спрашиваем: со звонка давно ушли, и вопрос из ниоткуда
    /// при старте app только сбил бы с толку.
    public var needsProject: Bool {
        trigger == .manual && calendar == nil && event == nil && stopReason != .recovered
    }
}

extension RecordingStore {
    /// Кладёт законченную ручную запись под календарь или обратно в Manual.
    /// calendar и folder либо оба nil (Manual), либо оба заданы (folder — имя папки календаря,
    /// как его считает calendarFolderName). Возвращает папку на новом месте с новой meta.
    ///
    /// Всё — под .transcribe.lock: воркер, стартующий одновременно, получит busy, а не папку,
    /// уехавшую посреди расшифровки. Транскрипты не переделываются — это `transcribe --force`.
    public func move(id: String, to calendar: CalendarRef?, folder: String?)
        throws(EarmarkError) -> RecordingFolder
    {
        guard (calendar == nil) == (folder == nil) else {
            throw .invalidArguments("calendar and folder go together: pass both or neither")
        }
        let (found, stale) = try movable(id)
        let parent = root.appendingPathComponent(
            Self.sanitize(folder ?? RecordingFiles.manualFolder), isDirectory: true)
        // Без учёта регистра, как APFS: «work» и «Work» — одна папка, переезжать некуда.
        let sameParent =
            found.url.deletingLastPathComponent().lastPathComponent
            .compare(parent.lastPathComponent, options: .caseInsensitive) == .orderedSame
        // Идемпотентно и до lock'а: повтор того же ответа не создаёт даже файла lock'а.
        if sameParent && stale.calendar == calendar { return found }

        let lock: FileLock?
        do {
            lock = try FileLock.tryAcquire(
                at: found.url.appendingPathComponent(RecordingFiles.transcribeLock))
        } catch {
            throw .operationFailed("\(RecordingFiles.transcribeLock): \(error.localizedDescription)")
        }
        guard let lock else {
            throw .busy("recording \(id) is being transcribed; move it when transcription finishes")
        }
        defer { lock.release() }
        // Снимок find мог устареть, пока брали lock: воркер, которого app не ведёт (ручной
        // `earmark transcribe <id> --now`), успел дописать status и transcription. Записав снимок
        // обратно, move стёр бы расшифровку. Поэтому проверки, новая meta и откат — по meta,
        // прочитанной уже под lock'ом.
        let current: RecordingFolder
        do {
            current = RecordingFolder(
                url: found.url, meta: try readMeta(in: found.url), manifest: try readManifest(in: found.url))
        } catch {
            throw .operationFailed("cannot read recording \(id): \(error.localizedDescription)")
        }
        let meta = try Self.movableMeta(current, id: id)
        if sameParent && meta.calendar == calendar { return current }
        var moved = meta
        moved.calendar = calendar
        let url = try relocate(found.url, from: meta, to: moved, into: sameParent ? nil : parent)
        return RecordingFolder(url: url, meta: moved, manifest: nil)
    }

    /// Запись по id, которую можно двигать, и её meta по снимку find.
    private func movable(_ id: String) throws(EarmarkError) -> (RecordingFolder, RecordingMeta) {
        let found: RecordingFolder?
        do {
            found = try find(id: id)
        } catch {
            throw .operationFailed("cannot read recordings: \(error.localizedDescription)")
        }
        guard let found else { throw .notFound("no recording \(id); take ids from `earmark recordings`") }
        return (found, try Self.movableMeta(found, id: id))
    }

    /// meta записи, которую можно двигать: законченной (meta есть, manifest нет), ручной, вне события.
    /// Дважды за move — по снимку find и по свежему чтению под lock'ом.
    private static func movableMeta(_ folder: RecordingFolder, id: String)
        throws(EarmarkError) -> RecordingMeta
    {
        // Пока есть manifest, запись идёт или ждёт восстановления: meta ещё перепишут.
        guard !folder.isRecording else { throw .busy("recording \(id) is still in progress") }
        guard let meta = folder.meta else { throw .badData("recording \(id) has no meta.json") }
        // Запись по событию уже лежит у своего календаря: переложить её — разойтись с событием.
        guard meta.trigger == .manual, meta.event == nil else {
            throw .invalidArguments("only manual recordings outside a calendar event can be moved")
        }
        return meta
    }

    /// Новая meta, потом папка в parent (nil — папка остаётся). Сбой второго шага откатывает первый:
    /// снаружи либо переехало всё, либо ничего. Порядок такой ради крэша между шагами: запись с верным
    /// календарём в старой папке найдёт `recordings --calendar`, а повтор move доделает переезд.
    private func relocate(_ dir: URL, from old: RecordingMeta, to new: RecordingMeta, into parent: URL?)
        throws(EarmarkError) -> URL
    {
        let id = new.id
        do {
            if let parent {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            }
            try writeMeta(new, in: dir)
        } catch {
            throw .operationFailed("cannot move \(id): \(error.localizedDescription)")
        }
        guard let parent else { return dir }
        do {
            return try Self.renameKeepingOthers(dir, into: parent)
        } catch {
            let reason = error.localizedDescription
            do {
                try writeMeta(old, in: dir)
            } catch {
                throw .operationFailed(
                    "cannot move \(id): \(reason); "
                        + "meta.json rollback failed too: \(error.localizedDescription)")
            }
            throw .operationFailed("cannot move \(id): \(reason)")
        }
    }

    /// rename(2) с RENAME_EXCL под тем же именем, занято — « (2)», « (3)»… как у createRecordingFolder.
    /// Голый rename молча заменил бы пустую чужую папку с тем же именем; EXCL решает это атомарно,
    /// без гонки «проверил — переименовал».
    ///
    /// exFAT RENAME_EXCL не умеет (ENOTSUP, проверено на образе), а без запасного пути move на внешний
    /// диск не работал бы вовсе. Там имя резервирует mkdir — он атомарен и на exFAT, — и rename(2)
    /// кладёт запись поверх этой своей пустой папки: пустой каталог rename заменяет атомарно, а в
    /// непустой (кто-то успел туда писать) не идёт — ENOTEMPTY, чужое не тронуто.
    private static func renameKeepingOthers(_ source: URL, into parent: URL) throws -> URL {
        func failure(_ code: Int32) -> POSIXError { POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
        let base = source.lastPathComponent
        var exclusive = true
        for attempt in 1...999 {
            let target = parent.appendingPathComponent(
                attempt == 1 ? base : "\(base) (\(attempt))", isDirectory: true)
            if exclusive {
                if renamex_np(source.path, target.path, UInt32(RENAME_EXCL)) == 0 { return target }
                let code = errno
                if code == EEXIST { continue }
                guard code == ENOTSUP else { throw failure(code) }
                // То же имя — уже через mkdir.
                exclusive = false
            }
            guard mkdir(target.path, 0o700) == 0 else {
                let code = errno
                if code == EEXIST { continue }
                throw failure(code)
            }
            guard rename(source.path, target.path) == 0 else {
                let code = errno
                rmdir(target.path)
                throw failure(code)
            }
            return target
        }
        throw POSIXError(.EEXIST)
    }
}
