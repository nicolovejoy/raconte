import Foundation
import CloudKit

/// The CloudKit record types this app writes (design §2). Constants rather than inline
/// literals because the record type is part of the wire format: a typo here is a second,
/// silently-empty schema in the owner's container, not a compile error.
/// One per record kind, added as its builder lands (T6, T9, T10) rather than declared up
/// front — an unused constant is the kind of thing that quietly acquires a typo.
enum SyncRecordType {
    static let journal = "Journal"
    static let entry = "Entry"
    static let audioAsset = "AudioAsset"
    static let liveLog = "LiveLog"
    static let revision = "Revision"
    static let markerStream = "MarkerStream"
}

/// The Journal record's field names (design §2, plus two as-built additions documented
/// on `SyncRecordBuilders.journalRecord`).
enum SyncJournalField {
    static let name = "name"
    static let createdAt = "createdAt"
    static let voiceLabels = "voiceLabels"
    static let cover = "cover"
    /// The journal's stored span (spec ruling 2, #70), additive like `voiceLabels`/`cover`
    /// above — a record built by a build that predates this field simply has no such key.
    static let span = "span"
    /// As-built: the per-field LWW stamps themselves. Design §2 says name/voiceLabels are
    /// "LWW per field" and §2 note 5 says `journals.json` grows a `modified` map — but the
    /// table never says how the stamps reach the other device. They have to: a receiver
    /// with no stamps cannot decide which side is newer, and would fall back to
    /// whole-record LWW, which is exactly the mutation this task's check rejects.
    static let modified = "modified"
    /// As-built: the origin device's `DeviceIdentity.stable()`. The locked tie-break rule
    /// is "equal stamps → lexicographically greater deviceID wins", which is unimplementable
    /// without knowing the remote's deviceID. See `JournalMerge` for the alternative that
    /// was rejected.
    static let deviceID = "deviceID"
}

/// The Entry record's field names (design §2 table). `capturedAt` and
/// `manifestSnapshot` are not `EntryMetadata` fields at all — `capturedAt` is the
/// capture's own creation instant (`Manifest.createdAt`) and `manifestSnapshot` is the
/// manifest's verbatim bytes — both supplied by the caller alongside the sidecar, the
/// same split `entryRecord`'s parameter list makes.
enum SyncEntryField {
    static let journalID = "journalID"
    static let originalDate = "originalDate"
    static let trashedAt = "trashedAt"
    static let multiVoice = "multiVoice"
    static let detectedDate = "detectedDate"
    static let detectionRan = "detectionRan"
    static let manifestSnapshot = "manifestSnapshot"
    static let capturedAt = "capturedAt"
    /// Per-field LWW stamps, same shape and same reason as `SyncJournalField.modified`
    /// — see that constant's doc comment.
    static let modified = "modified"
    /// As-built (M4 T8), mirroring `SyncJournalField.deviceID`: the origin device's
    /// `DeviceIdentity.stable()`, needed by `EntryFieldMerge`'s locked tie-break rule
    /// ("equal stamps → lexicographically greater deviceID wins"), which is
    /// unimplementable without knowing the remote's deviceID.
    static let deviceID = "deviceID"
}

/// Shared by `AudioAsset`, `LiveLog`, and `Revision` (design §2): all three are
/// immutable, write-once child records that reference their `Entry` with a
/// `.deleteSelf` action, so a purge of the Entry cascades to all of them server-side
/// (design §5) rather than orphaning them.
enum SyncChildAssetField {
    static let file = "file"
    static let sha256 = "sha256"
    static let bytes = "bytes"
    static let entryRef = "entryRef"
}

/// `AudioAsset`-only fields, beyond the shared integrity/reference set above.
enum SyncAudioField {
    static let frameCount = "frameCount"
    static let sampleRate = "sampleRate"
}

