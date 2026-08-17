import Foundation

/// Where the app's on-disk state lives, in one place.
///
/// `captures/` is the capture machine's tree and is hardened by the recovery suite;
/// everything M3 adds that is *not* about a single capture (the journals registry today)
/// sits **beside** it under the same container root, never inside a capture directory and
/// never inside `captures/` — a stray non-ULID child of `captures/` would be walked by
/// `DirectorySnapshot.gather` and handed to the recovery planner.
///
///     <Application Support>/Raconte/
///       captures/<ULID>/…      capture machine territory
///       journals.json          journals registry (M3 T1)
///       journals/<ULID>/cover.jpg   journal cover image, optional (issue #14 part 3)
///       trash-pending/<name>/  staged-removal holding pen (#25)
///       sync/                  sync bookkeeping cache, disposable (M4 T2)
enum AppContainer {
    static let directoryName = "Raconte"
    static let capturesDirectoryName = "captures"
    static let journalsFileName = "journals.json"
    /// Not the same name as `journalsFileName` — a directory named `journals` sitting
    /// beside a file named `journals.json` is deliberate; `capturesDirectoryName`
    /// establishes that a scan only walks `captures/`, so this tree is invisible to
    /// `DirectorySnapshot.gather` regardless of what it's called.
    static let journalCoversDirectoryName = "journals"
    static let journalCoverFileName = "cover.jpg"
    /// Where a capture directory waits between its atomic rename out of `captures/` and its
    /// actual removal (#25). A sibling of `captures/`, never inside it, for the reason this
    /// type's header already gives: a stray child of `captures/` is walked by
    /// `DirectorySnapshot.gather` and handed to the recovery planner. A staged directory
    /// still holds `final/recording.m4a`, so being unreachable by that walk is what keeps
    /// the quarantine rule from adopting it forever.
    static let trashPendingDirectoryName = "trash-pending"
    /// M4: root of the sync engine's on-disk bookkeeping (`SyncBookkeepingStore`) — a
    /// sibling of `captures/`, never inside it, for the reason this type's header
    /// already gives: a stray child of `captures/` is walked by `DirectorySnapshot.gather`
    /// and handed to the recovery planner. Unlike every other sibling here, this whole
    /// directory is a disposable cache (CKSyncEngine state, per-record system fields, an
    /// upload dedupe ledger) — losing it costs a resync against CloudKit, never data, so
    /// its interior layout is owned by `SyncBookkeepingStore`, not spelled out here.
    static let syncDirectoryName = "sync"

    /// Application Support/Raconte, created on demand. Falls back to the temporary
    /// directory if Application Support is unavailable, matching the pre-existing
    /// capture-root behaviour (losing recordings to a throw at launch is worse).
    static func root() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true)) ?? fm.temporaryDirectory
        let root = base.appendingPathComponent(directoryName, isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func capturesRoot() -> URL {
        let root = capturesRoot(containerRoot: root())
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // Pure path math, so tests can point the whole layout at a temp directory.

    static func capturesRoot(containerRoot: URL) -> URL {
        containerRoot.appendingPathComponent(capturesDirectoryName, isDirectory: true)
    }

    static func journalsURL(containerRoot: URL) -> URL {
        containerRoot.appendingPathComponent(journalsFileName)
    }

    static func journalCoverURL(containerRoot: URL, journalID: String) -> URL {
        containerRoot
            .appendingPathComponent(journalCoversDirectoryName, isDirectory: true)
            .appendingPathComponent(journalID, isDirectory: true)
            .appendingPathComponent(journalCoverFileName)
    }

    static func trashPendingRoot(containerRoot: URL) -> URL {
        containerRoot.appendingPathComponent(trashPendingDirectoryName, isDirectory: true)
    }

    static func trashPendingURL(containerRoot: URL, name: String) -> URL {
        trashPendingRoot(containerRoot: containerRoot).appendingPathComponent(name, isDirectory: true)
    }

    static func syncRoot(containerRoot: URL) -> URL {
        containerRoot.appendingPathComponent(syncDirectoryName, isDirectory: true)
    }

    /// The container root inferred from a captures root — the inverse of
    /// `capturesRoot(containerRoot:)`. Lets a type that was handed only `capturesRoot`
    /// (everything in M1/M2 was) find the registry without rethreading the composition
    /// root.
    static func containerRoot(capturesRoot: URL) -> URL {
        capturesRoot.deletingLastPathComponent()
    }
}
