import Darwin
import Foundation

public enum InstanceLockError: Error { case alreadyRunning, unsafeFile, system(Int32) }

/// Held before the live ledger/sampler is created, across all copies of the app.
/// Never unlink a held lock: a second inode would permit a second owner.
public final class SingleInstanceLock {
    private let descriptor: Int32
    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let fd = Darwin.open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw InstanceLockError.system(errno) }
        var valid = false
        defer { if !valid { Darwin.close(fd) } }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), (info.st_mode & S_IFMT) == S_IFREG else {
            throw InstanceLockError.unsafeFile
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { throw InstanceLockError.alreadyRunning }
            throw InstanceLockError.system(errno)
        }
        guard fchmod(fd, 0o600) == 0 else { throw InstanceLockError.system(errno) }
        descriptor = fd
        valid = true
    }
    deinit { Darwin.close(descriptor) }
}
