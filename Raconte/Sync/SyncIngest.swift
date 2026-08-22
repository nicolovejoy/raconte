import Foundation
import CloudKit
import os
#if canImport(Darwin)
import Darwin
#endif

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

/// One fetched Entry record, decoded (design §2, §6, T7). Mirrors `RemoteJournal`'s shape
/// and reasoning: everything downstream (T8's per-field merge, this task's assembly) is
/// pure and needs no `CKRecord` fixtures to exercise.
///
/// **Deliberately does NOT carry `manifestSnapshot`.** `EntryIngest.Incoming.manifestJSON`
/// holds those bytes separately, verbatim, because writing them to `manifest.json` is a
/// pass-through with no decode step at all — unlike every field here, which becomes part
/// of `entry.json` through the normal `EntryMetadata` encoder.
struct RemoteEntryFields: Equatable, Sendable, Codable {
    /// From the record NAME, never a field (T5's `RemoteJournal` rule — there is no
    /// captureID field on the Entry record at all, only its identity in the name).
    var captureID: String
    /// The one field `entryRecord` never omits regardless of value (design table:
    /// "ordering without downloading children") — its absence means the record itself is
    /// damaged, not merely that this field was never set, so init fails rather than
    /// defaulting it.
    var capturedAt: Date
    var journalID: String?
    var originalDate: PartialDate?
    var trashedAt: Date?
    var multiVoice: Bool
    var detectedDate: PartialDate?
    var detectionRan: Bool
    var modified: [String: Date]
    /// The origin device's `DeviceIdentity.stable()` (M4 T8 as-built addition, mirroring
    /// `RemoteJournal.deviceID`). Optional for the identical reason: a record written by
    /// a build older than this one has no such field, and an absent deviceID loses every
    /// tie — the safe direction, since a tie means both stamps landed in the same
    /// millisecond and nothing perceptible is lost either way.
    var deviceID: String?

    /// Strict about identity (`captureID`, `capturedAt`) and about `originalDate` — the
    /// same split `EntryMetadata.init(from:)` makes on the local decode path, for the
    /// same reason: `originalDate` is user-authored content, and a value that is present
    /// but unparseable must not be silently treated as "never backdated". Every other
    /// field is additive/lenient, matching `EntryMetadata`'s own leniency for the same
    /// fields, so a damaged optional costs only itself, never the whole record.
    init?(record: CKRecord) {
        guard record.recordType == SyncRecordType.entry,
              case .entry(let captureID)? = SyncCloudIdentifiers.name(of: record.recordID) else { return nil }
        guard let capturedAt = record[SyncEntryField.capturedAt] as? Date else { return nil }
        self.captureID = captureID
        self.capturedAt = capturedAt
        self.journalID = record[SyncEntryField.journalID] as? String
        if let originalDateString = record[SyncEntryField.originalDate] as? String {
            guard let parsed = try? PartialDate(parsing: originalDateString) else { return nil }
            self.originalDate = parsed
        } else {
            self.originalDate = nil
        }
        self.trashedAt = record[SyncEntryField.trashedAt] as? Date
        self.multiVoice = (record[SyncEntryField.multiVoice] as? Bool) ?? false
        self.detectedDate = (record[SyncEntryField.detectedDate] as? String)
            .flatMap { try? PartialDate(parsing: $0) }
        self.detectionRan = (record[SyncEntryField.detectionRan] as? Bool) ?? (self.detectedDate != nil)
        self.modified = SyncRecordBuilders.decodeJSON(record[SyncEntryField.modified] as? String)
        self.deviceID = record[SyncEntryField.deviceID] as? String
    }

    /// Direct construction, for tests and for anything that already has the decoded
    /// values.
    init(captureID: String, capturedAt: Date, journalID: String? = nil, originalDate: PartialDate? = nil,
        trashedAt: Date? = nil, multiVoice: Bool = false, detectedDate: PartialDate? = nil,
        detectionRan: Bool? = nil, modified: [String: Date] = [:], deviceID: String? = nil) {
        self.captureID = captureID
        self.capturedAt = capturedAt
        self.journalID = journalID
        self.originalDate = originalDate
        self.trashedAt = trashedAt
        self.multiVoice = multiVoice
        self.detectedDate = detectedDate
        self.detectionRan = detectionRan ?? (detectedDate != nil)
        self.modified = modified
        self.deviceID = deviceID
    }

    /// What this record describes, as the sidecar type `entry.json` is actually written
    /// as — so a synced-in entry's sidecar is byte-for-byte what a local capture with the
    /// same field values would produce, through the exact same `CaptureCoding.encoder()`.
    var metadata: EntryMetadata {
        EntryMetadata(journalID: journalID, originalDate: originalDate, trashedAt: trashedAt,
                      detectedDate: detectedDate, detectionRan: detectionRan,
                      multiVoice: multiVoice, modified: modified.isEmpty ? nil : modified)
    }
}

