// Copyright (c) 2026 Andrew Jones
// Copyright (c) 2026 Samat Galimov
// Портировано из amanu@fbccc13: Sources/amanu/RecordingSession.swift (durableWrite), MIT
import Foundation

/// Запись файла целиком или никак.
///
/// meta.json, config.json и транскрипты читают в любой момент: CLI, агент, скрипты пользователя.
/// Половинчатый JSON для них хуже старого, поэтому: temp в той же папке (rename атомарен только
/// в пределах тома) → F_FULLFSYNC (иначе после потери питания rename переживёт данные и останется
/// пустой файл) → rename(2) поверх цели.
public enum AtomicFile {
    /// temp в той же папке → F_FULLFSYNC (или fsync, где его нет) → rename(2). Права файла 0600.
    public static func write(_ data: Data, to url: URL) throws {
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        // 0600 сразу при создании, а не chmod потом: иначе в промежутке транскрипт читаем всем
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            // fsync на macOS доводит данные только до диска, а не через его кэш — после потери
            // питания файл всё равно может оказаться пустым. F_FULLFSYNC сбрасывает и кэш;
            // ФС без его поддержки (SMB, часть внешних дисков) отвечают ошибкой — тогда fsync.
            guard fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try handle.close()
            guard Darwin.rename(temp.path, url.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            // цель не тронута: rename либо не случился, либо упал целиком
            try? handle.close()
            unlink(temp.path)
            throw error
        }
    }
}