/// `Revision`-only field (design §2 table, T9): the payload itself, named `body`
/// rather than reusing `SyncChildAssetField.file` — the design table's own wording,
/// kept distinct because `file` on `AudioAsset`/`LiveLog` names literal captured
/// media while `body` names a `canonical-<n>.json` chain node.
///
/// `entryRef` (shared, above) carries a second job for THIS record kind that it does
/// not carry for `AudioAsset`/`LiveLog`: `SyncRecordName.revision(id:)` names only the
/// revision's own ULID (design §2 note 1 — "never the file number"), with no captureID
/// component at all, unlike `.audio(captureID:)`/`.liveLog(captureID:)`, which both
/// embed it directly. A fetched Revision record therefore has NO OTHER WAY to say
/// which capture it belongs to — `entryRef` is read back on ingest
/// (`SyncRecordExchange.ingestRevision`) to recover that captureID, in addition to its
/// ordinary cascade-delete job. Deliberately not a change to `SyncRecordName` itself
/// (already shipped/consumed by T3's `SyncTreeScanner.scanRevisions`, which mints
/// `.revision(id:)` with a single argument) — extending this record's OWN fields
/// closes the gap without touching that already-tested shape.
enum SyncRevisionField {
    static let body = "body"
}

/// `MarkerStream`-only field (design §2 table, T10): the device's own marker-log bytes,
/// travelling as a plain `String` (like `Entry.manifestSnapshot`), never a `CKAsset` —
/// design §7.4/§2 says so explicitly ("single-writer by construction → grows
/// monotonically; whole-field replace is safe"), and a marker log is small text, not
/// media, so there is no size reason to prefer an asset either.
enum SyncMarkerStreamField {
    static let content = "content"
}

/// Pure builders: local state in, `CKRecord` out. No IO beyond the caller-supplied file
/// URL for an asset, no engine, no store — which is what makes every field-coverage
/// assertion in `SyncJournalRecordTests`/`SyncEntryRecordTests` runnable with no
/// CloudKit account and no server traffic (`CKRecord` is constructible offline; only
/// `CKSyncEngine` is not).
///
/// `revisionRecord` landed in T9; `markerStreamRecord` landed in T10.
enum SyncRecordBuilders {

    /// The Journal record (design §2).
    ///
    /// `base` carries the archived CloudKit **system fields** for this record when this
    /// device has seen a server copy before — that is what makes the push carry the
    /// server's change tag, so CloudKit can detect a conflict instead of blindly
    /// clobbering. With no archive (never synced, or the disposable `sync/` cache was
    /// lost) a fresh record is built and the first save resolves as an ordinary conflict.
    ///
    /// Dictionary fields (`voiceLabels`, `modified`) travel as **sorted-keys JSON
    /// strings**, not as CloudKit dictionaries — CloudKit has no dictionary field type,
    /// and encoding them with the same `CaptureCoding.lineEncoder()` that writes
    /// `journals.json` means a stamp's millisecond resolution is identical on the wire
    /// and on disk. If it were not, a value that merely round-tripped through the cloud
    /// would compare as *newer* than itself and both devices would push forever.
    ///
    /// `voiceLabels` and `modified` are written even when empty (`"{}"`), unlike
    /// `Journal`'s own encoder which omits them: on disk, omitting keeps an untouched
    /// journal's bytes stable; on the wire, omitting a key from a record whose server
    /// copy has it would leave the server's stale value in place, so clearing every voice
    /// label would silently not sync.
    static func journalRecord(journal: Journal,
                              coverFileURL: URL?,
                              deviceID: String,
                              zoneID: CKRecordZone.ID,
                              base: CKRecord? = nil) -> CKRecord {
        let recordID = SyncCloudIdentifiers.recordID(.journal(id: journal.id), zoneID: zoneID)
        let record = base ?? CKRecord(recordType: SyncRecordType.journal, recordID: recordID)

        record[SyncJournalField.name] = journal.name
        record[SyncJournalField.createdAt] = journal.createdAt
        record[SyncJournalField.voiceLabels] = encodeJSON(journal.voiceLabels)
        record[SyncJournalField.modified] = encodeJSON(journal.modified ?? [:])
        record[SyncJournalField.deviceID] = deviceID
        // Assigned in BOTH directions on purpose. Clearing a cover has to travel as an
        // explicit nil — leaving the key untouched would let the server keep the old
        // asset forever, so "remove cover" would be the one journal edit that never
        // synced. Assigning nil removes the key, so an absent cover still produces a
        // record with no `cover` in `allKeys()`.
        record[SyncJournalField.cover] = coverFileURL.map { CKAsset(fileURL: $0) }
        // Same "assigned in both directions" rule as `cover` immediately above: a journal
        // with no span produces no `span` key at all, and clearing a span on a `base:`
        // record that had one removes the key — otherwise "I cleared the span" would be
        // the one journal edit that never syncs.
        record[SyncJournalField.span] = journal.span.map(encodeJSON)
        return record
    }

