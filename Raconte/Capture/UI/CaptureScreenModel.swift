import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Composition + orchestration for the capture screen. Owns the (per-capture, ephemeral)
/// `CaptureCoordinator`, the launch-recovery banner list, the background finalizer, and
/// the post-stop receipt. Kept out of the pure-tested layer on purpose: the testable
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
    private var finishing = false
    /// Tail of the sidecar-write chain — see `enqueueEntryMetadataWrite`.
    private var pendingMetadataWrite: Task<Void, Never>?
    private let idleTimer: any IdleTimerControlling

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

    /// Whether this capture's sidecar already carries `multiVoice: true` — set on the
    /// first live voice mark, reset when the coordinator is replaced. A latch, not a
    /// re-read of the sidecar: the write is asynchronous and a second tap in the same
    /// beat must not enqueue a duplicate.
    private var wroteMultiVoiceForActiveCapture = false

    /// Dismiss the receipt and return to the landing screen. What opening the entry from
    /// the receipt does on its way out (#118 §3 deleted "Record another"; the bar's
    /// record button retires the receipt through `record()`) — coming back from the
    /// detail screen to a receipt for an entry you have just been reading would be a loop.
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
    /// The capture screen's receipt reconciliation (`reconcileReceipt()`) and the Library
    /// screen read through the SAME instance — one scanner, one `JournalStore`/
    /// `EntryMetadataStore` pair, per the "don't build a second data path" rule this task
    /// exists to fix. Defaults to a model over the same `capturesRoot`/
    /// `journalsContainerRoot` when the caller (a test, the UI-test harness) does not
    /// share one in.
    let library: LibraryScreenModel
    private let spawn: @MainActor () -> CaptureCoordinator
    private let finalizer: FinalizerWorker

    /// Live transcription, or nil when the build has none wired (the UI-test harness).
    let transcription: LiveTranscriptionCoordinator?

    /// M4 T6. Nil everywhere sync is off — unit tests, the UI-test harness, and any
    /// build whose composition root refused to construct an engine. Wired by
    /// `AppServices.init()` once `sync` exists, mirroring `JournalStore.attach
    /// (syncHooks:)`/`EntryMetadataStore.attach(syncHooks:)`: construction order means
    /// the coordinator does not exist yet when this model is built.
    private var syncHooks: (any SyncHooks)?

    func attach(syncHooks: any SyncHooks) {
        self.syncHooks = syncHooks
    }

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
    /// off `journals`, so a journal switch — or a save made in the journal editor, which
    /// lands here through `library.rescan()` — is visible with no separate cache to go
    /// stale.
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

    /// Launch-recovered captures the user hasn't dismissed (via Keep/Delete) yet.
    var visibleRecovered: [RecoveredRecording] {
        recovered.filter { !dismissed.contains($0.captureID) }
    }

    /// True while the CURRENT coordinator's phase must hold the display awake
    /// (`CaptureState.keepsDisplayAwake`, pure and unit-tested). Re-derived off
    /// `coordinator` on every read, so it is automatically correct across a respawn.
    var keepsDisplayAwake: Bool { coordinator.phase.keepsDisplayAwake }

    init(capturesRoot: URL,
         makeSession: @escaping () -> AudioSessionController,
         makeRecorder: @escaping () -> EngineRecording,
         encoder: AudioEncoder,
         startCue: (@MainActor () async -> Void)? = nil,
         makeSecondarySink: SecondarySinkFactory? = nil,
         transcription: LiveTranscriptionCoordinator? = nil,
         journalsContainerRoot: URL? = nil,
         journalPreferenceStore: any JournalPreferenceStore = UserDefaultsJournalPreferenceStore(),
         library: LibraryScreenModel? = nil,
         idleTimer: any IdleTimerControlling = PlatformIdleTimer()) {
        self.idleTimer = idleTimer
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
        // All stored properties are assigned by this point, so `self` is usable. The
        // idle-timer call here is the `initial: true` the old view-mounted `.onChange`
        // carried — an idle model must not hold the display awake, matching a fresh
        // launch or a freshly respawned coordinator.
        armCoordinatorObservation()
        idleTimer.setIdleTimerDisabled(keepsDisplayAwake)
        // Last, deliberately (nav T3, #62): nothing above can trigger a rescan
        // synchronously during init (that only happens from `bootstrap()`, which the
        // caller runs after construction returns), so there is no correctness reason
        // to register earlier — this just keeps the true "last thing init does" reading
        // honest rather than splitting it across two spots.
        //
        // The slot is single-occupancy: a second `CaptureScreenModel` built over the
        // SAME `library` (a caller passing an already-observed instance in) would
        // silently steal the slot and unhook the first model's #62 reconcile with no
        // test anywhere failing — Debug-only, loud, rather than a silent
        // last-writer-wins.
        assert(resolvedLibrary.rescanObserver == nil,
               "a second CaptureScreenModel has taken over this library's rescanObserver slot; "
               + "the first model's #62 receipt-reconcile is now silently unhooked")
        resolvedLibrary.rescanObserver = self
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
    /// Library screen with — receipt reconciliation and the library list must read
    /// through one scanner, not two (M3 T4.5). Ignored under the UI-test harness,
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

    /// The one bootstrap, shared by every caller.
    ///
    /// Was a plain `didBootstrap` boolean flipped synchronously at the top, which made a
    /// second caller return immediately while `recoverAtLaunch()` and the trash sweep were
    /// still running. That was harmless while `CaptureView.task` was the only caller;
    /// `beginCapture(inJournal:)` (record-flow plan, Task 5) starts a recording as soon as
    /// this returns, and starting one on top of an in-flight recovery pass over the same
    /// directory is not harmless. A stored `Task` runs the work once and lets everyone
    /// await the same completion.
    ///
    /// Must never be called from within `performBootstrap()` itself: `bootstrapTask` is
    /// assigned synchronously before the body below can acquire the main actor, so a
    /// re-entrant call would see it already set, take the `await bootstrapTask.value`
    /// branch, and deadlock forever waiting on itself. Currently unreachable — nothing in
    /// `performBootstrap()` calls back into `bootstrap()` — but undocumented otherwise.
    private var bootstrapTask: Task<Void, Never>?

    func bootstrap() async {
        if let bootstrapTask {
            await bootstrapTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performBootstrap()
        }
        bootstrapTask = task
        await task.value
    }

    private func performBootstrap() async {
        await resolveCurrentJournal()
        await coordinator.recoverAtLaunch()
        recovered = coordinator.recoveredRecordings
        let recoveredQueue = coordinator.finalizeQueue
        await runFinalizer(recoveredQueue)
        // Same hook, launch-recovery side: a capture killed before its transcript could
        // be read has never had detection run over it, and this is the one other place a
        // transcript first becomes available.
        for id in recoveredQueue { await detectSpokenDate(for: id) }
        // #94 secondary finding: the launch-recovery mirror of
        // `finishCurrentCapture`'s push loop. Without it a capture healed at
        // launch is not enqueued for sync until the NEXT launch's reconcile.
        // `push` is internally gated on `isFinalized`, so only captures whose
        // `.m4a` really verified fire, and a nil `syncHooks` no-ops exactly as
        // everywhere else. Before `rescan()` so the library's refreshed view and
        // sync eligibility can never disagree within one bootstrap.
        for id in recoveredQueue {
            await FinalizeArtifactPush.push(capturesRoot: capturesRoot, captureID: id, syncHooks: syncHooks)
        }
        // #122: the backlog is finished; take it off the live coordinator's queue so the
        // next real capture's early `.captured` flip finds nothing to drain.
        coordinator.consumeFinalized(recoveredQueue)
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

    /// A live voice mark (#118 §4). The ONLY route from the view to `markVoice` on the
    /// coordinator, because a mark has two side effects the coordinator does not own:
    ///
    /// 1. The frame-0 `bn` opener is written first, if this capture has none yet. The
    ///    coordinator's `didWriteOpeningVoice` latch makes that idempotent, and it writes
    ///    at the literal frame 0, so seq order stays frame order.
    /// 2. The first mark of a capture writes `multiVoice: true` to the sidecar, through
    ///    the same chained `enqueueEntryMetadataWrite` every other sidecar write uses.
    ///
    /// Outside `.recording` the coordinator refuses the mark (`canMark`), and this method
    /// must refuse the sidecar write for the same reason — hence the phase guard.
    func markVoice(_ voice: String) {
        guard coordinator.phase == .recording, let id = coordinator.activeCaptureID else { return }
        coordinator.markOpeningVoice()
        coordinator.markVoice(voice)
        if !wroteMultiVoiceForActiveCapture {
            wroteMultiVoiceForActiveCapture = true
            enqueueEntryMetadataWrite(for: id, multiVoice: true)
        }
    }

    /// Start a reading from outside the capture screen — the library's floating record
    /// button and Home's "New entry" (record-flow plan, Task 5).
    ///
    /// Owner ruling 2026-08-29, option 1: those buttons used to preselect the journal and
    /// route to capture's IDLE screen, where a second tap was needed and the "Last entry"
    /// card read as noise. A big red mic button should record.
    ///
    /// Lives here rather than in the call site's closure because of the repo invariant:
    /// nothing that must happen while a capture is running may hang off a view's
    /// lifecycle. The caller routes and fires this; it does not matter whether, or when,
    /// `CaptureView` mounts.
    ///
    /// `bootstrap()` is awaited, not fired: on a launch that went straight to the library,
    /// `CaptureView` has never mounted and the launch-recovery scan has not run. Starting
    /// a capture on top of an in-flight recovery pass over the same directory is the race
    /// Task 4 made this method able to avoid.
    ///
    /// The `.idle` guard is the safety property, and it sits BEFORE the journal select on
    /// purpose: a second tap of the floating button, or arriving from the library while a
    /// reading is already under way, must leave that reading exactly alone — including
    /// which journal it is filed in. Selecting first and then bailing out would re-file a
    /// live capture underneath the owner, which is the worse half of the bug.
    ///
    /// Two concurrent taps cannot both start a recording, but that safety is not this
    /// method's own — it rests on an unstated invariant one layer down. This is
    /// `@MainActor`, and nothing between `coordinator.record()`'s own `guard
    /// machineState.phase == .idle` and `send(_:)`'s synchronous `phase = next.phase`
    /// commit (`CaptureCoordinator.swift`) suspends, so a second call can never observe
    /// `.idle` in the gap. If anything in that chain becomes `async` and starts
    /// suspending before the phase commit — `mintCaptureID()`, say — that window reopens
    /// and this method's `.idle` guard alone would not close it, since both callers could
    /// still read `.idle` before either commits.
    func beginCapture(inJournal journalID: String? = nil) async {
        await bootstrap()
        guard coordinator.phase == .idle else { return }
        if let journalID { selectJournal(journalID) }
        await record()
    }

    /// Called when the coordinator's finalize queue changes. Keyed off the queue, NOT
    /// the phase: `phase` flips to `.captured` before that transition's effects run
    /// (the debug-harness gate sits between), so a phase-triggered drain reads an
    /// empty queue, no-ops, and the capture never finalizes until the next launch's
    /// recovery scan. `enqueueFinalize` runs after `store.finish` — the durability
    /// commit — so this signal means the capture is fully on disk.
    /// The phase guard skips launch-recovery fills (`bootstrap` drains those itself and
    /// then `consumeFinalized` takes them off the queue — #122).
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
        // Journal + backdate only. `multiVoice` is no longer decided at record time
        // (#118 §4): the first live voice mark writes it, see `markVoice`.
        enqueueEntryMetadataWrite(for: id)
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

    /// `library.journals` (what the sidebar reads) and this model's own `journals` (the
    /// picker's copy, patched above) are separate arrays with no shared storage — only a
    /// rescan reconciles them, and nothing else on this path was triggering one (task
    /// review, nav T5: a journal created here was invisible in the sidebar until some
    /// unrelated place selection happened to rescan first). `await library.rescan()`
    /// last, same convention as `LibraryScreenModel`'s own mutations
    /// (`setJournalCover`/`trashEntry`): the write is durable before the rescan reads it
    /// back, so the shared library never observes a half-applied change.
    @discardableResult
    func createJournal(name: String) async -> Journal? {
        guard let created = try? await journalStore.create(name: name) else { return nil }
        // Re-sort, not append-and-trust: display order, not insertion order (#79).
        journals = (journals + [created]).displayOrdered
        selectedJournalID = created.id
        currentJournal.select(created.id)
        resolveBackdateForJournalChange()
        syncActiveEntryMetadata()
        await library.rescan()
        return created
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

    /// #47: after a day-precision backdated capture commits, pre-fill the NEXT reading
    /// with the following day — consecutive pages of a paper journal are usually
    /// consecutive days. Only `.day` advances; never into the future (the field would
    /// then be silently refused at `EntryMetadata.setOriginalDate`). Sets the properties
    /// directly rather than through `setBackdateDate`, which would try to sync a sidecar
    /// for a capture that has already finished.
    private func advanceBackdateForNextEntry(now: Date = Date()) {
        guard backdateEnabled, backdatePrecision == .day else { return }
        let current = PartialDate(from: backdateDate, precision: .day, calendar: .gregorianCurrent)
        guard let next = current.nextDay(calendar: .gregorianCurrent),
              !next.isFuture(now: now) else { return }
        backdateDate = next.anchorDate(calendar: .gregorianCurrent)
        rememberBackdate()
    }

    // MARK: internals

    /// Everything that used to be an `.onChange` on `CaptureView` — the screen is no
    /// longer permanently mounted (nav T2: it must keep dispatching even while the owner
    /// is elsewhere in the app, once `CaptureView` can be pushed off a
    /// `NavigationSplitView` selection), so a view-lifecycle hook is no longer a
    /// guarantee about anything.
    ///
    /// LEVEL-triggered, not edge-triggered: `withObservationTracking`'s `onChange` fires
    /// *before* the new value is visible, so the work hops to the next main-actor turn
    /// and every handler re-reads current state rather than trusting a delivered value.
    /// Consequence worth stating: changes that land inside the hop window are coalesced,
    /// never lost, because no handler depends on seeing a particular edge.
    ///
    /// Re-arming is mandatory and load-bearing twice over: `withObservationTracking`
    /// fires at most once per arm, and `finishCurrentCapture` REPLACES `coordinator`
    /// outright, so the arm must follow the new instance. Reading `coordinator.phase`
    /// registers a dependency on `self.coordinator` as well as on `phase`, which is what
    /// makes the swap itself a trigger.
    private func armCoordinatorObservation() {
        withObservationTracking {
            _ = coordinator.phase
            _ = coordinator.finalizeQueue
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.handlePhase()
                self.handleFinalizeQueue()
                self.idleTimer.setIdleTimerDisabled(self.keepsDisplayAwake)
                self.armCoordinatorObservation()
            }
        }
    }

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
        // M4 T6 choke point (design §3: "finalize completion (m4a verified +
        // promotion) → enqueue Entry + AudioAsset + LiveLog"). Placed strictly after
        // the `recordTranscriptRef` loop above: that is the first point at which BOTH
        // halves of "m4a verified AND transcript ref recorded" are true for this id —
        // `runFinalizer` already ran (so `FinalizeArtifactPush.isFinalized` can only
        // read true for a capture whose `.m4a` really was verified/promoted), and
        // whatever transcript ref exists has already been written into `manifest.json`
        // by `recordTranscriptRef`, so the entry that gets pushed today never needs a
        // second push just to pick up a ref that landed moments after the first one.
        // This is the ONE place capture-side code fires `.entry`/`.audio`/`.liveLog`;
        // every later edit to `entry.json` re-fires `.entry` on its own, from
        // `EntryMetadataStore.update`'s own hook (same eligibility gate) — see that
        // method's doc comment.
        for id in transcribed {
            await FinalizeArtifactPush.push(capturesRoot: capturesRoot, captureID: id, syncHooks: syncHooks)
        }
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
        advanceBackdateForNextEntry()
        coordinator = spawn()
        wroteMultiVoiceForActiveCapture = false
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
            // Display order, not registry (insertion) order — issue #79.
            journals = registry.journals.displayOrdered
            selectedJournalID = id
            currentJournal.select(id)
        case .needsDefault:
            // #84: the auto-mint stays local (no push) until it is actually used — see
            // `JournalStore.createProvisionalDefault`'s doc comment. Otherwise, on a
            // fresh install of an account that already has journals in CloudKit, this
            // mint pushes before the first fetch can land and pollutes every device with
            // a spurious empty "Journal".
            if let created = try? await journalStore.createProvisionalDefault(name: "Journal") {
                journals = [created]
                selectedJournalID = created.id
                currentJournal.select(created.id)
            } else {
                // Best-effort: the registry stays empty and the header falls back to the
                // "Journal" literal in `selectedJournalName` until the next bootstrap.
                journals = registry.journals.displayOrdered
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
    /// parameter**: nil means "leave `metadata.multiVoice` alone". This function is shared
    /// with `syncActiveEntryMetadata()`, which runs on a mid-capture journal switch — the
    /// nil default there is what keeps that switch from rewriting the running entry's mode
    /// out from under the markers already on disk. Only `markVoice` passes a value, and
    /// only `true`, on the first live voice mark of a capture.
    ///
    /// Writes are chained so they land in submission order.
    ///
    /// `BackdateEditorContent`'s `DatePicker` used to fire a fresh `Task` per change, each of
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
        let journalStore = journalStore
        let previous = pendingMetadataWrite
        let task = Task { @MainActor in
            await previous?.value
            let wrote = try? await store.update(captureID: captureID) { metadata in
                if let journalID { metadata.journalID = journalID }
                if writeBackdate {
                    metadata.setOriginalDate(originalDate)
                }
                if let multiVoice { metadata.multiVoice = multiVoice }
            }
            // #84 point 2: routes through the ONE shared chokepoint every caller that
            // files an entry into a journal must use (`promoteProvisionalDefaultAfterEntrySave`'s
            // own doc comment names the other one, `LibraryScreenModel.moveEntry`) — a
            // still-provisional default is promoted and pushed the moment an entry is
            // saved into it; a no-op for every other journal (the common case) or a
            // failed write (`wrote != nil` gates it). Idempotent — this call is shared by
            // both the initial-recording path and a mid-capture journal switch via
            // `syncActiveEntryMetadata`, which calls this same function.
            _ = await promoteProvisionalDefaultAfterEntrySave(
                journalStore: journalStore, journalID: journalID, entryWriteSucceeded: wrote != nil)
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

/// #62, nav redesign §5.1: `library`'s rescan notifies straight into `reconcileReceipt()`
/// — model-to-model, no view required. Registered as `library.rescanObserver` at the end
/// of `init`; see `reconcileReceipt()`'s own doc comment for what the invariant means.
extension CaptureScreenModel: LibraryRescanObserver {
    func libraryDidRescan() {
        reconcileReceipt()
        refreshJournalsFromLibrary()
    }

    /// #79 (second half): this model used to hold a bootstrap-once copy of `journals`
    /// that nothing but its own create/rename/label intents ever refreshed. A journal
    /// adopted from another device reaches the registry via
    /// `JournalStore.applySyncMerge` + `library.rescan()` (`SyncCoordinator.swift:120`)
    /// — neither of those calls into `CaptureScreenModel` at all — so the capture
    /// picker stayed stuck on its bootstrap snapshot until the app relaunched.
    ///
    /// Wired through the SAME `libraryDidRescan()` seam #62 already uses, deliberately:
    /// it is the one hook this model has that already fires on every rescan regardless
    /// of who triggered it (a local mutation, launch, or a background sync pull), with
    /// no view lifecycle involved.
    ///
    /// `library.journals` is already `.displayOrdered` (`LibraryScreenModel.rescan()`),
    /// so this is a straight assignment — re-sorting here would be redundant, not a
    /// second source of truth for order.
    ///
    /// #67-class guard: a background refresh must never move the user's capture
    /// target. The selected id is left untouched whenever it still resolves in the
    /// refreshed list — even when that SAME journal's name/cover/labels changed
    /// remotely, since `selectedJournalName`/`selectedJournalVoiceLabels` already read
    /// live off `journals` and need no extra wiring to pick up the new values. Only
    /// when the selected id has genuinely left the registry — unreachable today,
    /// reachable once Phase B ships deletion — does this fall back, through the exact
    /// same `JournalSelection` rule `resolveCurrentJournal()` applies at bootstrap
    /// (never a second, ad hoc copy of that rule).
    private func refreshJournalsFromLibrary() {
        guard !library.journalsUnreadable else { return }
        journals = library.journals
        guard let selectedJournalID, !journals.contains(where: { $0.id == selectedJournalID })
        else { return }
        switch JournalSelection.resolve(registry: JournalRegistry(journals: journals),
                                        storedID: currentJournal.storedID) {
        case .existing(let id):
            self.selectedJournalID = id
            currentJournal.select(id)
            resolveBackdateForJournalChange()
            syncActiveEntryMetadata()
        case .needsDefault:
            // The registry has gone from "the selected journal is gone" to "every
            // journal is gone" between the guard above and here — only reachable if
            // every journal in the app is deleted mid-session (Phase B). Best-effort,
            // matching `resolveCurrentJournal()`'s own `.needsDefault` fallback: mint
            // "Journal" and select it, off the main actor's next turn since minting is
            // a `JournalStore` write.
            Task { [weak self] in
                // #84: same local-only mint as `resolveCurrentJournal()`'s own
                // `.needsDefault` fallback — see that call site's comment.
                guard let self, let created = try? await self.journalStore.createProvisionalDefault(name: "Journal")
                else { return }
                self.journals = (self.journals + [created]).displayOrdered
                self.selectedJournalID = created.id
                self.currentJournal.select(created.id)
                self.resolveBackdateForJournalChange()
                self.syncActiveEntryMetadata()
                // Same convention as `createJournal` (see its doc comment above):
                // `library.journals` and this model's own `journals` are separate
                // arrays with no shared storage, and only a rescan reconciles them.
                // Without this, the freshly-minted default is invisible to
                // `library.journals` — the sidebar, and anything else that reads
                // through `library` rather than this model — until some UNRELATED
                // rescan happens to run first. Last, same reason: the write must be
                // durable before the rescan reads it back.
                await self.library.rescan()
            }
        }
    }
}
