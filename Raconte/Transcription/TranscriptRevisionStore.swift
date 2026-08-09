import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Three-answer listing of `transcript/`'s `canonical-<n>.json` files (design §4.5a —
/// deliberate 4th copy of the `.absent`/`.unreadable`/`.present` shape already used by
/// `EntryMetadataStore`/`LiveTranscriptReader`/`JournalStore`). `.unreadable` NEVER
/// collapses to an empty `.present` — that distinction is what keeps `append` from
/// allocating `n = 0` over a chain it simply failed to read.
enum TranscriptChainListing: Equatable {
    case absent
    case unreadable(String)
    case present(files: [Int])
}

enum TranscriptRevisionStoreError: Error, Equatable {
    /// `transcript/` exists but could not be listed. `append` refuses rather than ever
    /// allocating `n = 0` over an unknown chain.
    case transcriptDirUnreadable(String)
    /// Two `EEXIST`s in a row on the same allocation attempt.
    case allocationCollision
    /// Surfaced by `loadChain`'s caller when a specific revision file failed to decode.
    case revisionUnreadable(file: Int)
    /// A write was attempted against a capture whose sidecar has `trashedAt != nil`.
    case trashedCapture
    /// `captures/<id>/` itself does not exist. Distinct from a merely absent sidecar
    /// (Gate A finding C2): `EntryMetadataStore.read` answers `.defaults` — "not
    /// trashed" — for BOTH "no entry.json yet" (a legit capture mid-finalize) and "the
    /// whole directory is gone" (staged away by `TrashSweeper`/`StagedRemover`), so the
    /// trashedAt guard alone cannot catch the second case. `append` refuses before any
    /// `mkdir` rather than let `createDirectory(withIntermediateDirectories:)` silently
    /// resurrect a tree the owner already deleted.
    case captureMissing
}

/// The two numbers §2.5 invents for the draft lifecycle, injectable so tests don't wait
/// on a real clock. `sessionEndSeconds` is the disk-observable definition of "the editor
/// went away" (`now - lastWriteAt`, checked by `closeStaleDrafts`); `hourCapSeconds` caps
/// how long one draft may keep accumulating edits before `closeDraft` forces it closed
/// regardless of the reason the caller asked for.
struct DraftPolicy: Sendable {
    var sessionEndSeconds: TimeInterval = 90
    var hourCapSeconds: TimeInterval = 3600
}

