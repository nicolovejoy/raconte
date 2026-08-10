import Foundation

/// Everything a screen needs to decide whether/what it may edit — one disk read, off the
/// main actor, writing nothing (T7 Task 2). Deliberately separate from `EntryTranscript`:
/// the row/scan path must never pay for this (#40.1, Task 3) — nothing here is called
/// from `LibraryScanner`, row construction, or `EntryTranscript` itself. The one caller is
/// `LibraryScreenModel.chainSnapshot(for:)`, a user action (editor open, revision-history
/// panel, storage stat), never first paint.
struct EntryChainSnapshot: Sendable, Equatable {
    enum Editability: Sendable, Equatable {
        case editable
        case readOnlyUnreadableRevision(file: Int)   // §4.8
        case readOnlyListingUnreadable(String)       // §4.5a
        case readOnlyTrashed
        case readOnlyNoTranscript                    // nothing promoted, nothing to edit
    }

    var editability: Editability
    var currentRevisionID: String?
    var currentText: String                 // TranscriptChain.plainText(current), "" when none
    var currentSource: RevisionSource?
    var revisionCount: Int
    var isForked: Bool                      // TranscriptChain.forkedHumanLineage
    var openDraft: TranscriptDraft?         // resume-in-progress, and Task 8's "unsaved" marker
    var detachedMachineRevisions: [TranscriptHeadSummary]  // §12.8 — visible, labeled
    var chainByteSize: Int64                // #39

    // MARK: - Build

