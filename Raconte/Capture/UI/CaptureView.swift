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

    func record() async { await coordinator.record() }
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
        coordinator = spawn()
        finishing = false
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

    var body: some View {
        ZStack {
            Color(white: 0.05).ignoresSafeArea()

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
                    MultiVoiceField(model: model)

                    ForEach(model.visibleRecovered) { rec in
                        RecoveryBanner(recording: rec,
                                       capturesRoot: model.capturesRoot,
                                       onKeep: { model.keep(rec.captureID) },
                                       onDelete: { model.delete(rec.captureID) })
                    }

                    Spacer(minLength: 12)

                    if let transcription = model.transcription, !transcription.displayText.isEmpty {
                        ScrollView {
                            Text(transcription.displayText)
                                .font(.callout)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 160)
                        .accessibilityIdentifier("capture.transcript")
                    }

                    RecStatusLine(phase: model.coordinator.phase,
                                  canResume: model.coordinator.canResume,
                                  elapsed: model.coordinator.elapsed)

                    MicMeter(level: model.coordinator.micLevel,
                             isLive: model.coordinator.phase == .recording)

                    RecordButton(model: control, action: primaryAction)
                        .accessibilityIdentifier("capture.record")

                    MarkerControlsRow(model: model, markers: markers)

                    if control.showsDoneButton {
                        Button("Done") { Task { await model.done() } }
                            .buttonStyle(.bordered)
                            .tint(.red)
                            .accessibilityIdentifier("capture.done")
                    }

                    if let error = model.coordinator.lastError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }

                    recentSection

                    Spacer(minLength: 24)

                    // Not DEBUG-gated: a wireless install is exactly when you can't tell
                    // which build you're holding, and TestFlight has the same problem.
                    Text(BuildInfo.stamp)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.35))
                        .accessibilityIdentifier("capture.buildStamp")
                }
                .padding(24)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
        }
        .foregroundStyle(.white)
        .task { await model.bootstrap() }
        .onChange(of: model.coordinator.phase) { _, _ in
            model.handlePhase()
        }
        .onChange(of: model.coordinator.finalizeQueue) { _, _ in
            model.handleFinalizeQueue()
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

    /// The 3 most recently captured entries (M3 T4.5), sourced from `model.library` —
    /// the SAME scan/store the Library screen reads — and rendered with the same
    /// `LibraryEntryRow` the library list uses. No play/delete affordances here: those
    /// moved to `EntryDetailView`, which every row pushes into via the existing
    /// `LibraryDestination.entry` route.
    @ViewBuilder
    private var recentSection: some View {
        if !model.library.recent.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Recent")
                        .font(.headline)
                        .foregroundStyle(Color(white: 0.7))
                    Spacer()
                    NavigationLink(value: RootDestination.library) {
                        Text("See all")
                            .font(.caption)
                            .foregroundStyle(Color(white: 0.7))
                    }
                    .accessibilityIdentifier("capture.seeAllLink")
                }
                ForEach(model.library.recent) { item in
                    NavigationLink(value: LibraryDestination.entry(item.captureID)) {
                        LibraryEntryRow(item: item)
                    }
                    .accessibilityIdentifier("capture.recentRow")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
    @State private var draftName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recording into")
                .font(.caption)
                .foregroundStyle(Color(white: 0.55))

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
                }
            } label: {
                HStack(spacing: 6) {
                    JournalCoverThumbnail(data: model.selectedJournalCover, size: 34)
                        .accessibilityIdentifier("capture.journalCoverThumbnail")
                    Text(model.selectedJournalName)
                        .font(.title3.weight(.semibold))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundStyle(Color(white: 0.6))
                }
                .foregroundStyle(.white)
            }
            .accessibilityIdentifier("capture.journalPicker")

            // The one honest case where nothing is selected. Says what it costs — the
            // recording is unaffected, only its filing — rather than raising an alarm.
            if model.registryUnreadable {
                Text("Your journals couldn’t be read. This entry will record normally "
                     + "and stay where it is until they’re back.")
                    .font(.caption)
                    .foregroundStyle(Color(white: 0.55))
                    .accessibilityIdentifier("capture.journalsUnreadable")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("capture.journalHeader")
        .alert("New Journal", isPresented: $showingNewJournalPrompt) {
            TextField("Journal name", text: $draftName)
                .accessibilityIdentifier("capture.newJournalNameField")
            Button("Create") { Task { await model.createJournal(name: draftName) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Journal", isPresented: $showingRenamePrompt) {
            TextField("Journal name", text: $draftName)
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
struct BackdateField: View {
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
                    .font(.caption)
                    .foregroundStyle(Color(white: 0.55))
            }
            .accessibilityIdentifier("capture.backdateToggle")
            // The capture screen's background is near-black regardless of the app's
            // color scheme; an ambient-scheme system control renders dark-on-dark in
            // light mode (smoke feedback 2026-08-02) — same rule as the date picker below.
            .environment(\.colorScheme, .dark)

            // Always rendered, disabled until the toggle is on — a conditional picker
            // with a hidden label left no visible "place to set the date" (smoke
            // feedback, 2026-08-02). The row itself is the affordance.
            VStack(alignment: .leading, spacing: 4) {
                Text("Entry date")
                    .font(.caption)
                    .foregroundStyle(Color(white: 0.55))
                PrecisionDatePicker(
                    date: Binding(get: { model.backdateDate }, set: { model.setBackdateDate($0) }),
                    precision: Binding(get: { model.backdatePrecision }, set: { model.setBackdatePrecision($0) }),
                    idPrefix: "capture")
                // The capture screen's background is near-black regardless of the app's
                // color scheme, but system controls style themselves for the ambient
                // scheme — in light mode that's dark-on-dark (smoke feedback 2026-08-02).
                .environment(\.colorScheme, .dark)
            }
            .disabled(!model.backdateEnabled)
            .opacity(model.backdateEnabled ? 1 : 0.45)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                    .font(.caption)
                    .foregroundStyle(Color(white: 0.55))
            }
            .accessibilityIdentifier("capture.multiVoiceToggle")
            // The capture screen's background is near-black regardless of the app's
            // color scheme; an ambient-scheme system control renders dark-on-dark in
            // light mode (smoke feedback 2026-08-02) — same rule as the date picker above.
            .environment(\.colorScheme, .dark)
            .disabled(model.coordinator.phase != .idle)
            .opacity(model.coordinator.phase == .idle ? 1 : 0.45)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The recording-time structure-marker controls (T6 §14, design §5): a thumb-reach voice
/// switch showing the *active* voice, and a paragraph button that is always present while
/// recording (owner decision 7 — paragraphs are structure in a single-voice reading too).
///
/// Visibility and enablement come from the pure `MarkerControlsModel`; everything here is
/// presentation plus the two coordinator calls.
struct MarkerControlsRow: View {
    let model: CaptureScreenModel
    let markers: MarkerControlsModel

    /// One player per row instance, reused across every marker tap for the capture's
    /// lifetime — the CHHapticEngine it lazily owns is worth keeping warm rather than
    /// spinning up per tap.
    @State private var haptics = MarkerHapticsPlayer()

    /// The voice the capture is currently in. A multi-voice capture opens with a frame-0
    /// `bn` marker, so nil — the window before that opener lands — shows "BN", which is
    /// the truth rather than a placeholder (plan §0.3.12).
    private var activeVoice: String {
        model.coordinator.currentVoice == StructureMarker.Voice.littleNico ? "LN" : "BN"
    }

    /// A tap switches to the *other* voice — the label states where you are, the tap
    /// says where you're going.
    private var otherVoice: String {
        model.coordinator.currentVoice == StructureMarker.Voice.littleNico
            ? StructureMarker.Voice.bigNico
            : StructureMarker.Voice.littleNico
    }

    /// A broken marker log means every tap can only no-op; a live-looking control over a
    /// dead path is the design §7 failure-state violation (plan §0.3.12). The failure is
    /// *reported* through `coordinator.lastError`, already rendered red below the button.
    private var isEnabled: Bool {
        markers.isEnabled && !model.coordinator.markerLoggingBroken
    }

    var body: some View {
        if markers.showsVoiceControl || markers.showsParagraphControl {
            HStack(spacing: 16) {
                if markers.showsVoiceControl {
                    Button(activeVoice) { model.coordinator.markVoice(otherVoice) }
                        .accessibilityIdentifier("capture.voiceSwitch")
                }
                if markers.showsParagraphControl {
                    Button("¶ Paragraph") { model.coordinator.markParagraph() }
                        .accessibilityIdentifier("capture.paragraph")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!isEnabled)
            .opacity(isEnabled ? 1 : 0.45)
            // The capture screen's background is near-black regardless of the app's
            // color scheme; an ambient-scheme system control renders dark-on-dark in
            // light mode (smoke feedback 2026-08-02) — same rule as the setup fields.
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
}
