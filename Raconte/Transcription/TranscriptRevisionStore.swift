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

    init(capturesRoot: URL) {
        self.capturesRoot = capturesRoot
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
    private nonisolated static func rawLoad(
        captureDirectory: URL
    ) -> (numbered: [(file: Int, revision: TranscriptRevision)], unreadableFiles: [Int],
          listingUnreadable: Bool)? {
        switch listing(captureDirectory: captureDirectory) {
        case .absent:
            return nil
        case .unreadable:
            return (numbered: [], unreadableFiles: [], listingUnreadable: true)
        case .present(let files):
            var numbered: [(file: Int, revision: TranscriptRevision)] = []
            var unreadableFiles: [Int] = []
            // Gate A finding C1: two canonical files can carry the same revision id (a
            // sync duplicate, or a hand-corrupted tree). `files` is ascending, so the
            // first file we see for a given id is always its lowest file number — keep
            // that one and silently drop any later file sharing the same id, rather
            // than let it flow into a chain (or a Dictionary keyed by id) with two
            // entries for one identity.
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
                guard seenIDs.insert(revision.id).inserted else { continue }
                numbered.append((file: file, revision: revision))
            }
            return (numbered: numbered, unreadableFiles: unreadableFiles, listingUnreadable: false)
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
        let revisionFiles = (raw.numbered.map(\.file) + raw.unreadableFiles).sorted()

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
}