    /// Builds the snapshot for one capture directory. No actor hop of its own — every
    /// primitive this touches (`TranscriptRevisionStore.listing`, `EntryMetadataStore
    /// .read(url:)`, `TranscriptChain.*`) is `nonisolated static`/pure — and, by
    /// construction, no filesystem write: the same "read path never writes" property
    /// `TranscriptRevisionStore` itself holds its own static reads to (design §4.3).
    ///
    /// **`editability` precedence** (brief rule, matching the store's write-guard order
    /// exactly, so "the editor let me start typing and then the save refused" is
    /// structurally impossible): trashed sidecar first, then an unreadable `transcript/`
    /// listing, then any individually-unreadable revision file, then "no current revision
    /// at all" (nothing promoted yet). Only when none of those apply is the entry
    /// `.editable`. An UNREADABLE (present-but-undecodable) sidecar is folded into the
    /// trashed branch — the same conservative default `closeStaleDraftIfNeeded` already
    /// uses (`guard let metadata = try? … else return`, TranscriptRevisionStore.swift):
    /// the store's own write guards throw outright on a sidecar we can't parse, so an
    /// entry we can't even confirm isn't trashed must never read as `.editable` — that
    /// would be exactly the bug this precedence exists to rule out. It doesn't literally
    /// mean "trashed" (there is no dedicated case for "sidecar unreadable"), but it is the
    /// one case that both blocks editing and costs nothing further to compute.
    ///
    /// The content fields (`currentRevisionID`/`currentText`/…/`detachedMachineRevisions`)
    /// are populated whenever the chain itself is readable, INDEPENDENT of the trashed
    /// flag: `trashedAt` lives on the sidecar, not `transcript/`, so a trashed entry's
    /// chain can be perfectly healthy, and the history panel / storage stat keep showing
    /// it through the 30-day trash window even though `editability` correctly still
    /// reports `.readOnlyTrashed`. They collapse to their empty defaults only when the
    /// underlying chain read itself failed (`.readOnlyListingUnreadable` /
    /// `.readOnlyUnreadableRevision`) — there is nothing safe to report in that case.
    /// `openDraft` and `chainByteSize` are the two exceptions: both are independent,
    /// best-effort reads (a stray draft or the chain's raw disk footprint can be
    /// meaningful even when a specific revision file is corrupt), so both are always
    /// attempted regardless of which branch below is taken.
    static func build(captureDirectory: URL) -> EntryChainSnapshot {
        let sidecarURL = SegmentLayout.entryMetadataURL(captureDirectory: captureDirectory)
        let trashed = (try? EntryMetadataStore.read(url: sidecarURL))?.isTrashed ?? true

        let openDraft = Self.readDraft(captureDirectory: captureDirectory)

        switch TranscriptRevisionStore.listing(captureDirectory: captureDirectory) {
        case .absent:
            return EntryChainSnapshot(editability: trashed ? .readOnlyTrashed : .readOnlyNoTranscript,
                                      currentRevisionID: nil, currentText: "", currentSource: nil,
                                      revisionCount: 0, isForked: false, openDraft: openDraft,
                                      detachedMachineRevisions: [], chainByteSize: 0)

        case .unreadable(let reason):
            return EntryChainSnapshot(editability: trashed ? .readOnlyTrashed : .readOnlyListingUnreadable(reason),
                                      currentRevisionID: nil, currentText: "", currentSource: nil,
                                      revisionCount: 0, isForked: false, openDraft: openDraft,
                                      detachedMachineRevisions: [], chainByteSize: 0)

        case .present(let files):
            let byteSize = Self.byteSize(captureDirectory: captureDirectory, files: files)
            let loaded = Self.numberedLoad(captureDirectory: captureDirectory, files: files)

            if let firstUnreadable = loaded.unreadableFiles.first {
                return EntryChainSnapshot(
                    editability: trashed ? .readOnlyTrashed : .readOnlyUnreadableRevision(file: firstUnreadable),
                    currentRevisionID: nil, currentText: "", currentSource: nil,
                    revisionCount: 0, isForked: false, openDraft: openDraft,
                    detachedMachineRevisions: [], chainByteSize: byteSize)
            }

            let ordered = loaded.ordered
            let forked = TranscriptChain.forkedHumanLineage(ordered)

            guard let current = TranscriptChain.current(ordered) else {
                return EntryChainSnapshot(editability: trashed ? .readOnlyTrashed : .readOnlyNoTranscript,
                                          currentRevisionID: nil, currentText: "", currentSource: nil,
                                          revisionCount: ordered.count, isForked: forked, openDraft: openDraft,
                                          detachedMachineRevisions: [], chainByteSize: byteSize)
            }

            // §12.8: every revision `TranscriptChain` itself calls unattached — labeled
            // "machine transcript, not applied" in the UI. This reuses `isAttached`
            // verbatim rather than re-deriving a narrower "off to the side only" filter,
            // per the brief's instruction not to reimplement chain logic here. Note this
            // also includes a chain's original root machine revision once ANY human tip
            // exists elsewhere in the chain — `isAttached` requires the human tip to be
            // among a machine revision's OWN ancestors, and a root has no ancestors at
            // all, so it can never satisfy that once a human edit exists anywhere (see
            // TranscriptChainTests.testF1MachineAfterMachineIsDetached /
            // .testA1DataLossWalk for the same already-shipped pattern on other
            // pre-human-tip machine revisions).
            let detached = ordered.filter { !TranscriptChain.isAttached($0, in: ordered) }
            let detachedSummaries = detached.compactMap { revision -> TranscriptHeadSummary? in
                guard let fileNumber = loaded.fileNumbers[revision.id] else { return nil }
                return Self.summary(for: revision, fileNumber: fileNumber, isForked: forked)
            }

            return EntryChainSnapshot(editability: trashed ? .readOnlyTrashed : .editable,
                                      currentRevisionID: current.id,
                                      currentText: TranscriptChain.plainText(current),
                                      currentSource: current.source,
                                      revisionCount: ordered.count,
                                      isForked: forked,
                                      openDraft: openDraft,
                                      detachedMachineRevisions: detachedSummaries,
                                      chainByteSize: byteSize)
        }
    }

    // MARK: - Private reads

    /// Best-effort read of `draft.json` — mirrors `TranscriptRevisionStore`'s own private
    /// `readDraft`: an undecodable or absent draft is treated identically as "no draft",
    /// never as an error.
    private static func readDraft(captureDirectory: URL) -> TranscriptDraft? {
        let url = SegmentLayout.transcriptDraftURL(captureDirectory: captureDirectory)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? CaptureCoding.decoder().decode(TranscriptDraft.self, from: data)
    }

