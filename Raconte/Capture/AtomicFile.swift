import Foundation

enum AtomicFileError: Error, Equatable {
    /// A POSIX call failed. `operation` names the syscall; `code` is errno.
    case posix(operation: String, code: Int32)
}

/// Atomic file replace (design §1 atomicity protocol): write `X.part`, `write()`,
/// `fsync(fd)`, `close`, `rename(X.part, X)`, then `fsync` the *directory* fd so
/// the rename itself is durable. POSIX `rename` within a volume is atomic, so a
/// reader/crash sees either the old file or the fully-written new one, never a
/// partial. Pure Foundation — no AVFoundation.
enum AtomicFile {
    /// Atomically replace the file at `url` with `data`.
    ///
    /// `beforeRename` is a test seam: it runs after the `.part` is written,
    /// fsync'd, and closed but before the rename. Throwing from it simulates a
    /// crash mid-replace, leaving the original untouched and a stray `.part`
    /// behind (exactly the on-disk situation recovery must tolerate).
    static func replace(at url: URL, writing data: Data,
                        beforeRename: (() throws -> Void)? = nil) throws {
        let partURL = SegmentLayout.partURL(for: url)
        let partPath = partURL.path
        let finalPath = url.path
        let dirPath = url.deletingLastPathComponent().path

        let fd = open(partPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw AtomicFileError.posix(operation: "open", code: errno) }

        do {
            try writeAll(fd: fd, data: data)
            guard fsync(fd) == 0 else { throw AtomicFileError.posix(operation: "fsync", code: errno) }
        } catch {
            close(fd)
            throw error
        }
        guard close(fd) == 0 else { throw AtomicFileError.posix(operation: "close", code: errno) }

        try beforeRename?()

        guard rename(partPath, finalPath) == 0 else {
            throw AtomicFileError.posix(operation: "rename", code: errno)
        }

        try fsyncDirectory(path: dirPath)
    }

    private static func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress, raw.count > 0 else { return }
            var offset = 0
            while offset < raw.count {
                let written = write(fd, base.advanced(by: offset), raw.count - offset)
                if written < 0 { throw AtomicFileError.posix(operation: "write", code: errno) }
                offset += written
            }
        }
    }

    /// fsync the directory so the rename entry is durable across a crash.
    private static func fsyncDirectory(path: String) throws {
        let dfd = open(path, O_RDONLY)
        guard dfd >= 0 else { throw AtomicFileError.posix(operation: "open(dir)", code: errno) }
        defer { close(dfd) }
        guard fsync(dfd) == 0 else { throw AtomicFileError.posix(operation: "fsync(dir)", code: errno) }
    }
}