    /// The Entry record (design §2, T6). Every field the design table lists travels
    /// unconditionally — unlike `journalRecord`'s cover/span, nothing on this record is
    /// ever omitted based on its value, because every field here is either identity
    /// (`capturedAt`, `manifestSnapshot`) or itself already carries its own "unset"
    /// representation (`nil`/`false`), so there is no separate "field absent" state to
    /// preserve. An untouched `EntryMetadata.defaults` still builds a complete, valid
    /// record — `journalID`/`originalDate`/`trashedAt`/`detectedDate` simply read `nil`,
    /// `multiVoice`/`detectionRan` read `false`, and `modified` reads `"{}"`.
    ///
    /// `base:` (wired at `SyncRecordExchange.entryRecordToPush`, the later task T6's own
    /// comment above pointed at): same role as `journalRecord`'s — an Entry is mutable
    /// (a later backdate/journal-move/trash edit re-pushes it), so a real push rebuilds
    /// onto this device's archived system fields when it has seen a server copy before,
    /// carrying the server's change tag so CloudKit can detect a conflict instead of
    /// blindly clobbering. `AudioAsset`/`LiveLog`/`Revision` have no such parameter —
    /// they are immutable, write-once children that are never rebuilt onto an older
    /// system-fields archive.
    ///
    /// `originalDate`/`detectedDate` travel as `PartialDate.isoString` — the same
    /// on-disk string `entry.json` itself stores them as (never a `Date`, which cannot
    /// represent a year-only or year-month backdate).
    ///
    /// `manifestSnapshot` is the caller's raw `manifest.json` bytes, verbatim, as a
    /// UTF-8 string — NOT re-encoded through `encodeJSON`, because the manifest is
    /// already its own JSON document on disk and re-encoding it here would be a second,
    /// possibly-diverging serialization of the same content design §2 note 3 says a
    /// receiving device must be able to materialize byte-for-byte.
    /// `deviceID` (M4 T8 as-built addition, mirroring `journalRecord`'s): the origin
    /// device's `DeviceIdentity.stable()`, written unconditionally like `journalRecord`
    /// writes its own — needed for `EntryFieldMerge`'s tie-break, and there is no
    /// "field was never set" state for it to preserve, unlike `cover`/`span`.
    static func entryRecord(captureID: String, metadata: EntryMetadata,
                            manifestJSON: Data, capturedAt: Date, deviceID: String,
                            zoneID: CKRecordZone.ID, base: CKRecord? = nil) -> CKRecord {
        let recordID = SyncCloudIdentifiers.recordID(.entry(captureID: captureID), zoneID: zoneID)
        let record = base ?? CKRecord(recordType: SyncRecordType.entry, recordID: recordID)

        record[SyncEntryField.journalID] = metadata.journalID
        record[SyncEntryField.originalDate] = metadata.originalDate?.isoString
        record[SyncEntryField.trashedAt] = metadata.trashedAt
        record[SyncEntryField.multiVoice] = metadata.multiVoice
        record[SyncEntryField.detectedDate] = metadata.detectedDate?.isoString
        record[SyncEntryField.detectionRan] = metadata.detectionRan
        record[SyncEntryField.manifestSnapshot] = String(data: manifestJSON, encoding: .utf8) ?? "{}"
        record[SyncEntryField.capturedAt] = capturedAt
        record[SyncEntryField.modified] = encodeJSON(metadata.modified ?? [:])
        record[SyncEntryField.deviceID] = deviceID
        return record
    }

