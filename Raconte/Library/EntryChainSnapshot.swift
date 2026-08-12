import Foundation

/// Everything a screen needs to decide whether/what it may edit — one disk read, off the
/// main actor, writing nothing (T7 Task 2). Deliberately separate from `EntryTranscript`:
/// the row/scan path must never pay for this (#40.1, Task 3) — nothing here is called
/// from `LibraryScanner`, row construction, or `EntryTranscript` itself. The one caller is
/// `LibraryScreenModel.chainSnapshot(for:)`, a user action (editor open, revision-history
/// panel, storage stat), never first paint.
struct EntryChainSnapshot: Sendable, Equatable {
    /// One revision's row in `orderedChain` (T7 Task 8, fix round 1): the same summary
    /// shape `detachedMachineRevisions` already used, plus whether THIS revision is
    /// genuinely detached. Exists so the revision-history panel can show the WHOLE
    /// chain — every revision between a machine revision and `current`, not just the
    /// two endpoints — while still asking `EntryChainSnapshot` the ONE question
    /// ("is this revision detached?") rather than re-deriving ancestry itself.
    struct ChainRevisionRow: Sendable, Equatable {
        var summary: TranscriptHeadSummary
        /// §12.8's "machine transcript, not applied" label — true ONLY for a genuinely
        /// detached machine revision (neither `current` nor one of its ancestors; see
        /// `detachedMachineRevisions`' own doc comment for the exact rule, including
        /// why a chain's root machine revision is NOT detached once a human edit
        /// exists above it). Always `false` for `current` itself and for every
        /// human-lineage revision, matching `detachedMachineRevisions`'s scope exactly
        /// — the label claims "machine transcript", so it must never sit on a row that
        /// isn't one.
        var isDetached: Bool
    }

    enum Editability: Sendable, Equatable {
        case editable
        case readOnlyUnreadableRevision(file: Int)   // §4.8
        case readOnlyListingUnreadable(String)       // §4.5a
        case readOnlyTrashed
        case readOnlyNoTranscript                    // nothing promoted, nothing to edit
        /// `entry.json` is present but did not decode (fix round 1, Important 4 — owner
        /// ruling). Blocking is correct (matches `TranscriptRevisionStore.guardWritable`,
        /// which throws on exactly this sidecar state), but the entry is NOT trashed —
        /// labeling it `.readOnlyTrashed` would tell the owner an entry is in the trash
        /// (wrong Restore / Delete Now affordances) when it is merely corrupt.
        case readOnlyMetadataUnreadable(String)
    }

    var editability: Editability
    var currentRevisionID: String?
    var currentText: String                 // TranscriptChain.plainText(current), "" when none
    var currentSource: RevisionSource?
    var revisionCount: Int
    var isForked: Bool                      // TranscriptChain.forkedHumanLineage
    var openDraft: TranscriptDraft?         // resume-in-progress, and Task 8's "unsaved" marker
    /// Machine-sourced revisions that are genuinely unapplied — neither `current` nor one
    /// of its ancestors (fix round 1, owner ruling; supersedes the plan's `!isAttached`
    /// shorthand for this field only — see `build`'s doc comment). §12.8: labeled "machine
    /// transcript, not applied" in the UI. Chain `(createdAt, id)` order — the same total
    /// order every other chain-derived list in this codebase uses — since Task 8 renders
    /// this list and needs it deterministic.
    var detachedMachineRevisions: [TranscriptHeadSummary]
    /// EVERY revision in the chain — current, its ancestors (rev0 included), and every
    /// detached one — as one `(createdAt, id)`-ordered list (T7 Task 8, fix round 1).
    /// Free to compute here (the `.present` branch already holds `ordered`,
    /// `fileNumbers`, and `forked` by the time this is populated; no new read, no
    /// second disk pass — see `build`'s doc comment). This is the revision-history
    /// panel's whole content list: "detached rows visible, clearly labeled" (§12.8)
    /// means the WHOLE chain, not just the head and the orphans, because the owner
    /// picking "revert to that machine revision" needs to see what sits between it and
    /// `current`. `detachedMachineRevisions` above stays as its own field (Task 2's
    /// original, narrower contract, still used by its own tests) — `orderedChain` is a
    /// superset built from the SAME per-revision detachment predicate, computed once
    /// and shared, never re-derived by a caller (Task 8's own view must not re-derive
    /// detachment). Empty in every branch that also leaves `currentRevisionID` nil.
    var orderedChain: [ChainRevisionRow]
    /// Sum of on-disk byte sizes of every LISTED `canonical-<n>.json` file — readable or
    /// not (a corrupt revision still occupies real bytes, and the storage stat, #39, is
    /// meant to show the chain's real disk cost, not just the successfully-parsed
    /// portion). Deliberately excludes `head.json` (a rebuildable cache, design §4.3) and
    /// `draft.json` (transient/mutable, not part of the immutable chain) — only the
    /// append-only canonical revision files themselves count as "the chain's own on-disk
    /// cost". `0` when `transcript/` is absent or its own listing failed. Computed by
    /// `TranscriptRevisionStore.canonicalFilesByteSize` — the SAME definition
    /// `DirectorySnapshot.revisionsByteSize` (Task 3) counts, on purpose (see that
    /// function's doc comment): the history panel and the diagnostics screen must never
    /// disagree about one entry's chain size.
    var chainByteSize: Int64                // #39

