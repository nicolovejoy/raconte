import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Composition + orchestration for the capture screen. Owns the (per-capture, ephemeral)
/// `CaptureCoordinator`, the launch-recovery banner list, the background finalizer, and
/// the recent-recordings list. Kept out of the pure-tested layer on purpose: the testable
/// mapping lives in `RecordControlModel` / `RecFormat`; this type is the imperative glue.
///
/// Why a fresh coordinator per capture: the machine has no `captured → idle` edge (a
/// coordinator instance is single-capture by design), so once a recording commits we spawn
/// a new idle coordinator for the next one, preserving the launch banners in view state.
@MainActor
@Observable
final class CaptureScreenModel {
    private(set) var coordinator: CaptureCoordinator
    private(set) var recovered: [RecoveredRecording] = []
    private var dismissed: Set<String> = []
    private var didBootstrap = false
    private var finishing = false
    /// Tail of the sidecar-write chain — see `enqueueEntryMetadataWrite`.
    private var pendingMetadataWrite: Task<Void, Never>?

    /// The just-finished capture's receipt, or nil when there is nothing to acknowledge.
    ///
    /// Screen state, not machine state, and it has to be: `finishCurrentCapture` replaces
    /// the coordinator with a fresh idle one, so by the time a capture is safely on disk
    /// the phase says `.idle` and is indistinguishable from having just opened the app.
    /// That gap is why the finished transcript used to end up loose on the landing screen
    /// with nothing owning it.
    ///
    /// Set once a capture is fully committed (after the finalizer, the transcript ref, and
    /// the rescan), and cleared only by an explicit dismissal — never on a timer. The owner
    /// is usually looking down at a paper journal when a recording ends, so anything that
    /// vanishes on its own vanishes unseen.
    private(set) var receipt: CaptureReceipt?

    /// Dismiss the receipt and return to the landing screen. The "Record another" action,
    /// and also what "Open" does on its way to the entry — coming back from the detail
    /// screen to a receipt for an entry you have just been reading would be a loop.
    func dismissReceipt() { receipt = nil }

    /// #62: retire the receipt if its entry has left the library (trashed from the
    /// detail screen or the library while the receipt sat here). The receipt's own
    /// "stays until dismissed, never on a timer" ruling stands — this is not a timer,
    /// it is the entry itself vanishing, and a receipt naming a trashed entry reads as
    /// a lost recording.
    ///
    /// A state CLEAR, deliberately not a computed hide over `allEntries`: restoring the
    /// entry from the trash must not resurrect the receipt (the acknowledgement moment
    /// has passed), and a computed gate would bring it back on the restore rescan.
    func reconcileReceipt() {
        guard let receipt,
              !library.allEntries.contains(where: { $0.captureID == receipt.captureID })
        else { return }
        self.receipt = nil
    }

    let capturesRoot: URL
    /// The recent-recordings section (M3 T4.5) and the Library screen read through the
    /// SAME instance — one scanner, one `JournalStore`/`EntryMetadataStore` pair, per
    /// the "don't build a second data path" rule this task exists to fix. Defaults to a
    /// model over the same `capturesRoot`/`journalsContainerRoot` when the caller (a
    /// test, the UI-test harness) does not share one in.
    let library: LibraryScreenModel
    private let spawn: @MainActor () -> CaptureCoordinator
    private let finalizer: FinalizerWorker

    /// Live transcription, or nil when the build has none wired (the UI-test harness).
    let transcription: LiveTranscriptionCoordinator?

    // MARK: Journal context (M3 T3)
    //
    // ONE `JournalStore` and ONE `EntryMetadataStore` instance for the whole **app** —
    // T1 flagged that two actors over the same file don't serialize with each other, so
    // every read/write of the registry or a sidecar goes through these. Since T5 they
    // are `library`'s instances rather than a second pair over the same paths.
    private let journalStore: JournalStore
    private let entryMetadataStore: EntryMetadataStore
    private let currentJournal: CurrentJournal
    /// The library's instance (T6c), not a second one over the same `capturesRoot` —
    /// same reasoning as `entryMetadataStore` above.
    private let revisionStore: TranscriptRevisionStore

    /// The registry, refreshed at bootstrap and on every create/rename. Not reloaded on
    /// every keystroke — the menu is the only reader, and it opens infrequently.
    private(set) var journals: [Journal] = []
    private(set) var selectedJournalID: String?

    /// `journals.json` exists and did not decode.
    ///
    /// Distinct from "no journals", which is a fresh install — `JournalStore.load` draws
    /// that line and throws for everything else, and collapsing the two here would be
    /// §11's absent-vs-unreadable mistake one level above the store that got it right.
    /// Concretely: the header would show the "Journal" literal as if a journal were
    /// selected, and every new `entry.json` would be written with `journalID = nil`,
    /// silently unfiling a whole session's captures.
    private(set) var registryUnreadable = false

    /// Never empty in the UI: `resolveCurrentJournal()` guarantees a selection exists
    /// before `bootstrap()` returns, per the M3 decision that "no journal selected"
    /// never arises — *unless* the registry is unreadable, which is the one case where
    /// there is honestly nothing to name.
    var selectedJournalName: String {
        if let name = journals.first(where: { $0.id == selectedJournalID })?.name { return name }
        return registryUnreadable ? "Journals unavailable" : "Journal"
    }

    /// The selected journal's voice labels, or `[:]` when nothing is selected or the
    /// journal has none configured (owner ruling 2026-08-12: the capture-time voice
    /// switch must speak the journal's labels, not hardcoded "LN"/"BN"). Reads straight
    /// off `journals`, so a journal switch or a `setCurrentJournalVoiceLabels` save is
    /// visible here with no separate cache to go stale.
    var selectedJournalVoiceLabels: [String: String] {
        journals.first(where: { $0.id == selectedJournalID })?.voiceLabels ?? [:]
    }

    /// Optional backdate (§ "entry date — set only if backdating"). `false`/`Date()`
    /// until the user opts in; `originalDate` in the sidecar stays nil while disabled —
    /// the default is never materialized (`EntryMetadata`'s doc comment).
    private(set) var backdateEnabled = false
    private(set) var backdateDate = Date()
    private(set) var backdatePrecision: DatePrecision = .day

    /// The last backdate the owner set, per journal (M3 issue #15, second half): reading
    /// a paper journal aloud is a sitting of many captures all dated near each other, and
    /// re-dialling 1987 for each one is the friction.
    ///
    /// Keyed by journal because that is the unit a sitting belongs to, and in-memory
    /// because a carried date is a convenience for the session in front of you, not a
    /// preference — a relaunch a week later should not pre-fill 1987. Upgrading it to
    /// survive relaunch is a one-line swap for a `JournalPreferenceStore`-style store,
    /// which is why the read and write are funnelled through two private helpers.
    private var carriedBackdates: [String: PartialDate] = [:]

    /// The owner's explicit in-session multi-voice choices, keyed by journal id (T6 §14).
    ///
    /// Consulted *before* the disk value, and the reason this map exists at all: a journal
    /// with no entries yet has nothing on disk to read, so toggling it on, switching away
    /// and switching back would silently drop the choice on a disk-only read.
    private var multiVoiceOverrides: [String: Bool] = [:]

    /// Launch-recovered captures the user hasn't dismissed (via Keep/Delete) yet.
    var visibleRecovered: [RecoveredRecording] {
        recovered.filter { !dismissed.contains($0.captureID) }
    }

    init(capturesRoot: URL,
         makeSession: @escaping () -> AudioSessionController,
         makeRecorder: @escaping () -> EngineRecording,
         encoder: AudioEncoder,
         startCue: (@MainActor () async -> Void)? = nil,
         makeSecondarySink: SecondarySinkFactory? = nil,
         transcription: LiveTranscriptionCoordinator? = nil,
         journalsContainerRoot: URL? = nil,
         journalPreferenceStore: any JournalPreferenceStore = UserDefaultsJournalPreferenceStore(),
         library: LibraryScreenModel? = nil) {
        self.capturesRoot = capturesRoot
        self.transcription = transcription
        self.finalizer = FinalizerWorker(capturesRoot: capturesRoot, encoder: encoder)
        let containerRoot = journalsContainerRoot ?? AppContainer.containerRoot(capturesRoot: capturesRoot)
        let resolvedLibrary = library ?? LibraryScreenModel(
            capturesRoot: capturesRoot, journalsContainerRoot: containerRoot)
        assert(resolvedLibrary.capturesRoot.standardizedFileURL == capturesRoot.standardizedFileURL,
               "the shared library must be over this model's captures root")
        self.library = resolvedLibrary
        // The library's instances, NOT new ones over the same files (M3 T5). Two actors
        // over one file serialize with nobody: `update` is a read-modify-write, and the
        // capture screen writing a journal while the detail screen writes a backdate was
        // a lost update with no failure mode that would ever show up in a test.
        self.journalStore = resolvedLibrary.journalStore
        self.entryMetadataStore = resolvedLibrary.entryMetadataStore
        self.revisionStore = resolvedLibrary.revisionStore
        self.currentJournal = CurrentJournal(store: journalPreferenceStore)
        let spawn: @MainActor () -> CaptureCoordinator = {
            CaptureCoordinator(
                capturesRoot: capturesRoot,
                session: makeSession(),
                makeRecorder: makeRecorder,
                makeStore: { id, fmt in
                    SegmentStore(capturesRoot: capturesRoot, captureID: id, format: fmt)
                },
                startCue: startCue,
                makeSecondarySink: makeSecondarySink)
        }
        self.spawn = spawn
        self.coordinator = spawn()
    }