/// New-entry ingest, decision half (design §6, T7): "assemble-then-commit". Pure — no
/// filesystem, no CloudKit beyond the value types `RemoteEntryFields` already decoded —
/// so the commit-set rule is exercised with plain fixtures, no staged directories at all.
enum EntryIngest {
    /// Everything gathered for one capture before a decision can be made. `audio` and
    /// `liveLog` are separate CloudKit records (AudioAsset, LiveLog) from `metadata`'s
    /// own Entry record, and may not have arrived yet — that is exactly what `plan`
    /// exists to check.
    struct Incoming {
        var captureID: String
        var manifestJSON: Data
        var metadata: RemoteEntryFields
        var audio: (url: URL, sha256: String)?
        var liveLog: (url: URL, sha256: String)?
    }

    enum IngestAction: Equatable {
        /// Nothing local for this captureID yet: stage, verify, and commit.
        case assembleNew
        /// A capture directory with this id already exists locally — T8's merge path,
        /// never a rename. `plan` never looks at whether the commit set is complete in
        /// this case; an existing capture's own content is authoritative, not whatever
        /// pieces happen to have arrived from the wire.
        case applyToExisting
        /// The commit set is incomplete. Leaves any earlier staging attempt as it was —
        /// the caller retries on the next piece to arrive or the next launch.
        case refuse(String)
    }

    /// Design §6's commit set: manifest + entry (metadata) + the m4a, ALL present, before
    /// anything is written to `captures/`. `metadata` is never optional here — a capture
    /// with no decodable Entry record has no `Incoming` to plan for at all (the caller
    /// never builds one; see `RemoteEntryFields.init?(record:)`), so the two genuinely
    /// independent pieces this function can find missing are the manifest bytes (a Data
    /// value truly empty until fetched — never happens once the Entry record itself has
    /// landed, since `entryRecord` never omits `manifestSnapshot`, but represented
    /// honestly rather than assumed) and the audio (`AudioAsset`, a SEPARATE record that
    /// commonly has not arrived yet). `liveLog` is deliberately absent from every check
    /// below — an optional rider, matching `FinalizeArtifactPush`'s own three-answer
    /// honesty: a degraded capture with no live.jsonl is exactly as syncable as any other.
    static func plan(incoming: Incoming, captureExists: Bool) -> IngestAction {
        guard !captureExists else { return .applyToExisting }
        guard !incoming.manifestJSON.isEmpty else { return .refuse("manifest not yet fetched") }
        guard incoming.audio != nil else { return .refuse("m4a not yet fetched") }
        return .assembleNew
    }
}

/// The durable record of what the Entry record itself carried — persisted to
/// `sync/staging/<captureID>/pending.json` the instant the record decodes (T7 fix round,
/// controller ruling), NOT held only in memory. **Why this exists at all:** CKSyncEngine's
/// change token advances once a fetched record is handed to the delegate, independent of
/// whether this app finished doing anything with it — a record already fetched is not
/// guaranteed to be redelivered absent a full resync. A crash or a background-then-kill
/// between two fetch batches (realistic on first-enable sync, which enqueues the whole
/// archive across paginated batches, plausibly across several app sessions) would
/// otherwise leave an in-memory-only accumulation for a captureID that received Entry +
/// LiveLog in one batch, awaiting AudioAsset in a later one, permanently orphaned: the
/// fresh actor after relaunch has no memory of it, the late AudioAsset alone has no
/// metadata to plan against, and nothing ever revisits it.
///
/// Audio/liveLog pieces are deliberately NOT recorded here — they land as real staged
/// files (`final/recording.m4a`, `transcript/live.jsonl`) beside this sidecar the instant
/// they arrive (sha256-verified before ever touching disk), and their presence is read
/// directly off disk rather than duplicated in this struct, so there is exactly one
/// source of truth for "did this piece arrive" per piece.
private struct PendingEntryRecord: Codable {
    var manifestJSON: Data
    var metadata: RemoteEntryFields
}

