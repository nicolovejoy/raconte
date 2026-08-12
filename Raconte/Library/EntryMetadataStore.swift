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

    /// Private (T7 §7.2 rule B4): every production write goes through `update`, which is
    /// the only place that can log the edit it makes. The static `write(_:url:)` seam
    /// below stays public — tests use it to plant fixtures without going through
    /// `update`'s diff-and-log machinery, and it is documented read/test-only.
    private func write(_ metadata: EntryMetadata, captureID: String) throws {
        try Self.write(metadata, url: url(captureID: captureID))
    }

    /// Read, mutate, write — the only safe way to change one field without clobbering
    /// the others written by a different screen.
    ///
    /// Generic over `T`, the mutate closure's own return value (review finding,
    /// T7 gate): callers that need to know what the mutation actually decided — e.g.
    /// `setOriginalDate` below, which needs `EntryMetadata.setOriginalDate`'s accept/
    /// reject Bool — get it back from the model itself rather than having to predict it
    /// by re-implementing the model's own predicate outside the actor (the standing
    /// branch rule: call existing internals, never re-implement them). Existing
    /// `Void`-returning call sites are unaffected in behavior; they just now receive
    /// `(EntryMetadata, Void)` instead of a bare `EntryMetadata` and either discard it
    /// (`_ = try await ...`) or destructure `let (updated, _) = ...`.
    ///
    /// T7 §7: also the one place `entry-log.jsonl` is written. Diffs `EntryMetadata`
    /// before/after the mutation (`EntryLogRecord.diff`) and appends one record per
    /// changed field, **strictly after** `write` returns (§7.2 rule 2 — the log never
    /// claims an edit the sidecar does not hold; if `write` throws, this method returns
    /// before the diff ever runs). Append failure is silent (§7.2 rule 4): this is
    /// diagnostics, and `EntryDegradation` is scan-derived with nowhere to carry a
    /// log-write failure.
    @discardableResult
    func update<T>(captureID: String,
                   cause: EntryLogCause = .userEdit,
                   _ mutate: @Sendable (inout EntryMetadata) -> T) throws -> (EntryMetadata, T) {
        let captureDirectory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: captureDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw EntryMetadataError.captureMissing
        }
        let before = try read(captureID: captureID)
        var metadata = before
        let result = mutate(&metadata)
        try write(metadata, captureID: captureID)

        let changes = EntryLogRecord.diff(from: before, to: metadata, at: Date(), cause: cause)
        for record in changes {
            do {
                try EntryLogWriter.append(record, captureDirectory: captureDirectory)
            } catch {
                #if DEBUG
                print("EntryLogWriter.append failed for \(captureID) field \(record.field): \(error)")
                #endif
            }
        }
        return (metadata, result)
    }

    /// §7.1 nit: `EntryMetadata.setOriginalDate` rejecting a future date leaves nothing
    /// for `update`'s diff to see — the value never changes — but the attempt itself is
    /// informative, so `cause: .rejected` is logged directly here.
    ///
    /// The accepted/rejected answer is `update`'s own `T` — `EntryMetadata
    /// .setOriginalDate`'s real Bool, threaded straight through the mutate closure —
    /// **never re-derived**. An earlier version of this method duplicated
    /// `setOriginalDate`'s `isFuture` guard to decide up front and then always returned a
    /// literal `true` for the accepted path; the two answers agreed only because nothing
    /// yet gives `EntryMetadata.setOriginalDate` a second reason to refuse. Getting the
    /// answer from the model itself means this method cannot drift from it, by
    /// construction, no matter how many rejection reasons `setOriginalDate` grows.
    @discardableResult
    func setOriginalDate(_ date: PartialDate?, captureID: String, now: Date = Date(),
                          calendar: Calendar = .gregorianCurrent) throws -> Bool {
        let (metadata, accepted) = try update(captureID: captureID) { md in
            md.setOriginalDate(date, now: now, calendar: calendar)
        }
        guard !accepted else { return true }

        let captureDirectory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
        let record = EntryLogRecord(at: now, field: "originalDate",
                                    from: metadata.originalDate?.isoString, to: date?.isoString,
                                    cause: .rejected, origin: nil)
        do {
            try EntryLogWriter.append(record, captureDirectory: captureDirectory)
        } catch {
            #if DEBUG
            print("EntryLogWriter.append failed for \(captureID) field originalDate: \(error)")
            #endif
        }
        return false
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
