import Foundation
import CloudKit
import os

/// One fetched Journal record, decoded (design §2, §6). A value type with no CloudKit in
/// it beyond a plain file URL for the cover asset, deliberately: everything downstream —
/// `JournalMerge` above all — is then pure, and its tests need no `CKRecord` fixtures at
/// all to exercise the rules that actually decide whose edit survives.
struct RemoteJournal: Equatable, Sendable {
    var id: String
    var name: String
    var createdAt: Date
    var voiceLabels: [String: String]
    /// The journal's stored span (spec ruling 2, #70). Optional both because the field is
    /// additive (a record built by an older device never has it) and because the value
    /// itself is nilable — an open journal, or one whose span was cleared.
    var span: JournalSpan?
    var modified: [String: Date]
    /// The fetched `CKAsset`'s local file URL, when the record carries a cover. CloudKit
    /// has already downloaded the bytes to this path by the time the record is handed
    /// over; the file is temporary and must be copied before the event returns.
    var coverAsset: URL?
    /// The origin device's `DeviceIdentity.stable()`. Optional because a record written by
    /// a build older than this one has no such field — an absent deviceID loses every
    /// tie, which is the safe direction (a tie means the values were written in the same
    /// millisecond, so nothing an owner can perceive is lost either way).
    var deviceID: String?

    /// Strict about identity, lenient about everything else — the same split
    /// `Journal.init(from:)` makes, for the same reason. `id`/`name`/`createdAt` are
    /// written at creation and never absent; a record missing one is damaged, and
    /// substituting a default would file entries under a journal nobody named. A damaged
    /// `voiceLabels` or `modified` costs only that field.
    ///
    /// The id comes from the **record name**, never from a field: `SyncRecordName` already
    /// guarantees `j.<well-formed ULID>`, and deriving it here means a record can never
    /// disagree with the name it is filed under.
    init?(record: CKRecord) {
        guard record.recordType == SyncRecordType.journal,
              case .journal(let id)? = SyncCloudIdentifiers.name(of: record.recordID) else { return nil }
        guard let name = record[SyncJournalField.name] as? String,
              !JournalRegistry.normalized(name).isEmpty,
              let createdAt = record[SyncJournalField.createdAt] as? Date else { return nil }
        self.id = id
        self.name = JournalRegistry.normalized(name)
        self.createdAt = createdAt
        self.voiceLabels = SyncRecordBuilders.decodeJSON(record[SyncJournalField.voiceLabels] as? String)
        // Absent (older build's record) and unparseable both read as nil — the same
        // leniency `voiceLabels`/`modified` get, and the same rule `Journal.init(from:)`
        // already applies to `span` on disk. Absence must never fail this init.
        self.span = SyncRecordBuilders.decodeJSON(record[SyncJournalField.span] as? String)
        self.modified = SyncRecordBuilders.decodeJSON(record[SyncJournalField.modified] as? String)
        self.coverAsset = (record[SyncJournalField.cover] as? CKAsset)?.fileURL
        self.deviceID = record[SyncJournalField.deviceID] as? String
    }

    /// Direct construction, for tests and for anything that already has the decoded
    /// values.
    init(id: String, name: String, createdAt: Date, voiceLabels: [String: String] = [:],
         span: JournalSpan? = nil, modified: [String: Date] = [:], coverAsset: URL? = nil,
         deviceID: String? = nil) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.voiceLabels = voiceLabels
        self.span = span
        self.modified = modified
        self.coverAsset = coverAsset
        self.deviceID = deviceID
    }
}

/// The one last-writer-wins comparison, shared by every per-field merge (journals here,
/// entry sidecar fields in T8). Pure and total — every combination of present/absent
/// stamps has a named answer, because "we did not think about that case" is how a merge
/// silently drops an edit.
enum LWWResolve {
    enum Winner: Equatable, Sendable { case local, remote }