    /// Sum of on-disk byte sizes of every LISTED `canonical-<n>.json` file — readable or
    /// not (a corrupt revision still occupies real bytes, and the storage stat, #39, is
    /// meant to show the chain's real disk cost, not just the successfully-parsed
    /// portion). Deliberately excludes `head.json` (a rebuildable cache, design §4.3) and
    /// `draft.json` (transient/mutable, not part of the immutable chain) — only the
    /// append-only canonical revision files themselves count as "the chain's own on-disk
    /// cost". `0` when `transcript/` is absent or its own listing failed: there is
    /// nothing to sum in either case (handled by the two early-return branches above,
    /// which never call this).
    private static func byteSize(captureDirectory: URL, files: [Int]) -> Int64 {
        files.reduce(Int64(0)) { total, file in
            let url = SegmentLayout.canonicalTranscriptURL(captureDirectory: captureDirectory, revision: file)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? NSNumber else {
                return total
            }
            return total + size.int64Value
        }
    }

    private struct NumberedLoad {
        var ordered: [TranscriptRevision]      // (createdAt, id) order, deduped by id
        var fileNumbers: [String: Int]         // revision id -> lowest file number seen for it
        var unreadableFiles: [Int]
    }

    /// Same decode-and-dedup rule as `TranscriptRevisionStore`'s own (private) `rawLoad`
    /// (Gate A finding C1: keep the first file seen for a given revision id, silently drop
    /// any later duplicate) — reimplemented here rather than reused because file numbers
    /// are needed for EVERY revision that may end up in `detachedMachineRevisions`, not
    /// just `current`'s, and `TranscriptRevisionStore.loadChain` deliberately discards
    /// file numbers entirely (see its own doc comment). `TranscriptRevisionStore.listing`
    /// — the public primitive — still supplies `files`, so only the per-file decode/dedup
    /// bookkeeping is duplicated, not the trashed/listing/unreadable precedence itself.
    private static func numberedLoad(captureDirectory: URL, files: [Int]) -> NumberedLoad {
        var numbered: [(file: Int, revision: TranscriptRevision)] = []
        var unreadableFiles: [Int] = []
        var seenIDs: Set<String> = []
        let decoder = CaptureCoding.decoder()
        for file in files {
            let url = SegmentLayout.canonicalTranscriptURL(captureDirectory: captureDirectory, revision: file)
            guard let data = try? Data(contentsOf: url),
                  let revision = try? decoder.decode(TranscriptRevision.self, from: data) else {
                unreadableFiles.append(file)
                continue
            }
            guard seenIDs.insert(revision.id).inserted else { continue }
            numbered.append((file: file, revision: revision))
        }
        let fileNumbers = Dictionary(numbered.map { ($0.revision.id, $0.file) }, uniquingKeysWith: min)
        return NumberedLoad(ordered: TranscriptChain.ordered(numbered.map(\.revision)),
                            fileNumbers: fileNumbers, unreadableFiles: unreadableFiles)
    }

    /// Same shape as `TranscriptRevisionStore`'s private `rebuildHead` summary
    /// construction (first line, truncated to 120 chars) — the one other place that mints
    /// a `TranscriptHeadSummary`.
    private static func summary(for revision: TranscriptRevision, fileNumber: Int,
                                isForked: Bool) -> TranscriptHeadSummary {
        let plain = TranscriptChain.plainText(revision)
        let firstLineFull = plain.split(separator: "\n", maxSplits: 1,
                                        omittingEmptySubsequences: false).first
            .map(String.init) ?? plain
        return TranscriptHeadSummary(id: revision.id, fileNumber: fileNumber, source: revision.source,
                                     createdAt: revision.createdAt, characterCount: plain.count,
                                     firstLine: String(firstLineFull.prefix(120)), isForked: isForked)
    }
}
