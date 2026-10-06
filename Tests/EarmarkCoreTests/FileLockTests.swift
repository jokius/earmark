import Foundation
import Testing

@testable import EarmarkCore

@Suite("FileLock: flock, который ядро снимает со смертью владельца")
struct FileLockTests {
    /// Свежий каталог на каждый тест: Swift Testing гоняет тесты параллельно.
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("earmark-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Сразу после release lock может мгновение числиться занятым: если другой тест этого процесса
    /// как раз порождает процесс, ядро копирует таблицу дескрипторов в ребёнка до exec — даже с
    /// O_CLOEXEC (замер: 8 из 20 000 повторных захватов при непрерывном posix_spawn, 0 без него).
    /// Контракт — «освобождается», а не «мгновенно», поэтому ждём до двух секунд.
    private func acquireSoon(_ url: URL) throws -> FileLock? {
        let deadline = Date().addingTimeInterval(2)
        repeat {
            if let lock = try FileLock.tryAcquire(at: url) { return lock }
            Thread.sleep(forTimeInterval: 0.01)
        } while Date() < deadline
        return nil
    }

    @Test("второй захват того же файла не проходит, пока первый держит lock; после release — проходит")
    func exclusiveUntilReleased() throws {
        let url = try makeTempDir().appendingPathComponent(".transcribe.lock")

        let first = try #require(try FileLock.tryAcquire(at: url))
        #expect(try FileLock.tryAcquire(at: url) == nil)

        first.release()
        first.release()  // повторный release — no-op, чужой fd не закрывает
        let second = try #require(try acquireSoon(url))
        second.release()
    }

    @Test("lock отпускается вместе с объектом")
    func deinitReleases() throws {
        let url = try makeTempDir().appendingPathComponent(".download.lock")

        var held: FileLock? = try FileLock.tryAcquire(at: url)
        #expect(held != nil)
        #expect(try FileLock.tryAcquire(at: url) == nil)

        held = nil  // последняя ссылка ушла — deinit закрыл fd
        #expect(try acquireSoon(url) != nil)
    }

    /// Чужой процесс держит flock и умирает от SIGKILL. Держателем выбран /usr/bin/perl: он есть
    /// в базовой macOS (/usr/bin/python3 — шим Command Line Tools, без них он предлагает установку),
    /// умеет flock(2) через Fcntl и печатает строку только после захвата — тест не гадает с таймингами.
    @Test("lock убитого процесса свободен: ядро снимает flock при смерти владельца")
    func killedHolderReleases() throws {
        let url = try makeTempDir().appendingPathComponent(".transcribe.lock")
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        holder.arguments = [
            "-e",
            #"use Fcntl qw(:flock); open(my $fh, ">>", $ARGV[0]) or die; flock($fh, LOCK_EX) or die; $| = 1; print "locked\n"; sleep 30;"#,
            url.path,
        ]
        let output = Pipe()
        holder.standardOutput = output
        try holder.run()
        defer { if holder.isRunning { holder.terminate() } }

        let line = output.fileHandleForReading.availableData
        try #require(String(bytes: line, encoding: .utf8)?.hasPrefix("locked") == true, "perl не взял lock")
        #expect(try FileLock.tryAcquire(at: url) == nil)

        kill(holder.processIdentifier, SIGKILL)
        holder.waitUntilExit()

        let lock = try #require(try FileLock.tryAcquire(at: url))
        lock.release()
    }
}
