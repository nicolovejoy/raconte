import Foundation

/// The disk seam the revision-history panel reads/writes through (T7 Task 8). Mirrors
/// `MarkerCorrectionStore`'s shape: the read is the SAME `chainSnapshot` every other T7
/// screen already uses (no new read — see `EntryChainSnapshot.currentSummary`'s doc
/// comment), and `revert` is a plain `async throws` passthrough to
/// `TranscriptRevisionStore.revert` via `LibraryScreenModel`.
@MainActor
protocol RevisionHistoryStore: AnyObject {
    func chainSnapshot(for captureID: String) async -> EntryChainSnapshot
    @discardableResult
    func revert(captureID: String, toRevisionID: String, now: Date) async throws -> String
}

/// The revision-history panel's whole behaviour (T7 Task 8, design §12.8 + §6.5).
/// `RevisionHistoryView` is a thin binding over this — SwiftUI body rendering is not
/// reachable from `RaconteTests`, so anything with a rule in it lives here, per the
/// editor's and marker-correction screen's own precedent.
///
/// **This panel is the whole undo story** (T7 plan ruling Q1): the editor has no
/// discard and no revert button, so revert-from-here is the only way back. It offers
/// exactly one write action — revert to an earlier MACHINE revision — because accept
/// and decline stay uncalled until retranscription exists (design §12.6/§6.6).
@MainActor
@Observable
final class RevisionHistoryModel {
    /// One row: either `current` or a genuinely detached machine revision (T7 Task 2's
    /// `EntryChainSnapshot.detachedMachineRevisions` — "not applied" per the owner's
    /// §12.8 ruling, i.e. neither `current` nor one of its ancestors). Earlier revisions
    /// that ARE part of `current`'s own lineage are not surfaced as separate rows: they
    /// are exactly the history current already carries forward, and showing them would
    /// need a disk read `EntryChainSnapshot` deliberately does not do (see its own doc
    /// comment on why the row/scan path must never pay for a chain decode).
    struct Row: Identifiable, Equatable {
        var id: String
        var fileNumber: Int
        var source: RevisionSource
        var createdAt: Date
        var firstLine: String
        var isCurrent: Bool
        /// §12.8's label: "machine transcript, not applied". `false` for `current`
        /// itself even when `current` is machine-sourced — "not applied" would be a
        /// false statement about the revision the entry is actually showing.
        var isDetached: Bool
        /// Revert is offered for a machine-lineage row that is not already current
        /// (brief: "the only merge action meaningful before T8" — reverting TO current
        /// is a no-op nobody asked for, and reverting to a human row is refused by
        /// `TranscriptMerge.revert`'s own `.notMachineLineage` guard regardless of what
        /// this flag says, so the flag is a UI nicety, never the enforcement).
        var canRevert: Bool
    }

    enum State: Equatable {
        case loading
        case ready
    }

    private(set) var state: State = .loading
    /// `(createdAt, id)` order — the same total order `EntryChainSnapshot
    /// .detachedMachineRevisions` already uses (T7 Task 2 fix round 2's ordering pin),
    /// extended here to include `current`.
    private(set) var rows: [Row] = []
    private(set) var revisionCount = 0
    private(set) var chainByteSize: Int64 = 0
    /// §12.8's fork indicator — concurrent edits that never converged. Read-only in v1.
    private(set) var isForked = false
    private(set) var errorMessage: String?

    /// #39's growth alarm (Task 3/`RevisionGrowthAlarm`) — revisions per entry, not
    /// bytes. Computed, not stored: `revisionCount` is the one source of truth and this
    /// is a pure re-read of it against the one named threshold.
    var isGrowthElevated: Bool { RevisionGrowthAlarm.isElevated(revisionCount: revisionCount) }

    let captureID: String
    private let store: any RevisionHistoryStore
    private let clock: @Sendable () -> Date

    init(captureID: String, store: any RevisionHistoryStore,
         clock: @escaping @Sendable () -> Date = { Date() }) {
        self.captureID = captureID
        self.store = store
        self.clock = clock
    }

