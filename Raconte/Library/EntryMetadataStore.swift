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
    /// M4 T1: the single clock `update` reads once per call, for both the audit-log
    /// record's `at` and every `EntryMetadata.modified` stamp that call produces — one
    /// read, so the log and the sync stamps can never disagree about when an edit
    /// happened. Matches `JournalStore`'s injected-clock shape (`now`, same name, same
    /// default), the sibling registry actor.
    private let now: @Sendable () -> Date

    /// M4 T6. Nil everywhere sync is off — unit tests, the UI-test harness, and any
    /// build whose composition root refused to construct an engine. A store with no
    /// hook behaves exactly as it did before M4, matching `JournalStore`'s identical
    /// seam (Task 5).
    private var syncHooks: (any SyncHooks)?

    init(capturesRoot: URL, now: @escaping @Sendable () -> Date = { Date() },
         syncHooks: (any SyncHooks)? = nil) {
        self.capturesRoot = capturesRoot
        self.now = now
        self.syncHooks = syncHooks
    }

    /// Wired after construction (M4 T6), for the same reason `JournalStore.attach
    /// (syncHooks:)` is: the composition root builds this store (inside
    /// `LibraryScreenModel`) before it can build the `SyncCoordinator` that conforms to
    /// `SyncHooks`.
    func attach(syncHooks: any SyncHooks) {
        self.syncHooks = syncHooks
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
    ///
    /// M4 T1: the same diff also stamps `EntryMetadata.modified[field]` for every
    /// changed field, ahead of `write` — so, unlike the log, the stamps are part of the
    /// durable sidecar itself. A field the mutate closure didn't actually change (its
    /// before/after values are equal) gets no stamp; a mutation that changes nothing at
    /// all leaves `modified` untouched entirely.
    ///
    /// M4 T6: also the one place a LOCAL entry edit reaches sync (design §3:
    /// "`EntryMetadataStore.update` → enqueue Entry"). Fires only when both are true —
    /// something actually changed (`!changes.isEmpty`, the same condition that gates
    /// the audit-log append above) AND the capture is already sync-eligible
    /// (`FinalizeArtifactPush.isFinalized`, the same "m4a verified" predicate the
    /// finalize-completion choke point uses). That second half is the eligibility pin:
    /// without it, a mid-recording backdate/journal write — `CaptureScreenModel
    /// .enqueueEntryMetadataWrite` runs on an ACTIVE capture, before any `.m4a` exists —
    /// would push an Entry record with no AudioAsset behind it yet, which design §2
    /// rule 6 ("entries sync only once finalized") forbids. Once a capture IS
    /// finalized, every later edit (a real backdate correction, trash, restore,
    /// `SpokenDateDetection`) re-fires this on its own; the finalize choke point never
    /// needs to re-push `.entry` itself for that reason.
    @discardableResult
    func update<T>(captureID: String,
                   cause: EntryLogCause = .userEdit,
                   _ mutate: @Sendable (inout EntryMetadata) -> T) async throws -> (EntryMetadata, T) {
        let captureDirectory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: captureDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw EntryMetadataError.captureMissing
        }
        let before = try read(captureID: captureID)
        var metadata = before
        let result = mutate(&metadata)

        // M4 T1: one clock read, shared by the log record below and every stamp here —
        // computed from the SAME before/after diff the log already needed, so "what
        // changed" is never derived two different ways. Stamped into `metadata` before
        // `write`, so the stamps are part of what actually lands on disk; a field that
        // didn't change gets no stamp at all (`changes` only lists fields that differ).
        let stamp = now()
        let changes = EntryLogRecord.diff(from: before, to: metadata, at: stamp, cause: cause)
        if !changes.isEmpty {
            var modified = metadata.modified ?? [:]
            for change in changes { modified[change.field] = stamp }
            metadata.modified = modified
        }

        try write(metadata, captureID: captureID)

        for record in changes {
            do {
                try EntryLogWriter.append(record, captureDirectory: captureDirectory)
            } catch {
                #if DEBUG
                print("EntryLogWriter.append failed for \(captureID) field \(record.field): \(error)")
                #endif
            }
        }

        if !changes.isEmpty, FinalizeArtifactPush.isFinalized(capturesRoot: capturesRoot, captureID: captureID) {
            await syncHooks?.noteLocalChange(.entry(captureID: captureID))
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
                          calendar: Calendar = .gregorianCurrent) async throws -> Bool {
        let (metadata, accepted) = try await update(captureID: captureID) { md in
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

    /// Writes a merged entry back (M4 T8, design §4/§6) through the SAME read→merge→write
    /// shape `JournalStore.applySyncMerge(id:decide:)` uses — but, unlike that twin,
    /// entries carry their OWN audit log (T7 §7), so a sync-caused merge still appends
    /// `.sync`-cause rows to `entry-log.jsonl` even though it must skip `update`'s
    /// stamping half entirely.
    ///
    /// **No re-stamping, and no sync hook — the same no-echo rule `JournalStore
    /// .applySyncMerge` follows, for the same reason.** `update`'s `now()`-stamping
    /// exists for LOCAL edits, where "this device just wrote this field" is genuinely
    /// true; it is not true here — `decide` already returns a value whose `modified` map
    /// carries each field's correct WINNING stamp (`EntryFieldMerge.merge`'s own output),
    /// and re-stamping with the local clock would make this device look like the writer
    /// of an edit it merely received. Combined with the deviceID tie-break, an echoed
    /// re-stamp is exactly the two-devices-trade-forever loop `SyncRecordExchange`'s own
    /// doc comment on `applySyncMerge` warns about — which is also why this cannot simply
    /// call `update(cause: .sync)`: that method's stamping is unconditional, not
    /// something a cause value can switch off.
    ///
    /// `decide` is **non-async and `@Sendable`**, for the identical reason
    /// `JournalStore.applySyncMerge(id:decide:)`'s is: a synchronous closure cannot
    /// suspend, so the read → merge → write below runs to completion under this actor's
    /// isolation with nothing — not a concurrent local edit, not a second ingest — able
    /// to interleave in the gap.
    ///
    /// Same `captureMissing` guard as `update`, for the same reason (#25/T6 §4.6): a
    /// merge write must never recreate a capture directory a staged removal has moved
    /// away, resurrecting a deleted entry.
    @discardableResult
    func applySyncMerge(captureID: String,
                        decide: @Sendable (EntryMetadata) -> EntryMetadata) async throws -> EntryMetadata {
        let captureDirectory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: captureDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw EntryMetadataError.captureMissing
        }
        let before = try read(captureID: captureID)
        let merged = decide(before)

        try write(merged, captureID: captureID)

        let changes = EntryLogRecord.diff(from: before, to: merged, at: now(), cause: .sync)
        for record in changes {
            do {
                try EntryLogWriter.append(record, captureDirectory: captureDirectory)
            } catch {
                #if DEBUG
                print("EntryLogWriter.append failed for \(captureID) field \(record.field): \(error)")
                #endif
            }
        }

        return merged
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