    /// Live composition root: platform session controller, real engine recorder, and the
    /// AVAssetWriter encoder, over Application Support.
    static func live(library: LibraryScreenModel = LibraryScreenModel.live()) -> CaptureScreenModel {
        #if DEBUG
        if let harness = uiTestHarness(library: library) { return harness }
        #endif
        return CaptureScreenModel(
            capturesRoot: Self.defaultCapturesRoot(),
            makeSession: {
                #if os(iOS)
                IOSAudioSessionController()
                #else
                MacAudioSessionController()
                #endif
            },
            makeRecorder: { AudioEngineRecorder() },
            encoder: AVAssetWriterAudioEncoder(),
            startCue: { await StartCue().play() },
            library: library)
    }

    /// Composition root with live transcription attached.
    ///
    /// The transcription coordinator is built *before* the model because the model's init
    /// constructs the capture coordinator, which needs the sink factory — so the factory
    /// closure captures the transcription coordinator, never the model.
    ///
    /// `library` is the SAME `LibraryScreenModel` instance `ContentView` pushes the
    /// Library screen with — the recent-recordings section and the library list must
    /// read through one scanner, not two (M3 T4.5). Ignored under the UI-test harness,
    /// which builds its own matching-root library the same way `LibraryScreenModel.live()`
    /// does for the caller's copy.
    static func liveWithTranscription(library: LibraryScreenModel) -> CaptureScreenModel {
        #if DEBUG
        if let harness = uiTestHarness(library: library) { return harness }
        #endif
        let root = Self.defaultCapturesRoot()
        let transcription = LiveTranscriptionCoordinator(
            capturesRoot: root,
            makeEngine: { SpeechAnalyzerEngine() })
        return CaptureScreenModel(
            capturesRoot: root,
            makeSession: {
                #if os(iOS)
                IOSAudioSessionController()
                #else
                MacAudioSessionController()
                #endif
            },
            makeRecorder: { AudioEngineRecorder() },
            encoder: AVAssetWriterAudioEncoder(),
            startCue: { await StartCue().play() },
            makeSecondarySink: { [weak transcription] id in transcription?.begin(captureID: id) },
            transcription: transcription,
            library: library)
    }

    /// Same path as before (`Application Support/Raconte/captures`), now owned by
    /// `AppContainer` so the journals registry and the capture tree cannot drift apart.
    static func defaultCapturesRoot() -> URL {
        AppContainer.capturesRoot()
    }

