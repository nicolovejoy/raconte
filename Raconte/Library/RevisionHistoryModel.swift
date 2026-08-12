import Foundation

/// The disk seam the revision-history panel reads/writes through (T7 Task 8). Mirrors
/// `VoiceMarkingStore`'s shape: the read is the SAME `chainSnapshot` every other T7
/// screen already uses (no new read — see `EntryChainSnapshot.orderedChain`'s doc
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
    /// One row per revision in the WHOLE chain (T7 Task 8, fix round 1 — the brief's
    /// "the chain in (createdAt, id) order" is literal: every revision, not just
    /// `current` and the orphans, so the owner can see what sits between a machine
    /// revision and `current` before reverting to it). One-to-one with
    /// `EntryChainSnapshot.orderedChain`.
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
        ///
        /// **Review fix (Critical 1):** gated on `!isCurrent`, NOT `isDetached` — an
        /// ATTACHED machine revision (rev0, current's own ancestor) must still offer
        /// revert. `isDetached` alone made the button inert for every chain the app can
        /// produce today: rev0 `.machineLive` is always either `current` or in
        /// `current`'s ancestry (never detached), `.userEdit`/`.merge`/`.import` are
        /// excluded by the source check regardless, and `.machineRetranscribe` (the one
        /// source that COULD be genuinely detached) has no production writer yet.
        ///
        /// **Review fix (Important 2):** also `false` on every row whenever
        /// `EntryChainSnapshot.editability != .editable` (trashed, degraded chain,
        /// unreadable sidecar, nothing transcribed yet) — content can still render, but
        /// no row may offer a write the store will only refuse anyway.
        var canRevert: Bool
    }

    enum State: Equatable {
        case loading
        case ready
    }

    private(set) var state: State = .loading
    /// `(createdAt, id)` order — straight from `EntryChainSnapshot.orderedChain`, never
    /// re-sorted or re-filtered here (T7 Task 8, fix round 1: ordering AND detachment
    /// are computed once, in `build`, and consumed as-is).
    private(set) var rows: [Row] = []
    private(set) var revisionCount = 0
    private(set) var chainByteSize: Int64 = 0
    /// §12.8's fork indicator — concurrent edits that never converged. Read-only in v1.
    private(set) var isForked = false
    /// `EntryChainSnapshot.editability` (review Important 2) — the panel used to never
    /// read this at all, so a degraded chain rendered as an empty history with a
    /// self-contradicting footer ("0 revisions, 14 KB": `chainByteSize` still counts raw
    /// bytes even when the chain can't be decoded), and a trashed entry showed rows
    /// with the refusal discoverable only via a failed-revert alert. `readOnlyMessage`
    /// below is the surfaceable form.
    private(set) var editability: EntryChainSnapshot.Editability = .editable
    private(set) var errorMessage: String?

    /// `nil` when `.editable`; otherwise the SAME sentence the editor uses
    /// (`TranscriptEditorModel.readOnlySentence`) — that function's own doc comment
    /// names this panel as its intended second consumer, precisely so the two surfaces
    /// can never drift on what a state means.
    var readOnlyMessage: String? {
        guard case .editable = editability else {
            return TranscriptEditorModel.readOnlySentence(editability)
        }
        return nil
    }

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
        editability = snapshot.editability
        state = .ready
    }

    /// Pure row derivation (T7 Task 8, step 8.1) — a plain function so the mapping is
    /// pinned without going through `open()`'s async read.
    ///
    /// A thin MAP, deliberately: ordering and per-revision detachment are both already
    /// computed, once, by `EntryChainSnapshot.build` (`orderedChain` is `(createdAt,
    /// id)`-ordered and each row already carries its own `isDetached` answer) — this
    /// function does not sort, filter, or re-derive ancestry. `isCurrent` is the one
    /// thing computed here, by identity against `snapshot.currentRevisionID`, since
    /// `ChainRevisionRow` itself doesn't carry it (it's a property of the SNAPSHOT, not
    /// of the revision).
    ///
    /// Review Important 2: `canRevert` is ALSO gated on `snapshot.editability ==
    /// .editable` — content still renders for a trashed or degraded entry (the same
    /// "show rows, refuse writes" split `EntryChainSnapshot` itself already documents
    /// for the trash window), but every revert affordance is suppressed rather than
    /// left to fail loudly through the store guard on first tap.
    static func buildRows(from snapshot: EntryChainSnapshot) -> [Row] {
        let isEditable: Bool = {
            if case .editable = snapshot.editability { return true }
            return false
        }()
        return snapshot.orderedChain.map { entry in
            let isCurrent = entry.summary.id == snapshot.currentRevisionID
            return Row(id: entry.summary.id, fileNumber: entry.summary.fileNumber,
                      source: entry.summary.source, createdAt: entry.summary.createdAt,
                      firstLine: entry.summary.firstLine,
                      isCurrent: isCurrent,
                      isDetached: entry.isDetached,
                      // Critical 1 fix: `!isCurrent`, not `entry.isDetached` — see
                      // `Row.canRevert`'s doc comment for why `isDetached` alone made
                      // the button inert for every v1-producible chain.
                      canRevert: isEditable && !entry.summary.source.isHumanLineage && !isCurrent)
        }
    }

    /// Revert to an earlier machine revision (design §6.5) — `TranscriptMerge.revert`'s
    /// first production caller, through `TranscriptRevisionStore.revert`'s guards
    /// (missing/trashed capture, §15b.15 degraded-chain refusal, `.notMachineLineage`).
    /// None of those guards are re-checked here: one guard, one place, so this model
    /// cannot silently drift from what the store actually enforces on disk.
    ///
    /// `row.canRevert` gates the CALLER (the view disables the row), not this method —
    /// mirrors `VoiceMarkingModel.markRange`'s "never trust that the UI already
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
        case .draftInProgress:
            // Review Important 3: `revert`'s own guard against the silent-reversal bug
            // (an open draft later closing and outranking the revert's merge). Route
            // the owner to finish the edit — the editor's own Done is exactly what
            // clears this.
            //
            // Gate B Minor 1: it used to say "finish or discard", and DISCARD is not a
            // thing this app can do — design §2.5 has no discard and the editor has no
            // cancel (ruling Q1), so the instruction named an affordance that does not
            // exist. Done is the only thing that clears this from the editor.
            return "There are unsaved edits open for this entry. Open it in the editor and tap Done to "
                + "finish them, then try reverting again."
        }
    }
}

/// The history panel reads/writes through this model, never straight to
/// `TranscriptRevisionStore` — same one-store-instance-per-file reasoning as
/// `TranscriptEditorStore`/`VoiceMarkingStore`'s conformances.
extension LibraryScreenModel: RevisionHistoryStore {}
