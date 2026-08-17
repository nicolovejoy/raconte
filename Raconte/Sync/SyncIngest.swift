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
        self.modified = SyncRecordBuilders.decodeJSON(record[SyncJournalField.modified] as? String)
        self.coverAsset = (record[SyncJournalField.cover] as? CKAsset)?.fileURL
        self.deviceID = record[SyncJournalField.deviceID] as? String
    }

    /// Direct construction, for tests and for anything that already has the decoded
    /// values.
    init(id: String, name: String, createdAt: Date, voiceLabels: [String: String] = [:],
         modified: [String: Date] = [:], coverAsset: URL? = nil, deviceID: String? = nil) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.voiceLabels = voiceLabels
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
        // The cover's bytes are not a field of this type — only its stamp is, and it moves
        // by the same rule. `adoptsRemoteCover` answers the bytes half.
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
                voiceLabels: remote.voiceLabels,
                modified: remote.modified.isEmpty ? nil : remote.modified)
    }

    /// Whether the remote's cover file should replace the local one.
    ///
    /// A separate question from `merge` because the cover is not a field of `Journal` at
    /// all — it is a file under `journals/<id>/cover.jpg`, written by `JournalCoverStore`.
    /// Only its LWW stamp lives in the registry, so the stamp merges with everything else
    /// while the bytes move (or don't) on this answer.
    static func adoptsRemoteCover(local: Journal, remote: RemoteJournal,
                                  localDeviceID: String, remoteDeviceID: String?) -> Bool {
        guard remote.coverAsset != nil else { return false }
        return LWWResolve.winner(localStamp: local.modified?["cover"],
                                 remoteStamp: remote.modified["cover"],
                                 localDeviceID: localDeviceID,
                                 remoteDeviceID: remoteDeviceID) == .remote
    }
}

/// The app's side of the CloudKit conversation: turns record names into records to push,
/// and fetched records into local writes (design §6).
///
/// An actor, and the reason is the no-echo rule. Ingest writes through `JournalStore`, the
/// same actor the owner's own edits go through; serializing the whole
/// decode → merge → save sequence here means a fetch landing mid-rename cannot read a
/// half-applied registry. The writes themselves deliberately use `applySyncMerge`, which
/// neither re-stamps `modified` nor fires the sync hook: a sync-caused save that echoed
/// back as a local change would re-upload what was just downloaded, and with a fresh local
/// stamp on it — two devices would then trade the same journal forever, each one's echo
/// looking newer than the other's.
actor SyncRecordExchange: CloudRecordExchange {
    private let journalStore: JournalStore
    private let coverStore: JournalCoverStore
    private let bookkeeping: SyncBookkeepingStore
    private let scanner: SyncTreeScanner
    private let deviceID: String
    private let log: Logger
    /// Called after ingest writes anything, so the library reloads instead of showing
    /// yesterday's journal names until the next launch. Optional — nothing about
    /// correctness depends on it.
    private let localStoreDidChange: (@Sendable () async -> Void)?

    /// Digests of what each in-flight push was actually built from, keyed by record name.
    ///
    /// Recorded at build time rather than re-read at save-confirm time, and the difference
    /// is a real hole rather than a nicety: an edit landing between "record built" and
    /// "save confirmed" would otherwise be written into the ledger as though it had been
    /// uploaded, and if the app died before the second push the reconciliation scan would
    /// see ledger == disk and never send it. A missing entry here means the ledger is left
    /// alone, which costs one redundant upload and never a lost one.
    private var inFlightDigests: [String: UploadedDigest] = [:]

    init(journalStore: JournalStore,
         coverStore: JournalCoverStore,
         bookkeeping: SyncBookkeepingStore,
         scanner: SyncTreeScanner,
         deviceID: String,
         localStoreDidChange: (@Sendable () async -> Void)? = nil,
         log: Logger = Logger(subsystem: "org.pianohouseproject.raconte", category: "sync")) {
        self.journalStore = journalStore
        self.coverStore = coverStore
        self.bookkeeping = bookkeeping
        self.scanner = scanner
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

        if let artifact = scanner.artifact(for: name) {
            inFlightDigests[name.rawValue] = UploadedDigest(sha256: artifact.sha256, bytes: artifact.bytes)
        }
        let base = await archivedRecord(for: name)
        return SyncRecordBuilders.journalRecord(journal: journal,
                                                coverFileURL: hasCover ? coverURL : nil,
                                                deviceID: deviceID,
                                                zoneID: zoneID,
                                                base: base)
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
        guard let digest = inFlightDigests.removeValue(forKey: name.rawValue) else { return }
        try? await bookkeeping.recordUpload(digest, for: name.rawValue)
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
        // `try?` is not enough here: it would collapse "this journal is new to us" and
        // "the registry could not be read" into the same nil, and adopting a remote
        // journal over an unreadable registry is issue #11's mistake in a new place. An
        // unreadable registry means we do not know what we have, so we write nothing —
        // the record will be offered again after the next token reset, and the
        // reconciliation scan reports the registry as skipped either way.
        let local: Journal?
        do {
            local = try await journalStore.journal(id: remote.id)
        } catch {
            log.error("sync: journals registry unreadable — ingest skipped for this fetch")
            return
        }

        let merged: Journal
        let takesCover: Bool
        if let local {
            merged = JournalMerge.merge(local: local, remote: remote,
                                        localDeviceID: deviceID, remoteDeviceID: remote.deviceID)
            takesCover = JournalMerge.adoptsRemoteCover(local: local, remote: remote,
                                                        localDeviceID: deviceID,
                                                        remoteDeviceID: remote.deviceID)
        } else {
            merged = JournalMerge.adopted(remote: remote)
            takesCover = remote.coverAsset != nil
        }

        // Cover first: the registry stamp is what a later comparison reads, so writing it
        // before the bytes are down would let a crash in between leave a journal claiming
        // a cover it does not have.
        if takesCover, let assetURL = remote.coverAsset, let bytes = try? Data(contentsOf: assetURL) {
            try? await coverStore.ingest(imageData: bytes, journalID: remote.id)
        }
        try? await journalStore.applySyncMerge(merged)
        await localStoreDidChange?()
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