    // MARK: intents

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        await resolveCurrentJournal()
        await coordinator.recoverAtLaunch()
        recovered = coordinator.recoveredRecordings
        let recoveredQueue = coordinator.finalizeQueue
        await runFinalizer(recoveredQueue)
        // Same hook, launch-recovery side: a capture killed before its transcript could
        // be read has never had detection run over it, and this is the one other place a
        // transcript first becomes available.
        for id in recoveredQueue { await detectSpokenDate(for: id) }
        await library.rescan()
        // Fire-and-forget corpus promotion (T6c) + head-cache stamping (T7 Task 3 fix
        // round 2) + stale-draft recovery (T7 prereq #41), ONE Task, sequential: the
        // library is already on screen and showing today's `live.jsonl` text via the
        // loader's fallback, so nothing here blocks bootstrap while a possibly-large
        // corpus walk runs. Placed before the trash sweep (`sweepTrash()` below).
        //
        // Deliberately one Task, not several independent ones (fix round 1, Minor 4):
        // separate unstructured Tasks give no guarantee that a LATER pass's per-capture
        // work doesn't interleave ahead of an EARLIER pass's for the SAME capture — and
        // the ordering here is load-bearing twice over:
        //   1. (Important 1, review fix round 1) closing a capture's stale draft before
        //      it is promoted mints a `.userEdit` that permanently blocks the
        //      `.machineLive` baseline from ever entering that capture's chain, since
        //      `promoteIfNeeded` skips unconditionally once any canonical file exists —
        //      promotion must run before `closeStaleDraftsOnce()`.
        //   2. (fix round 2) stamping runs after promotion for the same reason: a
        //      capture with no canonical files yet — either no `transcript/` at all, or
        //      a `transcript/` promotion hasn't populated (`live.jsonl`-only, or empty —
        //      `stampHeadIfNeeded` explicitly refuses `.present([])`, not just `.absent`,
        //      as of fix round 3) — has nothing for `stampUnstampedHeads` to stamp, so
        //      running it before promotion would just mean walking those captures twice:
        //      once finding no chain, again after promotion lands one later this same
        //      launch. It runs before `closeStaleDraftsOnce()` too — stamping is a pure
        //      read-then-maybe-write over the EXISTING chain and has no dependency on
        //      drafts either way, so this position costs nothing and keeps the "promote,
        //      then everything else" shape simple to reason about.
        // A single Task with sequential awaits removes the race instead of merely
        // hoping several Tasks happen to run in source order.
        Task {
            await library.promoteCorpusOnce()
            await library.stampUnstampedHeadsOnce()
            await library.closeStaleDraftsOnce()
        }
        // Last, deliberately: the library is already on screen, and the trash sweep
        // runs off the main actor. Also strictly after the finalizer has drained, so it
        // can never remove a directory an encode is still writing into.
        await library.sweepTrash()
    }

    /// Starting a new reading retires the previous one's receipt.
    ///
    /// `CaptureLayoutModel` already refuses to draw a receipt in a capturing phase, so
    /// this is not what keeps the screen correct — it is what keeps the STATE honest, so
    /// a receipt for the previous entry can never reappear when this capture ends and the
    /// build of the new one fails.
    func record() async {
        receipt = nil
        await coordinator.record()
    }
    func done() async { await coordinator.done() }
    func resume() async { await coordinator.resume() }

    /// Called when the coordinator's finalize queue changes. Keyed off the queue, NOT
    /// the phase: `phase` flips to `.captured` before that transition's effects run
    /// (the debug-harness gate sits between), so a phase-triggered drain reads an
    /// empty queue, no-ops, and the capture never finalizes until the next launch's
    /// recovery scan. `enqueueFinalize` runs after `store.finish` — the durability
    /// commit — so this signal means the capture is fully on disk.
    /// The phase guard skips launch-recovery fills (`bootstrap` drains those itself).
    func handleFinalizeQueue() {
        guard !coordinator.finalizeQueue.isEmpty,
              coordinator.phase == .captured || coordinator.phase == .complete else { return }
        Task { await finishCurrentCapture() }
    }

    /// Stand the transcription session up once the format is readable, and write the
    /// entry's journal/backdate sidecar now that the capture directory exists (M3 T3 —
    /// `SegmentStore.begin()`, called just before this phase publishes, creates it).
    ///
    /// Keyed off `.recording` rather than the factory call: the factory runs inside
    /// `configureAndStart`, before `recorder.start` returns, so `activeFormat` is still
    /// nil there. Idempotent — SwiftUI may deliver the same phase more than once (also
    /// true on resume from an interruption, which re-enters `.recording`; rewriting the
    /// same journal/backdate values is harmless).
    func handlePhase() {
        guard coordinator.phase == .recording, let id = coordinator.activeCaptureID else { return }
        if let transcription, let format = coordinator.activeFormat {
            transcription.activate(captureID: id, inputFormat: format)
        }
        // Snapshot the computed value once, here: the sidecar write runs later on a
        // serialized Task chain, and a rescan landing mid-capture could shift what
        // `multiVoiceEnabled` derives underneath it.
        let multiVoice = multiVoiceEnabled
        enqueueEntryMetadataWrite(for: id, multiVoice: multiVoice)
        // Once per capture, enforced by the coordinator's own latch — this method
        // re-enters `.recording` on an interruption resume, and a duplicate frame-0
        // opener would reset `currentVoice` to "bn" and mis-attribute the rest.
        if multiVoice { coordinator.markOpeningVoice() }
    }

    func keep(_ id: String) { dismissed.insert(id) }

    /// The recovery banner's Delete. Trash semantics since M3 T5, not a hard delete:
    /// a capture the owner rejects at launch is a delete like any other, and "delete
    /// anywhere, recoverable 30 days" has no exception for the one delete that happens
    /// before he has heard the recording.
    ///
    /// This never touched the recovery executor — it removed the directory directly —
    /// so nothing about the recovery machine changes here. The capture is left fully
    /// intact and still finalizes normally; it is simply filed in the trash, and the
    /// sweep removes it in thirty days on the same terms as everything else.
    func delete(_ id: String) {
        dismissed.insert(id)
        Task { await library.trashEntry(id) }
    }

    // MARK: Journal + backdate intents (M3 T3)

    /// Switch the journal captures file into. If a capture is live, its sidecar is
    /// updated immediately — the file that's on disk when the app is killed must never
    /// disagree with what the header showed.
    ///
    /// Synchronous: it only touches main-actor state and *enqueues* the sidecar write.
    /// Every intent that can change what the sidecar should say is synchronous for that
    /// reason — the enqueue order then is the order the user made the changes in.
    func selectJournal(_ id: String) {
        guard journals.contains(where: { $0.id == id }) else { return }
        selectedJournalID = id
        currentJournal.select(id)
        resolveBackdateForJournalChange()
        syncActiveEntryMetadata()
    }

    @discardableResult
    func createJournal(name: String) async -> Journal? {
        guard let created = try? await journalStore.create(name: name) else { return nil }
        journals.append(created)
        selectedJournalID = created.id
        currentJournal.select(created.id)
        resolveBackdateForJournalChange()
        syncActiveEntryMetadata()
        return created
    }

    func renameCurrentJournal(to name: String) async {
        guard let id = selectedJournalID,
              let renamed = try? await journalStore.rename(id: id, to: name) else { return }
        if let index = journals.firstIndex(where: { $0.id == id }) { journals[index] = renamed }
    }

    /// Sets (or clears, via an empty dict) the current journal's voice labels
    /// (T7 Mark Voices, issue #56). Same load/patch shape as `renameCurrentJournal`:
    /// `journalStore` is the source of truth, and `journals[index]` is patched in place
    /// so the change is visible through `journals` with no rescan. `labels` is passed
    /// through to `JournalStore.setVoiceLabels`, which trims VALUES but not keys — the
    /// sheet only ever constructs the "bn"/"ln" keys as literals, so no untrimmed key can
    /// reach here today, but a future caller building keys dynamically would need to
    /// trim/normalize them itself before calling this.
    @discardableResult
    func setCurrentJournalVoiceLabels(_ labels: [String: String]) async -> Bool {
        guard let id = selectedJournalID,
              let updated = try? await journalStore.setVoiceLabels(id: id, labels: labels)
        else { return false }
        if let index = journals.firstIndex(where: { $0.id == id }) { journals[index] = updated }
        return true
    }

    /// Cover image for the currently selected journal, sourced from `library` —
    /// the same store/scan the Library screen reads (M3's one-data-path rule, applied
    /// to covers too).
    var selectedJournalCover: Data? {
        selectedJournalID.flatMap { library.journalCovers[$0] }
    }

    func setCurrentJournalCover(imageData: Data) async throws {
        guard let id = selectedJournalID else { return }
        try await library.setJournalCover(id, imageData: imageData)
    }

    func removeCurrentJournalCover() async {
        guard let id = selectedJournalID else { return }
        await library.removeJournalCover(id)
    }

    /// Toggling off clears the date too — `originalDate` in the sidecar goes back to
    /// nil ("use the capture's own date"), not to whatever was last picked. Precision
    /// resets to `.day` alongside it, for the same reason: nothing should carry over
    /// silently into the next time the owner turns backdating back on.
    /// Turning it *on* pre-fills from the last backdate set in this journal this session,
    /// if there is one — date and precision together, since carrying a 1987 day-precision
    /// picker over a year-precision sitting would re-invent the fabricated-day problem.
    /// The toggle itself is never flipped on automatically: pre-filling a field the owner
    /// opened is help, opening it for him is a decision he did not make.
    func setBackdateEnabled(_ enabled: Bool) {
        let wasEnabled = backdateEnabled
        backdateEnabled = enabled
        if enabled {
            if !wasEnabled, let carried = carriedBackdate() {
                backdateDate = carried.anchorDate(calendar: .gregorianCurrent)
                backdatePrecision = carried.precision
            }
            rememberBackdate()
        } else {
            backdateDate = Date()
            backdatePrecision = .day
        }
        // The explicit toggle-off must still clear the sidecar's date — unlike a
        // phase re-entry sync (see `enqueueEntryMetadataWrite`), this IS the user
        // asking for the backdate to go away.
        syncActiveEntryMetadata(clearingBackdateIfDisabled: true)
    }

    func setBackdateDate(_ date: Date) {
        backdateDate = date
        rememberBackdate()
        syncActiveEntryMetadata()
    }

    func setBackdatePrecision(_ precision: DatePrecision) {
        backdatePrecision = precision
        rememberBackdate()
        syncActiveEntryMetadata()
    }

    /// Whether the next capture is a two-voice reading (T6 §14, owner decisions 4 and 5).
    ///
    /// **Computed, never stored.** The explicit in-session choice for the selected journal
    /// wins; otherwise the journal's most recent entry on disk. Deriving it on read rather
    /// than refreshing a stored flag is what makes carry-over survive a relaunch with no
    /// choreography: `library.allEntries` is `@Observable`, so the toggle re-renders when
    /// the launch rescan lands, and every future call site — journal switch, the rescan
    /// after a capture completes, T7 edits — is correct without remembering to call
    /// anything. (Contrast `resolveBackdateForJournalChange()`, which exists precisely
    /// because backdate state *is* stored.)
    ///
    /// Unlike the backdate toggle, this one **auto-enables** — the deliberate divergence
    /// recorded in the design (§2): a wrong voice attribute is visible and editable in T7,
    /// where a wrong backdate is a quiet data error.
    var multiVoiceEnabled: Bool {
        guard let journalID = selectedJournalID else { return false }
        return multiVoiceOverrides[journalID] ?? library.lastMultiVoice(forJournal: journalID)
    }

    /// The owner's explicit choice, for this journal, for the rest of the session. It is
    /// never written back to disk from here — the *capture* records what it actually was
    /// (`handlePhase`), and that entry becomes the next capture's carry-over.
    func setMultiVoiceEnabled(_ enabled: Bool) {
        guard let journalID = selectedJournalID else { return }
        multiVoiceOverrides[journalID] = enabled
    }

    /// The carried backdate for the currently selected journal, if any. Exposed for the
    /// tests that pin the carry-over rule; the view reads it only through the pre-fill.
    func carriedBackdate() -> PartialDate? {
        selectedJournalID.flatMap { carriedBackdates[$0] }
    }

    /// Re-anchors the live backdate picker to the JUST-selected journal, when the toggle
    /// is on. Carry-over is per journal (M3 issue #15, owner decision) — leaving
    /// `backdateDate`/`backdatePrecision` untouched across a journal switch would carry
    /// journal A's dialled date into journal B's next capture, which is not what "on"
    /// means for B. The toggle itself is left alone: switching journals is not the
    /// owner turning backdating off.
    ///
    /// Must run AFTER `selectedJournalID` is updated to the new journal (so
    /// `carriedBackdate()` reads B's entry, not A's) and does not call `rememberBackdate()`
    /// — writing the resolved value back would either re-stamp B's own carry with itself
    /// or, worse, invent a carry for B out of a same-session default.
    private func resolveBackdateForJournalChange() {
        guard backdateEnabled else { return }
        if let carried = carriedBackdate() {
            backdateDate = carried.anchorDate(calendar: .gregorianCurrent)
            backdatePrecision = carried.precision
        } else {
            backdateDate = Date()
            backdatePrecision = .day
        }
    }

    /// Records whatever backdate is currently in force. Only while the toggle is on: a
    /// disabled backdate is "use the capture's own date", which is nothing to carry.
    private func rememberBackdate() {
        guard backdateEnabled, let journalID = selectedJournalID else { return }
        carriedBackdates[journalID] = PartialDate(from: backdateDate,
                                                  precision: backdatePrecision,
                                                  calendar: .gregorianCurrent)
    }

    // MARK: internals

    private func finishCurrentCapture() async {
        guard !finishing else { return }
        finishing = true
        // The queue, NOT `activeCaptureID`: teardown runs `resetCaptureWiring()` before
        // this point and nils the id out, so reading it here silently skipped the ref
        // write on every capture. The queue holds exactly the ids that just committed.
        let transcribed = coordinator.finalizeQueue
        await runFinalizer(coordinator.finalizeQueue)
        // Strictly AFTER the finalizer. Three things read-modify-write `manifest.json`
        // and none are serialized against each other: `SegmentStore` holds it in memory
        // for the whole capture and clobbers on its next write, and `FinalizerWorker`
        // reads and writes across the encode+verify awaits, so a ref written into that
        // window is silently reverted. Here the store is dead and the finalizer is done —
        // the only point today where neither is true.
        for id in transcribed { await recordTranscriptRef(for: id) }
        // Between the ref write and spoken-date detection: promotion reads
        // `manifest.transcript` for `coverageFrames`/`skippedRanges` provenance, so it
        // must run AFTER the ref lands, not before.
        for id in transcribed { await revisionStore.promoteIfNeeded(captureID: id) }
        for id in transcribed { await detectSpokenDate(for: id) }
        await library.rescan()
        // Strictly after the rescan: the receipt is built from the library's own view of
        // the entry, so it cannot be assembled until the scan has seen it. Also after
        // `detectSpokenDate`, or a receipt could name a date the sidecar is about to
        // change under it.
        await buildReceipt(for: transcribed)
        coordinator = spawn()
        finishing = false
    }

    /// Assemble the post-stop receipt for the capture that just committed.
    ///
    /// Best-effort in every direction, and deliberately so: this runs on the path that has
    /// just made a recording safe on disk, and nothing about acknowledging it may stand
    /// between the owner and that fact. An entry the scan cannot see, or a transcript that
    /// will not read, leaves the screen on its ordinary landing state — the recording is
    /// still saved and still in the library. It never throws and never blocks.
    ///
    /// The LAST id, not the first: `finalizeQueue` can hold more than one capture (launch
    /// recovery drains a backlog through here), and the receipt is about the reading the
    /// owner just finished, which is the most recent one.
    private func buildReceipt(for captureIDs: [String]) async {
        guard let captureID = captureIDs.last,
              let entry = library.allEntries.first(where: { $0.captureID == captureID })
        else { return }
        let transcript = await library.transcript(for: captureID)
        receipt = CaptureReceipt.make(entry: entry, transcript: transcript)
    }

    /// M3 issue #15. Run when a capture's transcript first exists — after finalize, and
    /// after launch recovery for one that never got here — rather than from the library
    /// scan: detection is a per-capture event, and hanging it off `rescan()` would mean
    /// re-reading every entry's `live.jsonl` a second time on every filter change.
    ///
    /// Everything about it degrades to silence. An absent, unreadable or empty transcript
    /// is not an error; neither is a sidecar we cannot write. A detected date is a
    /// convenience, and nothing here may stand between the owner and a finished recording.
    private func detectSpokenDate(for captureID: String) async {
        let transcript = await library.transcript(for: captureID)
        guard transcript.state == .present, let text = transcript.text, !text.isEmpty else { return }

        // After the pending sidecar chain, so a backdate the owner set during this very
        // capture is already on disk when the "no manual backdate" test is made.
        await pendingMetadataWrite?.value

        // Read first purely to avoid writing when there is nothing to write — `update`
        // always writes. The decision is then *remade* inside `update`, under the actor's
        // serialization, so a concurrent edit between the two is honoured rather than
        // clobbered by the copy read out here.
        guard var probe = try? await entryMetadataStore.read(captureID: captureID),
              SpokenDateDetection.apply(to: &probe, transcriptText: text) else { return }
        // T7 §7: labelled .detection (not the update(_:) default .userEdit) so the audit
        // log reflects what actually wrote this — the room's spoken date, not the owner's
        // hand.
        _ = try? await entryMetadataStore.update(captureID: captureID, cause: .detection) { metadata in
            SpokenDateDetection.apply(to: &metadata, transcriptText: text)
        }
    }

    private func recordTranscriptRef(for captureID: String) async {
        guard let transcription, let ref = await transcription.finish(captureID: captureID) else {
            return
        }
        let url = SegmentLayout.manifestURL(
            captureDirectory: SegmentLayout.captureDirectory(capturesRoot: capturesRoot,
                                                             captureID: captureID))
        guard let data = try? Data(contentsOf: url),
              var manifest = try? CaptureCoding.decoder().decode(Manifest.self, from: data)
        else { return }
        manifest.transcript = ref
        guard let encoded = try? CaptureCoding.encoder().encode(manifest) else { return }
        // Best-effort by design: a manifest we cannot update costs the re-derive hint,
        // not the recording or the transcript, both of which are already on disk.
        try? AtomicFile.replace(at: url, writing: encoded)
    }

    /// Decide which journal capture files into, per the M3 default-journal rule: a
    /// stored, still-valid selection wins; otherwise fall back to an existing journal;
    /// otherwise mint "Journal" and select it. Runs once, before `recoverAtLaunch()`,
    /// so the header never shows "no journal selected" even on the very first launch.
    private func resolveCurrentJournal() async {
        let registry: JournalRegistry
        do {
            registry = try await journalStore.load()
            registryUnreadable = false
        } catch {
            // A registry we merely failed to parse is not an empty one. Falling through
            // to `.needsDefault` here would mint a second "Journal" and write it over
            // the file — the registry equivalent of issue #8. Capture still works; it
            // files nothing until the next launch reads the registry successfully.
            registryUnreadable = true
            journals = []
            selectedJournalID = nil
            return
        }
        switch JournalSelection.resolve(registry: registry, storedID: currentJournal.storedID) {
        case .existing(let id):
            journals = registry.journals
            selectedJournalID = id
            currentJournal.select(id)
        case .needsDefault:
            if let created = try? await journalStore.create(name: "Journal") {
                journals = [created]
                selectedJournalID = created.id
                currentJournal.select(created.id)
            } else {
                // Best-effort: the registry stays empty and the header falls back to the
                // "Journal" literal in `selectedJournalName` until the next bootstrap.
                journals = registry.journals
            }
        }
    }

    /// Update the live capture's sidecar after a journal/backdate change made mid-
    /// recording. A no-op when idle — the next capture picks up the new selection via
    /// `handlePhase()` when it starts.
    private func syncActiveEntryMetadata(clearingBackdateIfDisabled: Bool = false) {
        guard let id = coordinator.activeCaptureID,
              coordinator.phase == .recording || coordinator.phase == .interrupted else { return }
        enqueueEntryMetadataWrite(for: id, clearingBackdateIfDisabled: clearingBackdateIfDisabled)
    }

    /// journalID = the currently selected journal; originalDate = the backdate only if
    /// the user turned it on — never materializing `capturedAt` here is what keeps an
    /// un-backdated entry distinguishable from one backdated to exactly its capture time.
    ///
    /// With **no** selection (only reachable through `registryUnreadable`) the journal is
    /// left alone rather than written as nil. `handlePhase` re-runs on every re-entry to
    /// `.recording`, including an interruption resume, so writing nil there would unfile
    /// an entry that a working earlier launch had filed.
    ///
    /// `clearingBackdateIfDisabled` draws the same distinction for originalDate/precision
    /// that `if let journalID` already draws for the journal: `handlePhase`'s phase
    /// re-entry sync (default `false`) must NOT write nil over a backdate the detail
    /// screen set while this capture sat interrupted — the model's `backdateEnabled` here
    /// reflects the live-capture UI, not the sidecar's actual state. Only an explicit user
    /// toggle-off (`setBackdateEnabled(false)`) passes `true` and clears it for real.
    ///
    /// `multiVoice` draws the same distinction a third time, as an explicit **nil-defaulted
    /// parameter**: nil means "leave `metadata.multiVoice` alone". It is a parameter rather
    /// than a live read of `multiVoiceEnabled` inside the closure because this function is
    /// shared with `syncActiveEntryMetadata()`, which runs on a mid-capture journal switch
    /// — a live read there would re-derive carry-over for the *new* journal and rewrite the
    /// running entry's mode out from under the markers already on disk. Only
    /// `handlePhase`'s `.recording` path passes a value; carry-over chooses the next
    /// capture's mode, never a running one's.
    ///
    /// Writes are chained so they land in submission order.
    ///
    /// `BackdateField`'s `DatePicker` used to fire a fresh `Task` per change, each of
    /// which snapshotted main-actor state and *then* awaited the store — so two spins of
    /// the wheel could reach the actor in either order and settle on the older date.
    /// Every caller now enqueues synchronously on the main actor and the writes run in
    /// the order those snapshots were taken: last write wins by construction, not by luck.
    @discardableResult
    private func enqueueEntryMetadataWrite(for captureID: String,
                                           clearingBackdateIfDisabled: Bool = false,
                                           multiVoice: Bool? = nil) -> Task<Void, Never> {
        let originalDate = backdateEnabled
            ? PartialDate(from: backdateDate, precision: backdatePrecision, calendar: .gregorianCurrent)
            : nil
        let writeBackdate = backdateEnabled || clearingBackdateIfDisabled
        let journalID = selectedJournalID
        let store = entryMetadataStore
        let previous = pendingMetadataWrite
        let task = Task { @MainActor in
            await previous?.value
            _ = try? await store.update(captureID: captureID) { metadata in
                if let journalID { metadata.journalID = journalID }
                if writeBackdate {
                    metadata.setOriginalDate(originalDate)
                }
                if let multiVoice { metadata.multiVoice = multiVoice }
            }
        }
        pendingMetadataWrite = task
        return task
    }

    private func runFinalizer(_ ids: [String]) async {
        guard !ids.isEmpty else { return }
        await finalizer.enqueue(contentsOf: ids)
        _ = await finalizer.drain()
    }
}