    /// Reads the chain snapshot fresh from disk — called on first appear and again
    /// after every successful revert, so the panel always reflects what a revert
    /// actually did rather than what the model assumed it did.
    func open() async {
        state = .loading
        let snapshot = await store.chainSnapshot(for: captureID)
        rows = Self.buildRows(from: snapshot)
        revisionCount = snapshot.revisionCount
        chainByteSize = snapshot.chainByteSize
        isForked = snapshot.isForked
        state = .ready
    }

    /// Pure row derivation (T7 Task 8, step 8.1) — a plain function so ordering and
    /// labeling are pinned without going through `open()`'s async read.
    static func buildRows(from snapshot: EntryChainSnapshot) -> [Row] {
        var entries: [(summary: TranscriptHeadSummary, isDetached: Bool)] =
            snapshot.detachedMachineRevisions.map { ($0, true) }
        if let current = snapshot.currentSummary {
            entries.append((current, false))
        }
        // The chain's own total order (design: `(createdAt, id)`), matching every other
        // chain-derived list in this codebase (`TranscriptChain.ordered`,
        // `detachedMachineRevisions` itself) — not insertion order, and not file order.
        entries.sort { lhs, rhs in
            if lhs.summary.createdAt != rhs.summary.createdAt {
                return lhs.summary.createdAt < rhs.summary.createdAt
            }
            return lhs.summary.id < rhs.summary.id
        }
        return entries.map { entry in
            Row(id: entry.summary.id, fileNumber: entry.summary.fileNumber,
                source: entry.summary.source, createdAt: entry.summary.createdAt,
                firstLine: entry.summary.firstLine, isCurrent: !entry.isDetached,
                isDetached: entry.isDetached,
                canRevert: !entry.summary.source.isHumanLineage && entry.isDetached)
        }
    }

    /// Revert to an earlier machine revision (design §6.5) — `TranscriptMerge.revert`'s
    /// first production caller, through `TranscriptRevisionStore.revert`'s guards
    /// (missing/trashed capture, §15b.15 degraded-chain refusal, `.notMachineLineage`).
    /// None of those guards are re-checked here: one guard, one place, so this model
    /// cannot silently drift from what the store actually enforces on disk.
    ///
    /// `row.canRevert` gates the CALLER (the view disables the row), not this method —
    /// mirrors `MarkerCorrectionModel.addBoundary`'s "never trust that the UI already
    /// enforced it" reasoning, and lets a test drive a disallowed revert without a
    /// SwiftUI harness.
    func revert(_ row: Row) async {
        do {
            _ = try await store.revert(captureID: captureID, toRevisionID: row.id, now: clock())
            await open()
        } catch {
            errorMessage = Self.revertFailureMessage(error)
        }
    }

    func acknowledgeError() { errorMessage = nil }

    /// A sentence, not a raw error dump — same "render true, specific copy" discipline
    /// as `TranscriptEditorModel.saveFailureMessage`, which this mirrors case-for-case
    /// for the store errors the two share.
    private static func revertFailureMessage(_ error: any Error) -> String {
        if case TranscriptMergeError.notMachineLineage = error {
            // Reachable only if a caller bypasses `row.canRevert` (or the panel shows a
            // stale row for a revision that was human-authored all along) — the store
            // never re-derives this itself, it just relays TranscriptMerge's own guard.
            return "That revision can’t be reverted to."
        }
        guard let storeError = error as? TranscriptRevisionStoreError else {
            return "That couldn’t be saved. Try again."
        }
        switch storeError {
        case .trashedCapture:
            return "This entry is in the trash, so it can’t be reverted. Restore it first."
        case .captureMissing:
            return "This entry’s files are no longer on this device."
        case .revisionUnreadable(let file):
            return "Revision file \(file) could not be read, so reverting now could lose what it holds."
        case .transcriptDirUnreadable:
            return "This entry’s revision folder could not be read, so reverting now could lose "
                + "what it holds."
        case .revisionNotFound:
            return "That revision could not be found. The history may have changed — try reopening it."
        case .allocationCollision:
            return "Another save is still finishing. Try again."
        }
    }
}

/// The history panel reads/writes through this model, never straight to
/// `TranscriptRevisionStore` — same one-store-instance-per-file reasoning as
/// `TranscriptEditorStore`/`MarkerCorrectionStore`'s conformances.
extension LibraryScreenModel: RevisionHistoryStore {}