    /// The AudioAsset record (design §2, T6): immutable, write-once, one per Entry. The
    /// record model keeps the door open to multiple audio assets per entry
    /// structurally (`SyncRecordName.audio` always addresses index 0), but nothing
    /// multi-recording is built (design §9).
    ///
    /// `entryRef` is a `CKRecord.Reference` with action `.deleteSelf` — the cascade
    /// design §2/§5 rely on so a permanently-deleted Entry takes its audio with it
    /// server-side, rather than leaving an orphaned asset behind.
    static func audioRecord(captureID: String, m4aURL: URL, sha256: String,
                            bytes: Int, frameCount: Int64, sampleRate: Double,
                            entryID: CKRecord.ID, zoneID: CKRecordZone.ID) -> CKRecord {
        let recordID = SyncCloudIdentifiers.recordID(.audio(captureID: captureID), zoneID: zoneID)
        let record = CKRecord(recordType: SyncRecordType.audioAsset, recordID: recordID)

        record[SyncChildAssetField.file] = CKAsset(fileURL: m4aURL)
        record[SyncChildAssetField.sha256] = sha256
        record[SyncChildAssetField.bytes] = bytes
        record[SyncAudioField.frameCount] = frameCount
        record[SyncAudioField.sampleRate] = sampleRate
        record[SyncChildAssetField.entryRef] = CKRecord.Reference(recordID: entryID, action: .deleteSelf)
        return record
    }

    /// The LiveLog record (design §2, T6): immutable, write-once, `live.jsonl` at
    /// promotion time. Same shape as `audioRecord` — `file` + integrity fields + the
    /// cascading `entryRef` — because both are write-once children of an Entry,
    /// uploaded once at finalize and never revised.
    ///
    /// Signature note (task brief ruling R2): the brief's original interface listed
    /// both a leftover `zoneID: CKRecord.ID? = nil` and a `zone: CKRecordZone.ID`
    /// parameter — an artifact of an earlier draft, and a second zone-shaped parameter
    /// serves no purpose but disagreeing with the real one. Normalized to match
    /// `audioRecord`'s `zoneID: CKRecordZone.ID`, plus the `bytes` parameter
    /// `audioRecord` and the design table's "verify-on-ingest" convention both call for.
    static func liveLogRecord(captureID: String, fileURL: URL, sha256: String, bytes: Int,
                              entryID: CKRecord.ID, zoneID: CKRecordZone.ID) -> CKRecord {
        let recordID = SyncCloudIdentifiers.recordID(.liveLog(captureID: captureID), zoneID: zoneID)
        let record = CKRecord(recordType: SyncRecordType.liveLog, recordID: recordID)

        record[SyncChildAssetField.file] = CKAsset(fileURL: fileURL)
        record[SyncChildAssetField.sha256] = sha256
        record[SyncChildAssetField.bytes] = bytes
        record[SyncChildAssetField.entryRef] = CKRecord.Reference(recordID: entryID, action: .deleteSelf)
        return record
    }