/// The Milestone 1 capture screen: recovery banners, elapsed timer + status, mic meter,
/// the one big round record button, and a recent-recordings list. Dark-first, minimal
/// chrome (design language: quiet personal journal; polish is Milestone 5).
struct CaptureView: View {
    let model: CaptureScreenModel
    #if DEBUG
    @State private var showDebugMenu = false
    #endif

    private var control: RecordControlModel {
        RecordControlModel.make(phase: model.coordinator.phase,
                                canResume: model.coordinator.canResume)
    }

    private var markers: MarkerControlsModel {
        MarkerControlsModel.make(phase: model.coordinator.phase,
                                 multiVoice: model.multiVoiceEnabled)
    }

    private var layout: CaptureLayoutModel {
        CaptureLayoutModel.make(phase: model.coordinator.phase,
                                hasReceipt: model.receipt != nil)
    }

    /// Issue #53. Three bands, top to bottom: a scrolling setup region, the live
    /// transcript, and a control bar pinned to the bottom.
    ///
    /// The single page-level `ScrollView` this replaces is what caused #53: the record
    /// button, voice switch and paragraph button sat inside it, *below* the transcript,
    /// so every word transcribed pushed them further down — and on a long reading the
    /// voice switch left the viewport altogether. Nothing hid it; it had scrolled away.
    ///
    /// The controls are now outside every scroll view, so no amount of transcript can
    /// move them. That property is what `CaptureControlsUITests` measures; the visibility
    /// rules per phase are `CaptureLayoutModel`'s.
    var body: some View {
        ZStack {
            Color(white: 0.05).ignoresSafeArea()

            VStack(spacing: 0) {
                if let receipt = model.receipt, layout.showsReceipt {
                    // Just stopped. The receipt owns everything above the bar; the arming
                    // controls step aside until it is dismissed.
                    receiptRegion(receipt)
                } else {
                    setupRegion
                    transcriptRegion
                    // Absorbs whatever the bands above do not want, so the bar stays welded
                    // to the bottom edge. Without it the stack sizes to its content and the
                    // ZStack centres the lot — which moved the record button 59 pt the
                    // moment recording started and the setup band shrank to its
                    // capture-time height. Only ever non-zero when neither the setup band
                    // nor the transcript is stretching, i.e. mid-capture with nothing
                    // transcribed yet.
                    Spacer(minLength: 0)
                }
                errorBanner
                controlBar
            }
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .frame(maxHeight: .infinity)
        }
        .foregroundStyle(.white)
        .task { await model.bootstrap() }
        .onChange(of: model.coordinator.phase) { _, _ in
            model.handlePhase()
        }
        .onChange(of: model.coordinator.finalizeQueue) { _, _ in
            model.handleFinalizeQueue()
        }
        // #62: CaptureView is the permanently-mounted NavigationStack root, so this fires
        // even while the library or an entry detail is pushed on top — which is exactly
        // where the trash that invalidates a receipt happens. The rescan those paths run
        // changes `allEntries`, and the model decides whether the receipt's entry is gone.
        .onChange(of: model.library.allEntries) { _, _ in
            model.reconcileReceipt()
        }
        #if os(iOS)
        // Derived from phase via `CaptureState.keepsDisplayAwake` (pure, unit-tested), not
        // paired start/stop calls: whatever ends recording (stop, finalize, interruption,
        // route-loss-without-resume) flips this back through the same onChange, and
        // `initial: true` covers a screen that mounts already mid-recording (e.g. a
        // relaunch) or a freshly spawned coordinator swapped in after finalize. `onDisappear`
        // is the backstop against leaving it stuck true.
        .onChange(of: model.coordinator.phase, initial: true) { _, phase in
            UIApplication.shared.isIdleTimerDisabled = phase.keepsDisplayAwake
        }
        // `CaptureView` is the NavigationStack root: pushing Library/detail fires ITS
        // onDisappear (below), and popping back never re-runs the onChange above —
        // `initial: true` only fires once, at first mount, not on every reappearance.
        // Without this, navigating away mid-recording and back drops the hold for the
        // rest of the capture. onDisappear remains the backstop for every other exit.
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = model.coordinator.phase.keepsDisplayAwake
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        #endif
    }

