import Foundation

enum JournalStoreError: Error, Equatable {
    /// The file exists and could not be read or decoded. **Not** the same as absent:
    /// treating it as empty would let the next write replace a registry we merely failed
    /// to parse (issue #11's rule, applied here before it can be broken).
    case unreadable(String)
}

/// Persists the journals registry as a single JSON file beside `captures/`.
///
/// An actor for the same reason `SegmentStore` is one: `create` and `rename` are
/// read-modify-write over one file, and two of them interleaving loses a journal. The
/// pure decisions live in `JournalRegistry`; everything here is I/O.
actor JournalStore {
    nonisolated let url: URL

    /// `mintID` is injected so tests get deterministic ids, matching
    /// `CaptureCoordinator`'s `mintCaptureID` seam.
    private let mintID: @Sendable () -> String
    private let now: @Sendable () -> Date

    /// M4 T5. Nil everywhere sync is off — unit tests, the UI-test harness, and any build
    /// whose composition root refused to construct an engine. A store with no hook behaves
    /// exactly as it did before M4.
    private var syncHooks: (any SyncHooks)?

    init(containerRoot: URL,
         mintID: @escaping @Sendable () -> String = { ULID.make() },
         now: @escaping @Sendable () -> Date = { Date() },
         syncHooks: (any SyncHooks)? = nil) {
        self.url = AppContainer.journalsURL(containerRoot: containerRoot)
        self.mintID = mintID
        self.now = now
        self.syncHooks = syncHooks
    }

    /// Wired after construction because the composition root builds this store (inside
    /// `LibraryScreenModel`) before it can build the sync coordinator that conforms to
    /// `SyncHooks` — and the coordinator's own ingest path needs this store, so one of the
    /// two has to be attached second. Doing it this way rather than with a two-phase init
    /// leaves every existing `init` call site untouched.
    func attach(syncHooks: any SyncHooks) {
        self.syncHooks = syncHooks
    }

    // MARK: Reads

    /// The registry on disk. An absent file is an empty registry — that is a fresh
    /// install, not a failure. Anything else that goes wrong throws.
    func load() throws -> JournalRegistry {
        try Self.load(url: url)
    }

    func list() throws -> [Journal] {
        try load().journals
    }

    func journal(id: String) throws -> Journal? {
        try load().journal(id: id)
    }

    // MARK: Writes

    @discardableResult
    func create(name: String) async throws -> Journal {
        var registry = try load()
        // `insert` normalizes the name and hands back what it stored. One clock read,
        // reused for both `createdAt` and the M4 T1 `modified["name"]` stamp `insert`
        // writes — the journal's creation instant and its name's first-write instant
        // are the same moment.
        let createdAt = now()
        let created = try registry.insert(Journal(id: mintID(), name: name, createdAt: createdAt),
                                          now: createdAt)
        try save(registry)
        await syncHooks?.noteLocalChange(.journal(id: created.id))
        return created
    }

    /// #84 point 1: mints an auto-default journal WITHOUT firing the sync push hook,
    /// marked `provisionalDefault: true`. On a fresh install of an account that already
    /// has journals in CloudKit, the ordinary `create` used to push this mint before the
    /// first fetch could land, polluting every device with a spurious empty "Journal" —
    /// this is the fix. The ONLY difference from `create` is the missing hook call and
    /// the flag; everything else (name normalization, the `modified["name"]` stamp) is
    /// identical, because a provisional default is still a real, valid journal locally —
    /// it is unpushed, not unfinished.
    @discardableResult
    func createProvisionalDefault(name: String) async throws -> Journal {
        var registry = try load()
        let createdAt = now()
        let created = try registry.insert(
            Journal(id: mintID(), name: name, createdAt: createdAt, provisionalDefault: true),
            now: createdAt)
        try save(registry)
        // No `syncHooks?.noteLocalChange` — design point 1, the whole point of this method.
        return created
    }

    /// #84 point 2, the entry-save half of "promote on use". `rename`/`setSpan`/
    /// `stampCoverModified` already fire the local-change hook unconditionally and merely
    /// needed the flag cleared alongside (see `JournalRegistry.rename`'s doc comment);
    /// entry-save has no reason to route through any of those, so this is its own
    /// primitive — never called directly by a screen model. **Every** caller that files
    /// an entry into a journal must go through the ONE shared chokepoint just below,
    /// `promoteProvisionalDefaultAfterEntrySave`, not this method directly (review
    /// finding, gate fix round: an earlier version of this doc comment claimed
    /// `CaptureScreenModel.enqueueEntryMetadataWrite` was the only entry-save call site —
    /// false; `LibraryScreenModel.moveEntry` files an entry too, via the detail screen's
    /// journal picker, and had silently bypassed promotion entirely).
    ///
    /// A no-op (returns `false`, no hook fired) when the journal is unknown or was never
    /// (or is no longer) provisional — the overwhelmingly common case, since this is
    /// called on every entry-metadata write regardless of which journal it targets, not
    /// only ones that are actually still-provisional defaults.
    @discardableResult
    func promoteProvisionalDefault(id: String) async throws -> Bool {
        var registry = try load()
        guard registry.promoteProvisionalDefault(id: id) else { return false }
        try save(registry)
        await syncHooks?.noteLocalChange(.journal(id: id))
        return true
    }

    /// #84 point 3: called after journal ingest lands a real journal from CloudKit.
    /// Removes the local auto-minted provisional default when it is confirmed still
    /// unused — its `provisionalDefault` flag is still set (never renamed, given a
    /// cover/span, labelled, or promoted by an entry save — every one of those clears the
    /// flag atomically as part of its own write) AND `isEmpty` confirms it currently holds
    /// no entries. The second check is not redundant with the first: `isEmpty` is called
    /// fresh, from the caller's own rescan, closing the narrow window between an entry's
    /// `journalID` landing on disk and this device's own `promoteProvisionalDefault` call
    /// clearing the flag for it (see `CaptureScreenModel.enqueueEntryMetadataWrite`) — a
    /// window this actor cannot see into on its own, since it has no visibility into
    /// entries at all (same limitation `deleteJournal`'s doc comment states).
    ///
    /// No sync hook fired and no CK delete issued: a provisional default is, by
    /// definition, never pushed, so there is no server record for anything to remove.
    ///
    /// Reentrancy discipline (same as `applySyncMerge(id:decide:)`): `isEmpty` suspends
    /// (it rescans), releasing this actor's isolation while it runs. The registry is
    /// re-read fresh after that await and the candidate re-confirmed still provisional
    /// before anything is written — a rename/promotion/second prune landing in the gap
    /// must not be reverted or duplicated.
    func pruneUnusedProvisionalDefault(excluding incomingID: String,
                                       isEmpty: @Sendable (String) async -> Bool) async throws {
        let registry = try load()
        guard let candidate = registry.journals.first(where: {
            $0.provisionalDefault && $0.id != incomingID
        }) else { return }
        guard await isEmpty(candidate.id) else { return }

        var fresh = try load()
        guard let stillCandidate = fresh.journal(id: candidate.id), stillCandidate.provisionalDefault
        else { return }
        do {
            try fresh.remove(id: candidate.id)
        } catch {
            // Already gone, or (should not happen here — the just-landed real journal
            // already makes this at least the second entry) the last remaining one.
            // Either way, nothing to write.
            return
        }
        try save(fresh)
    }

    @discardableResult
    func rename(id: String, to name: String) async throws -> Journal {
        var registry = try load()
        let renamed = try registry.rename(id: id, to: name, now: now())
        try save(registry)
        await syncHooks?.noteLocalChange(.journal(id: id))
        return renamed
    }

    /// Stamps `modified["cover"]` — the LWW stamp for the cover image, which lives outside
    /// this registry at `journals/<id>/cover.jpg`. Called by `JournalCoverStore` after it
    /// writes or removes those bytes, so `journals.json` keeps exactly one writer (this
    /// actor) while the stamp still lands.
    ///
    /// Fires the hook like any other local edit: the journal record's digest includes the
    /// cover's own sha (`SyncTreeScanner.journalArtifact`), so a new cover really is a
    /// change to the Journal record and has to be pushed.
    func stampCoverModified(id: String) async throws {
        var registry = try load()
        try registry.stampCover(id: id, now: now())
        try save(registry)
        await syncHooks?.noteLocalChange(.journal(id: id))
    }

    /// Writes a merged journal back verbatim (M4 T5, design §6) — **no restamping, and no
    /// sync hook**.
    ///
    /// The missing hook is the no-echo rule, and it is load-bearing rather than an
    /// optimization. A sync-caused save that announced itself as a local change would
    /// re-upload what was just downloaded; and because `applySyncMerge` also does not
    /// restamp, the echo would carry the *remote's* stamps back at the remote — which,
    /// combined with the deviceID tie-break, is a loop two devices can sit in indefinitely,
    /// each one's echo answering the other's. See `JournalRegistry.applySyncMerge` for why
    /// the stamps travel untouched.
    func applySyncMerge(_ journal: Journal) throws {
        var registry = try load()
        registry.applySyncMerge(journal)
        try save(registry)
    }

    /// The ingest path's read-merge-write, as ONE isolated operation.
    ///
    /// The two-call version of this — read the journal, merge, write it back — was a lost
    /// update, and the reason is worth stating precisely because the obvious defence does
    /// not work: **an actor releases its isolation at every `await`.** The ingest side
    /// being an actor bought nothing, because the read and the write were two separate
    /// hops into *this* actor, and a `rename` landing between them was silently reverted —
    /// `applySyncMerge` replaces the whole `Journal`, stamps included, so the newer local
    /// stamp was destroyed, the revert was then pushed, and the edit was lost on both
    /// devices.
    ///
    /// `decide` is **non-async on purpose**: a synchronous closure cannot suspend, so
    /// load → decide → save runs to completion under this actor's isolation with nothing
    /// able to interleave. Making it `async` would silently reintroduce the bug, which is
    /// why the signature is the guard rather than a comment asking callers to be careful.
    ///
    /// The caller gets back whatever the closure decided about the cover, because the
    /// cover's bytes live in a different store and cannot be written from here. Only the
    /// registry's read-modify-write has to be atomic; see `SyncRecordExchange.ingestJournal`
    /// for what the cover half then does and the one crash window it leaves.
    ///
    /// No restamping and no sync hook, for the same no-echo reason as `applySyncMerge`.
    func applySyncMerge(id: String,
                        decide: @Sendable (Journal?) -> JournalSyncMerge) throws -> JournalSyncMerge.CoverAction {
        var registry = try load()
        let outcome = decide(registry.journal(id: id))
        registry.applySyncMerge(outcome.journal)
        try save(registry)
        return outcome.coverAction
    }

    /// Sets (or clears, via an empty dict) a journal's voice labels (T7 Mark Voices,
    /// issue #56). Same load -> mutate -> save shape as `rename`; the pure trim/drop
    /// rule lives on `JournalRegistry.setVoiceLabels`.
    @discardableResult
    func setVoiceLabels(id: String, labels: [String: String]) async throws -> Journal {
        var registry = try load()
        let updated = try registry.setVoiceLabels(id: id, labels: labels, now: now())
        try save(registry)
        await syncHooks?.noteLocalChange(.journal(id: id))
        return updated
    }

    /// Sets (or clears, via `nil`) a journal's stored span (spec ruling 2). Same
    /// load -> mutate -> save shape as `setVoiceLabels`; the pure rule lives on
    /// `JournalRegistry.setSpan`. M4 sync (#70): passes the store's clock through so the
    /// `modified["span"]` stamp lands, on both a set and a clear, and fires the sync hook
    /// exactly like every other local-edit setter (`rename`, `setVoiceLabels`) — without
    /// it a span edit would sit stamped-but-unpushed until the next launch's
    /// reconciliation scan happened to notice the digest moved.
    ///
    /// Value-changed guard (gate F1, for #70): a no-op call — e.g. a journal editor
    /// opened and closed without touching the span — must NOT re-stamp `modified["span"]`
    /// or fire the sync hook. Without this, re-stamping a value that did not change can
    /// beat a genuinely older but real edit from an offline peer in a later LWW merge,
    /// silently discarding it. `rename`/`setVoiceLabels` rely on their *caller* (the
    /// editor view) to skip a no-op call instead; `setSpan` guards here too, as a second
    /// chokepoint any future caller inherits for free.
    @discardableResult
    func setSpan(id: String, span: JournalSpan?) async throws -> Journal {
        var registry = try load()
        guard let current = registry.journal(id: id) else {
            throw JournalError.unknownJournal(id)
        }
        guard current.span != span else { return current }
        let updated = try registry.setSpan(id: id, span: span, now: now())
        try save(registry)
        await syncHooks?.noteLocalChange(.journal(id: id))
        return updated
    }

    /// Removes an EMPTY journal from the registry (#80, v1: non-empty journal deletion
    /// is a separate, later design). Refuses (`JournalError`) when the id is unknown, or
    /// when it is the last remaining journal — every device always needs somewhere for
    /// capture to point, and "no journals" has no UI story anywhere in the app.
    ///
    /// "Empty" (zero items AND zero trashed entries) is NOT checked here — this actor
    /// cannot see entries at all, only `journals.json`. `LibraryScreenModel.deleteJournal`
    /// is the only legitimate caller and enforces that rule from the scan before ever
    /// reaching this method; see its doc comment for why a trashed entry still counts.
    ///
    /// Cover cleanup runs only after the registry write lands, and the sync delete hook
    /// only after that — telling either layer the journal is gone before the registry
    /// write has actually succeeded on disk would be a lie they could act on.
    func deleteJournal(id: String) async throws {
        var registry = try load()
        try registry.remove(id: id)
        try save(registry)
        JournalCoverStore.removeDirectory(containerRoot: url.deletingLastPathComponent(), journalID: id)
        await syncHooks?.noteLocalDelete(.journal(id: id))
    }

    /// Removes a journal due to an INBOUND deletion (#80, B2) — **no sync hook fired**,
    /// the same no-echo rule `applySyncMerge` follows and for the same reason: announcing
    /// a sync-caused removal as a local delete would re-enqueue a delete for a record the
    /// server already told us is gone, and combined with the deviceID tie-break two
    /// devices could trade the same delete back and forth.
    ///
    /// Same guards as `deleteJournal` (`JournalRegistry.remove` throws
    /// `.unknownJournal`/`.lastRemainingJournal`) because they are the same rule for the
    /// same reason regardless of which direction triggered it — an inbound delete of this
    /// device's only journal is refused just as hard as a local one would be.
    ///
    /// The not-empty-locally guard is NOT here, deliberately: this actor cannot see
    /// entries at all, only `journals.json` — `SyncRecordExchange.acceptRemoteJournalDeletion`
    /// is the only legitimate caller and has already asked
    /// `LibraryScreenModel.isJournalEmptyAfterRescan` (R3) before ever reaching here.
    func applySyncDelete(id: String) async throws {
        var registry = try load()
        try registry.remove(id: id)
        try save(registry)
        JournalCoverStore.removeDirectory(containerRoot: url.deletingLastPathComponent(), journalID: id)
    }

    private func save(_ registry: JournalRegistry) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try AtomicFile.replace(at: url, writing: try Self.encode(registry))
    }

    // MARK: Pure seams (sync, so tests can exercise the format without an actor hop)

    static func load(url: URL) throws -> JournalRegistry {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile
                                           || error.code == .fileNoSuchFile {
            return JournalRegistry()
        } catch {
            throw JournalStoreError.unreadable(String(describing: error))
        }
        do {
            return try CaptureCoding.decoder().decode(JournalRegistry.self, from: data)
        } catch {
            throw JournalStoreError.unreadable(String(describing: error))
        }
    }

    /// `lineEncoder()` (sorted keys, no pretty-printing) rather than the manifest's
    /// pretty encoder: this file is machine state, is rewritten whole on every change,
    /// and a stable single-line-per-value encoding keeps diffs and byte counts boring.
    /// Dates are the same ISO8601-with-milliseconds the capture path uses.
    static func encode(_ registry: JournalRegistry) throws -> Data {
        try CaptureCoding.lineEncoder().encode(registry)
    }
}