    /// The Revision record (design §2 table, T9): immutable, write-once, one per
    /// `canonical-<n>.json` file ever minted anywhere (`TranscriptRevisionStore
    /// .append`/`.ingestForeignRevision`). Same shape as `audioRecord`/
    /// `liveLogRecord` — payload asset + integrity fields + a cascading `entryRef` —
    /// because all three are write-once children of an Entry; see
    /// `SyncRevisionField`'s doc comment for why `entryRef` does double duty here.
    ///
    /// `fileURL` is the on-disk `canonical-<n>.json` this revision is numbered at on
    /// THIS device right now — irrelevant to identity (`SyncRecordName.revision(id:)`
    /// is the revision's own ULID, never its file number, design §2 note 1) but is
    /// exactly the bytes design §2's "body CKAsset, the canonical-N.json bytes,
    /// verbatim" wants pushed. `sha256`/`bytes` are the caller's own fresh digest of
    /// those bytes — same verify-on-ingest convention as `audioRecord`/`liveLogRecord`.
    static func revisionRecord(revisionID: String, fileURL: URL, sha256: String, bytes: Int,
                               entryID: CKRecord.ID, zoneID: CKRecordZone.ID) -> CKRecord {
        let recordID = SyncCloudIdentifiers.recordID(.revision(id: revisionID), zoneID: zoneID)
        let record = CKRecord(recordType: SyncRecordType.revision, recordID: recordID)

        record[SyncRevisionField.body] = CKAsset(fileURL: fileURL)
        record[SyncChildAssetField.sha256] = sha256
        record[SyncChildAssetField.bytes] = bytes
        record[SyncChildAssetField.entryRef] = CKRecord.Reference(recordID: entryID, action: .deleteSelf)
        return record
    }

    /// The MarkerStream record (design §2 table, §7.4, T10): mutable but structurally
    /// conflict-free — `SyncRecordName.markerStream(captureID:deviceID:)` names exactly
    /// one device's own stream, so only that device ever writes this record (design §4,
    /// "one writer per record"). `content` is that device's own `markers.jsonl` bytes,
    /// decoded as UTF-8 by the caller (`SyncRecordExchange.markerStreamRecordToPush`)
    /// and handed here as a `String`, matching `entryRecord`'s `manifestSnapshot`
    /// convention — never re-encoded through `encodeJSON`, since the bytes are already
    /// a JSONL document and re-encoding would risk a second, possibly-diverging
    /// serialization.
    ///
    /// `entryRef` (`.deleteSelf`) is the same cascade every other child record carries
    /// (Locked decisions: "Children (AudioAsset, Revision, LiveLog, MarkerStream) carry
    /// a field `entryRef`…") so purging the Entry takes every device's marker stream
    /// with it, not just this device's own.
    ///
    /// `base:` — same role as `journalRecord`'s/`entryRecord`'s: rebuilds onto this
    /// device's archived system fields when a prior push has already been confirmed, so
    /// a later re-push (this device's own log grew since the last upload) carries the
    /// server's change tag. Unlike Journal/Entry, no OTHER device's edit can ever
    /// collide with it (design §4: "structurally conflict-free — one writer per
    /// record"), but the change tag is still what tells CloudKit "update", not "create
    /// a second record at this id" after this device's own prior save.
    static func markerStreamRecord(captureID: String, deviceID: String, content: String,
                                   entryID: CKRecord.ID, zoneID: CKRecordZone.ID,
                                   base: CKRecord? = nil) -> CKRecord {
        let recordID = SyncCloudIdentifiers.recordID(.markerStream(captureID: captureID, deviceID: deviceID),
                                                      zoneID: zoneID)
        let record = base ?? CKRecord(recordType: SyncRecordType.markerStream, recordID: recordID)

        record[SyncMarkerStreamField.content] = content
        record[SyncChildAssetField.entryRef] = CKRecord.Reference(recordID: entryID, action: .deleteSelf)
        return record
    }

    /// Sorted-keys JSON, through the same encoder `journals.json` uses — so a stamp's
    /// resolution is identical on the wire and on disk, and two devices holding the same
    /// dictionary produce byte-identical strings rather than one that merely looks changed.
    static func encodeJSON<Value: Encodable>(_ value: [String: Value]) -> String {
        guard let data = try? CaptureCoding.lineEncoder().encode(value),
              let string = String(data: data, encoding: .utf8) else {
            // Unreachable for `[String: String]` / `[String: Date]`; degrading to an empty
            // object rather than trapping keeps a bad value costing only that field.
            return "{}"
        }
        return string
    }

    /// Lenient by design, matching `Journal`'s own decoder rule for these two fields: a
    /// damaged `voiceLabels`/`modified` string must cost only that field, never the
    /// journal's identity. An absent field and an unparseable one both read as empty.
    static func decodeJSON<Value: Decodable>(_ string: String?) -> [String: Value] {
        guard let string, let data = string.data(using: .utf8),
              let value = try? CaptureCoding.decoder().decode([String: Value].self, from: data) else {
            return [:]
        }
        return value
    }