    /// Rules, in order:
    ///
    /// 1. **No stamps at all → local.** Neither side claims to have written this field, so
    ///    there is nothing to move; churning would rewrite `journals.json` on every fetch.
    /// 2. **One side stamped → that side.** An unstamped field predates M4's stamps
    ///    entirely; a stamped one is a real, dated edit and outranks it.
    /// 3. **Different stamps → newer.**
    /// 4. **Equal stamps → lexicographically greater deviceID** (the locked tie-break).
    ///    Two devices wrote the same field in the same millisecond; the rule only has to
    ///    be deterministic and identical on both machines, which this is. An absent remote
    ///    deviceID cannot be "greater", so local keeps it; equal deviceIDs mean the same
    ///    device wrote both, which is not a conflict at all.
    static func winner(localStamp: Date?, remoteStamp: Date?,
                       localDeviceID: String, remoteDeviceID: String?) -> Winner {
        switch (localStamp, remoteStamp) {
        case (nil, nil):
            return .local
        case (nil, .some):
            return .remote
        case (.some, nil):
            return .local
        case (.some(let local), .some(let remote)):
            if remote > local { return .remote }
            if local > remote { return .local }
            guard let remoteDeviceID else { return .local }
            return remoteDeviceID > localDeviceID ? .remote : .local
        }
    }
}

/// Per-field last-writer-wins for journals (design §4). Pure — no store, no CloudKit, no
/// clock. Everything that decides whose edit survives lives here so it can be tested
/// exhaustively and mutated deliberately.
///
/// **Per-field, not per-record**, and the difference is the whole point: two devices that
/// each changed a *different* attribute of the same journal while offline must both keep
/// their change. A whole-record LWW would silently revert one of them — the mutation this
/// task's check restores, to prove the tests can tell.
enum JournalMerge {

    /// The merged journal, written back verbatim by `JournalStore.applySyncMerge`.
    ///
    /// `id` and `createdAt` are **not** merged. Both are immutable from the moment a
    /// journal is created, and a local journal that arrived by ingest already carries the
    /// origin's values, so the two sides agree; if they somehow did not, preferring local
    /// keeps entries filed where they are rather than letting a damaged remote rewrite a
    /// creation date that nothing can re-derive.
    ///
    /// The merged `modified` map takes each stamp from the side that won that field —
    /// **not** the newer stamp of the two. Keeping the loser's newer-looking stamp would
    /// make the next comparison on a third device disagree with this one.
    static func merge(local: Journal, remote: RemoteJournal,
                      localDeviceID: String, remoteDeviceID: String?) -> Journal {
        var merged = local
        var modified = local.modified ?? [:]

        func resolve(_ field: String) -> LWWResolve.Winner {
            let winner = LWWResolve.winner(localStamp: local.modified?[field],
                                           remoteStamp: remote.modified[field],
                                           localDeviceID: localDeviceID,
                                           remoteDeviceID: remoteDeviceID)
            if winner == .remote, let stamp = remote.modified[field] { modified[field] = stamp }
            return winner
        }

        if resolve("name") == .remote { merged.name = remote.name }
        if resolve("voiceLabels") == .remote { merged.voiceLabels = remote.voiceLabels }
        if resolve("span") == .remote { merged.span = remote.span }
        // The cover's bytes are not a field of this type — only its stamp is, and it moves
        // by the same rule whether or not the remote actually carries an image.
        // `coverAction` answers the bytes half, including the deletion case that a bare
        // "did the remote send one?" test would read as nothing to do.
        _ = resolve("cover")

        merged.modified = modified.isEmpty ? nil : modified
        return merged
    }

    /// A remote journal with no local counterpart is taken **as-is, stamps included**.
    ///
    /// Never through `JournalRegistry.insert`: that stamps `modified["name"]` with the
    /// local clock unconditionally, which would overwrite the origin device's stamp with
    /// "now". The next comparison would then read this device as the most recent writer of
    /// a name it merely received, and a genuinely older local edit elsewhere could never
    /// win again.
    static func adopted(remote: RemoteJournal) -> Journal {
        Journal(id: remote.id, name: remote.name, createdAt: remote.createdAt,
                voiceLabels: remote.voiceLabels, span: remote.span,
                modified: remote.modified.isEmpty ? nil : remote.modified)
    }