/// Owns the on-disk revision chain for one capture: create-once append, a validated
/// (never-trusted) head cache, and the pure `TranscriptChain` derivation over whatever
/// is actually readable.
///
/// **Read path never writes.** `listing`, `loadChain`, and `validatedHead` are
/// `nonisolated static` — no actor hop, and by construction no filesystem write: they
/// only `contentsOfDirectory` and `Data(contentsOf:)`. **`validatedHead` is `head.json`'s
/// whole reason to exist (design §4.3): an O(1) scan cache, not a decorative one.** It
/// reads the persisted head and compares its `revisionFiles` against the store's own
/// three-answer listing — a directory read, no JSON decode of any revision body. Only
/// on a mismatch, an absent/corrupt head, or an unreadable `transcript/` does it fall
/// back to `rebuildHead`, which *does* decode every revision. `unreadableFiles` is what
/// makes a rebuilt head a fixed point (F6): once persisted, its own `revisionFiles`
/// (the full file-number set, readable or not) matches the directory listing again, so
/// the *next* `validatedHead` call takes the trust path instead of rebuilding forever.
/// Only `append` and `persistHead`, both actor-isolated instance methods, are allowed
/// to write, and only `append` may create `transcript/` itself (A2b) — a content-
/// carrying write, never a read and never head persistence alone.
actor TranscriptRevisionStore {
    nonisolated let capturesRoot: URL
    private let policy: DraftPolicy

    init(capturesRoot: URL, policy: DraftPolicy = DraftPolicy()) {
        self.capturesRoot = capturesRoot
        self.policy = policy
    }

    // MARK: - Listing

    nonisolated static func listing(captureDirectory: URL) -> TranscriptChainListing {
        let directory = SegmentLayout.transcriptDirectory(captureDirectory: captureDirectory)
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile
                                             || error.code == .fileNoSuchFile {
            return .absent
        } catch {
            // `transcript/` exists but can't be listed — e.g. it's a plain file, or a
            // permissions error. Mirrors `DirectorySnapshot.gatherCapture`'s identical
            // distinction, made here independently because this store must not depend
            // on the scanner's stat-only pass.
            return .unreadable(String(describing: error))
        }
        let files = names.compactMap(SegmentLayout.canonicalRevision(fromFileName:)).sorted()
        return .present(files: files)
    }

    // MARK: - Loading

    struct ChainLoad: Sendable, Equatable {
        var revisions: [TranscriptRevision]   // ordered (createdAt, id)
        var unreadableFiles: [Int]            // non-empty ⇒ entry is read-only (§4.8)
        /// `transcript/` itself could not be listed — distinct from a specific
        /// `canonical-<n>.json` failing to decode. `unreadableFiles` stays empty in
        /// this case: there is no file number to name, and the array's domain is
        /// real revision file numbers only, never a sentinel.
        var listingUnreadable: Bool
    }

    nonisolated static func loadChain(captureDirectory: URL) -> ChainLoad? {
        guard let raw = rawLoad(captureDirectory: captureDirectory) else { return nil }
        let ordered = TranscriptChain.ordered(raw.numbered.map(\.revision))
        return ChainLoad(revisions: ordered, unreadableFiles: raw.unreadableFiles,
                         listingUnreadable: raw.listingUnreadable)
    }

    /// Same read as `loadChain`, but keeping each revision's file number — needed to
    /// build a `TranscriptHeadSummary.fileNumber` and `TranscriptHead.revisionFiles`,
    /// neither of which `TranscriptRevision` itself carries. `nil` ⇔ `listing == .absent`.
    ///
    /// `dedupedFiles` (Gate A finding N1) is the third bucket a duplicate-id file falls
    /// into: it decoded fine — it is NOT unreadable — but it was dropped from `numbered`
    /// because another file already claimed its id (C1). It still counts as "seen" for
    /// `TranscriptHead.revisionFiles`' own contract ("every canonical-<n> filename seen,
    /// readable or not"); routing it into `unreadableFiles` instead would trip the I1
    /// trust condition and reproduce C1's exact symptom (a head that can never be
    /// trusted again, because `unreadableFiles` would never be empty).
    private nonisolated static func rawLoad(
        captureDirectory: URL
    ) -> (numbered: [(file: Int, revision: TranscriptRevision)], unreadableFiles: [Int],
          dedupedFiles: [Int], listingUnreadable: Bool)? {
        switch listing(captureDirectory: captureDirectory) {
        case .absent:
            return nil
        case .unreadable:
            return (numbered: [], unreadableFiles: [], dedupedFiles: [], listingUnreadable: true)
        case .present(let files):
            var numbered: [(file: Int, revision: TranscriptRevision)] = []
            var unreadableFiles: [Int] = []
            var dedupedFiles: [Int] = []
            // Gate A finding C1: two canonical files can carry the same revision id (a
            // sync duplicate, or a hand-corrupted tree). `files` is ascending, so the
            // first file we see for a given id is always its lowest file number — keep
            // that one and silently drop any later file sharing the same id from the
            // chain (or a Dictionary keyed by id), rather than let it produce two
            // entries for one identity. The file number itself is NOT dropped — see
            // `dedupedFiles` above.
            var seenIDs: Set<String> = []
            let decoder = CaptureCoding.decoder()
            for file in files {
                let url = SegmentLayout.canonicalTranscriptURL(captureDirectory: captureDirectory,
                                                                revision: file)
                guard let data = try? Data(contentsOf: url),
                      let revision = try? decoder.decode(TranscriptRevision.self, from: data) else {
                    unreadableFiles.append(file)
                    continue
                }
                guard seenIDs.insert(revision.id).inserted else {
                    dedupedFiles.append(file)
                    continue
                }
                numbered.append((file: file, revision: revision))
            }
            return (numbered: numbered, unreadableFiles: unreadableFiles,
                    dedupedFiles: dedupedFiles, listingUnreadable: false)
        }
    }

    // MARK: - Head

    /// Builds the head content fresh from the readable chain, decoding every revision
    /// body — the expensive path, used only when `validatedHead` can't trust the
    /// persisted cache. `nil` ⇔ `transcript/` is absent (no chain to summarize); a
    /// capture with an unreadable `transcript/` still yields a head (empty chain,
    /// `listingUnreadable == true`) rather than collapsing to "no chain".
    private nonisolated static func rebuildHead(captureDirectory: URL) -> TranscriptHead? {
        guard let raw = rawLoad(captureDirectory: captureDirectory) else { return nil }
        let ordered = TranscriptChain.ordered(raw.numbered.map(\.revision))
        // `rawLoad` already dedupes by id (C1), so this never actually hits a
        // collision — `uniquingKeysWith` is defense in depth against
        // `Dictionary(uniqueKeysWithValues:)`'s crash-on-duplicate-key behavior for any
        // future code path that builds this map from non-deduped input.
        let fileNumberByID = Dictionary(raw.numbered.map { ($0.revision.id, $0.file) },
                                        uniquingKeysWith: min)
        // N1: a deduped (duplicate-id) file WAS seen — it belongs in revisionFiles per
        // that field's own contract — but must NOT land in unreadableFiles (it decoded
        // fine) or the I1 trust condition would never be satisfiable again for this
        // capture.
        let revisionFiles = (raw.numbered.map(\.file) + raw.unreadableFiles + raw.dedupedFiles).sorted()

        let summary: TranscriptHeadSummary? = TranscriptChain.current(ordered).flatMap { revision in
            guard let fileNumber = fileNumberByID[revision.id] else { return nil }
            let plain = TranscriptChain.plainText(revision)
            let firstLineFull = plain.split(separator: "\n", maxSplits: 1,
                                            omittingEmptySubsequences: false).first
                .map(String.init) ?? plain
            return TranscriptHeadSummary(id: revision.id,
                                         fileNumber: fileNumber,
                                         source: revision.source,
                                         createdAt: revision.createdAt,
                                         characterCount: plain.count,
                                         firstLine: String(firstLineFull.prefix(120)),
                                         isForked: TranscriptChain.forkedHumanLineage(ordered))
        }

        return TranscriptHead(current: summary,
                              revisionFiles: revisionFiles,
                              unreadableFiles: raw.unreadableFiles,
                              revisionCount: ordered.count,
                              listingUnreadable: raw.listingUnreadable)
    }

    /// Best-effort read of the persisted `head.json`, or `nil` if it's absent or
    /// doesn't decode. Never throws — an unreadable cache just means "don't trust it",
    /// not an error.
    private nonisolated static func readPersistedHead(captureDirectory: URL) -> TranscriptHead? {
        let url = SegmentLayout.transcriptHeadURL(captureDirectory: captureDirectory)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? CaptureCoding.decoder().decode(TranscriptHead.self, from: data)
    }

    /// The scanner's read path — `head.json`'s entire purpose (design §4.3): an O(1)
    /// cache, not a decorative one. When the store's own (cheap, decode-free) listing
    /// has exactly the same file numbers the persisted head says it does, AND that head
    /// admits no unreadable files of its own (Gate A finding I1), the cache is trusted
    /// as-is — no revision body is opened or decoded. A head persisted while some file
    /// was undecodable is never trusted, even once the file-number set matches again:
    /// otherwise a head cached during damage would keep serving the same stale
    /// `current`/`unreadableFiles` forever after the underlying file becomes readable —
    /// trusting the cache would silently mask a recovery the reader should see. On a
    /// mismatch, an absent/corrupt/damage-admitting head, or an unreadable
    /// `transcript/`, this falls back to `rebuildHead`, which decodes the whole chain
    /// (still zero writes — an in-memory rebuild every call is fine; the property F6
    /// protects is write-freedom, not the O(1) path staying engaged forever). A
    /// stale-but-still-wrong head is left on disk for `persistHead` to fix, not patched
    /// inline here.
    nonisolated static func validatedHead(captureDirectory: URL) -> TranscriptHead? {
        switch listing(captureDirectory: captureDirectory) {
        case .absent:
            return nil
        case .unreadable:
            // Nothing to compare a cache against, and rebuilding here is itself O(1)
            // (an unreadable directory has no bodies to decode).
            return rebuildHead(captureDirectory: captureDirectory)
        case .present(let files):
            if let persisted = readPersistedHead(captureDirectory: captureDirectory),
               !persisted.listingUnreadable,
               persisted.unreadableFiles.isEmpty,
               persisted.revisionFiles.sorted() == files.sorted() {
                return persisted
            }
            return rebuildHead(captureDirectory: captureDirectory)
        }
    }

    /// The only head writer. Recomputes and atomically replaces `head.json`. A no-op
    /// (throws nothing, writes nothing) when `transcript/` is absent — head persistence
    /// alone must never create the directory (A2b); only `append` does that.
    ///
    /// Gate A finding I3 (design §4.6: head rebuild is FIRST among the writer-side
    /// actions that must skip a trashed capture): also a silent no-op when
    /// `captures/<id>/` itself is missing (mirrors `append`'s C2 guard — never risk
    /// creating anything under a vanished capture) or when the sidecar reports
    /// `trashedAt != nil`. A capture with NO sidecar at all (mid-finalize, legitimate)
    /// is neither of those and stays fully persistable.
    ///
    /// Behavior note (Gate A close-out ruling): the I3 sidecar guard means this method
    /// now `throws` on an UNREADABLE (present-but-undecodable) `entry.json` — a case
    /// that, before I3, would have been ignored and the head written anyway. `append`
    /// already swallows any `persistHead` failure (C1-trigger), so this is invisible
    /// through that path; a future caller invoking `persistHead` directly (e.g. T6c)
    /// will see the throw and must decide how to handle a damaged sidecar itself.
    func persistHead(captureID: String) throws {
        let captureDirectory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: captureDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return
        }

        let metadata = try EntryMetadataStore.read(
            url: SegmentLayout.entryMetadataURL(captureDirectory: captureDirectory))
        if metadata.isTrashed {
            return
        }

        guard let head = Self.rebuildHead(captureDirectory: captureDirectory) else { return }
        let data = try CaptureCoding.encoder().encode(head)
        try AtomicFile.replace(at: SegmentLayout.transcriptHeadURL(captureDirectory: captureDirectory),
                               writing: data)
    }

    // MARK: - Append

    /// Create-once append (design §4.5): refuses if `captures/<id>/` itself doesn't
    /// exist (`.captureMissing`, Gate A finding C2 — see below); checks the sidecar's
    /// `trashedAt` next (`.trashedCapture`, nothing written); an unreadable
    /// `transcript/` throws rather than allocating over an unknown chain; `n =
    /// max(present) + 1` (or 0 if absent/empty); `transcript/` is created here — and
    /// ONLY here (A2b) — before the first write; on `EEXIST` the listing is redone once
    /// and the write retried once more; a second collision gives up rather than
    /// looping. Persists the head last; a head-persistence failure is swallowed (Gate A
    /// finding C1-trigger) rather than thrown — the revision file above is already
    /// durable at that point, so failing loudly here would make a legitimate caller
    /// retry, which would allocate a FRESH `n` over an id that's already on disk under
    /// the OLD `n` — the exact duplicate-id state C1 exists to survive, not something
    /// this method should ever manufacture itself. `head.json` is a rebuildable cache
    /// (design §4.3); `validatedHead` rebuilds it in memory on the next read regardless.
    ///
    /// `beforeWrite` is a test seam: it runs after `n` is computed and `transcript/` is
    /// guaranteed to exist, but before the exclusive create — letting a test plant a
    /// colliding `canonical-<n>.json` to force the EEXIST retry path deterministically.
    @discardableResult
    func append(_ revision: TranscriptRevision, captureID: String,
                beforeWrite: (@Sendable () -> Void)? = nil) throws -> Int {
        let captureDirectory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)

        // C2 (verified by the reviewer): EntryMetadataStore.read answers `.defaults` —
        // "not trashed" — for BOTH "no entry.json yet" (a legit capture mid-finalize,
        // stays appendable below) and "the whole directory is gone" (staged away by
        // TrashSweeper/StagedRemover). The trashedAt check alone cannot tell those
        // apart, and createDirectory(withIntermediateDirectories:) below would silently
        // RECREATE a deleted tree. Refuse before any mkdir when the directory itself is
        // missing — this must run before the sidecar read, not just before the mkdir,
        // since reading a sidecar that lives under nothing is meaningless.
        var isCaptureDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: captureDirectory.path, isDirectory: &isCaptureDirectory),
              isCaptureDirectory.boolValue else {
            throw TranscriptRevisionStoreError.captureMissing
        }

        let sidecarURL = SegmentLayout.entryMetadataURL(captureDirectory: captureDirectory)
        let metadata = try EntryMetadataStore.read(url: sidecarURL)
        if metadata.isTrashed {
            throw TranscriptRevisionStoreError.trashedCapture
        }

        func nextFileNumber() throws -> Int {
            switch Self.listing(captureDirectory: captureDirectory) {
            case .absent:
                return 0
            case .unreadable(let reason):
                throw TranscriptRevisionStoreError.transcriptDirUnreadable(reason)
            case .present(let files):
                return (files.max() ?? -1) + 1
            }
        }

        var fileNumber = try nextFileNumber()
        let data = try CaptureCoding.encoder().encode(revision)

        // A2b: transcript/ is created only by this content-carrying write, never by a
        // read and never by head persistence alone.
        try FileManager.default.createDirectory(
            at: SegmentLayout.transcriptDirectory(captureDirectory: captureDirectory),
            withIntermediateDirectories: true)

        beforeWrite?()

        do {
            try AtomicFile.createExclusively(
                at: SegmentLayout.canonicalTranscriptURL(captureDirectory: captureDirectory,
                                                         revision: fileNumber),
                writing: data)
        } catch let error as AtomicFileError where isEEXIST(error) {
            fileNumber = try nextFileNumber()
            do {
                try AtomicFile.createExclusively(
                    at: SegmentLayout.canonicalTranscriptURL(captureDirectory: captureDirectory,
                                                             revision: fileNumber),
                    writing: data)
            } catch let secondError as AtomicFileError where isEEXIST(secondError) {
                throw TranscriptRevisionStoreError.allocationCollision
            }
        }

        do {
            try persistHead(captureID: captureID)
        } catch {
            // C1-trigger: see the doc comment above. The revision file is already
            // durable; a head-persistence failure must not be surfaced as an append
            // failure. validatedHead rebuilds over the readable chain on the next call
            // regardless of what state head.json was left in here.
        }
        return fileNumber
    }

    private func isEEXIST(_ error: AtomicFileError) -> Bool {
        if case .posix(_, let code) = error { return code == EEXIST }
        return false
    }

    // MARK: - Draft lifecycle (T6d, design §2.5)

    /// Best-effort read of `draft.json`, or `nil` if it's absent or doesn't decode.
    /// Mirrors `readPersistedHead`: an undecodable draft is treated the same as no
    /// draft rather than as an error — there is nothing safe to close or overwrite.
    private nonisolated static func readDraft(captureDirectory: URL) -> TranscriptDraft? {
        let url = SegmentLayout.transcriptDraftURL(captureDirectory: captureDirectory)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? CaptureCoding.decoder().decode(TranscriptDraft.self, from: data)
    }

    /// §6.4's propagation rule, captured once at draft-open time (the parent revision
    /// is immutable, so this can never go stale between then and `closeDraft`): a draft
    /// opened against a machine revision carries that revision's own id; opened against
    /// a human revision (or no revision at all) carries that revision's own
    /// `basedOnMachineID` (nil if there is none).
    private nonisolated static func basedOnMachineID(forDraftOpenedAgainst parent: TranscriptRevision?) -> String? {
        guard let parent else { return nil }
        return parent.source.isHumanLineage ? parent.basedOnMachineID : parent.id
    }

    /// Guards common to every draft-lifecycle write: the capture directory must exist
    /// (mirrors `append`'s C2 guard — never risk resurrecting a staged-away capture),
    /// and the sidecar must not report `trashedAt != nil`.
    private func guardWritable(captureDirectory: URL) throws {
        var isCaptureDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: captureDirectory.path, isDirectory: &isCaptureDirectory),
              isCaptureDirectory.boolValue else {
            throw TranscriptRevisionStoreError.captureMissing
        }
        let sidecarURL = SegmentLayout.entryMetadataURL(captureDirectory: captureDirectory)
        let metadata = try EntryMetadataStore.read(url: sidecarURL)
        if metadata.isTrashed {
            throw TranscriptRevisionStoreError.trashedCapture
        }
    }

    /// Writes `transcript/draft.json` via `AtomicFile.replace`. `transcript/` is created
    /// lazily here — ONLY when `text` differs from current's `plainText` (A2b: a
    /// content-carrying write, never a bare open) — unless the directory already exists,
    /// in which case a draft matching current is still recorded (harmless: `closeDraft`
    /// treats a draft equal to current as "close to nothing" regardless of when it was
    /// written).
    func writeDraft(captureID: String, text: String, now: Date) throws {
        let captureDirectory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
        try guardWritable(captureDirectory: captureDirectory)

        let ordered = Self.loadChain(captureDirectory: captureDirectory)?.revisions ?? []
        let current = TranscriptChain.current(ordered)
        let currentText = current.map(TranscriptChain.plainText) ?? ""

        let transcriptDirectory = SegmentLayout.transcriptDirectory(captureDirectory: captureDirectory)
        let transcriptDirectoryExists = FileManager.default.fileExists(atPath: transcriptDirectory.path)
        guard text != currentText || transcriptDirectoryExists else {
            return
        }

        try FileManager.default.createDirectory(at: transcriptDirectory, withIntermediateDirectories: true)

        let existing = Self.readDraft(captureDirectory: captureDirectory)
        let draft = TranscriptDraft(
            captureID: captureID,
            parentID: existing?.parentID ?? current?.id,
            basedOnMachineID: existing?.basedOnMachineID ?? Self.basedOnMachineID(forDraftOpenedAgainst: current),
            openedAt: existing?.openedAt ?? now,
            lastWriteAt: now,
            text: text)

        let data = try CaptureCoding.encoder().encode(draft)
        try AtomicFile.replace(at: SegmentLayout.transcriptDraftURL(captureDirectory: captureDirectory),
                               writing: data)
    }

    /// Closes the draft per §2.5.
    ///
    /// `text == CURRENT's plainText` (read fresh, not `draft.parentID`'s revision — the
    /// F7 crash-duplicate rule) deletes the draft and mints nothing: if a prior close
    /// already durably minted the revision and only crashed before deleting the draft
    /// file, current now equals `draft.text` and this call is a safe no-op retry.
    ///
    /// Otherwise mints a `userEdit` revision via `TranscriptSplice`, diffed against the
    /// revision named by `draft.parentID` (a synthetic empty revision stands in when
    /// there is none — a root draft with nothing to inherit from). `parentID` and
    /// `basedOnMachineID` on the new revision are copied straight from the draft's own
    /// fields, snapshotted at open time per §6.4. `closedBy` records why — except the
    /// hour cap overrides whatever `reason` the caller passed, since §2.5 defines it as
    /// a hard 60-minute ceiling on one draft's lifetime, not an optional trigger.
    @discardableResult
    func closeDraft(captureID: String, reason: DraftCloseReason, now: Date) throws -> String? {
        let captureDirectory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
        try guardWritable(captureDirectory: captureDirectory)

        guard let draft = Self.readDraft(captureDirectory: captureDirectory) else {
            return nil
        }
        let draftURL = SegmentLayout.transcriptDraftURL(captureDirectory: captureDirectory)

        let ordered = Self.loadChain(captureDirectory: captureDirectory)?.revisions ?? []
        let currentRevision = TranscriptChain.current(ordered)
        let currentText = currentRevision.map(TranscriptChain.plainText) ?? ""

        if draft.text == currentText {
            try FileManager.default.removeItem(at: draftURL)
            return nil
        }

        let parentForSplice = draft.parentID.flatMap { pid in ordered.first { $0.id == pid } }
            ?? TranscriptRevision(id: draft.parentID ?? "", source: .userEdit,
                                  createdAt: draft.openedAt, spans: [])

        var spans = TranscriptSplice.spans(parent: parentForSplice, editedText: draft.text)
        let newID = ULID.make(now: now)
        // The caller-side half of the sourceRevisionID omit-when-equal economy
        // (TranscriptSpan.swift:150-156, Task 1 ledger note): TranscriptSplice can't
        // know the id its output will be minted under, so it always writes an explicit
        // resolved id for borrowed frames; now that the id is known, drop it back to
        // nil wherever it happens to equal the revision the span is about to live in.
        for index in spans.indices where spans[index].sourceRevisionID == newID {
            spans[index].sourceRevisionID = nil
        }

        let effectiveReason: DraftCloseReason =
            now.timeIntervalSince(draft.openedAt) > policy.hourCapSeconds ? .hourCap : reason

        let revision = TranscriptRevision(id: newID, source: .userEdit, createdAt: now, spans: spans,
                                          parentID: draft.parentID, basedOnMachineID: draft.basedOnMachineID,
                                          deviceID: DeviceIdentity.stable(), closedBy: effectiveReason)

        try append(revision, captureID: captureID)
        try FileManager.default.removeItem(at: draftURL)
        return revision.id
    }

    /// Stale-draft pass for launch + entry-open (rule 9, §4.6 — NEVER the scan): closes
    /// every capture's draft whose `lastWriteAt` is older than `policy.sessionEndSeconds`
    /// with reason `.recovered`. Skips a capture with no draft, a fresh draft, or
    /// `trashedAt != nil`; one bad capture's failure never aborts the rest of the pass.
    func closeStaleDrafts(now: Date) async {
        guard let ids = try? FileManager.default.contentsOfDirectory(atPath: capturesRoot.path) else {
            return
        }
        for id in ids.sorted() {
            let captureDirectory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: id)
            var isCaptureDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: captureDirectory.path, isDirectory: &isCaptureDirectory),
                  isCaptureDirectory.boolValue else {
                continue
            }
            let sidecarURL = SegmentLayout.entryMetadataURL(captureDirectory: captureDirectory)
            guard let metadata = try? EntryMetadataStore.read(url: sidecarURL), !metadata.isTrashed else {
                continue
            }
            guard let draft = Self.readDraft(captureDirectory: captureDirectory) else {
                continue
            }
            guard now.timeIntervalSince(draft.lastWriteAt) > policy.sessionEndSeconds else {
                continue
            }
            _ = try? closeDraft(captureID: id, reason: .recovered, now: now)
        }
    }

    // MARK: - Promotion (T6c, design §5.1/§5.2)

    /// What `promoteIfNeeded` decided, or why it declined to write anything.
    enum PromotionOutcome: Sendable, Equatable {
        case promoted(revisionID: String)
        case skippedAlreadyPromoted, skippedTrashed, skippedNoAudio, skippedNoLog
        case failed(String)
    }

    /// Promote `transcript/live.jsonl` into revision zero of the canonical chain, once.
    ///
    /// Skip order matches the brief exactly, cheapest/safest check first:
    /// 1. The capture directory itself is missing — mirrors `append`'s C2 guard. A
    ///    missing sidecar reads identically to "not trashed" through
    ///    `EntryMetadataStore.read`, so a vanished (staged-away) capture would
    ///    otherwise look promotable; there is no dedicated outcome for this case, so it
    ///    folds into `.skippedTrashed` — the same "never gain new files" rule.
    /// 2. `trashedAt != nil` → `.skippedTrashed`.
    /// 3. Any canonical file already listed (readable or not) → `.skippedAlreadyPromoted`
    ///    — promotion runs at most once per capture, by construction of `append`'s own
    ///    `n = max(present) + 1` allocation, but this check keeps a re-run cheap (no
    ///    log read at all) rather than relying on `append` to no-op.
    /// 4. No `final/recording.m4a` → `.skippedNoAudio` — nothing durable to derive from.
    /// 5. `live.jsonl` absent → `.skippedNoLog` — an honest "nothing was ever
    ///    transcribed", not an error.
    /// 6. `live.jsonl` present but unreadable → `.failed` — never promote a log we
    ///    cannot fully read; a partial promotion here would be worse than none.
    @discardableResult
    func promoteIfNeeded(captureID: String, now: Date = Date()) async -> PromotionOutcome {
        let captureDirectory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)

        var isCaptureDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: captureDirectory.path, isDirectory: &isCaptureDirectory),
              isCaptureDirectory.boolValue else {
            return .skippedTrashed
        }

        let sidecarURL = SegmentLayout.entryMetadataURL(captureDirectory: captureDirectory)
        let metadata: EntryMetadata
        do {
            metadata = try EntryMetadataStore.read(url: sidecarURL)
        } catch {
            return .failed("sidecar unreadable: \(error)")
        }
        if metadata.isTrashed { return .skippedTrashed }

        switch Self.listing(captureDirectory: captureDirectory) {
        case .absent:
            break
        case .present(let files):
            if !files.isEmpty { return .skippedAlreadyPromoted }
        case .unreadable(let reason):
            return .failed(reason)
        }

        let audioURL = SegmentLayout.finalRecordingURL(captureDirectory: captureDirectory)
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            return .skippedNoAudio
        }

        let loaded = LiveTranscriptReader.load(captureDirectory: captureDirectory)
        switch loaded.source {
        case .absent:
            return .skippedNoLog
        case .unreadable(let reason):
            return .failed("live.jsonl unreadable: \(reason)")
        case .present:
            break
        }

        let consolidator = LiveTranscriptReader.consolidate(loaded.records)
        let spans = Self.spans(fromCommitted: consolidator.committed)
        // Generator/locale come from the RAW records, not the consolidated
        // `TranscriptResult`s — `TranscriptResult(_ record:)` deliberately does not
        // carry them (they are per-record on disk, revision-wide here), so the last
        // record decided is the only place left to read them from.
        let lastRecord = loaded.records.last
        let ref = Self.readManifest(captureDirectory: captureDirectory)?.transcript

        let revision = TranscriptRevision(
            id: ULID.make(now: now),
            source: .machineLive,
            createdAt: now,
            spans: spans,
            parentID: nil,
            basedOnMachineID: nil,
            generator: lastRecord?.generator,
            locale: lastRecord?.locale,
            // nil when the manifest carries no `TranscriptRef` (locked decision 3): a
            // launch-recovered capture never got a clean-close ref written, and a
            // fabricated coverage number here would claim more than is actually known.
            coverageFrames: ref?.coverageFrames,
            skippedRanges: ref?.skippedRanges,
            deviceID: DeviceIdentity.stable(),
            closedBy: nil)

        do {
            try append(revision, captureID: captureID)
            return .promoted(revisionID: revision.id)
        } catch {
            return .failed("\(error)")
        }
    }

    /// One-shot pass over every capture directory (design §5.1). Each capture is
    /// independent — one bad directory (unreadable sidecar, corrupt manifest) reports
    /// its own `.failed` entry rather than aborting the rest of the corpus.
    func promoteCorpus() async -> [String: PromotionOutcome] {
        guard let ids = try? FileManager.default.contentsOfDirectory(atPath: capturesRoot.path) else {
            return [:]
        }
        var outcomes: [String: PromotionOutcome] = [:]
        for id in ids.sorted() {
            outcomes[id] = await promoteIfNeeded(captureID: id)
        }
        return outcomes
    }

    private nonisolated static func readManifest(captureDirectory: URL) -> Manifest? {
        let url = SegmentLayout.manifestURL(captureDirectory: captureDirectory)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? CaptureCoding.decoder().decode(Manifest.self, from: data)
    }

    /// Pure mapping from a consolidated committed-result list to canonical spans
    /// (design §5.2). No I/O — testable without the actor.
    ///
    /// A committed result WITH runs becomes one span per run: a run carries its own
    /// frame bounds, so `.exact` anchoring iff BOTH `captureFrameStart`/`captureFrameEnd`
    /// are present, else `.none` (never a partial bound — the `TranscriptSpan`
    /// invariant is "frameStart nil iff anchor has no usable bounds", not "whichever
    /// half happened to survive").
    ///
    /// A RUNLESS result (legal — `TranscriptResult.runs`'s own doc comment: the
    /// transcriber need not attribute any) becomes exactly ONE span for the whole
    /// result, anchored `.inherited` off the result's own frame range — the bounds are
    /// real, just result- rather than run-granularity (code-maps finding C1).
    ///
    /// Every span's `sourceRevisionID` is left `nil`: these spans originate IN the
    /// revision they are about to be written into, and `TranscriptSpan`'s own doc
    /// comment defers "never write a redundant equal id" enforcement to whichever of
    /// T6c/T6e constructs spans first — this is that constructor.
    nonisolated static func spans(fromCommitted committed: [TranscriptResult]) -> [TranscriptSpan] {
        committed.flatMap { result -> [TranscriptSpan] in
            guard !result.runs.isEmpty else {
                return [TranscriptSpan(text: result.text, anchor: .inherited,
                                       frameStart: result.range.start, frameEnd: result.range.end,
                                       confidence: result.confidence, sourceRevisionID: nil)]
            }
            return result.runs.map { run in
                if let start = run.captureFrameStart, let end = run.captureFrameEnd {
                    return TranscriptSpan(text: run.text, anchor: .exact,
                                          frameStart: start, frameEnd: end,
                                          confidence: run.confidence, sourceRevisionID: nil)
                }
                return TranscriptSpan(text: run.text, anchor: .none,
                                      frameStart: nil, frameEnd: nil,
                                      confidence: run.confidence, sourceRevisionID: nil)
            }
        }
    }
}

/// A per-install stable id, minted once and cached in `UserDefaults` (design §5.2's
/// `TranscriptRevision.deviceID`). Not a preference — nothing else in the app reads or
/// writes this key — so a bare `UserDefaults.standard` read/write needs no seam of its
/// own the way `CurrentJournal` needed `JournalPreferenceStore` for testability; no
/// test asserts on the exact id, only that it is stable and non-empty.
enum DeviceIdentity {
    private static let defaultsKey = "raconte.deviceID"

    static func stable(defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: defaultsKey), !existing.isEmpty {
            return existing
        }
        let minted = ULID.make()
        defaults.set(minted, forKey: defaultsKey)
        return minted
    }
}
