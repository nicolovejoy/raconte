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
///       sync/staging/<ULID>/   new-entry ingest assembly area, disposable (M4 T7)
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
    /// M4 T7: where a new entry's pieces are materialized before the commit rename
    /// (design §6, "assemble-then-commit"). A child of `sync/` — disposable cache, same
    /// as the rest of that directory: a stale or half-assembled staging directory costs
    /// nothing but a rebuild, never data, because `captures/` is never touched until the
    /// final `rename(2)` succeeds.
    static let syncStagingDirectoryName = "staging"

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

    /// `sync/staging/` — a sibling of `sync/`'s other bookkeeping, never of `captures/`
    /// itself, for the same reason this type's header gives for every other sibling: a
    /// stray child of `captures/` is walked by `DirectorySnapshot.gather` and handed to
    /// the recovery planner. A half-assembled entry must stay invisible to that walk
    /// until its commit rename lands it under `captures/` as a complete directory.
    static func syncStagingRoot(containerRoot: URL) -> URL {
        syncRoot(containerRoot: containerRoot).appendingPathComponent(syncStagingDirectoryName,
                                                                      isDirectory: true)
    }

    /// One capture's staging directory: `sync/staging/<captureID>/`.
    static func syncStagingCaptureURL(containerRoot: URL, captureID: String) -> URL {
        syncStagingRoot(containerRoot: containerRoot).appendingPathComponent(captureID, isDirectory: true)
    }

    /// M4 T7 fix round: the durable sidecar `sync/staging/<captureID>/pending.json`
    /// recording an arrived Entry record's decoded metadata + manifest snapshot bytes —
    /// see `PendingEntryRecord` in `SyncIngest.swift`. Written the instant the Entry
    /// record decodes, so assembly can resume across a relaunch instead of depending on
    /// an in-memory buffer CKSyncEngine's change-token semantics do not guarantee will
    /// ever be reconstructable (a record already fetched is not redelivered).
    static let syncStagingPendingStateFileName = "pending.json"
    static func syncStagingPendingStateURL(containerRoot: URL, captureID: String) -> URL {
        syncStagingCaptureURL(containerRoot: containerRoot, captureID: captureID)
            .appendingPathComponent(syncStagingPendingStateFileName)
    }

    /// M4 T9: a sibling of `pending.json` — `sync/staging/<captureID>/pending-revisions.json`
    /// — durably parking Revision records that arrive for a captureID this device has not
    /// committed yet. Ordering between fetched record types is not guaranteed (design
    /// §6), so a revision can land before the Entry/Audio pair that would let it be
    /// written straight into a real `transcript/` via `TranscriptRevisionStore
    /// .ingestForeignRevision`. Deliberately a SIBLING file, not folded into
    /// `pending.json`: a revision can arrive before the Entry record itself has, when
    /// `pending.json` does not exist yet at all, so parking cannot depend on that
    /// sidecar's presence.
    ///
    /// **Rides the same `EntryAssembler.assemble` rename `pending.json` does NOT** — this
    /// file must be added to that function's `pruneUnexpectedStagingContents` allow-list
    /// or it is deleted, unrecovered, the instant a commit's prune step runs (T7's own
    /// fix-round note: "the allow-list must learn any new staged filename"). It survives
    /// into `captures/<captureID>/pending-revisions.json` for exactly as long as it takes
    /// `SyncRecordExchange.ingestParkedRevisions` to ingest and delete it — a committed
    /// capture directory does not keep it around.
    static let syncStagingPendingRevisionsFileName = "pending-revisions.json"
    static func syncStagingPendingRevisionsURL(containerRoot: URL, captureID: String) -> URL {
        syncStagingCaptureURL(containerRoot: containerRoot, captureID: captureID)
            .appendingPathComponent(syncStagingPendingRevisionsFileName)
    }

    /// The container root inferred from a captures root — the inverse of
    /// `capturesRoot(containerRoot:)`. Lets a type that was handed only `capturesRoot`
    /// (everything in M1/M2 was) find the registry without rethreading the composition
    /// root.
    static func containerRoot(capturesRoot: URL) -> URL {
        capturesRoot.deletingLastPathComponent()
    }
}
