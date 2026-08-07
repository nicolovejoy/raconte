import Foundation

enum StagedRemovalError: Error, Equatable {
    /// Nothing at `captures/<id>/` to stage.
    case captureDirectoryMissing
    /// A POSIX call failed. Mirrors `AtomicFileError.posix` deliberately rather than
    /// reusing it: that type is about replacing a file, this is about moving a tree.
    case posix(operation: String, code: Int32)
}

struct StagedPurgeResult: Sendable, Equatable {
    var removed: [String] = []
    var failed: [String] = []
    var isEmpty: Bool { removed.isEmpty && failed.isEmpty }
}

/// Stage-then-purge deletion (#25): atomically `rename(2)` a capture directory out of
/// `captures/` into `<container>/trash-pending/`, then remove staged directories at
/// leisure. The rename is the one-way door — once it lands the entry is gone from every
/// scanned tree and cannot be recovered by any in-app path — and it is atomic within a
/// volume, so a mid-walk failure (the shape of #25) cannot happen: either the whole
/// directory moved, or nothing did.
struct StagedRemover: Sendable {
    let capturesRoot: URL
    let containerRoot: URL
    var mintStagingID: @Sendable () -> String = { ULID.make() }

    init(capturesRoot: URL, containerRoot: URL? = nil,
         mintStagingID: @escaping @Sendable () -> String = { ULID.make() }) {
        self.capturesRoot = capturesRoot
        self.containerRoot = containerRoot ?? AppContainer.containerRoot(capturesRoot: capturesRoot)
        self.mintStagingID = mintStagingID
    }

    /// Atomically move `captures/<captureID>/` out of every scanned tree. Returns the
    /// staged directory's name. After this returns the entry is gone from the library and
    /// cannot be recovered by any in-app path — the one-way door, and the correct
    /// semantics for both "Delete Now" and the 30-day sweep.
    func stage(captureID: String) throws -> String {
        let fm = FileManager.default
        let source = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw StagedRemovalError.captureDirectoryMissing
        }

        let stagingRoot = AppContainer.trashPendingRoot(containerRoot: containerRoot)
        try fm.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        // A backup hint must never block a deletion.
        var stagingRootForResourceValues = stagingRoot
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? stagingRootForResourceValues.setResourceValues(values)

        let name = "\(mintStagingID())-\(captureID)"
        let destination = AppContainer.trashPendingURL(containerRoot: containerRoot, name: name)

        guard rename(source.path, destination.path) == 0 else {
            throw StagedRemovalError.posix(operation: "rename", code: errno)
        }
        return name
    }

    /// Remove everything in `trash-pending/`. Best effort: a child that will not delete is
    /// reported and left for the next launch. An absent staging root is an empty success —
    /// that is a fresh install, not a failure.
    func purge() -> StagedPurgeResult {
        var result = StagedPurgeResult()
        let fm = FileManager.default
        let stagingRoot = AppContainer.trashPendingRoot(containerRoot: containerRoot)
        guard let names = try? fm.contentsOfDirectory(atPath: stagingRoot.path) else {
            return result
        }
        for name in names.sorted() {
            let url = stagingRoot.appendingPathComponent(name, isDirectory: true)
            do {
                try fm.removeItem(at: url)
                result.removed.append(name)
            } catch {
                result.failed.append(name)
            }
        }
        return result
    }
}