/// New-entry ingest, IO half (design §6, T7): commits an already-durably-staged capture
/// directory with one `rename(2)` into `captures/<captureID>/` — mirroring the `.part` →
/// rename convention every other atomic write in this codebase uses (`AtomicFile`). By
/// the time this runs, every piece it needs (manifest bytes, metadata, the audio, and
/// optionally the liveLog) has ALREADY been sha256-verified and durably persisted into
/// `sync/staging/<captureID>/` at arrival — see `PendingEntryRecord` and
/// `SyncRecordExchange`'s `ingestAudio`/`ingestLiveLog`, the T7 fix round's actual fix.
/// This type's job is narrower than its original shape: materialize `manifest.json` +
/// `entry.json` from what was handed to it, make sure nothing unexpected rides along, and
/// commit. The recovery scanner and the library only ever see complete directories; a
/// partially-arrived entry is invisible to both until the rename succeeds.
///
/// **Never partially commits.** Any failure — a losing sha comparison (defense in depth;
/// production only ever hands this function an already-self-consistent pair, since
/// verification now happens at arrival, but a direct caller gets the same protection), an
/// IO error, a losing `rename` — discards the staging directory (R3: `removeItem` is only
/// ever used on paths under `sync/staging/`, never on `captures/` itself) and leaves
/// `captures/` exactly as it was.
enum EntryAssembler {
    /// Stages (idempotently — the directory may already hold durably-persisted pieces),
    /// verifies, and commits `incoming`. Returns whether the capture now exists under
    /// `captures/` as a direct result of this call.
    ///
    /// Callers are expected to have already confirmed `EntryIngest.plan(...) ==
    /// .assembleNew`; this re-derives nothing about that decision — only about whether the
    /// bytes it is actually handed check out.
    ///
    /// **Deliberately does NOT discard the staging directory at entry** — that was the
    /// fix-round defect: the directory is now the durable accumulation site (audio/liveLog
    /// bytes may already be sitting there, sha-verified at arrival, from a PREVIOUS launch
    /// entirely), and wiping it unconditionally would destroy exactly the durability this
    /// fix exists to provide. Instead, `pruneUnexpectedStagingContents` runs right before
    /// the rename — active cleanup, not a blanket wipe, so a stray leftover (a crash-
    /// orphaned atomic-write temp file, garbage a test or a bug left lying around) can
    /// never ride into `captures/`, while a genuinely valid, durably-staged piece set
    /// still commits regardless of what unrelated cruft sits beside it.
    @discardableResult
    static func assemble(incoming: EntryIngest.Incoming, containerRoot: URL) -> Bool {
        let fm = FileManager.default
        let stagingDir = AppContainer.syncStagingCaptureURL(containerRoot: containerRoot,
                                                             captureID: incoming.captureID)

        guard let audio = incoming.audio else { return false }

        do {
            try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)

            try incoming.manifestJSON.write(
                to: SegmentLayout.manifestURL(captureDirectory: stagingDir), options: .atomic)

            let entryData = try CaptureCoding.encoder().encode(incoming.metadata.metadata)
            try entryData.write(
                to: SegmentLayout.entryMetadataURL(captureDirectory: stagingDir), options: .atomic)

            let audioBytes = try Data(contentsOf: audio.url)
            guard SyncTreeScanner.sha256Hex(audioBytes) == audio.sha256 else {
                try? fm.removeItem(at: stagingDir)
                return false
            }
            let finalDir = SegmentLayout.finalDirectory(captureDirectory: stagingDir)
            try fm.createDirectory(at: finalDir, withIntermediateDirectories: true)
            try audioBytes.write(
                to: SegmentLayout.finalRecordingURL(captureDirectory: stagingDir), options: .atomic)

            // Transcript artifacts are optional riders (design §6): a degraded capture
            // with no live.jsonl assembles exactly like any other.
            if let liveLog = incoming.liveLog {
                let liveBytes = try Data(contentsOf: liveLog.url)
                guard SyncTreeScanner.sha256Hex(liveBytes) == liveLog.sha256 else {
                    try? fm.removeItem(at: stagingDir)
                    return false
                }
                let transcriptDir = SegmentLayout.transcriptDirectory(captureDirectory: stagingDir)
                try fm.createDirectory(at: transcriptDir, withIntermediateDirectories: true)
                try liveBytes.write(
                    to: SegmentLayout.liveTranscriptURL(captureDirectory: stagingDir), options: .atomic)
            }

            // The durable pending sidecar (`PendingEntryRecord`) is now fully materialized
            // into manifest.json + entry.json above and must not ride into `captures/` — a
            // committed capture directory never has one.
            try? fm.removeItem(at: AppContainer.syncStagingPendingStateURL(
                containerRoot: containerRoot, captureID: incoming.captureID))

            pruneUnexpectedStagingContents(stagingDir: stagingDir, hasLiveLog: incoming.liveLog != nil)

            let capturesRoot = AppContainer.capturesRoot(containerRoot: containerRoot)
            try fm.createDirectory(at: capturesRoot, withIntermediateDirectories: true)
            let destination = SegmentLayout.captureDirectory(capturesRoot: capturesRoot,
                                                              captureID: incoming.captureID)
            // The commit: one `rename(2)`, same primitive `AtomicFile` uses for a single
            // file. POSIX rename within a volume is atomic, so the recovery scanner and
            // the library see either nothing here or the fully-assembled directory, never
            // a partial one.
            guard rename(stagingDir.path, destination.path) == 0 else {
                try? fm.removeItem(at: stagingDir)
                return false
            }
            return true
        } catch {
            try? fm.removeItem(at: stagingDir)
            return false
        }
    }

    /// Removes anything under `stagingDir` that is not part of the canonical committed
    /// shape (`manifest.json`, `entry.json`, `final/recording.m4a`, and — only when a
    /// liveLog rider is present — `transcript/live.jsonl`), so nothing else can ride the
    /// rename into `captures/`. All removals are strictly scoped to paths under
    /// `stagingDir` itself (R3).
    private static func pruneUnexpectedStagingContents(stagingDir: URL, hasLiveLog: Bool) {
        let fm = FileManager.default
        var allowedTop: Set<String> = [SegmentLayout.manifestFileName, SegmentLayout.entryMetadataFileName,
                                       SegmentLayout.finalDirName]
        if hasLiveLog { allowedTop.insert(SegmentLayout.transcriptDirName) }
        if let names = try? fm.contentsOfDirectory(atPath: stagingDir.path) {
            for name in names where !allowedTop.contains(name) {
                try? fm.removeItem(at: stagingDir.appendingPathComponent(name))
            }
        }

        let finalDir = SegmentLayout.finalDirectory(captureDirectory: stagingDir)
        if let names = try? fm.contentsOfDirectory(atPath: finalDir.path) {
            for name in names where name != SegmentLayout.finalRecordingName {
                try? fm.removeItem(at: finalDir.appendingPathComponent(name))
            }
        }

        let transcriptDir = SegmentLayout.transcriptDirectory(captureDirectory: stagingDir)
        if hasLiveLog {
            if let names = try? fm.contentsOfDirectory(atPath: transcriptDir.path) {
                for name in names where name != SegmentLayout.liveTranscriptFileName {
                    try? fm.removeItem(at: transcriptDir.appendingPathComponent(name))
                }
            }
        } else {
            // No liveLog rider at all this commit: `transcript/`, if present, is entirely
            // unexpected — a leftover directory must not ride along looking like a real one.
            try? fm.removeItem(at: transcriptDir)
        }
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

/// Per-field last-writer-wins for entries (design §4, M4 T8) — mirrors `JournalMerge`'s
/// shape exactly, and shares its `LWWResolve` comparison rather than re-implementing it:
/// a tie-break rule that diverged between the two merges would mean the SAME pair of
/// stamps resolves differently depending on which record type they happened to sit on.
///
/// `journalID`/`originalDate`/`trashedAt`/`multiVoice` are ordinary per-field LWW
/// (design §2's schema table). `detectedDate`/`detectionRan` are deliberately NOT — the
/// table calls them "write-once (origin device only)" / "write-once latch", and this
/// task's owner ruling states the rule precisely: once `detectionRan` is true anywhere,
/// it must never merge back to false regardless of either side's stamp. An ordinary
/// stamp comparison would let an un-run remote — unstamped, or merely stamped LATER by
/// nothing but wall-clock skew — revert a detection this device already ran and the
/// owner may since have cleared by hand: issue #21's exact hazard, newly reachable
/// through sync instead of only through a corrupted local latch.
enum EntryFieldMerge {
    /// The merged sidecar, written back verbatim by `EntryMetadataStore.applySyncMerge`.
    ///
    /// Unlike `JournalMerge.merge`, there is no identity field to protect here —
    /// `EntryMetadata` carries no id/createdAt of its own (`captureID`/`capturedAt` live
    /// only in `RemoteEntryFields`, for record identity and ordering, never in the
    /// sidecar) — so every field this type owns participates in the merge.
    static func merge(local: EntryMetadata, remote: RemoteEntryFields,
                      localDeviceID: String, remoteDeviceID: String?) -> EntryMetadata {
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

        if resolve("journalID") == .remote { merged.journalID = remote.journalID }
        if resolve("originalDate") == .remote { merged.originalDate = remote.originalDate }
        if resolve("trashedAt") == .remote { merged.trashedAt = remote.trashedAt }
        if resolve("multiVoice") == .remote { merged.multiVoice = remote.multiVoice }

        // The write-once latch (owner ruling, verbatim above). `detectedDate` travels
        // WITH `detectionRan` — the pair is set together, never independently
        // (`EntryMetadata.detectionRan`'s own doc comment) — so the first device to have
        // actually run detection donates both. Once local has already run, an
        // independently-run remote (only reachable if detection somehow ran twice)
        // changes nothing: local's answer, whatever it is, stands.
        if !merged.detectionRan && remote.detectionRan {
            merged.detectionRan = true
            merged.detectedDate = remote.detectedDate
            if let stamp = remote.modified["detectionRan"] { modified["detectionRan"] = stamp }
            if let stamp = remote.modified["detectedDate"] { modified["detectedDate"] = stamp }
        }

        merged.modified = modified.isEmpty ? nil : modified
        return merged
    }
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
    /// Where an already-local entry's inbound field merge writes (M4 T8). Optional for
    /// the same reason `containerRoot` is: every existing test/call site that never
    /// exercises entry sync keeps compiling unchanged, and `SyncCoordinator.live()` is
    /// the one production caller and always supplies the library's real, single shared
    /// instance — never a throwaway one built here, which would be a second,
    /// uncoordinated writer over the same `entry.json` files a local edit can also be
    /// writing (the identical reasoning `SyncCoordinator.live()`'s doc comment gives for
    /// reusing `library.journalStore` rather than building a fresh `JournalStore`).
    private let entryMetadataStore: EntryMetadataStore?
    /// Where `captures/` and `sync/staging/` live (T7). Optional so every existing
    /// test/call site that never exercises entry ingest keeps compiling unchanged — a
    /// nil root degrades exactly like the pre-T7 "no builder/ingest yet" cases did,
    /// never a crash. `SyncCoordinator.live()` is the one production caller and always
    /// supplies the real container root; without it entry ingest would silently never
    /// run in a shipped build, so that wiring is load-bearing, not decorative.
    private let containerRoot: URL?
    /// Called after ingest actually writes something, so the library reloads instead of
    /// showing yesterday's journal names until the next launch. Optional — nothing about
    /// correctness depends on it.
    private let localStoreDidChange: (@Sendable () async -> Void)?
    /// The not-empty-locally guard for #80's inbound journal deletion (B2, R3) —
    /// `LibraryScreenModel.isJournalEmptyAfterRescan`, injected rather than
    /// reimplemented here: the rule that decides emptiness lives once, at the library,
    /// against a FRESH scan (its own doc comment states the freshness obligation
    /// travels with the exposure). Optional so every existing test/call site that never
    /// exercises deletion keeps compiling unchanged; `ingestJournalDeletion` treats a nil
    /// closure as "refuse" — see there.
    private let journalIsEmptyAfterRescan: (@Sendable (String) async -> Bool)?
    /// The engine, wired after construction (`attach(engine:)`) because
    /// `SyncCoordinator.live()` builds this exchange before the engine that needs it
    /// exists — the engine's own init takes the exchange. Needed for exactly one thing:
    /// re-pushing a journal whose inbound deletion was refused (not empty locally), so
    /// the deleting device's server copy is restored rather than left to drift.
    private var engine: (any CloudEngineControl)?

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
         containerRoot: URL? = nil,
         entryMetadataStore: EntryMetadataStore? = nil,
         localStoreDidChange: (@Sendable () async -> Void)? = nil,
         journalIsEmptyAfterRescan: (@Sendable (String) async -> Bool)? = nil,
         log: Logger = Logger(subsystem: "org.pianohouseproject.raconte", category: "sync")) {
        self.journalStore = journalStore
        self.coverStore = coverStore
        self.bookkeeping = bookkeeping
        self.deviceID = deviceID
        self.containerRoot = containerRoot
        self.entryMetadataStore = entryMetadataStore
        self.localStoreDidChange = localStoreDidChange
        self.journalIsEmptyAfterRescan = journalIsEmptyAfterRescan
        self.log = log
    }

    /// See `engine`'s doc comment for why this cannot be an init parameter in production
    /// — tests that need it (the not-empty-locally re-push) call this directly instead.
    func attach(engine: any CloudEngineControl) {
        self.engine = engine
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
        case .entry(let captureID):
            await ingestEntry(record, captureID: captureID)
        case .audio(let captureID):
            await ingestAudio(record, captureID: captureID)
        case .liveLog(let captureID):
            await ingestLiveLog(record, captureID: captureID)
        case .revision, .markerStream:
            // T9/T10 own these.
            log.debug("sync: no ingest yet for \(name.rawValue, privacy: .public)")
        }
    }

    // MARK: Ingest — new entries (T7, design §6; fix round: durable staging — see
    // `PendingEntryRecord`'s doc comment for why an in-memory-only buffer is not
    // sufficient. Every piece is persisted into `sync/staging/<captureID>/` the instant
    // it arrives and sha256-verified BEFORE it is ever written to disk — never after —
    // so a mismatched piece is refused and simply never persisted. Nothing about the
    // captureID's state lives in this actor's memory; `attemptEntryAssembly` always
    // rereads `sync/staging/<captureID>/` fresh, which is what makes a brand-new actor
    // after a relaunch pick up exactly where a torn-down one left off.)

    private func ingestEntry(_ record: CKRecord, captureID: String) async {
        guard let containerRoot else {
            log.debug("sync: no container root wired — entry ingest skipped")
            return
        }
        guard let fields = RemoteEntryFields(record: record) else {
            log.notice("sync: fetched Entry record could not be decoded — ignored")
            return
        }
        // `manifestSnapshot` is read here, not through `RemoteEntryFields` (see that
        // type's header) — a pass-through string→Data conversion, not a decode.
        let manifestString = record[SyncEntryField.manifestSnapshot] as? String
        let manifestJSON = manifestString?.data(using: .utf8) ?? Data()
        let stagingDir = AppContainer.syncStagingCaptureURL(containerRoot: containerRoot, captureID: captureID)
        do {
            try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            let state = PendingEntryRecord(manifestJSON: manifestJSON, metadata: fields)
            let data = try CaptureCoding.encoder().encode(state)
            try data.write(to: AppContainer.syncStagingPendingStateURL(
                containerRoot: containerRoot, captureID: captureID), options: .atomic)
        } catch {
            log.error("""
                sync: could not persist pending entry state for \(captureID, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
            return
        }
        await attemptEntryAssembly(captureID: captureID, containerRoot: containerRoot)
    }

    private func ingestAudio(_ record: CKRecord, captureID: String) async {
        guard let containerRoot else {
            log.debug("sync: no container root wired — entry ingest skipped")
            return
        }
        guard let asset = record[SyncChildAssetField.file] as? CKAsset, let url = asset.fileURL,
              let claimedSHA256 = record[SyncChildAssetField.sha256] as? String else {
            log.notice("sync: fetched AudioAsset record missing its file or sha256 — ignored")
            return
        }
        guard let bytes = try? Data(contentsOf: url) else {
            log.error("sync: could not read the fetched AudioAsset bytes for \(captureID, privacy: .public)")
            return
        }
        // Verified BEFORE anything is persisted — the whole point of the fix round: a
        // mismatched piece must never sit on disk waiting for a commit that will only
        // discover the mismatch later, and must never poison a sibling piece that
        // arrived correctly.
        guard SyncTreeScanner.sha256Hex(bytes) == claimedSHA256 else {
            log.error("""
                sync: AudioAsset sha256 mismatch for \(captureID, privacy: .public) — refused, \
                never persisted
                """)
            return
        }
        let stagingDir = AppContainer.syncStagingCaptureURL(containerRoot: containerRoot, captureID: captureID)
        do {
            try FileManager.default.createDirectory(
                at: SegmentLayout.finalDirectory(captureDirectory: stagingDir), withIntermediateDirectories: true)
            try bytes.write(to: SegmentLayout.finalRecordingURL(captureDirectory: stagingDir), options: .atomic)
        } catch {
            log.error("""
                sync: could not persist staged audio for \(captureID, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
            return
        }
        await attemptEntryAssembly(captureID: captureID, containerRoot: containerRoot)
    }

    private func ingestLiveLog(_ record: CKRecord, captureID: String) async {
        guard let containerRoot else {
            log.debug("sync: no container root wired — entry ingest skipped")
            return
        }
        guard let asset = record[SyncChildAssetField.file] as? CKAsset, let url = asset.fileURL,
              let claimedSHA256 = record[SyncChildAssetField.sha256] as? String else {
            log.notice("sync: fetched LiveLog record missing its file or sha256 — ignored")
            return
        }
        guard let bytes = try? Data(contentsOf: url) else {
            log.error("sync: could not read the fetched LiveLog bytes for \(captureID, privacy: .public)")
            return
        }
        guard SyncTreeScanner.sha256Hex(bytes) == claimedSHA256 else {
            log.error("""
                sync: LiveLog sha256 mismatch for \(captureID, privacy: .public) — refused, \
                never persisted
                """)
            return
        }
        let stagingDir = AppContainer.syncStagingCaptureURL(containerRoot: containerRoot, captureID: captureID)
        do {
            try FileManager.default.createDirectory(
                at: SegmentLayout.transcriptDirectory(captureDirectory: stagingDir), withIntermediateDirectories: true)
            try bytes.write(to: SegmentLayout.liveTranscriptURL(captureDirectory: stagingDir), options: .atomic)
        } catch {
            log.error("""
                sync: could not persist staged liveLog for \(captureID, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
            return
        }
        await attemptEntryAssembly(captureID: captureID, containerRoot: containerRoot)
    }

    /// Rereads `sync/staging/<captureID>/pending.json` fresh from disk every time — this
    /// IS the rehydration (fix round): there is no in-memory cache to be stale, because
    /// there is no in-memory cache at all. `nil` means no Entry piece is durably staged:
    /// either none ever arrived, or what was there could not be parsed and has just been
    /// discarded as garbage (R3: the `removeItem` below is strictly scoped to this
    /// captureID's own `sync/staging/` subdirectory — the whole directory, not merely the
    /// sidecar, since a corrupt sidecar means this device cannot trust anything else
    /// staged alongside it either).
    private func readPendingState(captureID: String, containerRoot: URL) -> PendingEntryRecord? {
        let stagingDir = AppContainer.syncStagingCaptureURL(containerRoot: containerRoot, captureID: captureID)
        let url = AppContainer.syncStagingPendingStateURL(containerRoot: containerRoot, captureID: captureID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url),
              let state = try? CaptureCoding.decoder().decode(PendingEntryRecord.self, from: data) else {
            log.error("sync: garbage staging for \(captureID, privacy: .public) — discarding")
            try? FileManager.default.removeItem(at: stagingDir)
            return nil
        }
        return state
    }

    /// Asks `EntryIngest.plan` whenever enough is DURABLY staged to ask it at all — the
    /// Entry record's pending sidecar must exist (it carries both `metadata` and the
    /// manifest bytes). Called after every piece arrives (in any order, and regardless of
    /// which app launch each piece arrived in).
    private func attemptEntryAssembly(captureID: String, containerRoot: URL) async {
        let stagingDir = AppContainer.syncStagingCaptureURL(containerRoot: containerRoot, captureID: captureID)
        let capturesRoot = AppContainer.capturesRoot(containerRoot: containerRoot)
        let captureExists = FileManager.default.fileExists(
            atPath: SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID).path)

        // T8 owns merging into an already-local capture. Checked and acted on BEFORE
        // trying to read any pending state: requiring a readable pending sidecar first
        // would leave staging permanently orphaned for every piece that arrives AFTER an
        // earlier piece already cleared it via this very branch (fix-round finding — the
        // pending sidecar for an existing capture is removed the first time this fires,
        // so a later late piece would otherwise find no sidecar and bail before ever
        // reaching a cleanup decision).
        //
        // Deliberately does NOT route through `EntryIngest.plan`'s `.applyToExisting`
        // case (still structurally unreachable below, for the same reason the T7-era
        // comment there gave): merging needs only the metadata fields, which arrive
        // solely on the Entry record itself, never assembled from a commit set. If an
        // Entry piece happens to be durably staged (this call was reached via the Entry
        // record's own arrival), its `metadata` is the remote side of the merge; if not
        // (this call was reached via a late audio/liveLog piece for a capture that
        // already exists — an entry sync already has locally never needs those bytes at
        // all), there is nothing to merge and this is cleanup only.
        guard !captureExists else {
            if let state = readPendingState(captureID: captureID, containerRoot: containerRoot) {
                await applyExistingEntryMerge(remote: state.metadata, captureID: captureID)
            }
            try? FileManager.default.removeItem(at: stagingDir)
            return
        }

        guard let state = readPendingState(captureID: captureID, containerRoot: containerRoot) else { return }

        // Presence, read directly off the staged files themselves — not duplicated
        // in-memory or in the sidecar. The sha256 is recomputed off what is already
        // durably staged (already verified once, at arrival); `EntryAssembler` re-checks
        // it again as a defense-in-depth safety net, not because production can make it
        // disagree.
        let audio = stagedPiece(url: SegmentLayout.finalRecordingURL(captureDirectory: stagingDir))
        let liveLog = stagedPiece(url: SegmentLayout.liveTranscriptURL(captureDirectory: stagingDir))

        let incoming = EntryIngest.Incoming(captureID: captureID, manifestJSON: state.manifestJSON,
                                            metadata: state.metadata, audio: audio, liveLog: liveLog)

        switch EntryIngest.plan(incoming: incoming, captureExists: false) {
        case .assembleNew:
            guard EntryAssembler.assemble(incoming: incoming, containerRoot: containerRoot) else {
                // Refused inside the assembler — logged there is not possible (it is a
                // pure/IO type with no logger), so the caller reports it. The durable
                // staging is left as-is (barring what the assembler itself discarded on a
                // hard failure): the same pieces are retried whenever another arrives, or
                // on this device's next launch.
                log.error("sync: entry \(captureID, privacy: .public) assembly failed — will retry")
                return
            }
            await localStoreDidChange?()
        case .applyToExisting:
            // Unreachable in practice — the `guard !captureExists` above already
            // handles that case, and does the actual T8 merge (`applyExistingEntryMerge`)
            // before ever reaching this call — but `IngestAction` is a 3-case enum and
            // the switch stays exhaustive. Same cleanup, for defensive symmetry.
            try? FileManager.default.removeItem(at: stagingDir)
        case .refuse(let reason):
            log.debug("sync: entry \(captureID, privacy: .public) assembly not ready yet: \(reason, privacy: .public)")
        }
    }

    /// T8: an inbound Entry record for a capture ALREADY present locally merges
    /// field-by-field via `EntryFieldMerge`/`EntryMetadataStore.applySyncMerge`, rather
    /// than being dropped. No staging, no rename — `EntryIngest.IngestAction
    /// .applyToExisting`'s own doc comment states the principle: "an existing capture's
    /// own content is authoritative, not whatever pieces happen to have arrived from the
    /// wire," so only the metadata fields participate, never the audio/manifest bytes.
    private func applyExistingEntryMerge(remote: RemoteEntryFields, captureID: String) async {
        guard let entryMetadataStore else {
            log.debug("sync: no entry metadata store wired — existing-entry merge skipped")
            return
        }
        let localDeviceID = deviceID
        do {
            try await entryMetadataStore.applySyncMerge(captureID: captureID) { local in
                EntryFieldMerge.merge(local: local, remote: remote,
                                      localDeviceID: localDeviceID, remoteDeviceID: remote.deviceID)
            }
        } catch {
            log.error("""
                sync: existing-entry merge failed for \(captureID, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
            return
        }
        await localStoreDidChange?()
    }

    /// `(url, sha256)` for a file already sitting at `url`, or nil when nothing is there —
    /// the shape `EntryIngest.Incoming` needs. The sha256 is a fresh hash of exactly what
    /// is on disk right now, not a value carried over from arrival time.
    private func stagedPiece(url: URL) -> (url: URL, sha256: String)? {
        guard let bytes = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return (url: url, sha256: SyncTreeScanner.sha256Hex(bytes))
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
                    //
                    // **This is the line that resurrects a deleted journal** (#80 owner
                    // ruling 3, accepted and not fixed): a peer that was offline when the
                    // deletion happened re-pushes the journal on reconnect, and to this
                    // device that save is indistinguishable from a journal it has simply
                    // never seen — there is no delete tombstone to consult. A reader
                    // debugging "why did my deleted journal come back?" lands HERE, not on
                    // `acceptRemoteJournalDeletion` (which only decides whether to apply a
                    // deletion), so the note belongs in both places.
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

    // MARK: Ingest — deletion (#80, B2)

    /// An inbound JOURNAL deletion. See `CloudEngineControl.acceptRemoteJournalDeletion`'s
    /// doc comment for why every other record kind never reaches this file at all.
    ///
    /// **Accepted, documented, not fixed (#80 owner ruling 3):** an offline peer that
    /// edits this journal AFTER the deleting device's delete lands here will still
    /// re-push it once that peer reconnects — last-writer-wins on the record's very
    /// existence, no delete tombstone. To THIS app, that later save looks exactly like a
    /// legitimate edit of a journal that still exists everywhere else it can see. v1
    /// accepts that a delete can be undone by a late edit; a real tombstone is out of
    /// scope.
    func acceptRemoteJournalDeletion(id: String) async {
        // The load-bearing rule (#80): a journal that is NOT empty locally must never be
        // removed by an inbound deletion — that would orphan its entries into a journal
        // no longer in the registry, with no UI route back to them.
        //
        // A nil closure (sync disabled in this build, or a fake with nothing to lose)
        // refuses rather than guesses: deleting blind with no way to check for local
        // entries is exactly the hazard this guard exists to close, so "cannot ask"
        // must read the same as "the answer might be no".
        guard let journalIsEmptyAfterRescan else {
            log.notice("""
                sync: inbound deletion for journal \(id, privacy: .public) refused — no \
                emptiness check wired
                """)
            return
        }
        guard await journalIsEmptyAfterRescan(id) else {
            // Refused. Re-push so the deleting device's server copy is restored rather
            // than left to drift until the next full reconciliation scan — which would
            // not even notice: this device's local content, and therefore its digest,
            // never changed, so the scan sees nothing to send.
            log.notice("""
                sync: inbound deletion for journal \(id, privacy: .public) refused — not \
                empty locally; re-pushing
                """)
            // Forget what this device knows about the SERVER's copy first (gate finding,
            // Important 4). Two independent reasons, and the second holds even if the
            // first turns out not to:
            //
            // 1. `journalRecordToPush` builds on `archivedRecord(for:)` — archived system
            //    fields carrying a `recordChangeTag` for a record the server has just
            //    deleted. A save under `.ifServerRecordUnchanged` cannot match a tag on a
            //    record that no longer exists, so it fails rather than recreating it.
            //    Dropping the archived fields makes the next build a plain create, which
            //    is what restoring a deleted record actually requires. (Not measured
            //    against CloudKit — no server access — but harmless if the error code
            //    turns out to differ: a create for a record that unexpectedly still
            //    exists comes back `.serverRecordChanged` and routes through the normal
            //    conflict merge.)
            // 2. Clearing the ledger entry gives this re-push a RETRY. `SyncPlanner
            //    .reconcile` enqueues new-or-digest-changed artifacts only, and this
            //    device's content never changed — so with the ledger intact, a re-push
            //    that fails for any reason is never attempted again and the two devices
            //    diverge silently. With it cleared, the journal reads as never-uploaded
            //    and the next launch's reconciliation scan re-enqueues it.
            await forgetServerState(for: .journal(id: id))
            await engine?.enqueueSaves([.journal(id: id)])
            return
        }
        do {
            try await journalStore.applySyncDelete(id: id)
            // The record is gone from the server and from here; its system fields and
            // ledger entry describe a record that no longer exists (gate finding, Minor
            // 3). Harmless if left — a resurrected journal's `acceptRemote` overwrites
            // them — but this is the same cleanup the refusal branch needs, so it is the
            // same call.
            await forgetServerState(for: .journal(id: id))
        } catch {
            // Unknown here too (already gone independently — a genuine no-op) or the
            // last-remaining-journal guard (this device's only journal — refused, the
            // same UI-story reason a LOCAL delete is refused for it). Neither is an
            // error worth logging above debug.
            log.debug("""
                sync: inbound deletion for journal \(id, privacy: .public) not applied: \
                \(String(describing: error), privacy: .public)
                """)
            return
        }
        await localStoreDidChange?()
    }

    /// Drops everything this device remembers about the SERVER's copy of `name`: the
    /// archived system fields (so the next push is a create, not an update against a tag
    /// the server no longer holds) and the upload-ledger entry (so a reconciliation scan
    /// treats the artifact as never-uploaded and re-enqueues it).
    ///
    /// Failures are logged, not swallowed: neither is data loss — the worst case is one
    /// redundant upload, or a re-push that has to wait for the next reconciliation — but
    /// a silent failure here is exactly what makes a divergence invisible.
    private func forgetServerState(for name: SyncRecordName) async {
        do {
            try await bookkeeping.deleteSystemFields(for: name.rawValue)
        } catch {
            log.error("""
                sync: could not drop archived system fields for \(name.rawValue, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
        }
        do {
            try await bookkeeping.clearUpload(for: name.rawValue)
        } catch {
            log.error("""
                sync: could not clear the upload ledger for \(name.rawValue, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
        }
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