    /// Journal, backdate, two-voices, recovery banners, recents, build stamp — everything
    /// that is setup or browsing rather than operating the recorder.
    ///
    /// Two different renderings by design (approach 2 of the 2026-08-16 IA discussion —
    /// owner: "there's two scrollable sections above [the bar]... I would rather have
    /// none, especially during the recording"). Idle is a browsing screen, so one honest
    /// scroll region is fine. While capturing, nothing left in this band is unbounded —
    /// journal name, backdate, build stamp — so nothing here scrolls at all;
    /// `CaptureLayoutModel.usesCompactBackdateField`/`showsRecoveryBanners` strip the band
    /// down to that bounded content instead of squeezing the full band into a fixed-height
    /// box that then had to scroll internally, which is what stacked a second scroll view
    /// above the transcript's own.
    @ViewBuilder
    private var setupRegion: some View {
        if layout.usesCompactBackdateField {
            VStack(alignment: .leading, spacing: 12) {
                JournalHeaderView(model: model)
                CompactBackdateSummary(model: model)
                // Not DEBUG-gated: a wireless install is exactly when you can't tell
                // which build you're holding, and TestFlight has the same problem.
                Text(BuildInfo.stamp)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.35))
                    .accessibilityIdentifier("capture.buildStamp")
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView {
                VStack(spacing: 28) {
                    // DEBUG-HARNESS-MOUNT — transition-pause menu (T11) for the kill-at-every-transition sweep.
                    #if DEBUG
                    HStack {
                        Spacer()
                        Button("Debug") { showDebugMenu = true }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .sheet(isPresented: $showDebugMenu) {
                        // Reset the capture screen's inherited .white foreground —
                        // it renders invisible on the system sheet background.
                        NavigationStack { DebugMenuView() }
                            .foregroundStyle(Color.primary)
                    }
                    #endif

                    JournalHeaderView(model: model)
                    BackdateField(model: model)

                    if layout.showsMultiVoiceField {
                        MultiVoiceField(model: model)
                    }

                    if layout.showsRecoveryBanners {
                        ForEach(model.visibleRecovered) { rec in
                            RecoveryBanner(recording: rec,
                                           capturesRoot: model.capturesRoot,
                                           onKeep: { model.keep(rec.captureID) },
                                           onDelete: { model.delete(rec.captureID) })
                        }
                    }

                    if layout.showsLastEntry {
                        lastEntrySection
                    }

                    if layout.showsLibraryDoor {
                        libraryDoor
                    }

                    // Not DEBUG-gated: a wireless install is exactly when you can't tell
                    // which build you're holding, and TestFlight has the same problem.
                    Text(BuildInfo.stamp)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.35))
                        .accessibilityIdentifier("capture.buildStamp")
                }
                .padding(24)
            }
        }
    }

    /// The live transcript: capped when idle, and free to take everything the setup band
    /// and the control bar leave behind during a capture.
    ///
    /// Its scroll view is now the ONLY one in this band — previously it was a same-axis
    /// scroll nested inside the page scroll, which is its own source of confused gestures.
    @ViewBuilder
    private var transcriptRegion: some View {
        if let transcription = model.transcription, !transcription.displayText.isEmpty {
            ScrollView {
                Text(transcription.displayText)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: layout.transcriptFillsAvailableHeight ? .infinity : 160)
            .padding(.horizontal, 24)
            .accessibilityIdentifier("capture.transcript")
        }
    }

    /// Capture errors, deliberately ABOVE the control bar rather than inside it.
    ///
    /// Its height depends on the message, and anything of variable height inside a
    /// bottom-anchored bar moves the controls. Here it displaces the transcript — the one
    /// band on this screen that is meant to flex — and the bar does not budge.
    @ViewBuilder
    private var errorBanner: some View {
        if let error = model.coordinator.lastError {
            Text(error)
                .captureLabel(.errorBanner)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
        }
    }

    /// Everything that operates the recorder, pinned outside every scroll view — the #53
    /// fix itself. Present in every phase so it never appears, disappears, or resizes
    /// under the owner's thumb mid-reading.
    ///
    /// Rebuilt 2026-08-15 to the owner-approved "Option B" mockup. The #53 version kept
    /// the controls still but took 331 pt — 38% of an iPhone 17 Pro — stacking timer,
    /// meter, record button, marker row and Done as five separate rows with 28 pt gaps.
    /// The owner's verdict: *"the bottom half stays put but it's so big I can't even see
    /// the full backdate interface let alone Two voices and Recents"*, and his ruling was
    /// a proportion — **at most a third of the screen**.
    ///
    /// Three rows now instead of five: the timer goes inline with the status text and
    /// Done, and the marker buttons move from their own row to FLANKING the record
    /// button. Every size comes from `CaptureControlBarMetrics`, which is where the
    /// ≤ ⅓ arithmetic can be tested.
    ///
    /// The background is opaque on purpose: the setup band scrolls behind this, and a
    /// transparent bar would let text slide under the record button.
    private var controlBar: some View {
        VStack(spacing: CaptureControlBarMetrics.rowSpacing) {
            statusRow

            MicMeter(level: model.coordinator.micLevel,
                     isLive: model.coordinator.phase == .recording)

            recordRow
        }
        .padding(.top, CaptureControlBarMetrics.topPadding)
        .padding(.bottom, CaptureControlBarMetrics.bottomPadding)
        .frame(maxWidth: .infinity)
        .background(Color(white: 0.05))
        // Deliberately NO accessibilityIdentifier on this container. Putting one here
        // turns the bar into a single accessibility element that absorbs its children,
        // and `capture.record` / `capture.voiceSwitch` / `capture.paragraph` stop being
        // queryable at all — which broke every capture UI test the first time round. Same
        // flattening this file already hit on the NavigationLink rows and the Task-6
        // backdate row.
    }

    /// Timer, live dot, status text and Done, all on one line — two rows of the old bar
    /// collapsed into one.
    ///
    /// Height is FIXED rather than sized to content. The bar is anchored to the bottom
    /// edge, so anything inside it that grows pushes the record button upward: the #53
    /// build measured 151 pt of exactly that before reserving space in every phase. The
    /// status string is the variable-length part and `RecStatusLine` shrinks it instead of
    /// wrapping; Done is reserved here for the same reason it was reserved before.
    private var statusRow: some View {
        HStack(spacing: 12) {
            RecStatusLine(phase: model.coordinator.phase,
                          canResume: model.coordinator.canResume,
                          elapsed: model.coordinator.elapsed)

            Spacer(minLength: 8)

            // Reserved, not inserted: `.opacity(0)` keeps the space and the row height
            // constant while `.disabled` + `.accessibilityHidden` keep it unreachable by
            // touch and by VoiceOver in the phases where it is not really there.
            Button("Done") { Task { await model.done() } }
                .buttonStyle(.bordered)
                .tint(.red)
                .accessibilityIdentifier("capture.done")
                .opacity(control.showsDoneButton ? 1 : 0)
                .disabled(!control.showsDoneButton)
                .accessibilityHidden(!control.showsDoneButton)
        }
        .frame(height: CaptureControlBarMetrics.statusRowHeight)
        .padding(.horizontal, CaptureControlBarMetrics.horizontalPadding)
    }

    /// The voice switch, the record button, and the paragraph button on one line, with the
    /// marks pushed out toward the screen edges.
    ///
    /// The owner's refinement on the mockup, verbatim: *"just make sure we separate the
    /// clickable buttons as much as we can within that paradigm… BN and paragraph marker
    /// could move towards the side just a bit"*. Hence the tighter inset here than on the
    /// status row: Stop keeps the widest exclusion zone the row can give it, so a marker
    /// tap during a reading cannot land on the one button that ends the recording.
    private var recordRow: some View {
        // The REAL markers model in every phase, with no `reservedForLayout` substitution:
        // each marker slot is a fixed size that holds its space whether or not the control
        // is shown, so the row's geometry no longer depends on what is visible in it.
        RecordControlsRow(model: model, markers: markers) {
            RecordButton(model: control, action: primaryAction)
                .accessibilityIdentifier("capture.record")
        }
        .frame(height: CaptureControlBarMetrics.recordDiameter)
        .padding(.horizontal, CaptureControlBarMetrics.controlRowHorizontalPadding)
    }

    /// The single most recent entry (M3 T4.5, cut down 2026-08-15), sourced from
    /// `model.library` — the SAME scan/store the Library screen reads — and rendered with
    /// the same `LibraryEntryRow` the library list uses.
    ///
    /// One, not three, and not a list. Owner smoke: "I'd rather not have too many things
    /// scrolling around. Would be better just to see the most recent one and then have an
    /// obvious link to the Library." Three rows were also what turned the setup band into a
    /// scroll view tall enough to compete with the control bar for height, which is why
    /// its last row rendered sliced through the middle of a sentence.
    @ViewBuilder
    private var lastEntrySection: some View {
        if let item = model.library.recent.first {
            VStack(alignment: .leading, spacing: 8) {
                Text("Last entry")
                    .captureLabel(.recentHeader)
                NavigationLink(value: LibraryDestination.entry(item.captureID)) {
                    LibraryEntryRow(item: item)
                }
                .accessibilityIdentifier("capture.recentRow")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The way into everything else, at full width and at the foot of the landing area.
    ///
    /// Replaces the "See all" link that sat in the Recent header's top-right corner. The
    /// owner's words: he wants "an obvious link to the Library… not just up in the top
    /// right like open more recent". A route this central should not be the smallest thing
    /// on the screen.
    private var libraryDoor: some View {
        NavigationLink(value: RootDestination.library) {
            HStack {
                Text("All entries & journals")
                    .captureLabel(.libraryDoor)
                Spacer()
                Image(systemName: "chevron.right")
                    .captureLabel(.libraryDoorChevron)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.white.opacity(0.28), lineWidth: 1))
        }
        // Combined, with an explicit label: a NavigationLink wrapping an HStack of Text
        // plus an Image is read out as two elements otherwise. This file has hit that
        // flattening/splitting pair repeatedly (Task-6 backdate row, the control bar).
        .accessibilityElement(children: .combine)
        .accessibilityLabel("All entries and journals")
        .accessibilityIdentifier("capture.libraryDoor")
    }

    /// The post-stop receipt (owner ruling 2026-08-15, capture-landing option B).
    ///
    /// Everything above the control bar for as long as it is up. What the owner lost
    /// before was any sense that a reading had FINISHED: the transcript simply stayed on
    /// screen as loose text under a sliced Recent list, belonging to nothing and leading
    /// nowhere. Here the same words are headed, dated, set in the reading serif with their
    /// voice marks, and have two doors out of them.
    private func receiptRegion(_ receipt: CaptureReceipt) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(receipt.dateText)
                        .captureLabel(.receiptDate)
                        .accessibilityIdentifier("capture.receipt.date")
                    Spacer()
                    Text("Saved")
                        .captureLabel(.receiptSavedChip)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.green.opacity(0.22)))
                }
                Text(receipt.summaryLine)
                    .captureLabel(.receiptSummary)
                    .monospacedDigit()
                    .accessibilityIdentifier("capture.receipt.summary")
            }

            receiptProse(receipt)

            HStack(spacing: 12) {
                NavigationLink(value: LibraryDestination.entry(receipt.captureID)) {
                    Text("Open")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                // Dismissed on the way out, not on the way back: returning from the entry
                // you were just reading to a receipt about it is a loop with no exit that
                // feels like progress.
                .simultaneousGesture(TapGesture().onEnded { model.dismissReceipt() })
                .accessibilityIdentifier("capture.receipt.open")

                Button("Record another") { model.dismissReceipt() }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("capture.receipt.dismiss")
            }
            .controlSize(.large)
            // Never `.preferredColorScheme` on this screen — see `BackdateField`.
            .environment(\.colorScheme, .dark)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The receipt's prose, or one calm line saying why there is none.
    ///
    /// Absent, unreadable and present-but-empty stay three distinct answers (issue #11's
    /// rule) rather than collapsing into a blank box — and none of them is an error, which
    /// is why they read as statements and not warnings. The recording is safe in all three.
    @ViewBuilder
    private func receiptProse(_ receipt: CaptureReceipt) -> some View {
        if let unavailable = receipt.proseUnavailableText {
            Text(unavailable)
                .captureLabel(.receiptSummary)
                .accessibilityIdentifier("capture.receipt.prose")
            Spacer(minLength: 0)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch receipt.body {
                    case .attributed(let paragraphs):
                        // `VoiceAttributedText` is the SAME renderer the detail screen
                        // uses, so the marks the owner asked to see "manifest" here are
                        // exactly the ones he'll see when he opens the entry.
                        ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                            VoiceAttributedText.paragraph(
                                paragraph, voiceLabels: model.selectedJournalVoiceLabels)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    case .plain(let text):
                        Text(text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    case .absent, .unreadable, .empty:
                        // Unreachable: `proseUnavailableText` is non-nil for all three, so
                        // the branch above handled them. Stated rather than defaulted, so
                        // a new display case has to be decided here instead of silently
                        // rendering nothing.
                        EmptyView()
                    }
                }
                // Serif, per the 2026-08-09 type ruling: the reading surface is New York,
                // and this is a reading surface.
                .font(.system(.callout, design: .serif))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("capture.receipt.prose")
        }
    }

    private func primaryAction() {
        switch control.action {
        case .record: Task { await model.record() }
        case .done: Task { await model.done() }
        case .resume: Task { await model.resume() }
        case .none: break
        }
    }
}