    /// What should happen to the local cover FILE.
    ///
    /// A separate question from `merge` because the cover is not a field of `Journal` at
    /// all — it is a file under `journals/<id>/cover.jpg`, written by `JournalCoverStore`.
    /// Only its LWW stamp lives in the registry, so the stamp merges with everything else
    /// while the bytes move (or don't) on this answer.
    ///
    /// **`.remove` is not a nicety.** `merge` adopts the winning cover stamp whether or not
    /// the remote carries an asset, because that is what per-field LWW means. Without a
    /// removal answer, a cover deleted on the other device left this one displaying the
    /// deleted picture forever AND holding the remote's newer stamp — so its own,
    /// still-present cover could never win a later comparison either. The deletion has to
    /// move the bytes as well as the stamp, exactly as `JournalCoverStore.delete` and the
    /// record builder's explicitly-nil cover field both already assumed it would.
    static func coverAction(local: Journal, remote: RemoteJournal,
                            localDeviceID: String,
                            remoteDeviceID: String?) -> JournalSyncMerge.CoverAction {
        let winner = LWWResolve.winner(localStamp: local.modified?["cover"],
                                       remoteStamp: remote.modified["cover"],
                                       localDeviceID: localDeviceID,
                                       remoteDeviceID: remoteDeviceID)
        guard winner == .remote else { return .leave }
        return remote.coverAsset == nil ? .remove : .adopt
    }
}

/// One ingest decision, carried out of `JournalStore.applySyncMerge(id:decide:)`.
///
/// Exists because the registry write and the cover-file write live in different stores: the
/// registry half must be atomic under `JournalStore`'s isolation, and the cover half cannot
/// be performed from there at all — so the decision is made inside the isolated call and
/// the file work is handed back to the caller.
struct JournalSyncMerge: Equatable, Sendable {
    enum CoverAction: Equatable, Sendable {
        /// The local cover file — or its absence — stands.
        case leave
        /// The remote's fetched asset replaces the local file.
        case adopt
        /// The other device deleted its cover; delete this one too.
        case remove
    }

    var journal: Journal
    var coverAction: CoverAction
}

