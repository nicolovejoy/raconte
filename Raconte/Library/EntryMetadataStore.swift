import Foundation

enum EntryMetadataError: Error, Equatable {
    /// `entry.json` exists and could not be read or decoded. Distinct from absent, which
    /// is not an error at all — see `EntryMetadataStore.read`.
    case unreadable(String)
    /// There is no `captures/<id>/` to write into. `write` creates intermediate
    /// directories, so without this an edit could *recreate* a capture directory that a
    /// staged removal had just moved away — resurrecting a deleted entry from a restore
    /// tap that lost a race (#25, and T6 §4.6's A2.3).
    ///
    /// This closes the ordinary ordering — a restore tapped after the stage — not a true
    /// race between this guard and the write that follows it: `update` still reads then
    /// writes in two steps, so a stage landing in between is not covered. §0.3.12 records
    /// why the fuller (actor-serialized) answer was rejected for now.
    case captureMissing
}

/// Reads and writes `captures/<id>/entry.json`.
///
/// An actor, like `SegmentStore`, because `update` is a read-modify-write: two concurrent
/// edits of the same entry (backdate from the detail screen while a sweep tombstones it)
/// would otherwise drop one. Serializing across *all* entries is more than strictly
/// needed and costs nothing at this scale.
///
/// Writes go through `AtomicFile.replace` — `.part`, fsync, rename — so a kill mid-write
/// leaves the previous sidecar intact rather than a half-written one. That matters more
/// here than for the transcript log: this file has no append-only structure to salvage,
/// so a torn write would lose the whole record.
actor EntryMetadataStore {
    nonisolated let capturesRoot: URL

    init(capturesRoot: URL) {
        self.capturesRoot = capturesRoot
    }

    nonisolated func url(captureID: String) -> URL {
        SegmentLayout.entryMetadataURL(
            captureDirectory: SegmentLayout.captureDirectory(capturesRoot: capturesRoot,
                                                             captureID: captureID))
    }

    /// An absent sidecar is `EntryMetadata.defaults` — the overwhelmingly common case
    /// (every capture starts without one) and not an error. Unreadable or undecodable
    /// throws, because answering "unfiled, not backdated, not trashed" for a file we
    /// merely failed to parse would re-file the entry and, once trash ships, un-delete it.
    func read(captureID: String) throws -> EntryMetadata {
        try Self.read(url: url(captureID: captureID))
    }

    func write(_ metadata: EntryMetadata, captureID: String) throws {
        try Self.write(metadata, url: url(captureID: captureID))
    }

    /// Read, mutate, write — the only safe way to change one field without clobbering
    /// the others written by a different screen.
    @discardableResult
    func update(captureID: String,
                _ mutate: @Sendable (inout EntryMetadata) -> Void) throws -> EntryMetadata {
        let captureDirectory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: captureDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw EntryMetadataError.captureMissing
        }
        var metadata = try read(captureID: captureID)
        mutate(&metadata)
        try write(metadata, captureID: captureID)
        return metadata
    }

    // MARK: Pure seams (sync; no actor hop, so the format is testable on its own)

    static func read(url: URL) throws -> EntryMetadata {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile
                                           || error.code == .fileNoSuchFile {
            return .defaults
        } catch {
            throw EntryMetadataError.unreadable(String(describing: error))
        }
        return try decode(data)
    }

    static func decode(_ data: Data) throws -> EntryMetadata {
        do {
            return try CaptureCoding.decoder().decode(EntryMetadata.self, from: data)
        } catch {
            throw EntryMetadataError.unreadable(String(describing: error))
        }
    }

    /// Same encoder as the journals registry: sorted keys, no pretty-printing, ISO8601
    /// dates with milliseconds.
    static func encode(_ metadata: EntryMetadata) throws -> Data {
        try CaptureCoding.lineEncoder().encode(metadata)
    }

    static func write(_ metadata: EntryMetadata, url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try AtomicFile.replace(at: url, writing: try encode(metadata))
    }
}