    // MARK: - Build

    /// Builds the snapshot for one capture directory. No actor hop of its own — every
    /// primitive this touches (`TranscriptRevisionStore.listing`/`.rawLoad`/`.readDraft`,
    /// `EntryMetadataStore.read(url:)`, `TranscriptChain.*`) is `nonisolated
    /// static`/pure — and, by construction, no filesystem write: the same "read path
    /// never writes" property `TranscriptRevisionStore` itself holds its own static reads
    /// to (design §4.3).
    ///
    /// **`editability` precedence** (brief rule, matching the store's write-guard order
    /// exactly, so "the editor let me start typing and then the save refused" is
    /// structurally impossible): an undecodable sidecar, THEN a genuinely trashed
    /// sidecar, then an unreadable `transcript/` listing, then any individually-
    /// unreadable revision file, then "no current revision at all" (nothing promoted
    /// yet). Only when none of those apply is the entry `.editable`. (Fix round 1,
    /// Important 4: the undecodable-sidecar case used to fold into `.readOnlyTrashed` —
    /// same blocking behavior, but a false label — and now has its own case,
    /// `.readOnlyMetadataUnreadable`.)
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
        var trashed = false
        var metadataUnreadableReason: String?
        do {
            trashed = try EntryMetadataStore.read(url: sidecarURL).isTrashed
        } catch {
            // `EntryMetadataStore.read(url:)` throws only for a PRESENT, undecodable
            // sidecar — an absent one returns `.defaults` (not trashed) without
            // throwing. So landing here means "corrupt", never "missing".
            metadataUnreadableReason = String(describing: error)
        }

        // The one override that beats every chain-derived Editability below, in order:
        // an unreadable sidecar first (we cannot even ask whether it's trashed), then a
        // genuinely trashed one.
        let precedenceOverride: Editability? = {
            if let reason = metadataUnreadableReason { return .readOnlyMetadataUnreadable(reason) }
            if trashed { return .readOnlyTrashed }
            return nil
        }()

        let openDraft = TranscriptRevisionStore.readDraft(captureDirectory: captureDirectory)