    /// The single-value sibling of `encodeJSON<Value>(_ value: [String: Value])` above, for
    /// fields that are not dictionaries — `span` is the first (#70). Same rule, same
    /// encoder: a value's wire representation must be byte-identical to its on-disk one, or
    /// a value that merely round-tripped through the cloud could compare as newer than
    /// itself.
    static func encodeJSON<Value: Encodable>(_ value: Value) -> String {
        guard let data = try? CaptureCoding.lineEncoder().encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    /// The single-value sibling of `decodeJSON<Value>(_ string: String?) -> [String: Value]`
    /// above. Returns `nil` rather than degrading to some default, because there is no safe
    /// default for an arbitrary value the way `[:]` is for a dictionary — the caller decides
    /// what an absent/damaged value means (for `span`, both read as "no span").
    static func decodeJSON<Value: Decodable>(_ string: String?) -> Value? {
        guard let string, let data = string.data(using: .utf8),
              let value = try? CaptureCoding.decoder().decode(Value.self, from: data) else {
            return nil
        }
        return value
    }
}

/// T6's finalize-completion choke point (design §3: "finalize completion (m4a verified
/// + promotion) → enqueue Entry + AudioAsset + LiveLog"), and the eligibility gate
/// `EntryMetadataStore.update`'s own post-write hook shares — the same predicate, one
/// place, so the two chokepoints can never disagree about what counts as "finalized".
///
/// **Deliberately pure/file-existence-only**, reusing the reconciliation scanner's own
/// "locked" definition rather than re-deriving it: `SyncTreeScanner.scanCapture` already
/// treats a capture as sync-eligible exactly when `manifest.final.verifiedAt != nil`
/// (design §2 rule 6, "m4a verified, promotion attempted"; `FinalizerWorker.finalize`
/// sets that stamp only after a real `promote(partURL:finalURL:)` has already run, on
/// both the clean `.completed` path and the verified-but-gapped `.needsAttention` path
/// — never on `.requeued` or a budget-exhausted/no-contiguous-prefix failure, where no
/// `.m4a` exists at all). Reading the same manifest field here means an in-flight or
/// still-retrying capture is structurally unreachable — there is no `verifiedAt` to
/// read — which is what makes the eligibility pin a fact about the data, not a
/// judgment call this type makes on its own.
enum FinalizeArtifactPush {
    /// True once this capture's `.m4a` has been verified and promoted (design §2 rule
    /// 6). False for an absent/unreadable manifest and for every pre-verification
    /// state — in-flight, interrupted, still retrying, or gave up with nothing usable.
    static func isFinalized(capturesRoot: URL, captureID: String) -> Bool {
        let dir = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
        guard let data = try? Data(contentsOf: SegmentLayout.manifestURL(captureDirectory: dir)),
              let manifest = try? CaptureCoding.decoder().decode(Manifest.self, from: data)
        else { return false }
        return manifest.final.verifiedAt != nil
    }

