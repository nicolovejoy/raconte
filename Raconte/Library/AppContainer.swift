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
enum AppContainer {
    static let directoryName = "Raconte"
    static let capturesDirectoryName = "captures"
    static let journalsFileName = "journals.json"

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

    /// The container root inferred from a captures root — the inverse of
    /// `capturesRoot(containerRoot:)`. Lets a type that was handed only `capturesRoot`
    /// (everything in M1/M2 was) find the registry without rethreading the composition
    /// root.
    static func containerRoot(capturesRoot: URL) -> URL {
        capturesRoot.deletingLastPathComponent()
    }
}
