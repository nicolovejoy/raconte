import Foundation

/// A copied-or-derived file's identity inside a written export package:
/// `ArchiveExporter` (T11) computes one of these for every file after it lands on disk,
/// and `ArchiveVerifier` (T12) recomputes it from the package alone — years later, off a
/// USB stick, with no access to the original container — to prove nothing rotted.
struct FileDigest: Codable, Equatable, Sendable {
    var sha256: String
    var bytes: Int
}

/// The exported package's own manifest — `raconte-export.json` (T11), written LAST so
/// its mere presence tells `ArchiveVerifier` the copy actually finished. Plain data: this
/// type carries no filesystem behavior of its own. `ArchiveWalker` decides what belongs
/// in a package; `ArchiveExporter` builds one of these describing what it wrote;
/// `ArchiveVerifier` checks a package against one it reads back.
struct ExportManifest: Codable, Equatable, Sendable {
    static let format = "raconte-export"
    static let schemaVersion = 1

    var format: String
    var schemaVersion: Int
    var exportedAt: Date
    var appVersion: String
    var build: String

    struct Counts: Codable, Equatable, Sendable {
        var entries: Int
        var journals: Int
        var files: Int
        var bytes: Int
    }
    var counts: Counts

    struct EntrySummary: Codable, Equatable, Sendable {
        var journalID: String?
        var hasAudio: Bool
        var revisionCount: Int
        var currentRevisionID: String?
        var transcriptCharacterCount: Int
        var sidecarReadable: Bool
    }
    /// Keyed by captureID.
    var entries: [String: EntrySummary]
    /// Package-relative path -> digest, for EVERY file in the package except this
    /// manifest itself.
    var files: [String: FileDigest]
    var warnings: [String]
}

/// One file the exporter will copy byte-for-byte: where it lives on disk today
/// (`source`), and where it lands inside the package (`relativePath`).
struct ExportFile: Equatable, Sendable {
    var source: URL
    var relativePath: String
}