/// "Recording into: <journal>" (M3 T3, phone mockup). A `Menu` doubles as the switcher
/// — tap to pick any existing journal — plus "Rename…" and "New Journal…", both taken
/// through an `.alert` text field so this stays a menu-and-alert screen, no navigation
/// push, matching M1/M2's quiet-chrome style.
struct JournalHeaderView: View {
    let model: CaptureScreenModel

    @State private var showingNewJournalPrompt = false
    @State private var showingRenamePrompt = false
    @State private var showingCoverPicker = false
    @State private var showingVoiceLabels = false
    @State private var draftName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recording into")
                .captureLabel(.journalHeaderCaption)

            Menu {
                ForEach(model.journals) { journal in
                    Button {
                        model.selectJournal(journal.id)
                    } label: {
                        if journal.id == model.selectedJournalID {
                            Label(menuTitle(for: journal), systemImage: "checkmark")
                        } else {
                            Text(menuTitle(for: journal))
                        }
                    }
                }
                Divider()
                Button("Rename “\(model.selectedJournalName)”…") {
                    draftName = model.selectedJournalName
                    showingRenamePrompt = true
                }
                Button("New Journal…") {
                    draftName = ""
                    showingNewJournalPrompt = true
                }
                if model.selectedJournalID != nil {
                    Button("Cover Photo…") { showingCoverPicker = true }
                        .accessibilityIdentifier("capture.coverPhotoMenuItem")
                    Button("Voice Labels…") { showingVoiceLabels = true }
                        .accessibilityIdentifier("capture.voiceLabelsMenuItem")
                }
            } label: {
                HStack(spacing: 6) {
                    JournalCoverThumbnail(data: model.selectedJournalCover, size: 34)
                        .accessibilityIdentifier("capture.journalCoverThumbnail")
                    // `captureLabel`, not a raw `.font(.title3…)`. The raw style rendered
                    // this at 15 pt on the Mac — below the 16 pt floor — on the very
                    // platform the "font too small" report came from, while
                    // `CaptureLabel.journalName` sat in the model declaring 22 pt and
                    // passing every check in `CaptureLabelTests`. The model said one thing
                    // and the screen did another; `testEveryLabelCaseIsActuallyAppliedToAView`
                    // is what now makes that disagreement impossible.
                    Text(model.selectedJournalName)
                        .captureLabel(.journalName)
                        .fontWeight(.semibold)
                    Image(systemName: "chevron.up.chevron.down")
                        .captureLabel(.journalPickerChevron)
                }
                .foregroundStyle(.white)
            }
            .accessibilityIdentifier("capture.journalPicker")
            // This control had NO color-scheme pin at all before (issue #58) — its
            // label was already explicit `.white`/gray, but nothing pinned the menu's
            // own rendering. `.environment(\.colorScheme, .dark)`, never
            // `.preferredColorScheme`: `CaptureView` is the app's one permanently-
            // mounted NavigationStack root (`ContentView.swift`), with no sheet/popover
            // boundary around it, so `preferredColorScheme` here would resolve to the
            // whole window — forcing Library/Detail/Trash dark for every macOS
            // light-mode user, not just this menu (fix-round-1 finding). Scoped to the
            // `Menu` only, not the enclosing `VStack` below, which also anchors this
            // view's `.sheet`/`.alert` presentations (cover picker, voice labels,
            // rename/new journal prompts) — those must keep following the system's
            // normal appearance. The menu's own dropdown *content* (journal list,
            // Rename/New Journal/Cover Photo/Voice Labels items) is a transient popup
            // and out of scope for #58 — it renders on its own material background,
            // not the near-black screen.
            .environment(\.colorScheme, .dark)

