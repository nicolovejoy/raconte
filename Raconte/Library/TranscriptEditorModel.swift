import Foundation

/// The disk seam the editor writes through (T7 Task 4). `LibraryScreenModel` is the one
/// production conformer — the editor never reaches `TranscriptRevisionStore` directly, for
/// the same reason the detail screen doesn't: one store instance per file, app-wide.
///
/// A protocol rather than a concrete dependency purely so the failure paths (a `writeDraft`
/// that throws, a `closeDraft` that throws) are reachable from a test without contriving a
/// disk state that would ALSO change what `chainSnapshot` reports — the two must be able to
/// disagree in a test, because on device they can disagree in the field (an entry trashed on
/// another screen while the editor is open).
@MainActor
protocol TranscriptEditorStore: AnyObject {
    func chainSnapshot(for captureID: String) async -> EntryChainSnapshot
    /// The un-edited machine transcript (`live.jsonl` through `EntryTranscriptLoader`),
    /// offered READ-ONLY beside a degraded chain (T7 plan ruling Q5). Never the source of
    /// the editor's editable text — see `TranscriptEditorModel.open()`.
    func machineTranscript(for captureID: String) async -> String?
    /// `transcript/draft.json` as it is on disk RIGHT NOW — the editor's only way to notice
    /// that something else closed the draft beneath it.
    func openDraft(for captureID: String) async -> TranscriptDraft?
    func writeDraft(captureID: String, text: String, now: Date) async throws
    @discardableResult
    func closeDraft(captureID: String, reason: DraftCloseReason, now: Date) async throws -> String?
}

/// The 2 s debounce's timer (design §12.1), injectable so tests never sleep on a real
/// clock. `arm` always cancels whatever was armed before — that re-arming IS the debounce.
@MainActor
protocol EditorDebounce: AnyObject {
    func arm(after seconds: TimeInterval, _ fire: @escaping @MainActor () async -> Void)
    func cancel()
}

/// The shipping timer: one `Task` per armed window, cancelled and replaced per keystroke.
@MainActor
final class TaskEditorDebounce: EditorDebounce {
    private var task: Task<Void, Never>?

