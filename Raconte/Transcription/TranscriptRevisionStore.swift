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
    /// `revert`'s target id (T7 Task 8) named no revision in the readable chain — the
    /// panel offering a stale row (the chain moved since it last opened) or a caller
    /// passing a bad id directly.
    case revisionNotFound(String)
    /// `revert`'s guard (T7 Task 8, review Important 3): a draft exists for this
    /// capture. Reverting while a draft is open risks a silent reversal —
    /// `closeDraft` (fired later by `closeStaleDrafts`, or the editor's own Done) mints
    /// a `.userEdit` parented on PRE-revert `current` with a fresh `createdAt`, which
    /// outranks the revert's merge in `(createdAt, id)` order and snaps `current` back
    /// to the pre-revert text — no bytes lost, but the panel's one undo action would be
    /// silently undone. Refuse rather than degrade, the same "refuse, don't guess"
    /// discipline every other write guard here already holds to. The owner finishes or
    /// discards the draft first (`EntryChainSnapshot.openDraft` is documented as
    /// "Task 8's 'unsaved' marker" precisely for this collision).
    case draftInProgress
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
    /// #42 pin 2: every internal `DeviceIdentity.stable()` call routes through this
    /// rather than calling it directly, so a test can supply a throwaway
    /// `UserDefaults(suiteName:)`-backed provider instead of writing into the real
    /// `UserDefaults.standard` domain (test pollution across runs — every test that
    /// exercises `closeDraft`/`revert`/`promoteIfNeeded` used to mint or read a real,
    /// persisted `raconte.deviceID` key on the machine running the suite). Production
    /// callers get the exact previous behavior via the default.
    private let deviceIDProvider: @Sendable () -> String

    /// M4 T9. Nil everywhere sync is off — unit tests, the UI-test harness, and any
    /// build whose composition root refused to construct an engine. A store with no
    /// hook behaves exactly as it did before M4, matching `JournalStore`/
    /// `EntryMetadataStore`'s identical seam.
    private var syncHooks: (any SyncHooks)?

    init(capturesRoot: URL, policy: DraftPolicy = DraftPolicy(),
        deviceIDProvider: @escaping @Sendable () -> String = { DeviceIdentity.stable() },
        syncHooks: (any SyncHooks)? = nil) {
        self.capturesRoot = capturesRoot
        self.policy = policy
        self.deviceIDProvider = deviceIDProvider
        self.syncHooks = syncHooks
    }

    /// Wired after construction (M4 T9), for the same reason `JournalStore.attach
    /// (syncHooks:)`/`EntryMetadataStore.attach(syncHooks:)` are: the composition root
    /// builds this store (inside `LibraryScreenModel`) before it can build the
    /// `SyncCoordinator` that conforms to `SyncHooks`.
    func attach(syncHooks: any SyncHooks) {
        self.syncHooks = syncHooks
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

    /// Per-file on-disk byte sizes for the given `canonical-<n>.json` file NUMBERS
    /// under one capture's `transcript/` — readable or not (a corrupt revision still
    /// occupies real bytes). Skips (rather than zero-fills) a file that can't be
    /// stat'd at all, e.g. it vanished between the caller's listing and this call — an
    /// absent entry reads as "unknown," never as a false 0.
    ///
    /// The ONE implementation both `canonicalFilesByteSize` (the byte-size STAT,
    /// #39/#40) and `sizesStillMatch` (the integrity check, T7 Task 3 fix round 1,
    /// Important 1) build from — so the storage stat and the trust condition can never
    /// silently drift on what "this file's size" means. Uses
    /// `URL.resourceValues(forKeys: [.fileSizeKey])`, not
    /// `FileManager.attributesOfItem` (cheaper — no full attribute-dictionary
    /// allocation per file — and load-bearing now that a size disagreement drives a
    /// real trust decision, not merely a decorative display number).
    nonisolated static func canonicalFileSizes(captureDirectory: URL, files: [Int]) -> [RevisionFileSize] {
        files.compactMap { file in
            let url = SegmentLayout.canonicalTranscriptURL(captureDirectory: captureDirectory, revision: file)
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
            return RevisionFileSize(file: file, byteSize: Int64(size))
        }
    }

    /// Sum of on-disk byte sizes for the given `canonical-<n>.json` file NUMBERS under
    /// one capture's `transcript/` — readable or not. The single implementation
    /// `EntryChainSnapshot.chainByteSize` and `DirectorySnapshot`'s
    /// `revisionsByteSize` (#39, Task 3) both call, so the editor's revision-history
    /// panel and the corpus-wide diagnostics screen can never silently disagree about
    /// what "one entry's chain size" means, even though each computes its own
    /// independent `files` listing to pass in (the panel via
    /// `TranscriptRevisionStore.listing`, the diagnostics screen via a stat-only
    /// directory walk `DirectorySnapshot` already does). No revision body is
    /// decoded — built on `canonicalFileSizes`, which is a directory listing (the
    /// caller's job) plus one stat per file.
    nonisolated static func canonicalFilesByteSize(captureDirectory: URL, files: [Int]) -> Int64 {
        canonicalFileSizes(captureDirectory: captureDirectory, files: files)
            .reduce(Int64(0)) { $0 + $1.byteSize }
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
    ///
    /// Not `private` (T7 Task 2 fix round 1, Important 3): `EntryChainSnapshot` needs
    /// per-revision file numbers for every revision it may show, not just `current`'s —
    /// something `loadChain` structurally can't provide — and reimplementing this
    /// decode-and-dedupe walk a second time is exactly how the C1/N1 duplicate-file-
    /// number rules end up with two implementations and only one carrying the fix.
    /// `internal` (module-default) rather than adding a new public API surface.
    nonisolated static func rawLoad(
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
        let forked = TranscriptChain.forkedHumanLineage(ordered)

        let summary: TranscriptHeadSummary? = TranscriptChain.current(ordered).flatMap { revision in
            guard let fileNumber = fileNumberByID[revision.id] else { return nil }
            return Self.headSummary(for: revision, fileNumber: fileNumber, isForked: forked)
        }

        return TranscriptHead(current: summary,
                              revisionFiles: revisionFiles,
                              unreadableFiles: raw.unreadableFiles,
                              revisionCount: ordered.count,
                              listingUnreadable: raw.listingUnreadable,
                              // Important 1 (T7 Task 3 fix round 1): every file this
                              // rebuild just re-derived a fresh answer for gets its
                              // size stamped too, so the NEXT `validatedHead` call can
                              // trust this head without decoding anything, until a
                              // byte actually changes.
                              fileSizes: Self.canonicalFileSizes(captureDirectory: captureDirectory,
                                                                 files: revisionFiles))
    }

    /// One `TranscriptHeadSummary` for a revision + the file number it lives in — the
    /// digest `head.json`'s `current` caches (first line truncated to 120 chars, plus
    /// the full-text-derived `snippet` — see that field's own doc comment). Not
    /// `private` (T7 Task 2 fix round 1, Important 3): `EntryChainSnapshot` mints the
    /// same shape for every entry in `detachedMachineRevisions`, and a second
    /// independent implementation is exactly how a future field (or a truncation-rule
    /// change) drifts between the two. `isForked` is chain-wide (design §4.2), computed
    /// once by the caller over the WHOLE `ordered` chain and threaded through here
    /// rather than recomputed per revision.
    nonisolated static func headSummary(for revision: TranscriptRevision, fileNumber: Int,
                                        isForked: Bool) -> TranscriptHeadSummary {
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
                                     isForked: isForked,
                                     // Important 3 (T7 Task 3 fix round 1): the ROW's
                                     // actual preview — the SAME `EntrySnippet.make`
                                     // the live.jsonl-fallback path already uses, over
                                     // the FULL plain text (every line, not just the
                                     // first) — so a truncated preview is visibly
                                     // truncated and a multi-line transcript doesn't
                                     // collapse to its opening line.
                                     snippet: EntrySnippet.make(from: plain) ?? "")
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
    /// admits no unreadable files of its own (Gate A finding I1), AND every one of
    /// those files' bytes still match the size recorded when the head was persisted
    /// (T7 Task 3 fix round 1, Important 1 — `sizesStillMatch`), the cache is trusted
    /// as-is — no revision body is opened or decoded. A head persisted while some file
    /// was undecodable is never trusted, even once the file-number set matches again:
    /// otherwise a head cached during damage would keep serving the same stale
    /// `current`/`unreadableFiles` forever after the underlying file becomes readable —
    /// trusting the cache would silently mask a recovery the reader should see. On a
    /// mismatch, an absent/corrupt/damage-admitting head, a size disagreement, or an
    /// unreadable `transcript/`, this falls back to `rebuildHead`, which decodes the
    /// whole chain (still zero writes — an in-memory rebuild every call is fine; the
    /// property F6 protects is write-freedom, not the O(1) path staying engaged
    /// forever). A stale-but-still-wrong head is left on disk for `persistHead` to fix,
    /// not patched inline here.
    nonisolated static func validatedHead(captureDirectory: URL) -> TranscriptHead? {
        switch listing(captureDirectory: captureDirectory) {
        case .absent:
            return nil
        case .unreadable:
            // Nothing to compare a cache against, and rebuilding here is itself O(1)
            // (an unreadable directory has no bodies to decode).
            return rebuildHead(captureDirectory: captureDirectory)
        case .present(let files):
            if let trusted = Self.trustedPersistedHead(captureDirectory: captureDirectory, files: files) {
                return trusted
            }
            return rebuildHead(captureDirectory: captureDirectory)
        }
    }

    /// The O(1) trust check itself, returning the persisted head when — and only
    /// when — it can be trusted exactly as-is. Split out of `validatedHead` (T7 Task 3
    /// fix round 2) so "is this head trustworthy right now" has exactly ONE
    /// implementation: the read path (`validatedHead`, above) and the launch-time
    /// stamping sweep (`stampUnstampedHeads`, below — the write path that decides
    /// whether a capture needs a fresh `persistHead` call at all) both call this
    /// rather than re-deriving the rule. `nil` for every reason `validatedHead` would
    /// otherwise fall back to `rebuildHead`.
    private nonisolated static func trustedPersistedHead(captureDirectory: URL, files: [Int]) -> TranscriptHead? {
        guard let persisted = readPersistedHead(captureDirectory: captureDirectory),
              !persisted.listingUnreadable,
              persisted.unreadableFiles.isEmpty,
              persisted.revisionFiles.sorted() == files.sorted(),
              Self.sizesStillMatch(persisted: persisted, captureDirectory: captureDirectory) else {
            return nil
        }
        return persisted
    }

    /// The trust condition's integrity check (T7 Task 3 fix round 1, Important 1): a
    /// cheap defense against truncation, a partial write, or cloud-eviction damage that
    /// leaves a canonical file's NAME in place while its BYTES change — the exact blind
    /// spot `revisionFiles`/`unreadableFiles` share, since both are keyed on filename
    /// alone and neither is re-checked once a head is otherwise trusted. Every file
    /// `persisted.revisionFiles` names must have a recorded size in
    /// `persisted.fileSizes` that matches a FRESH stat of that file right now (no body
    /// decoded — `canonicalFileSizes` is the one implementation, shared with the
    /// storage stat).
    ///
    /// A head persisted before `fileSizes` existed has NONE recorded for anything —
    /// `recorded.count` (0) will never equal `persisted.revisionFiles.count` (>0 for
    /// any capture with a chain), so this returns `false` for it: MISSING sizes read as
    /// "does not match," never as "nothing to disagree with." Trusting an unstamped
    /// head here would silently accept the exact damage this check exists to catch —
    /// the owner's explicit ruling. The forced rebuild that follows recomputes and
    /// stamps sizes for the next read (self-heals, §4.8's disposable-cache philosophy).
    ///
    /// Deliberately does NOT catch same-size corruption — an accepted, owner-ruled
    /// residual gap, pinned by its own test rather than left to read as an oversight.
    private nonisolated static func sizesStillMatch(persisted: TranscriptHead, captureDirectory: URL) -> Bool {
        let recorded = Dictionary(persisted.fileSizes.map { ($0.file, $0.byteSize) },
                                  uniquingKeysWith: { first, _ in first })
        guard recorded.count == persisted.revisionFiles.count else { return false }
        for file in persisted.revisionFiles {
            guard let expectedSize = recorded[file] else { return false }
            let url = SegmentLayout.canonicalTranscriptURL(captureDirectory: captureDirectory, revision: file)
            guard let actualSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  Int64(actualSize) == expectedSize else {
                return false
            }
        }
        return true
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

    // MARK: - Corpus head stamping (T7 Task 3 fix round 2)

    /// The launch-time sweep the owner ruled for: without it, Task 3's whole win
    /// never reaches a single entry that existed before this fix shipped.
    /// `persistHead` has exactly one production caller — `append` — and
    /// `promoteIfNeeded` writes nothing once a chain already exists
    /// (`.skippedAlreadyPromoted`), so every `head.json` on a device today predates
    /// `fileSizes` and is — correctly, per fix round 1's ruling — distrusted forever
    /// by `sizesStillMatch`. Left unswept, every row read for every already-promoted
    /// entry keeps paying the full chain decode `validatedHead`'s O(1) path exists to
    /// avoid, permanently: reproduced by the reviewer as three consecutive row reads
    /// against an unstamped head each returning the decoded body, head still
    /// unstamped afterwards.
    ///
    /// A NO-OP for a capture whose head is already trustworthy (`trustedPersistedHead`
    /// — the SAME check `validatedHead` uses, not a second implementation): never
    /// rewrites `head.json` on a launch that changed nothing, which would be churn on
    /// the owner's real data and would defeat the point of caching at all. Thin
    /// plumbing over `persistHead` for everything else, so the trashed/missing-capture
    /// guards (§15.4, Gate A finding C2/I3) are enforced exactly once, there — this
    /// sweep adds no guard logic of its own. `.absent`/`.unreadable` listings are
    /// skipped outright: neither has a chain worth stamping, and `validatedHead`
    /// never even consults `head.json` for either case, so stamping one would help
    /// nothing. `.present([])` — `transcript/` exists but holds no `canonical-<n>.json`
    /// (a capture whose `live.jsonl` promotion skipped, or a `transcript/` left empty
    /// by a crash between its `createDirectory` and first write) — is ALSO skipped
    /// (fix round 3): there is no chain to stamp there either, and writing `head.json`
    /// into an otherwise-empty `transcript/` would flip
    /// `DirectorySnapshot.holdsIrreplaceableArtifacts` from false to true, making a
    /// mis-tapped capture permanently undeletable — the exact zero-byte-log hazard
    /// (rule 10) `MarkerLog.swift`/`CaptureCoordinator.swift` both already guard
    /// against elsewhere.
    func stampUnstampedHeads() async {
        guard let ids = try? FileManager.default.contentsOfDirectory(atPath: capturesRoot.path) else {
            return
        }
        for id in ids.sorted() {
            await stampHeadIfNeeded(captureID: id)
        }
    }

    /// Sibling to `stampUnstampedHeads`, scoped to one capture — matches this file's
    /// existing corpus-pass/per-capture pairing (`promoteCorpus`/`promoteIfNeeded`,
    /// `closeStaleDrafts`/`closeStaleDraftIfNeeded`), kept `private` since the sweep
    /// is the only caller today.
    private func stampHeadIfNeeded(captureID: String) async {
        let captureDirectory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
        guard case .present(let files) = Self.listing(captureDirectory: captureDirectory), !files.isEmpty else {
            return
        }
        guard Self.trustedPersistedHead(captureDirectory: captureDirectory, files: files) == nil else {
            return
        }
        // `persistHead` already enforces every guard this write needs (trashed,
        // missing capture, unreadable sidecar) — swallowed here the same way
        // `append`'s own `persistHead` call swallows it (C1-trigger): a stamping
        // failure must never abort the rest of the corpus sweep.
        try? await persistHead(captureID: captureID)
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
    /// guaranteed to exist, but before EACH exclusive-create attempt (first AND retry —
    /// #42 pin 1) — letting a test plant a colliding `canonical-<n>.json` at whichever
    /// slot `n` it's handed, to force the EEXIST retry path, or a SECOND EEXIST
    /// (`.allocationCollision`), deterministically. `nextFileNumber()`'s own
    /// `(files.max() ?? -1) + 1` definition means a single, one-shot plant can never
    /// force a second collision on its own — the retry always recomputes to a slot
    /// one past whatever's already present, which by construction is never occupied —
    /// so a real double-collision test needs the callback to fire again with the
    /// retry's recomputed number.
    @discardableResult
    func append(_ revision: TranscriptRevision, captureID: String,
                beforeWrite: (@Sendable (Int) -> Void)? = nil) async throws -> Int {
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

        var fileNumber = try nextFileNumber(captureDirectory: captureDirectory)
        let data = try CaptureCoding.encoder().encode(revision)

        // A2b: transcript/ is created only by this content-carrying write, never by a
        // read and never by head persistence alone.
        try FileManager.default.createDirectory(
            at: SegmentLayout.transcriptDirectory(captureDirectory: captureDirectory),
            withIntermediateDirectories: true)

        beforeWrite?(fileNumber)

        do {
            try AtomicFile.createExclusively(
                at: SegmentLayout.canonicalTranscriptURL(captureDirectory: captureDirectory,
                                                         revision: fileNumber),
                writing: data)
        } catch let error as AtomicFileError where isEEXIST(error) {
            fileNumber = try nextFileNumber(captureDirectory: captureDirectory)
            beforeWrite?(fileNumber)
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

        // M4 T9 chokepoint (design §3: "TranscriptRevisionStore.append → enqueue
        // Revision (fires once per revision)"). Fired once, here, regardless of which
        // caller minted the revision (`closeDraft`, `revert`, `promoteIfNeeded`, or a
        // direct caller) — one write, one notification, matching every sibling store's
        // hook placement at the end of a successful write.
        await syncHooks?.noteLocalChange(.revision(id: revision.id))
        return fileNumber
    }

    /// Where the next revision would land if written right now: `0` for an absent
    /// chain, `max(present) + 1` otherwise, and a refusal for a `transcript/` this
    /// device cannot list — the "never allocate over an unknown chain" rule (Gate A).
    /// Shared by `append` (mints new content) and `ingestForeignRevision` (writes
    /// already-minted foreign bytes verbatim) so the two write paths can never quietly
    /// diverge on what "next free n" means — the standing branch rule applied to this
    /// store's own internals, not just to external callers.
    private nonisolated func nextFileNumber(captureDirectory: URL) throws -> Int {
        switch Self.listing(captureDirectory: captureDirectory) {
        case .absent:
            return 0
        case .unreadable(let reason):
            throw TranscriptRevisionStoreError.transcriptDirUnreadable(reason)
        case .present(let files):
            return (files.max() ?? -1) + 1
        }
    }

    private nonisolated func isEEXIST(_ error: AtomicFileError) -> Bool {
        if case .posix(_, let code) = error { return code == EEXIST }
        return false
    }

    // MARK: - Foreign ingest (M4 T9, design §6)

    /// Writes an already-minted revision fetched from another device, verbatim, at
    /// this device's own next free `canonical-N` slot — never `n`, never the file
    /// number the pushing device happened to use (design §2 note 1: revision identity
    /// is the ULID, never the file number; file numberings may differ across devices
    /// forever, and the chain doesn't care — parents are named by id). Does NOT fire
    /// `syncHooks` — an ingest must never echo back as a local change, or two devices
    /// would trade the same revision's arrival forever (the same reasoning
    /// `JournalStore.applySyncMerge`/`EntryMetadataStore.applySyncMerge` already state
    /// for their own writes).
    ///
    /// (a) **Idempotence**: a no-op when `revisionID` already names a revision this
    /// device can read anywhere in `transcript/` — checked against `rawLoad`'s own
    /// id-dedupe walk (Gate A finding C1) rather than a second, independently-derived
    /// "does this id exist" rule. Only readable files are consulted; an unreadable
    /// `transcript/` refuses below via `nextFileNumber` rather than risking a
    /// duplicate write over a chain this device cannot fully see.
    ///
    /// (b) **Next-free-`n` allocation**, via the exact `nextFileNumber` +
    /// `AtomicFile.createExclusively` + one-retry-then-`.allocationCollision` dance
    /// `append` itself uses (factored out above so the two can never diverge) —
    /// `body` is written byte-for-byte, never re-encoded through
    /// `CaptureCoding.encoder()`, so a device-specific encoding drift can never make a
    /// synced-in revision differ from the bytes the origin device pushed.
    ///
    /// (c) **`head.json` refresh** via the same `persistHead` every local write uses —
    /// swallowed on failure for the identical C1-trigger reason `append` swallows it:
    /// the revision file is already durable, and `validatedHead` rebuilds over the
    /// readable chain on the next read regardless.
    ///
    /// Guarded exactly like `append` (`guardWritable`: capture directory must exist,
    /// sidecar must not be trashed) — inherited, not re-derived: a trashed-but-not-
    /// purged capture refuses new local writes today, and there is no reason a foreign
    /// revision should be able to write where a local edit could not.
    ///
    /// `beforeWrite` is a test-only seam (M4 T9 fix round 2), same idiom as `append`'s
    /// own `beforeWrite`: a no-op in production (default `nil`), and the only way a
    /// test can force a deterministic suspension at the exact point this call is about
    /// to commit — after every refusal reason (trashed, missing, already-present) has
    /// already been ruled out — for probing `SyncRecordExchange`'s cross-actor
    /// reentrancy during this call (the finding: `SyncRecordExchange` is an actor, and
    /// the `await` into this store is a suspension point during which the exchange can
    /// be reentered by an unrelated concurrent delivery).
    func ingestForeignRevision(captureID: String, revisionID: String, body: Data,
                               beforeWrite: (@Sendable () async -> Void)? = nil) async throws {
        let captureDirectory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
        try guardWritable(captureDirectory: captureDirectory)

        if let raw = Self.rawLoad(captureDirectory: captureDirectory),
           raw.numbered.contains(where: { $0.revision.id == revisionID }) {
            return
        }

        await beforeWrite?()

        var fileNumber = try nextFileNumber(captureDirectory: captureDirectory)

        try FileManager.default.createDirectory(
            at: SegmentLayout.transcriptDirectory(captureDirectory: captureDirectory),
            withIntermediateDirectories: true)

        do {
            try AtomicFile.createExclusively(
                at: SegmentLayout.canonicalTranscriptURL(captureDirectory: captureDirectory,
                                                         revision: fileNumber),
                writing: body)
        } catch let error as AtomicFileError where isEEXIST(error) {
            fileNumber = try nextFileNumber(captureDirectory: captureDirectory)
            do {
                try AtomicFile.createExclusively(
                    at: SegmentLayout.canonicalTranscriptURL(captureDirectory: captureDirectory,
                                                             revision: fileNumber),
                    writing: body)
            } catch let secondError as AtomicFileError where isEEXIST(secondError) {
                throw TranscriptRevisionStoreError.allocationCollision
            }
        }

        try? persistHead(captureID: captureID)
    }

    /// Finds which capture currently holds a readable canonical file for `revisionID`,
    /// and its LOCAL file number — the reverse lookup the sync push path needs
    /// (`SyncRecordExchange.recordToPush`): `SyncRecordName.revision(id:)` carries only
    /// the revision's own id (design §2 note 1 — never the file number, and, unlike
    /// `.entry`/`.audio`/`.liveLog`, never the captureID either), so building the
    /// record to push has no other way to find either back except by looking.
    ///
    /// Walks every capture directory's readable chain — O(archive size), the same cost
    /// this codebase already accepts for `SyncTreeScanner.scan()`'s own whole-archive
    /// walk on every launch reconciliation. A revision is pushed at most once per
    /// mint (immutable, create-once), never on a hot path, so this is not a
    /// per-keystroke cost.
    nonisolated static func locateRevision(capturesRoot: URL,
                                           revisionID: String) -> (captureID: String, fileNumber: Int)? {
        guard let ids = try? FileManager.default.contentsOfDirectory(atPath: capturesRoot.path) else {
            return nil
        }
        for captureID in ids.sorted() {
            let directory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
            guard let raw = rawLoad(captureDirectory: directory) else { continue }
            if let match = raw.numbered.first(where: { $0.revision.id == revisionID }) {
                return (captureID: captureID, fileNumber: match.file)
            }
        }
        return nil
    }

    // MARK: - Draft lifecycle (T6d, design §2.5)

    /// Best-effort read of `draft.json`, or `nil` if it's absent or doesn't decode.
    /// Mirrors `readPersistedHead`: an undecodable draft is treated the same as no
    /// draft rather than as an error — there is nothing safe to close or overwrite.
    ///
    /// Not `private` (T7 Task 2 fix round 1, Important 3), same reasoning as
    /// `draftExists` (T7 prereq #41): `EntryChainSnapshot.openDraft` reuses this exact
    /// read rather than a second copy of the same absent/undecodable-collapse rule.
    nonisolated static func readDraft(captureDirectory: URL) -> TranscriptDraft? {
        let url = SegmentLayout.transcriptDraftURL(captureDirectory: captureDirectory)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? CaptureCoding.decoder().decode(TranscriptDraft.self, from: data)
    }

    /// Cheap existence check for `draft.json` — no decode, no actor hop (T7 prereq #41,
    /// fix round 1, Important 2). `LibraryScreenModel.hasDraft(_:)` uses this so
    /// entry-open can skip the actor entirely for a draft-free capture, the
    /// overwhelmingly common case, rather than queueing behind an in-flight corpus walk
    /// that's holding the actor (the exact regression the T6c comment on
    /// `EntryDetailView.refresh()`'s promote call already warns about).
    nonisolated static func draftExists(capturesRoot: URL, captureID: String) -> Bool {
        let captureDirectory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
        let url = SegmentLayout.transcriptDraftURL(captureDirectory: captureDirectory)
        return FileManager.default.fileExists(atPath: url.path)
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

    /// The readable chain a draft operation is allowed to see — REFUSES (Critical 2,
    /// design §4.8/F5) when any part of the chain is damaged, rather than silently
    /// treating an unreadable revision as absent. `loadChain`'s `?? []` convenience
    /// discards exactly that distinction (`ChainLoad.unreadableFiles` /
    /// `.listingUnreadable`); using it directly here would let `writeDraft` splice
    /// against a chain missing its true tip and `closeDraft` mint a revision that
    /// silently drops the undecodable revision's content from the text forever — the
    /// worked example design §4.8 exists to prevent, now reachable through the draft
    /// path (`closeStaleDrafts` in particular runs at launch with no editor in the loop
    /// to enforce §4.8's "the editor refuses to open" half of that rule). `.absent`
    /// (no `transcript/` yet) is not damage — an empty chain is a legitimate starting
    /// point and returns `[]`.
    private static func readableOrderedRevisions(captureDirectory: URL) throws -> [TranscriptRevision] {
        guard let load = Self.loadChain(captureDirectory: captureDirectory) else {
            return []
        }
        if load.listingUnreadable {
            throw TranscriptRevisionStoreError.transcriptDirUnreadable(
                "draft operation refused: transcript/ could not be listed")
        }
        if let firstUnreadable = load.unreadableFiles.first {
            throw TranscriptRevisionStoreError.revisionUnreadable(file: firstUnreadable)
        }
        return load.revisions
    }

    /// Writes `transcript/draft.json` via `AtomicFile.replace`. `transcript/` is created
    /// lazily here — ONLY when `text` differs from current's `plainText` (A2b: a
    /// content-carrying write, never a bare open) — unless the directory already exists,
    /// in which case a draft matching current is still recorded (harmless: `closeDraft`
    /// treats a draft equal to current as "close to nothing" regardless of when it was
    /// written).
    ///
    /// **#40.2 (T7 Task 3) — bounding the per-write cost.** `readableOrderedRevisions`
    /// below runs UNCONDITIONALLY, on every write, and MUST: it is where §15b.15's
    /// degraded-chain refusal actually throws, and a file reads as "unreadable"
    /// precisely because its decode failed — keeping the refusal while skipping the
    /// decode is not possible; the issue's own wording invited exactly that mistake and
    /// it is wrong (see the brief). What this task DOES skip: `TranscriptChain
    /// .plainText`'s flatten of `current` plus the `text != currentText` comparison,
    /// when `transcript/` already exists — because the guard they feed lets the write
    /// through unconditionally once that's true, so the comparison's result is
    /// structurally never read. (`TranscriptChain.current(ordered)` itself stays
    /// unconditional: it is a pure, decode-free, in-memory walk over `ordered` — no
    /// I/O, no allocation of a joined string — and is still needed below to snapshot a
    /// brand-new draft's `parentID`/`basedOnMachineID` even when `transcript/` already
    /// holds a promoted revision with no draft opened against it yet, the single most
    /// common first-keystroke case. Only the genuinely costly flatten+compare is gated.)
    /// The whole-chain DECODE itself (inside `readableOrderedRevisions`) still runs on
    /// every write — filed as #50 rather than improvised here: a body-free readability
    /// check is a design change to the chain's format/contract (needs its own
    /// fingerprinting scheme in `head.json`), not a drop-in optimization.
    func writeDraft(captureID: String, text: String, now: Date,
                    currentTextComparisonRan: (@Sendable () -> Void)? = nil) throws {
        let captureDirectory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
        try guardWritable(captureDirectory: captureDirectory)

        // Critical 2 / §15b.15: refuse rather than silently splice against a chain
        // missing its true tip. Unconditional — see doc comment above.
        let ordered = try Self.readableOrderedRevisions(captureDirectory: captureDirectory)
        let current = TranscriptChain.current(ordered)

        let transcriptDirectory = SegmentLayout.transcriptDirectory(captureDirectory: captureDirectory)
        let transcriptDirectoryExists = FileManager.default.fileExists(atPath: transcriptDirectory.path)

        // #40.2: the flatten + comparison are moot once transcript/ already exists —
        // `currentTextComparisonRan` is a test-only seam (mirrors `append`'s
        // `beforeWrite`) proving that skip actually happens.
        if !transcriptDirectoryExists {
            currentTextComparisonRan?()
            let currentText = current.map(TranscriptChain.plainText) ?? ""
            guard text != currentText else {
                return
            }
        }

        try FileManager.default.createDirectory(at: transcriptDirectory, withIntermediateDirectories: true)

        // Important 4: the three snapshot fields (parentID, basedOnMachineID,
        // openedAt) are captured ATOMICALLY, all from the SAME source — either all
        // three come from an already-open draft, or all three come fresh from
        // `current`. Reading them field-by-field via independent `??` fallbacks let a
        // draft opened with no revision yet (`parentID == nil`) silently pick up a
        // machine revision's id on a LATER write once one got promoted mid-draft,
        // while its `openedAt` stayed the original (stale) value — a
        // `basedOnMachineID` claiming the owner saw a machine revision they never did
        // (design line ~745: it must track what the owner actually saw).
        let draft: TranscriptDraft
        if let existing = Self.readDraft(captureDirectory: captureDirectory) {
            draft = TranscriptDraft(captureID: captureID, parentID: existing.parentID,
                                    basedOnMachineID: existing.basedOnMachineID,
                                    openedAt: existing.openedAt, lastWriteAt: now, text: text)
        } else {
            draft = TranscriptDraft(captureID: captureID, parentID: current?.id,
                                    basedOnMachineID: Self.basedOnMachineID(forDraftOpenedAgainst: current),
                                    openedAt: now, lastWriteAt: now, text: text)
        }

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
    func closeDraft(captureID: String, reason: DraftCloseReason, now: Date) async throws -> String? {
        let captureDirectory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
        try guardWritable(captureDirectory: captureDirectory)

        guard let draft = Self.readDraft(captureDirectory: captureDirectory) else {
            return nil
        }
        let draftURL = SegmentLayout.transcriptDraftURL(captureDirectory: captureDirectory)

        // Critical 2: refuse rather than silently splice against — or compare "current"
        // to — a chain missing its true tip. The draft stays on disk untouched; nothing
        // is minted.
        let ordered = try Self.readableOrderedRevisions(captureDirectory: captureDirectory)
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
        let mintedAt = TranscriptChain.mintInstant(now: now, after: ordered)
        let newID = ULID.make(now: mintedAt)
        // The caller-side half of the sourceRevisionID omit-when-equal economy
        // (TranscriptSpan.swift:150-156, Task 1 ledger note): TranscriptSplice can't
        // know the id its output will be minted under, so it always writes an explicit
        // resolved id for borrowed frames; now that the id is known, drop it back to
        // nil wherever it happens to equal the revision the span is about to live in.
        for index in spans.indices where spans[index].sourceRevisionID == newID {
            spans[index].sourceRevisionID = nil
        }

        // #43/#51: the hour-cap comparison stays on the wall clock `now`, not the minted
        // (possibly bumped) instant — the cap is about how long the draft has actually
        // been open, not an artifact of tie-breaking.
        let effectiveReason: DraftCloseReason =
            now.timeIntervalSince(draft.openedAt) > policy.hourCapSeconds ? .hourCap : reason

        let revision = TranscriptRevision(id: newID, source: .userEdit, createdAt: mintedAt, spans: spans,
                                          parentID: draft.parentID, basedOnMachineID: draft.basedOnMachineID,
                                          deviceID: deviceIDProvider(), closedBy: effectiveReason)

        try await append(revision, captureID: captureID)
        try FileManager.default.removeItem(at: draftURL)
        return revision.id
    }

    /// Stale-draft pass for launch + entry-open (rule 9, §4.6 — NEVER the scan): closes
    /// every capture's draft whose `lastWriteAt` is older than `policy.sessionEndSeconds`
    /// with reason `.recovered`. Skips a capture with no draft, a fresh draft, or
    /// `trashedAt != nil`; one bad capture's failure never aborts the rest of the pass
    /// (`closeStaleDraftIfNeeded` never throws, so a per-capture failure can only ever
    /// surface as `nil`, which the loop below simply ignores). The corpus walk owns
    /// nothing but the directory enumeration and that never-abort property; every rule
    /// about WHICH capture is stale and closeable lives once in `closeStaleDraftIfNeeded`.
    func closeStaleDrafts(now: Date) async {
        guard let ids = try? FileManager.default.contentsOfDirectory(atPath: capturesRoot.path) else {
            return
        }
        for id in ids.sorted() {
            _ = await closeStaleDraftIfNeeded(captureID: id, now: now)
        }
    }

    /// Sibling to `closeStaleDrafts(now:)`, same rules, scoped to one capture (T7 prereq
    /// #41): the entry-open call site (`EntryDetailView.refresh()`) needs to recover just
    /// the capture it's opening, not pay for a corpus walk on every screen open.
    ///
    /// Returns the minted revision id, or `nil` in every one of: no draft on disk, the
    /// draft is fresher than `policy.sessionEndSeconds`, the capture is missing or
    /// trashed, `closeDraft` itself threw (a degraded chain, §15b.15 — the draft stays
    /// on disk untouched, nothing is minted, and there is no caller here to show an
    /// error to), OR `closeDraft`'s own §2.5 no-op (`draft.text == current`'s text —
    /// `closeDraft`'s F7 crash-duplicate branch). That last case is the ONE `nil` that
    /// does NOT leave `draft.json` in place: it deletes the (now-redundant) draft file
    /// and mints nothing, same as every other `nil` in effect but different on disk. A
    /// caller must not read `nil` as "draft.json still exists" (fix round 1, Minor 1).
    @discardableResult
    func closeStaleDraftIfNeeded(captureID: String, now: Date) async -> String? {
        let captureDirectory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
        var isCaptureDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: captureDirectory.path, isDirectory: &isCaptureDirectory),
              isCaptureDirectory.boolValue else {
            return nil
        }
        let sidecarURL = SegmentLayout.entryMetadataURL(captureDirectory: captureDirectory)
        guard let metadata = try? EntryMetadataStore.read(url: sidecarURL), !metadata.isTrashed else {
            return nil
        }
        guard let draft = Self.readDraft(captureDirectory: captureDirectory) else {
            return nil
        }
        guard now.timeIntervalSince(draft.lastWriteAt) > policy.sessionEndSeconds else {
            return nil
        }
        return try? await closeDraft(captureID: captureID, reason: .recovered, now: now)
    }

    // MARK: - Revert (T7 Task 8, design §6.5)

    /// Mints a `.merge` revision restoring an earlier MACHINE revision's spans verbatim
    /// — `TranscriptMerge.revert`'s first production caller, reached from the
    /// revision-history panel (`LibraryScreenModel.revert` is a thin passthrough to
    /// this). Guarded exactly like `closeDraft`, in the same order: `guardWritable`
    /// (missing/trashed capture) first, then `readableOrderedRevisions` — §15b.15's
    /// degraded-chain refusal — BEFORE any mint, so a revert can never silently drop
    /// content from a revision file this device failed to read, the same reason a draft
    /// close refuses on the identical chain shape.
    ///
    /// `toRevisionID` must name a revision presently in the readable chain
    /// (`.revisionNotFound` otherwise — the panel's row went stale, or a caller passed
    /// a bad id). `TranscriptMerge.revert` itself throws `TranscriptMergeError
    /// .notMachineLineage` if that revision is human-lineage (Task 1's caller-side
    /// precondition on `basedOnMachineID`, exercised here for the first time in
    /// production) — deliberately NOT re-checked here first: one guard, one place,
    /// never a parallel copy that could drift from it.
    ///
    /// Returns the minted revision's id.
    @discardableResult
    func revert(captureID: String, toRevisionID: String, now: Date) async throws -> String {
        let captureDirectory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
        try guardWritable(captureDirectory: captureDirectory)

        // Review Important 3: refuse rather than let an open draft silently reverse
        // this revert later (see `.draftInProgress`'s own doc comment for the exact
        // mechanism). Cheap check, placed right after `guardWritable` — same
        // "cheapest/safest guard first" ordering the rest of this file already uses —
        // and before the chain read, since there is nothing to gain from reading the
        // chain only to refuse afterward.
        if Self.readDraft(captureDirectory: captureDirectory) != nil {
            throw TranscriptRevisionStoreError.draftInProgress
        }

        // Critical 2 / §15b.15, same as writeDraft/closeDraft: refuse rather than
        // revert against — or even locate the target revision within — a chain missing
        // its true tip.
        let ordered = try Self.readableOrderedRevisions(captureDirectory: captureDirectory)
        guard let machine = ordered.first(where: { $0.id == toRevisionID }) else {
            throw TranscriptRevisionStoreError.revisionNotFound(toRevisionID)
        }
        // `TranscriptChain.current` returns `nil` only when `ordered` is empty
        // (`ordered.last { … }` over nothing) — which the `machine` lookup just above
        // already ruled out (a non-empty chain, since it contains `machine`). Guarded
        // anyway rather than force-unwrapped: no unsafe assumption across the actor
        // boundary for a branch that should be unreachable.
        guard let current = TranscriptChain.current(ordered) else {
            throw TranscriptRevisionStoreError.revisionNotFound(toRevisionID)
        }

        let mintedAt = TranscriptChain.mintInstant(now: now, after: ordered)
        let revision = try TranscriptMerge.revert(current: current, toMachine: machine,
                                                   id: ULID.make(now: mintedAt), createdAt: mintedAt,
                                                   deviceID: deviceIDProvider())
        try await append(revision, captureID: captureID)
        return revision.id
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

        // The chain is empty by construction here (`.skippedAlreadyPromoted` above
        // already handled the non-empty case), so `mintInstant` only ever truncates.
        let mintedAt = TranscriptChain.mintInstant(now: now, after: [])
        let revision = TranscriptRevision(
            id: ULID.make(now: mintedAt),
            source: .machineLive,
            createdAt: mintedAt,
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
            deviceID: deviceIDProvider(),
            closedBy: nil)

        do {
            try await append(revision, captureID: captureID)
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
    ///
    /// Gate B finding C1: `AttributedString` runs PARTITION their result's text, so
    /// `SpeechAnalyzerEngine.runs(of:)` builds run text straight off `text[run.range]`
    /// — a run's text carries its own boundary whitespace (`"hello there"` splits into
    /// `"hello"` / `" there"`, not `"hello"` / `"there"`). `TranscriptChain.plainText`
    /// re-joins span texts with `TranscriptText.join`'s single separator, so a span
    /// text that ALSO carries that boundary space doubles it on every run boundary —
    /// reproduced by the reviewer at both the promotion and the loader level. Each
    /// run's text is trimmed here before it becomes a span, and a run that trims to
    /// nothing (a bare separator run) is dropped entirely rather than kept as an
    /// empty-text span. Frames are untouched by the trim — only `text` changes; `join`
    /// alone is responsible for supplying the separator back.
    nonisolated static func spans(fromCommitted committed: [TranscriptResult]) -> [TranscriptSpan] {
        committed.flatMap { result -> [TranscriptSpan] in
            guard !result.runs.isEmpty else {
                return [TranscriptSpan(text: result.text, anchor: .inherited,
                                       frameStart: result.range.start, frameEnd: result.range.end,
                                       confidence: result.confidence, sourceRevisionID: nil)]
            }
            return result.runs.compactMap { run -> TranscriptSpan? in
                let trimmed = run.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                if let start = run.captureFrameStart, let end = run.captureFrameEnd {
                    return TranscriptSpan(text: trimmed, anchor: .exact,
                                          frameStart: start, frameEnd: end,
                                          confidence: run.confidence, sourceRevisionID: nil)
                }
                return TranscriptSpan(text: trimmed, anchor: .none,
                                      frameStart: nil, frameEnd: nil,
                                      confidence: run.confidence, sourceRevisionID: nil)
            }
        }
    }
}

/// A per-install stable id, minted once and cached in `UserDefaults` (design §5.2's
/// `TranscriptRevision.deviceID`). Not a preference — nothing else in the app reads or
/// writes this key — so `stable(defaults:)` takes a plain `UserDefaults` parameter
/// rather than a dedicated store type the way `CurrentJournal` needed
/// `JournalPreferenceStore` for testability. `TranscriptRevisionStore`'s own
/// `deviceIDProvider` seam (#42 pin 2) is what lets a test route this through a
/// throwaway `UserDefaults(suiteName:)` instead of the real `.standard` domain; no
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