        switch TranscriptRevisionStore.listing(captureDirectory: captureDirectory) {
        case .absent:
            return EntryChainSnapshot(editability: precedenceOverride ?? .readOnlyNoTranscript,
                                      currentRevisionID: nil, currentText: "", currentSource: nil,
                                      revisionCount: 0, isForked: false, openDraft: openDraft,
                                      detachedMachineRevisions: [], orderedChain: [], chainByteSize: 0)

        case .unreadable(let reason):
            return EntryChainSnapshot(editability: precedenceOverride ?? .readOnlyListingUnreadable(reason),
                                      currentRevisionID: nil, currentText: "", currentSource: nil,
                                      revisionCount: 0, isForked: false, openDraft: openDraft,
                                      detachedMachineRevisions: [], orderedChain: [], chainByteSize: 0)

        case .present(let files):
            // #39/#40 Task 3: shared with `DirectorySnapshot.revisionsByteSize` — see
            // `TranscriptRevisionStore.canonicalFilesByteSize`'s doc comment for why
            // this must stay the one implementation.
            let byteSize = TranscriptRevisionStore.canonicalFilesByteSize(
                captureDirectory: captureDirectory, files: files)

            guard let raw = TranscriptRevisionStore.rawLoad(captureDirectory: captureDirectory) else {
                // Cannot happen: `.present` above already proves `transcript/` exists,
                // and `rawLoad` only returns `nil` for `.absent`. No unsafe force-unwrap
                // across the module boundary, so degrade the same way `.absent` does
                // rather than crash on a state that should be unreachable.
                return EntryChainSnapshot(editability: precedenceOverride ?? .readOnlyNoTranscript,
                                          currentRevisionID: nil, currentText: "", currentSource: nil,
                                          revisionCount: 0, isForked: false, openDraft: openDraft,
                                          detachedMachineRevisions: [], orderedChain: [], chainByteSize: byteSize)
            }

            if let firstUnreadable = raw.unreadableFiles.first {
                return EntryChainSnapshot(
                    editability: precedenceOverride ?? .readOnlyUnreadableRevision(file: firstUnreadable),
                    currentRevisionID: nil, currentText: "", currentSource: nil,
                    revisionCount: 0, isForked: false, openDraft: openDraft,
                    detachedMachineRevisions: [], orderedChain: [], chainByteSize: byteSize)
            }

            let ordered = TranscriptChain.ordered(raw.numbered.map(\.revision))
            let fileNumbers = Dictionary(raw.numbered.map { ($0.revision.id, $0.file) }, uniquingKeysWith: min)
            let forked = TranscriptChain.forkedHumanLineage(ordered)

            guard let current = TranscriptChain.current(ordered) else {
                return EntryChainSnapshot(editability: precedenceOverride ?? .readOnlyNoTranscript,
                                          currentRevisionID: nil, currentText: "", currentSource: nil,
                                          revisionCount: ordered.count, isForked: forked, openDraft: openDraft,
                                          detachedMachineRevisions: [], orderedChain: [], chainByteSize: byteSize)
            }

            // Fix round 1, owner ruling: "not applied" (§12.8) is reserved for machine
            // revisions that are genuinely orphaned — neither `current` nor one of its
            // ancestors. A chain's root machine revision is `current`'s own ancestor (the
            // foundation a human edit was built on) and must NOT carry this label, even
            // though it fails the plan's original, broader `!TranscriptChain.isAttached`
            // test — `isAttached` requires the human tip to be among a CANDIDATE's own
            // ancestors, which a root (having none at all) can never satisfy once any
            // human tip exists anywhere in the chain. `TranscriptChain.isAttached` itself
            // is unchanged, and `TranscriptChain.current` still uses it; this supersedes
            // the shorthand for THIS field only. Expressed with existing primitives only
            // (`current`, `TranscriptChain.ancestry(of:among:)`) — no new chain logic.
            //
            // Human-lineage revisions are excluded outright regardless of ancestry: this
            // field is `detachedMachineRevisions` and must never carry a human-authored
            // edit, including a diverged (forked) one that also happens to be neither
            // `current` nor its ancestor — see `RevisionSource.isHumanLineage`.
            //
            // Order: `ordered.filter`/`ordered.compactMap` below both preserve
            // `ordered`'s own `(createdAt, id)` order.
            let currentAncestry = TranscriptChain.ancestry(of: current, among: ordered)
            func isGenuinelyDetached(_ revision: TranscriptRevision) -> Bool {
                !revision.source.isHumanLineage
                    && revision.id != current.id
                    && !currentAncestry.contains(revision.id)
            }

            // T7 Task 8, fix round 1: ONE pass over the WHOLE chain — not just the
            // detached subset — since the history panel must show every revision
            // between a machine revision and `current`, not just the two endpoints.
            // `detachedSummaries` below is then a FILTER of this list (never a second,
            // independent walk), so the two fields can never disagree about which
            // revisions are detached.
            let orderedRows: [ChainRevisionRow] = ordered.compactMap { revision in
                guard let fileNumber = fileNumbers[revision.id] else { return nil }
                let summary = TranscriptRevisionStore.headSummary(for: revision, fileNumber: fileNumber,
                                                                   isForked: forked)
                return ChainRevisionRow(summary: summary, isDetached: isGenuinelyDetached(revision))
            }
            let detachedSummaries = orderedRows.filter(\.isDetached).map(\.summary)

            return EntryChainSnapshot(editability: precedenceOverride ?? .editable,
                                      currentRevisionID: current.id,
                                      currentText: TranscriptChain.plainText(current),
                                      currentSource: current.source,
                                      revisionCount: ordered.count,
                                      isForked: forked,
                                      openDraft: openDraft,
                                      detachedMachineRevisions: detachedSummaries,
                                      orderedChain: orderedRows,
                                      chainByteSize: byteSize)
        }
    }
}