    func arm(after seconds: TimeInterval, _ fire: @escaping @MainActor () async -> Void) {
        task?.cancel()
        task = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await fire()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

/// The transcript editor's whole behaviour (T7 Task 4). `TranscriptEditorView` is a thin
/// binding over this, per the `EntryDetailView.transcriptDisplay` precedent: SwiftUI body
/// rendering is not reachable from `RaconteTests`, so anything with a rule in it lives here.
///
/// **Three things this type owns that the store deliberately does not:**
/// 1. **The read-only guard.** `EntryChainSnapshot.Editability` and the store's write guards
///    agree on every case but one: `.readOnlyNoTranscript` is a state where `writeDraft`
///    would happily SUCCEED (and create a `draft.json` for an entry with nothing
///    transcribed). Editability is therefore the authority here, never "the write didn't
///    throw" — see `isEditable`.
/// 2. **Debounced writing.** Every flush is `writeDraft`; only `done()` calls `closeDraft`.
/// 3. **Noticing that the draft was closed beneath it.** `EntryDetailView.refresh()` runs
///    after a backdate save, a journal move, and entry open — each one closing drafts older
///    than `DraftPolicy.sessionEndSeconds` (90 s) with reason `.recovered`. An editor left
///    open and idle for two minutes while the owner backdates the entry underneath it will
///    have its draft minted into a revision and deleted out from under it. See
///    `noteDraftClosedBeneathSessionIfNeeded()`.
///
/// **No cancel, no discard, no revert** (T7 plan ruling Q1): design §2.5 has no discard, so
/// a "Cancel" that actually meant "Done" would be a lie. Navigating away IS Done. The undo
/// story is revision history + revert (Task 8).
@MainActor
@Observable
final class TranscriptEditorModel {
    enum State: Equatable {
        case loading
        case editing
        case readOnly(EntryChainSnapshot.Editability)
        /// A save failed. The text stays on screen and stays editable — the one thing this
        /// state must never do is take the owner's unsaved words away, or dismiss the screen
        /// (the 2026-08-03 detail-trash bug: pop first, write later, failure invisible).
        case failed(String)
    }

    private(set) var state: State = .loading

    /// Bound to the text view. Assignment is REFUSED unless the entry is editable, so a
    /// read-only surface cannot accumulate edits that would then have nowhere to go.
    var text: String {
        get {
            access(keyPath: \.text)
            return storedText
        }
        set {
            guard isEditable else { return }
            withMutation(keyPath: \.text) { storedText = newValue }
        }
    }

    @ObservationIgnored private var storedText = ""

    private(set) var hasUnsavedChanges = false

    /// `true` when `open()` found a `draft.json` whose text differs from `current` and
    /// adopted it (resume beats reload). Rendered as a plain line, never an alert.
    private(set) var resumedFromDraft = false

    /// The un-edited machine transcript, offered read-only beside a degraded chain (Q5).
    /// `nil` in every other state, including `.readOnlyTrashed`: a trashed entry is refused
    /// outright, with no text and no edit-with-a-warning path.
    private(set) var machineTranscript: String?

    /// Set once something else closed this session's draft (see the type doc). The view says
    /// so; the editor keeps every visible character and simply writes forward from here —
    /// the next `writeDraft` re-snapshots `parentID`/`basedOnMachineID` off the new
    /// `current`, so the recovered revision becomes this session's parent rather than being
    /// silently written over.
    private(set) var draftClosedBeneathSession = false

    let captureID: String

    /// §12.1's debounce window. Named, and `internal`, so the number has ONE home and is
    /// reachable by a test: every behavioural test injects its own window (they drive an
    /// injected timer), so the initializer's default was otherwise exercised by nothing at
    /// all and could have been changed to 20 s with the whole suite still green.
    static let defaultDebounceSeconds: TimeInterval = 2

    private let store: any TranscriptEditorStore
    private let debounce: any EditorDebounce
    let debounceSeconds: TimeInterval
    private let clock: @Sendable () -> Date

    /// `openedAt` of the `draft.json` this editing session believes it owns; `nil` before the
    /// first write. Identity, not equality of contents: `openedAt` is snapshotted once at
    /// draft-open time and never rewritten by a later `writeDraft` (design §6.4), so a
    /// different value — or no draft at all — means the file we were writing into is gone.
    @ObservationIgnored private var sessionDraftOpenedAt: Date?

    /// The text as of the last thing that was NOT a keystroke — a load, a resume. The view
    /// observes the text with `.onChange(of: model.text)`, and SwiftUI compares values across
    /// body evaluations, so `open()` filling the text and flipping `state` to `.editing`
    /// re-evaluates the body, sees the value change from `""`, and reports an edit nobody
    /// made. Without this, opening an entry merely to READ it armed the debounce and left a
    /// `draft.json` behind, and `hasUnsavedChanges` claimed work the owner never did.
    @ObservationIgnored private var lastKnownText = ""

    /// Whether THIS editing session has already been closed — see `finishIfNeeded()`.
    @ObservationIgnored private var hasFinished = false

    /// Which editing session the model is on. A plain "already finished" Bool was a lost
    /// update (Gate A Critical 2): `open()` cleared it BEFORE its own `await`, while
    /// `finishIfNeeded()` assigned it AFTER `await done()`, so a finish belonging to session
    /// one could latch the flag for session two — whose edit then never reached the store,
    /// while `finishIfNeeded()` cheerfully returned true. A token makes "does this result
    /// still belong to the session that asked for it?" answerable, which a Bool cannot be.
    @ObservationIgnored private var sessionID = 0

    /// The finish currently in flight, with the session that started it. Both exit paths (the
    /// Done button and the pop) can race on device; without this they pass the `hasFinished`
    /// check together and close twice, minting a second revision for one edit.
    @ObservationIgnored private var finishInFlight: (session: Int, task: Task<Bool, Never>)?

    init(captureID: String,
         store: any TranscriptEditorStore,
         debounce: any EditorDebounce = TaskEditorDebounce(),
         debounceSeconds: TimeInterval = TranscriptEditorModel.defaultDebounceSeconds,
         clock: @escaping @Sendable () -> Date = { Date() }) {
        self.captureID = captureID
        self.store = store
        self.debounce = debounce
        self.debounceSeconds = debounceSeconds
        self.clock = clock
    }

    /// Editable ⇔ the snapshot said `.editable`. `.failed` stays editable on purpose: a
    /// write that failed must leave the owner able to keep typing and try again.
    var isEditable: Bool {
        switch state {
        case .editing, .failed: return true
        case .loading, .readOnly: return false
        }
    }

    /// Whether the view shows a text box at all. Read-only states render as SENTENCES —
    /// which revision file is unreadable, that the entry is trashed, that there is nothing
    /// transcribed — never as a disabled text box.
    var showsTextEditor: Bool { isEditable }

    // MARK: - Open

    /// Reads the chain snapshot and decides what this screen is. The editable text comes
    /// from `draft.text` (resume) or `EntryChainSnapshot.currentText`, and NEVER from
    /// `EntryTranscript.text`: under `AttributionMode.skip` that field is a truncated
    /// snippet, and opening an editor over a truncated snippet would let a Done button
    /// replace a whole entry with its own preview.
    ///
    /// The draft is read through `chainSnapshot` (`TranscriptRevisionStore.readDraft`), NOT
    /// through `LibraryScreenModel.hasDraft` — the `nonisolated` existence check that
    /// entry-open uses. That check has a TOCTOU (a draft written between the check and the
    /// read is missed), which went live the moment this editor became the app's first real
    /// draft writer; routing open through the real read means a draft that appears after any
    /// such check is still resumed rather than silently discarded.
    func open() async {
        // A new session, from this line on. Everything below that says "this session" is
        // keyed to it, and any finish still in flight from the previous one is now a dead
        // session's business and may not latch this one.
        // Captured before anything is reset: unsaved words that never reached disk are this
        // model's only copy, and must survive a re-open. `hasUnsavedChanges` is false whenever
        // the text IS safely on disk (a flush clears it), so this fires only when it must —
        // never pinning stale text over an entry that has genuinely moved on.
        let unsavedTextToPreserve = hasUnsavedChanges && !storedText.isEmpty ? storedText : nil

        sessionID &+= 1
        let session = sessionID
        // A window armed against the PREVIOUS session's text must not survive into this one.
        // The ledger carried this as "unreachable today"; Gate A disproved that.
        debounce.cancel()
        finishInFlight = nil
        state = .loading
        // A re-open (navigating back into the editor on the same model) is a fresh session:
        // last time's notices must not outlive the thing they described.
        draftClosedBeneathSession = false
        hasFinished = false
        let snapshot = await store.chainSnapshot(for: captureID)
        // The one rule, applied once for BOTH branches below: nothing a session that has been
        // left behind read may be written into the live session's state. `chainSnapshot` is a
        // `Task.detached` read, so two overlapping opens resume in unspecified order — and
        // `.task { await model.open() }` re-runs on every push while cancellation does not stop
        // the detached read already in flight. This guard used to sit further down, covering
        // only the editable branch; the read-only branch above it wrote five live-session
        // fields unguarded and could leave the owner staring at an empty text box over an
        // entry that has a transcript.
        guard sessionID == session else { return }

        guard case .editable = snapshot.editability else {
            // Re-review Important: unsaved words survive a REFUSED re-entry too. The C1 alert
            // offers "Back to my edit" and promises the words are still here; landing in a
            // read-only state used to be exactly what erased them, and restoring the entry
            // first is impossible without leaving the detail screen, which drops the model.
            // So the refusal keeps the text — readable and copyable, never editable. It is the
            // SAVE that must refuse, not the display of the owner's own words.
            storedText = unsavedTextToPreserve ?? ""
            hasUnsavedChanges = unsavedTextToPreserve != nil
            resumedFromDraft = false
            lastKnownText = storedText
            sessionDraftOpenedAt = nil
            let offer = await machineTranscriptIfDegraded(snapshot.editability)
            guard sessionID == session else { return }
            machineTranscript = offer
            state = .readOnly(snapshot.editability)
            return
        }

        machineTranscript = nil
        if let unsaved = unsavedTextToPreserve {
            // Re-entering after a save that refused (Critical 1): the words never reached
            // disk, so this model's memory is the only copy there is. Reloading the entry over
            // them would quietly finish the job the failed save started — and re-entry is
            // exactly what the alert's "Back to my edit" does.
            storedText = unsaved
            sessionDraftOpenedAt = snapshot.openDraft?.openedAt
            resumedFromDraft = false
            hasUnsavedChanges = true
        } else if let draft = snapshot.openDraft {
            storedText = draft.text
            sessionDraftOpenedAt = draft.openedAt
            resumedFromDraft = draft.text != snapshot.currentText
            hasUnsavedChanges = storedText != snapshot.currentText
        } else {
            storedText = snapshot.currentText
            sessionDraftOpenedAt = nil
            resumedFromDraft = false
            hasUnsavedChanges = storedText != snapshot.currentText
        }
        lastKnownText = storedText
        state = .editing
    }

    /// Q5: a degraded chain refuses, then offers the `live.jsonl` transcript read-only,
    /// labeled as the un-edited machine transcript. Both degradation shapes qualify — one
    /// unreadable revision file (§4.8) and an unreadable `transcript/` listing (§4.5a) are
    /// the same "we cannot read the chain" answer with different granularity. The other
    /// read-only cases get nothing: a trashed entry is refused outright (Q4), an entry with
    /// nothing transcribed has nothing to offer, and an undecodable `entry.json` is a
    /// sidecar problem whose chain the detail screen already renders.
    private func machineTranscriptIfDegraded(_ editability: EntryChainSnapshot.Editability) async -> String? {
        switch editability {
        case .readOnlyUnreadableRevision, .readOnlyListingUnreadable:
            return await store.machineTranscript(for: captureID)
        case .editable, .readOnlyTrashed, .readOnlyNoTranscript, .readOnlyMetadataUnreadable:
            return nil
        }
    }

    // MARK: - Editing

    /// Re-arms the 2 s debounce. Never writes directly — that is the whole point.
    func textChanged() {
        guard isEditable else { return }
        // A load is not a keystroke — see `lastKnownText`. Note this is NOT the same test as
        // `hasUnsavedChanges`: a resumed draft is unsaved work AND not a fresh edit.
        guard storedText != lastKnownText else { return }
        lastKnownText = storedText
        hasUnsavedChanges = true
        armFlush()
    }

    /// Arms the debounce for THIS session. The session check inside the closure is not
    /// redundant with `open()`'s `cancel()`: a real `Task.sleep` can complete at the same
    /// instant cancellation arrives, so cancelling cannot be the guarantee on its own — the
    /// window that fires anyway has to decline by itself.
    private func armFlush() {
        let session = sessionID
        debounce.arm(after: debounceSeconds) { [weak self] in
            guard let self, self.sessionID == session else { return }
            _ = await self.flush()
        }
    }

    /// The debounce fired, the app left `.active`, or `done()` asked. Every flush is a
    /// `writeDraft` — never a `closeDraft`.
    ///
    /// A failure is LOUD: `.failed` with the reason, and nothing dismisses. No `_ = try?` on
    /// an editor save, ever.
    ///
    /// **Returns whether THIS invocation failed to write — not whether the editor is in a
    /// failed state** (review finding 1). Those are different questions, and conflating them
    /// made Done permanently unretryable: a draft that flushed fine and then failed to CLOSE
    /// leaves `hasUnsavedChanges == false` and `state == .failed`, so the next `done()` found
    /// nothing to flush, saw the stale `.failed`, and returned false without ever reaching
    /// `closeDraft` again — while the alert on screen said "Try Done again". Realistic close
    /// failures are transient (I/O; a §15b.15 degraded-chain refusal that a re-promote
    /// clears), so that dead-ended the screen's recovery affordance against exactly the
    /// failures it exists for.
    ///
    /// "Nothing to write" is a SUCCESS, and it also clears a stale `.failed` — otherwise the
    /// banner outlives the problem and the short-circuit comes straight back.
    @discardableResult
    func flush() async -> Bool {
        guard isEditable else { return true }
        // Captured at entry and re-checked after EVERY await below. The work itself still
        // completes when the owner has moved on — session one's draft deserves to be written
        // and closed — but not one byte of the LIVE session's state may be written by a
        // session that has been left behind. That was the re-review's Critical: `done()`
        // resuming out of `closeDraft` wrote `hasUnsavedChanges = false` into session two,
        // whose next flush then short-circuited and saved nothing while reporting success.
        let session = sessionID
        debounce.cancel()
        await noteDraftClosedBeneathSessionIfNeeded()
        // NOT an early return on a token mismatch (re-review Minor). Returning `true` here
        // without writing let `done()` go on to `closeDraft` and mint whatever stale
        // `draft.json` was on disk instead of the text that is actually current — the exact
        // opposite of the rule stated above, which the guards after the write already honour.
        // So the write still happens; only the STATE writes below are skipped.
        guard hasUnsavedChanges else {
            if sessionID == session, case .failed = state { state = .editing }
            return true
        }

        let pending = storedText
        do {
            try await store.writeDraft(captureID: captureID, text: pending, now: clock())
            guard sessionID == session else { return true }
            if storedText == pending { hasUnsavedChanges = false }
            if case .failed = state { state = .editing }
            if sessionDraftOpenedAt == nil {
                let openedAt = await store.openDraft(for: captureID)?.openedAt
                if sessionID == session { sessionDraftOpenedAt = openedAt }
            }
            return true
        } catch {
            guard sessionID == session else { return false }
            state = .failed(Self.saveFailureMessage(error))
            // Gate A Minor 4: `flush()` cancels the window on entry, so without this a failed
            // save sat with unsaved changes and retried NOTHING until the owner happened to
            // type another character. Re-arming makes a transient failure self-healing — the
            // entry gets restored from the trash, the next window succeeds, and the banner
            // clears itself. It stops as soon as a write succeeds or the editor closes
            // (`done()` cancels), and it is armed for THIS session only.
            armFlush()
            return false
        }
    }

    /// Ending an edit — the Done button, and navigating away, which are the same path.
    /// Returns `false` when anything refused to save, and the caller must NOT dismiss.
    ///
    /// `closeDraft` runs even when nothing changed: a resumed draft whose text equals
    /// `current` still has a `draft.json` on disk, and §2.5's close is what deletes it
    /// (minting nothing). The editor does not work around that — it relies on it.
    @discardableResult
    func done() async -> Bool {
        let session = sessionID
        debounce.cancel()
        guard isEditable else { return true }

        // Gated on THIS flush's own result, never on `state` — see `flush()`. A flush that
        // genuinely failed still blocks the close: "retryable" must never become "closes
        // over a draft that never saved".
        guard await flush() else {
            guard sessionID == session else { return false }
            unreportedSaveFailure = saveFailureReason ?? "The edit couldn’t be saved."
            // Bound the M4 retry (re-review Minor): `flush()`'s failure branch re-armed the
            // window, and `done()` used to return without cancelling it again — so a Done
            // against a PERMANENT refusal left an invisible 2 s loop running for the life of
            // the detail screen, each turn an `openDraft` plus a whole-chain-decode
            // `writeDraft` (#50's cost), with the editor already gone. M4 itself is
            // untouched: a failure while the editor is still open re-arms and retries, which
            // is visible, bounded by the screen, and has its own test.
            debounce.cancel()
            return false
        }

        do {
            _ = try await store.closeDraft(captureID: captureID, reason: .sessionEnd, now: clock())
            guard sessionID == session else { return true }
            hasUnsavedChanges = false
            sessionDraftOpenedAt = nil
            return true
        } catch {
            guard sessionID == session else { return false }
            let message = Self.saveFailureMessage(error)
            state = .failed(message)
            unreportedSaveFailure = message
            return false
        }
    }

    /// "Navigating away IS Done" (ruling Q1), made literal — the pop path, taken by system
    /// Back and interactive swipe-back, which the Done button alone never covered.
    ///
    /// Idempotent so the Done button and the `onDisappear` that follows its `dismiss()` do not
    /// double-close. The guard is per SESSION, not per model: `EntryDetailView` holds ONE
    /// editor model in `@State` for the life of the screen, so `open()` clears it and every
    /// later visit can save. A FAILED finish deliberately does not latch — the owner has left,
    /// but the next attempt must still be able to try.
    @discardableResult
    func finishIfNeeded() async -> Bool {
        let session = sessionID
        // Both exit paths can be in flight at once; the second joins the first rather than
        // closing a second time (which would mint two revisions for one edit).
        if let inFlight = finishInFlight, inFlight.session == session {
            return await inFlight.task.value
        }
        guard !hasFinished else { return true }

        let task = Task { @MainActor in await self.done() }
        finishInFlight = (session: session, task: task)
        let closed = await task.value

        // Only a finish that STILL belongs to the current session may latch it. A finish from
        // a session the owner has already left behind must not mark the new one saved — that
        // was Critical 2, and it silently discarded the second session's words entirely.
        guard sessionID == session else { return closed }
        finishInFlight = nil
        hasFinished = closed
        return closed
    }

    /// A save that refused on the way OUT, which nobody has been told about yet (Gate A
    /// Critical 1). The editor's own `.failed` banner cannot serve here: by the time an exit
    /// fails the screen has already popped, so the refusal was completely silent and the only
    /// copy of the words went with the model — locked rule 6, the 2026-08-03 detail-trash bug
    /// in a new place.
    ///
    /// Recorded on the model rather than returned, deliberately: BOTH exit paths can be the
    /// one that discovers the failure (`onDisappear` and the detail screen's dismissal
    /// handler race), and only the surviving screen can show an alert. `EntryDetailView`
    /// reads this, tells the owner, and acknowledges it.
    private(set) var unreportedSaveFailure: String?

    func acknowledgeSaveFailure() { unreportedSaveFailure = nil }

    /// The reason behind a `.failed` state, if that is the state.
    var saveFailureReason: String? {
        if case .failed(let reason) = state { return reason }
        return nil
    }

    // MARK: - Draft closed beneath us

    /// `EntryDetailView.refresh()` also runs after a backdate save, a backdate clear, and a
    /// journal move — each one calling `closeStaleDraftIfNeeded`, which closes any draft
    /// idle for more than `DraftPolicy.sessionEndSeconds` with reason `.recovered`. So an
    /// open editor's draft really can be minted into a revision and deleted while the editor
    /// is still on screen.
    ///
    /// The response is deliberately NOT "reload": the owner's visible, unsaved text is the
    /// one thing that must survive. This records that it happened (the view says so) and
    /// forgets the draft identity, so the next `writeDraft` opens a FRESH draft and
    /// re-snapshots `parentID`/`basedOnMachineID` off the now-current revision — which is
    /// the recovered one. The recovered revision becomes this session's parent instead of
    /// being written over as though it never existed.
    private func noteDraftClosedBeneathSessionIfNeeded() async {
        guard let owned = sessionDraftOpenedAt else { return }
        let session = sessionID
        let onDisk = await store.openDraft(for: captureID)
        guard sessionID == session else { return }
        guard onDisk?.openedAt != owned else { return }
        draftClosedBeneathSession = true
        sessionDraftOpenedAt = nil
    }

    // MARK: - Copy

    /// A sentence, not a raw `String(describing:)` dump — this text is rendered to the owner,
    /// in the editor's banner and in the detail screen's alert. (Ledgered as deferred; done
    /// here because the Important above rewrote that alert's copy anyway and the mapping is
    /// four lines.) An unrecognised error still says something true rather than nothing.
    private static func saveFailureMessage(_ error: any Error) -> String {
        guard let storeError = error as? TranscriptRevisionStoreError else {
            return "The save didn’t complete."
        }
        switch storeError {
        case .trashedCapture:
            return "This entry is in the trash, so edits can’t be saved to it. Restore it first."
        case .captureMissing:
            return "This entry’s files are no longer on this device."
        case .revisionUnreadable(let file):
            return "Revision file \(file) could not be read, so saving now could lose what it holds."
        case .transcriptDirUnreadable:
            return "This entry’s revision folder could not be read, so saving now could lose "
                + "what it holds."
        case .allocationCollision:
            return "Another save is still finishing. Try again."
        case .revisionNotFound:
            // Never actually thrown by writeDraft/closeDraft (T7 Task 8's `revert` is
            // the only caller that can produce this) — kept exhaustive rather than a
            // silent `default:` so a future store method that COULD throw it here
            // doesn't inherit a wrong message by accident.
            return "That revision could not be found in this entry’s history."
        }
    }

    /// The read-only sentence for each refusal. One place, so the editor and any later
    /// surface (Task 8's history panel) cannot drift on what a state means.
    static func readOnlySentence(_ editability: EntryChainSnapshot.Editability) -> String {
        switch editability {
        case .editable:
            return ""
        case .readOnlyUnreadableRevision(let file):
            return "This entry can’t be edited: revision file \(file) could not be read. "
                + "Editing it now would silently drop whatever that revision holds."
        case .readOnlyListingUnreadable(let reason):
            return "This entry can’t be edited: its revision folder could not be read "
                + "(\(reason)). Editing it now would silently drop whatever the folder holds."
        case .readOnlyTrashed:
            return "This entry is in the trash. Restore it first, then edit it."
        case .readOnlyNoTranscript:
            return "There’s nothing transcribed in this entry to edit yet."
        case .readOnlyMetadataUnreadable(let reason):
            return "This entry’s details file could not be read (\(reason)), so it can’t be "
                + "edited. The recording and transcript are untouched."
        }
    }
}
