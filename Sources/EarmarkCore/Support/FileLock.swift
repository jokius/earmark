import Foundation
import Synchronization

/// flock(LOCK_EX|LOCK_NB) на файле, открытом с O_CLOEXEC. Ядро снимает lock при смерти владельца.
///
/// Поэтому протухшую задачу видно без pid-файлов: lock свободен — владельца нет. O_CLOEXEC — чтобы
/// дочерний процесс (воркер транскрипции, `open`) не унаследовал descriptor и не держал lock за нас.
/// Файл lock'а никогда не удаляем: unlink при живом владельце дал бы следующему процессу новый
/// «свободный» файл рядом с занятым.
///
/// Блокирующего захвата нет намеренно: чужая загрузка модели идёт минутами, а держать столько поток
/// кооперативного пула нельзя. Кто ждёт, опрашивает tryAcquire с паузой (Task 21).
///
/// Только что отпущенный lock может долю миллисекунды казаться занятым: если соседний поток этого
/// процесса в этот момент порождает процесс, ядро копирует дескрипторы в ребёнка до exec, даже
/// с O_CLOEXEC (воспроизведено замером). Поэтому nil из tryAcquire — «занято сейчас, повтори позже»,
/// а не ошибка.
public final class FileLock: @unchecked Sendable {
    // Mutex — чтобы явный release() и deinit с разных потоков не закрыли fd дважды:
    // номер к тому времени мог достаться чужому файлу.
    private let descriptor: Mutex<Int32>

    private init(descriptor: Int32) {
        self.descriptor = Mutex(descriptor)
    }

    deinit { release() }

    /// nil, если lock уже держит кто-то другой.
    public static func tryAcquire(at url: URL) throws -> FileLock? {
        let fd = try openLockFile(url)
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { return FileLock(descriptor: fd) }
        let code = errno
        close(fd)
        if code == EWOULDBLOCK { return nil }
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    /// Закрытие fd снимает flock: lock принадлежит открытому описанию файла. Повторный вызов — no-op.
    public func release() {
        descriptor.withLock { fd in
            guard fd >= 0 else { return }
            close(fd)
            fd = -1
        }
    }

    private static func openLockFile(_ url: URL) throws -> Int32 {
        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return fd
    }
}