            // The one honest case where nothing is selected. Says what it costs — the
            // recording is unaffected, only its filing — rather than raising an alarm.
            if model.registryUnreadable {
                Text("Your journals couldn’t be read. This entry will record normally "
                     + "and stay where it is until they’re back.")
                    .captureLabel(.journalsUnreadable)
                    .accessibilityIdentifier("capture.journalsUnreadable")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("capture.journalHeader")
        // `.foregroundStyle(Color.primary)` on both fields, for the same reason the
        // `.sheet` below resets it: an alert draws on the SYSTEM's own light material,
        // but its content is a SwiftUI builder nested inside `CaptureView`, which sets
        // `.foregroundStyle(.white)` for the near-black capture surface. That white is
        // inherited straight into the text field — owner smoke, 2026-08-15: "the 'new
        // folder' text field is white on white, can't read what I type. but it does
        // work." Exactly that: the binding was fine, the text was invisible.
        .alert("New Journal", isPresented: $showingNewJournalPrompt) {
            TextField("Journal name", text: $draftName)
                .foregroundStyle(Color.primary)
                .accessibilityIdentifier("capture.newJournalNameField")
            Button("Create") { Task { await model.createJournal(name: draftName) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Journal", isPresented: $showingRenamePrompt) {
            TextField("Journal name", text: $draftName)
                .foregroundStyle(Color.primary)
                .accessibilityIdentifier("capture.renameJournalNameField")
            Button("Rename") { Task { await model.renameCurrentJournal(to: draftName) } }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showingCoverPicker) {
            // Reset the capture screen's inherited .white foreground —
            // it renders invisible on the system sheet background.
            JournalCoverPickerSheet(
                journalName: model.selectedJournalName,
                currentCover: model.selectedJournalCover,
                onPick: { data in
                    do { try await model.setCurrentJournalCover(imageData: data); return true }
                    catch { return false }
                },
                onRemove: { await model.removeCurrentJournalCover() })
            .foregroundStyle(Color.primary)
        }
        .sheet(isPresented: $showingVoiceLabels) {
            // Same foreground reset as the cover sheet above — system sheet background.
            JournalVoiceLabelsSheet(
                journalName: model.selectedJournalName,
                currentLabels: model.journals.first(where: { $0.id == model.selectedJournalID })?
                    .voiceLabels ?? [:],
                onSave: { labels in await model.setCurrentJournalVoiceLabels(labels) })
            .foregroundStyle(Color.primary)
        }
    }

    /// Journal name plus its derived date range in parentheses (issue #14 part 2), e.g.
    /// "1987 (1987)" or "Trip to France (March – July 1998)". Omitted for an empty
    /// journal — appending "()" to a journal nobody has recorded into yet is noise.
    private func menuTitle(for journal: Journal) -> String {
        guard let range = model.library.dateRange(forJournal: journal.id) else { return journal.name }
        return "\(journal.name) (\(range.formatted()))"
    }
}

/// Optional backdate — off by default, so an un-backdated entry never has a date
/// materialized into its sidecar (`EntryMetadata.originalDate == nil` means "use the
/// capture's own date"). Settable before or during recording (M3 T3); the model pushes
/// every change straight to the live capture's `entry.json` when one is in progress.
/// The backdate toggle plus its precision date picker, with no styling applied. Two
/// callers style this content for two different surfaces: `BackdateField` pins it to the
/// near-black capture background (issue #58, the idle setup band's inline field);
/// `CompactBackdateSummary`'s sheet leaves it in the system's own light/dark appearance —
/// the same convention `JournalHeaderView`'s cover/voice-labels sheets already use, and
/// the reason this content is factored out rather than duplicated (approach 2, 2026-08-16
/// IA discussion: the sheet needs the identical write-through bindings, just un-styled).
struct BackdateEditorContent: View {
    let model: CaptureScreenModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Both bindings write through synchronously — no `Task` per change. Two
            // spins of the date wheel then reach the sidecar-write chain in the order
            // the user made them, which a Task per change could not guarantee.
            Toggle(isOn: Binding(
                get: { model.backdateEnabled },
                set: { model.setBackdateEnabled($0) }
            )) {
                Text("Backdate this entry")
                    .captureLabel(.backdateToggle)
            }
            .accessibilityIdentifier("capture.backdateToggle")
            // `.switch`, not the platform-default checkbox: a checkbox's outline-only
            // chrome is low-contrast against near-black in light mode; the switch style
            // always paints a distinctly-colored track + thumb, so legibility doesn't
            // depend on the color-scheme pin below actually reaching the control.
            .toggleStyle(.switch)

            // Always rendered, disabled until the toggle is on — a conditional picker
            // with a hidden label left no visible "place to set the date" (smoke
            // feedback, 2026-08-02). The row itself is the affordance.
            VStack(alignment: .leading, spacing: 4) {
                Text("Entry date")
                    .captureLabel(.backdateFieldCaption)
                PrecisionDatePicker(
                    date: Binding(get: { model.backdateDate }, set: { model.setBackdateDate($0) }),
                    precision: Binding(get: { model.backdatePrecision }, set: { model.setBackdatePrecision($0) }),
                    idPrefix: "capture")
            }
            .disabled(!model.backdateEnabled)
            .opacity(model.backdateEnabled ? 1 : 0.45)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct BackdateField: View {
    let model: CaptureScreenModel

    var body: some View {
        BackdateEditorContent(model: model)
            // Belt-and-suspenders alongside the `.environment` pin below (issue #58): an
            // explicit foreground/tint at this call site (not inside
            // `BackdateEditorContent`, which `CompactBackdateSummary`'s light-background
            // sheet also uses and must not force) so the toggle's and date field's own
            // text/highlight read correctly even if the environment pin doesn't reach
            // every native subview.
            .tint(.white)
            .foregroundStyle(.white)
            // The capture screen's background is near-black regardless of the app's color
            // scheme; an ambient-scheme system control renders dark-on-dark in light mode
            // (smoke feedback 2026-08-02, issue #58). `.environment(\.colorScheme, .dark)`
            // ONLY — never `.preferredColorScheme`, which governs "the nearest enclosing
            // presentation, such as a popover or window" (Apple's own wording): this view
            // lives inside `CaptureView`, the app's one permanently-mounted NavigationStack
            // root (`ContentView.swift`), with no sheet/popover boundary around it, so a
            // `preferredColorScheme` pin here would resolve to the WHOLE WINDOW — forcing
            // Library/Detail/Trash dark for every macOS light-mode user, all the time. The
            // scoped `.environment` pin has no such reach; a control's own transient popup
            // (the calendar/segment dropdown) is explicitly out of scope for #58 — it
            // renders on its own material background, not the near-black screen.
            .environment(\.colorScheme, .dark)
    }
}

/// One-line, non-scrolling stand-in for `BackdateField` while capturing (approach 2,
/// 2026-08-16 IA discussion). Owner: "there's two scrollable sections above [the bar]...
/// I would rather have none, especially during the recording." The full field is bounded
/// (a toggle and a date), so it never needed a scroll region — it just needed to stop
/// being drawn as one. Tapping opens the same write-through editor in a sheet, unstyled
/// (system light/dark material), the same convention `JournalHeaderView`'s other sheets
/// already use.
struct CompactBackdateSummary: View {
    let model: CaptureScreenModel
    @State private var showingEditor = false

    var body: some View {
        Button {
            showingEditor = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                Text(Self.summaryText(enabled: model.backdateEnabled,
                                      date: model.backdateDate,
                                      precision: model.backdatePrecision))
                    .captureLabel(.backdateSummary)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .accessibilityIdentifier("capture.backdateSummary")
        .sheet(isPresented: $showingEditor) {
            NavigationStack {
                Form {
                    BackdateEditorContent(model: model)
                }
                .navigationTitle("Backdate")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showingEditor = false }
                            .accessibilityIdentifier("capture.backdateSheetDone")
                    }
                }
            }
            // Reset the capture screen's inherited .white foreground — same reasoning as
            // `JournalHeaderView`'s cover/voice-labels sheets, which render on the
            // system's own light material, not the near-black capture surface.
            .foregroundStyle(Color.primary)
        }
    }

    /// Pulled out as its own pure function, same reasoning as
    /// `EntryDetailView.navigationTitleText`: a name a test can call directly.
    static func summaryText(enabled: Bool, date: Date, precision: DatePrecision,
                            calendar: Calendar = .gregorianCurrent) -> String {
        guard enabled else { return "Not backdated" }
        let partial = PartialDate(from: date, precision: precision, calendar: calendar)
        return "Backdated to \(partial.formatted(calendar: calendar))"
    }
}

/// Whether this is a two-voice reading (T6 §14, design §5) — the setup-area gate for the
/// voice switch. Pre-record only: the frame-0 `bn` opener can only be written at recording
/// start, so enabling mid-capture has no coherent meaning in this build (plan §0.3.5).
///
/// The toggle reads `multiVoiceEnabled`, which is *computed* — the in-session per-journal
/// override, else the journal's most recent entry on disk. Unlike the backdate toggle this
/// one auto-enables from carry-over: a wrong voice attribute is visible and editable in T7,
/// where a wrong backdate is a quiet data error (the deliberate divergence, design §2).
struct MultiVoiceField: View {
    let model: CaptureScreenModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(
                get: { model.multiVoiceEnabled },
                set: { model.setMultiVoiceEnabled($0) }
            )) {
                Text("Two voices")
                    .captureLabel(.multiVoiceToggle)
            }
            .accessibilityIdentifier("capture.multiVoiceToggle")
            .disabled(model.coordinator.phase != .idle)
            .opacity(model.coordinator.phase == .idle ? 1 : 0.45)
            // Same `.switch` reasoning as `BackdateField`'s toggle — not itself named
            // in issue #58, but the same control class on the same background.
            .toggleStyle(.switch)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // `.environment(\.colorScheme, .dark)` ONLY, never `.preferredColorScheme` —
        // see the matching comment on `BackdateField` (issue #58 fix-round-1 finding):
        // `CaptureView` is the app's permanently-mounted NavigationStack root with no
        // sheet/popover boundary, so `preferredColorScheme` here would resolve to the
        // whole window, not this subtree.
        .environment(\.colorScheme, .dark)
    }
}