/// The app's side of the CloudKit conversation: turns record names into records to push,
/// and fetched records into local writes (design §6).
///
/// An actor so that its own bookkeeping (`inFlight`) is not raced by the several engine
/// callbacks that reach it concurrently.
///
/// **It is emphatically NOT what makes a read-merge-write safe**, and an earlier version of
/// this file claimed it was. An actor releases its isolation at every `await`, so a
/// sequence of hops into `JournalStore` from here interleaves with anything else calling
/// that store — a local rename, or a second `acceptRemote` for the same journal, both of
/// which really happen (`resolvePushConflicts` loops over `acceptRemote`, and fetched
/// changes arrive in batches). The registry's read-merge-write is atomic because it happens
/// inside one `JournalStore.applySyncMerge(id:decide:)` call whose closure cannot suspend —
/// not because of anything this type is.
///
/// The writes deliberately use `applySyncMerge`, which neither re-stamps `modified` nor
/// fires the sync hook: a sync-caused save that echoed back as a local change would
/// re-upload what was just downloaded, and with a fresh local stamp on it — two devices
/// would then trade the same journal forever, each one's echo looking newer than the
/// other's.
actor SyncRecordExchange: CloudRecordExchange {
    private let journalStore: JournalStore
    private let coverStore: JournalCoverStore
    private let bookkeeping: SyncBookkeepingStore
    private let deviceID: String
    private let log: Logger
    /// Called after ingest actually writes something, so the library reloads instead of
    /// showing yesterday's journal names until the next launch. Optional — nothing about
    /// correctness depends on it.
    private let localStoreDidChange: (@Sendable () async -> Void)?

    /// What each in-flight push was built from, keyed by record name.
    ///
    /// Recorded at build time rather than re-read at save-confirm time, and the difference
    /// is a real hole rather than a nicety: an edit landing between "record built" and
    /// "save confirmed" would otherwise be written into the ledger as though it had been
    /// uploaded, and if the app died before the second push, the reconciliation scan would
    /// see ledger == disk and never send it.
    ///
    /// `.ambiguous` exists because a record name is not enough to tell two builds apart. If
    /// the same journal is built twice before the first save confirms, a confirmation
    /// cannot be attributed to either one — and attributing it to the newer digest would
    /// ledger content that was never sent, which loses the second edit exactly the way the
    /// re-read version did. So a second build poisons the entry, and the confirmation
    /// writes nothing. Every miss here costs one redundant upload; there is no arrangement
    /// of it that loses an edit.
    private enum InFlightBuild {
        case one(UploadedDigest)
        case ambiguous
    }
    private var inFlight: [String: InFlightBuild] = [:]

    init(journalStore: JournalStore,
         coverStore: JournalCoverStore,
         bookkeeping: SyncBookkeepingStore,
         deviceID: String,
         localStoreDidChange: (@Sendable () async -> Void)? = nil,
         log: Logger = Logger(subsystem: "org.pianohouseproject.raconte", category: "sync")) {
        self.journalStore = journalStore
        self.coverStore = coverStore
        self.bookkeeping = bookkeeping
        self.deviceID = deviceID
        self.localStoreDidChange = localStoreDidChange
        self.log = log
    }

    // MARK: Push

    func recordToPush(for name: SyncRecordName, zoneID: CKRecordZone.ID) async -> CKRecord? {
        switch name {
        case .journal(let id):
            return await journalRecordToPush(id: id, name: name, zoneID: zoneID)
        case .entry, .audio, .revision, .liveLog, .markerStream:
            // T6/T9/T10 build these. Nil drops the pending change; the next launch's
            // reconciliation scan re-enqueues it, because nothing was written to the
            // ledger.
            log.debug("sync: no builder yet for \(name.rawValue, privacy: .public)")
            return nil
        }
    }

    private func journalRecordToPush(id: String, name: SyncRecordName,
                                     zoneID: CKRecordZone.ID) async -> CKRecord? {
        guard let journal = try? await journalStore.journal(id: id) else {
            // Gone, or the registry is unreadable. Both mean "nothing to say about this
            // journal right now"; the reconciliation scan is the retry.
            log.notice("sync: journal \(id, privacy: .public) not available to push")
            return nil
        }
        let coverURL = coverStore.url(journalID: id)
        let hasCover = FileManager.default.fileExists(atPath: coverURL.path)

        // The ledger digest is derived from the SAME `journal` value the record is built
        // from, not from a second read of the registry. Re-reading here meant an edit
        // landing between the two reads was ledgered as uploaded while the record carried
        // the older content — after which reconciliation saw ledger == disk and never sent
        // the newer version.
        let digest = SyncTreeScanner.journalDigest(journal: journal, coverURL: coverURL)
        note(build: digest, for: name)

        let base = await archivedRecord(for: name)
        return SyncRecordBuilders.journalRecord(journal: journal,
                                                coverFileURL: hasCover ? coverURL : nil,
                                                deviceID: deviceID,
                                                zoneID: zoneID,
                                                base: base)
    }

    private func note(build digest: UploadedDigest, for name: SyncRecordName) {
        if inFlight[name.rawValue] == nil {
            inFlight[name.rawValue] = .one(digest)
        } else {
            // A second build before the first confirmed. Neither confirmation can be
            // attributed, so neither may write the ledger.
            inFlight[name.rawValue] = .ambiguous
            log.debug("sync: second build of \(name.rawValue, privacy: .public) in flight — ledger deferred")
        }
    }

    /// A save this device attempted did not land. Drop the build record: leaving it would
    /// let a *later*, unrelated confirmation for the same name ledger a digest describing
    /// content that was never accepted.
    func noteSaveFailed(for name: SyncRecordName) async {
        inFlight.removeValue(forKey: name.rawValue)
    }

    /// A `CKRecord` rebuilt from this device's archived system fields, or nil when there
    /// are none. Archived fields carry the server's change tag, which is what lets
    /// CloudKit answer a push with "the server copy moved" instead of overwriting it.
    private func archivedRecord(for name: SyncRecordName) async -> CKRecord? {
        guard let data = await bookkeeping.systemFields(for: name.rawValue) else { return nil }
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = true
        let record = CKRecord(coder: unarchiver)
        unarchiver.finishDecoding()
        return record
    }

    func noteSaved(_ record: CKRecord) async {
        guard let name = SyncCloudIdentifiers.name(of: record.recordID) else { return }
        await archiveSystemFields(of: record, for: name)
        guard case .one(let digest)? = inFlight.removeValue(forKey: name.rawValue) else {
            // No build on record, or an ambiguous one. The ledger is left alone, so the
            // next reconciliation scan re-enqueues — one redundant upload, never a lost
            // edit.
            return
        }
        do {
            try await bookkeeping.recordUpload(digest, for: name.rawValue)
        } catch {
            log.error("""
                sync: could not record upload for \(name.rawValue, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
        }
    }

    private func archiveSystemFields(of record: CKRecord, for name: SyncRecordName) async {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        try? await bookkeeping.saveSystemFields(archiver.encodedData, for: name.rawValue)
    }

    // MARK: Ingest

    func acceptRemote(_ record: CKRecord) async {
        guard let name = SyncCloudIdentifiers.name(of: record.recordID) else {
            log.notice("sync: fetched a record whose name does not parse — ignored")
            return
        }
        await archiveSystemFields(of: record, for: name)
        switch name {
        case .journal:
            await ingestJournal(record)
        case .entry, .audio, .revision, .liveLog, .markerStream:
            // T7-T10 own these.
            log.debug("sync: no ingest yet for \(name.rawValue, privacy: .public)")
        }
    }

    private func ingestJournal(_ record: CKRecord) async {
        guard let remote = RemoteJournal(record: record) else {
            log.notice("sync: fetched Journal record could not be decoded — ignored")
            return
        }
        // ONE call into the store, doing load → merge → save with no suspension in the
        // middle. Reading the journal here and writing it back in a second call was a lost
        // update: a `rename` landing in the gap was reverted by a merge computed against
        // the pre-rename value, and `applySyncMerge` replaces the whole record, stamps
        // included, so the revert then propagated. Actor isolation does not close that gap
        // — it is released at every `await`.
        //
        // A throw is the registry being unreadable. `try?` would collapse that with "this
        // journal is new to us", and adopting a remote journal over a registry we merely
        // failed to parse is issue #11's mistake in a new place. Nothing is written; the
        // record is offered again after the next token reset.
        let localDeviceID = deviceID
        let coverAction: JournalSyncMerge.CoverAction
        do {
            coverAction = try await journalStore.applySyncMerge(id: remote.id) { local in
                guard let local else {
                    // Unknown here: take it as-is, stamps included, and take its cover if
                    // it has one.
                    return JournalSyncMerge(journal: JournalMerge.adopted(remote: remote),
                                            coverAction: remote.coverAsset == nil ? .leave : .adopt)
                }
                return JournalSyncMerge(
                    journal: JournalMerge.merge(local: local, remote: remote,
                                                localDeviceID: localDeviceID,
                                                remoteDeviceID: remote.deviceID),
                    coverAction: JournalMerge.coverAction(local: local, remote: remote,
                                                          localDeviceID: localDeviceID,
                                                          remoteDeviceID: remote.deviceID))
            }
        } catch {
            log.error("""
                sync: journals registry write failed for \(remote.id, privacy: .public) — \
                ingest skipped: \(error.localizedDescription, privacy: .public)
                """)
            return
        }

        // The cover's bytes live in a different store and cannot be written under the
        // registry's isolation, so they move here, after the stamp.
        //
        // **Known window:** a crash between the two leaves this device holding the winning
        // cover stamp with the losing bytes, and the stamps then match, so the picture only
        // corrects on the next cover change on either device. Accepted rather than papered
        // over — the alternative ordering (bytes first) would let a local cover pick landing
        // in the same window be silently overwritten by the fetched one, which is a real
        // loss rather than a stale thumbnail.
        await applyCover(coverAction, for: remote)
        await localStoreDidChange?()
    }

    private func applyCover(_ action: JournalSyncMerge.CoverAction, for remote: RemoteJournal) async {
        switch action {
        case .leave:
            return
        case .adopt:
            guard let assetURL = remote.coverAsset else { return }
            do {
                try await coverStore.ingest(imageData: try Data(contentsOf: assetURL),
                                            journalID: remote.id)
            } catch {
                log.error("""
                    sync: fetched cover for \(remote.id, privacy: .public) could not be \
                    written: \(error.localizedDescription, privacy: .public)
                    """)
            }
        case .remove:
            await coverStore.removeIngested(journalID: remote.id)
        }
    }

    func resolvePushConflicts(_ serverRecords: [CKRecord]) async -> [SyncRecordName] {
        var names: [SyncRecordName] = []
        for record in serverRecords {
            guard let name = SyncCloudIdentifiers.name(of: record.recordID) else { continue }
            // The server's copy is ingested exactly like a fetched change — same merge,
            // same rules — and its system fields are archived, so the resave carries the
            // server's current change tag. The merged CONTENT is not assembled here: the
            // next `recordToPush` reads it back out of the store, which keeps one and only
            // one path from local state to a pushed record.
            await acceptRemote(record)
            names.append(name)
        }
        return names
    }
}