/// #84 point 2's **shared chokepoint** — the ONE place every caller that files an entry
/// into a journal (via ANY path) must route through, so a third future call site cannot
/// silently reintroduce the promotion gap a review caught here: an earlier version wired
/// promotion only into `CaptureScreenModel.enqueueEntryMetadataWrite` (the live-capture
/// recording path) and missed `LibraryScreenModel.moveEntry` (the entry detail screen's
/// journal picker, `EntryDetailView`'s move-to-journal control) entirely — filing an
/// entry into a still-provisional default that way left the journal, and the entry filed
/// under it, permanently unsynced. Not prunable (`pruneUnusedProvisionalDefault`'s
/// `isEmpty` check correctly protects a journal that really does hold an entry) but
/// invisible to CloudKit forever, since nothing had ever called
/// `JournalStore.promoteProvisionalDefault` for it.
///
/// A free function, not a method on either screen model or on `JournalStore` itself,
/// precisely so it carries no single "obvious" owner to bypass — every call site that
/// writes `EntryMetadata.journalID` calls this, by name, right after the write, instead
/// of reaching for `journalStore.promoteProvisionalDefault` directly. Success-gated
/// (`entryWriteSucceeded`): a failed metadata write (`captureMissing`, a race with a
/// staged removal) never actually filed anything and must not promote a journal on its
/// behalf. A `nil` `journalID` (unfiling an entry) is also a no-op — there is nothing to
/// promote.
@discardableResult
func promoteProvisionalDefaultAfterEntrySave(journalStore: JournalStore,
                                             journalID: String?,
                                             entryWriteSucceeded: Bool) async -> Bool {
    guard entryWriteSucceeded, let journalID else { return false }
    return (try? await journalStore.promoteProvisionalDefault(id: journalID)) ?? false
}