/// The recorder's control row: the voice switch, the record button, and the paragraph
/// button, side by side with the marks pushed toward the screen edges.
///
/// The structure-marker controls (T6 §14, design §5) are a thumb-reach voice switch
/// showing the *active* voice, and a paragraph button always present while recording
/// (owner decision 7 — paragraphs are structure in a single-voice reading too). Visibility
/// and enablement still come from the pure `MarkerControlsModel`; everything here is
/// presentation plus the two coordinator calls.
///
/// They used to occupy a row of their own beneath the record button, which cost the bar
/// 44 pt plus a gap for two small buttons. Taking the record button as a centre slot lets
/// all three share one row — the change that made the owner's ≤ ⅓ ruling reachable — and
/// keeps the haptics, the enablement rule and the voice-label resolution in the one place
/// that already owned them.
struct RecordControlsRow<Center: View>: View {
    let model: CaptureScreenModel
    let markers: MarkerControlsModel

    @ViewBuilder let center: () -> Center

    /// One player per row instance, reused across every marker tap for the capture's
    /// lifetime — the CHHapticEngine it lazily owns is worth keeping warm rather than
    /// spinning up per tap.
    @State private var haptics = MarkerHapticsPlayer()

    /// `coordinator.currentVoice` before a capture opens (or before its frame-0 `bn`
    /// marker lands) is `nil`; the main voice (`bn`) is the truth for that window, not
    /// a placeholder (plan §0.3.12) — same rule the pre-`VoiceDisplay` ternary encoded.
    private var effectiveVoice: String {
        model.coordinator.currentVoice ?? VoiceDisplay.mainVoice
    }

    /// The voice the capture is currently in, spoken in the selected journal's own
    /// labels when it has configured them (owner ruling 2026-08-12) — else exactly
    /// today's fallback, the uppercased id ("BN"/"LN"), via `VoiceDisplay`'s one
    /// label-resolution rule rather than a local copy of it.
    private var activeVoice: String {
        VoiceDisplay.accessibilityName(forVoice: effectiveVoice, voiceLabels: model.selectedJournalVoiceLabels)
    }

    /// A tap switches to the *other* voice — the label states where you are, the tap
    /// says where you're going. The flip rule lives once, in `VoiceDisplay.other`.
    private var otherVoice: String {
        VoiceDisplay.other(effectiveVoice)
    }

    /// A broken marker log means every tap can only no-op; a live-looking control over a
    /// dead path is the design §7 failure-state violation (plan §0.3.12). The failure is
    /// *reported* through `coordinator.lastError`, already rendered red below the button.
    private var isEnabled: Bool {
        markers.isEnabled && !model.coordinator.markerLoggingBroken
    }

    /// One marker button: fixed size, hidden-but-present when its phase says it isn't
    /// there, and dimmed when it's there but can't be tapped.
    ///
    /// **The fixed width is load-bearing.** The record button is centred by equal spacers,
    /// so the two flanking slots have to be equal. Intrinsic widths would not be: "¶" is
    /// far narrower than "BN", and the voice button's label CHANGES mid-capture — to
    /// "LN", or to whatever the journal's own voice labels are, which can be any length.
    /// Sizing to content would slide the Stop button sideways on every voice mark, which
    /// is #53 all over again in the horizontal axis.
    ///
    /// **Hidden, never absent**, for the same reason: a slot that disappears when a
    /// capture is single-voice, or between phases, lets the record button drift off
    /// centre. `.opacity(0)` keeps the geometry while `.disabled` + `.accessibilityHidden`
    /// keep the control unreachable by touch and by VoiceOver when it is not really there.
    /// This replaces `MarkerControlsModel.reservedForLayout`, which reserved a whole ROW's
    /// height back when the marks had a row of their own.
    /// An ABSENT marker button still occupies its slot — as an empty space of exactly the
    /// same size, not as a hidden button.
    ///
    /// `.opacity(0)` + `.accessibilityHidden(true)` was tried first and is not enough:
    /// XCUITest still finds an accessibility-hidden `Button` by identifier, so the control
    /// remained queryable (and, more to the point, VoiceOver-reachable) in phases where it
    /// does nothing. `CaptureUITests.testVoiceControlsFollowTheMultiVoiceToggle` — which
    /// asserts the voice switch does not exist during a single-voice capture — caught it,
    /// and is the pin for it. A `Color.clear` of the same fixed size keeps the geometry
    /// without keeping the control.
    @ViewBuilder
    private func markerButton(_ title: String,
                              identifier: String,
                              accessibilityLabel: String? = nil,
                              isShown: Bool,
                              action: @escaping () -> Void) -> some View {
        if isShown {
            Button(action: action) {
                Text(title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: .infinity)
            }
            .frame(width: CaptureControlBarMetrics.markerButtonWidth,
                   height: CaptureControlBarMetrics.markerButtonHeight)
            .disabled(!isEnabled)
            .opacity(isEnabled ? 1 : 0.45)
            .accessibilityIdentifier(identifier)
            .accessibilityLabel(accessibilityLabel ?? title)
        } else {
            Color.clear
                .frame(width: CaptureControlBarMetrics.markerButtonWidth,
                       height: CaptureControlBarMetrics.markerButtonHeight)
                .accessibilityHidden(true)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            markerButton(activeVoice,
                         identifier: "capture.voiceSwitch",
                         isShown: markers.showsVoiceControl) {
                model.coordinator.markVoice(otherVoice)
            }

            // Pushes the marks apart as far as the row allows — the owner's refinement,
            // so the Stop button keeps the widest possible exclusion zone around it.
            Spacer(minLength: 12)

            // The record button. Deliberately NOT inside the `.disabled` that gates the
            // marks: a broken marker log must never take Stop down with it.
            center()

            Spacer(minLength: 12)

            // "¶" alone on screen — the mockup's glyph — but spoken as "Paragraph".
            markerButton("¶",
                         identifier: "capture.paragraph",
                         accessibilityLabel: "Paragraph",
                         isShown: markers.showsParagraphControl) {
                model.coordinator.markParagraph()
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        // `.environment(\.colorScheme, .dark)` ONLY, never `.preferredColorScheme` —
        // see the matching comment on `BackdateField` (issue #58 fix-round-1
        // finding: `CaptureView` is the permanently-mounted NavigationStack root,
        // so `preferredColorScheme` here would resolve to the whole window).
        .environment(\.colorScheme, .dark)
        // The owner is reading a page, not watching the screen: confirmation has to
        // be felt (design §5). Watching `markerCount`, which counts what reached
        // disk — a failed append is felt as the absence of a buzz.
        //
        // The `old, new` guard, not a bare "any change" trigger: `markerCount` resets
        // to 0 at capture teardown (the coordinator is respawned per capture), and an
        // unguarded trigger fires on that reset too — a phantom buzz on Done
        // (plan §0.3.4). Firing only on an *increase* is what keeps teardown silent.
        //
        // CoreHaptics via `MarkerHapticsPlayer`, not `.sensoryFeedback(.impact, …)`:
        // device feedback (2026-08-07) was "a weak single dot" — the dash-dot pattern
        // (`MarkerHaptic`) needs a real duration on the first beat, which
        // `.sensoryFeedback`/`UIImpactFeedbackGenerator` cannot express.
        .onChange(of: model.coordinator.markerCount) { old, new in
            if new > old { haptics.play() }
        }
    }
}