    /// Which record names to push for a capture, decided purely from disk (no
    /// `FinalizeOutcome`, no CaptureScreenModel — this is what makes it directly
    /// testable, and what lets `EntryMetadataStore`'s hook and this file's own
    /// `push(...)` share one answer instead of two).
    ///
    /// Three-answer honesty, matching `SyncTreeScanner.liveLogArtifact`'s own doc
    /// comment verbatim: **not finalized → no names at all**; **finalized with a
    /// `transcript/live.jsonl`** (the ordinary case) → Entry + AudioAsset + LiveLog;
    /// **finalized but transcription never ran or never produced a log** (a degraded
    /// capture — SpeechAnalyzer unavailable, denied permission, or the session never
    /// started) → Entry + AudioAsset only. A degraded capture's *recording* is exactly
    /// as safe and as real as any other, so it must not be held back from syncing
    /// merely because nothing derived from it exists yet.
    ///
    /// The LiveLog check is a **readability** probe (`try? Data(contentsOf:)`), not a
    /// bare `fileExists`, and deliberately the identical technique
    /// `SyncTreeScanner.liveLogArtifact` uses — not a second, independently-invented
    /// check that happens to agree today. `fileExists` alone would read an
    /// EXISTING-BUT-UNREADABLE `live.jsonl` (a directory somehow at that path, a
    /// permissions problem, a torn write mid-`open()`) as "has a log," and queue
    /// `.liveLog` for push here while the reconciliation scanner — which actually reads
    /// the bytes to hash them — silently produces no LiveLog artifact for the same
    /// capture. That is exactly the "unreadable read as present" conflation this
    /// codebase has hit repeatedly (§11 of the M2 design; issue #11), and here it would
    /// also mis-scope Task 7/8's future `recordToPush` wiring, which has to read this
    /// same file to hash it and would find nothing to push.
    /// **The marker stream is the fourth answer (final review I1).** A capture's
    /// `markers.jsonl` is written DURING capture, by voice taps, long before finalize —
    /// and while it is being written the eligibility gate above correctly refuses every
    /// push (nothing is finalized yet). Without this append, nothing pushed that file at
    /// finalize either: the only remaining path was the next launch's
    /// `SyncPlanner.reconcile()` scan, which on iOS can be weeks away, and until then the
    /// receiving device renders that entry's transcript with its speaker attribution
    /// missing. Same readability probe as the LiveLog check directly above, for the
    /// identical reason — `SyncTreeScanner.markerStreamArtifact` reads the bytes to hash
    /// them, so an existing-but-unreadable `markers.jsonl` must read here exactly as an
    /// absent one does. `deviceID` names THIS device's own stream: it is the only marker
    /// stream this device may ever push (`SyncRecordExchange.markerStreamRecordToPush`
    /// refuses every other), foreign streams under `transcript/markers-<deviceID>.jsonl`
    /// being somebody else's record to write. Defaulted rather than threaded from the
    /// caller, matching `SyncRecordFamily.names`' own `DeviceIdentity.stable()` call —
    /// the parameter exists so a test can pin an id without touching `.standard`.
    static func namesToPush(capturesRoot: URL, captureID: String,
                            deviceID: String = DeviceIdentity.stable()) -> [SyncRecordName] {
        guard isFinalized(capturesRoot: capturesRoot, captureID: captureID) else { return [] }
        var names: [SyncRecordName] = [.entry(captureID: captureID), .audio(captureID: captureID)]
        let dir = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
        let liveLogURL = SegmentLayout.liveTranscriptURL(captureDirectory: dir)
        if (try? Data(contentsOf: liveLogURL, options: .mappedIfSafe)) != nil {
            names.append(.liveLog(captureID: captureID))
        }
        let markerURL = SegmentLayout.markerLogURL(captureDirectory: dir)
        if (try? Data(contentsOf: markerURL, options: .mappedIfSafe)) != nil {
            names.append(.markerStream(captureID: captureID, deviceID: deviceID))
        }
        return names
    }

    /// Fires `noteLocalChange` for every name `namesToPush` returns, in order. The
    /// finalize-completion choke point as one call, so `CaptureScreenModel`'s per-id
    /// loop stays a one-liner and the exact "decide, then notify" sequence a test
    /// exercises is the real one, not a hand-simulation of it.
    ///
    /// A no-op with no `syncHooks` (unit tests, the UI-test harness, or any build whose
    /// composition root refused to construct a `SyncCoordinator`) — the same "nil hook
    /// behaves exactly as before M4" rule every other store's hook already follows.
    static func push(capturesRoot: URL, captureID: String, syncHooks: (any SyncHooks)?,
                     deviceID: String = DeviceIdentity.stable()) async {
        guard let syncHooks else { return }
        for name in namesToPush(capturesRoot: capturesRoot, captureID: captureID, deviceID: deviceID) {
            await syncHooks.noteLocalChange(name)
        }
    }
}
