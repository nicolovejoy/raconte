import XCTest
@testable import Raconte

/// T7 Task 4 — the transcript editor's whole behaviour. `TranscriptEditorView` is a thin
/// binding over `TranscriptEditorModel`, so everything with a rule in it is here.
///
/// Two kinds of fixture, deliberately:
/// - **`FakeEditorStore`** for the states disk cannot express independently — a `writeDraft`
///   that throws while `chainSnapshot` still says `.editable` is exactly the field case
///   (an entry trashed on another screen while the editor is open) and exactly the case a
///   disk fixture can't build, because trashing it on disk would also flip the snapshot.
/// - **A real `LibraryScreenModel` over a temp directory** for the round-trip law: `done()`
///   must mint a revision whose `plainText` IS the edited text (design §15b.11). Only the
///   real splice can prove that; a fake would prove the test's own arithmetic.
@MainActor
final class TranscriptEditorModelTests: XCTestCase {

    private var containerRoot: URL!
    private var capturesRoot: URL { AppContainer.capturesRoot(containerRoot: containerRoot) }
    private let captureID = "01KYX77KK5QM15915EZBVXTQZ4"

    override func setUpWithError() throws {
        containerRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("TranscriptEditor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: containerRoot)
    }

    // MARK: - Fixtures

    private var captureDirectory: URL {
        SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
    }

    private var transcriptDirectory: URL {
        SegmentLayout.transcriptDirectory(captureDirectory: captureDirectory)
    }

    private var draftURL: URL {
        SegmentLayout.transcriptDraftURL(captureDirectory: captureDirectory)
    }

    private func store() -> TranscriptRevisionStore { TranscriptRevisionStore(capturesRoot: capturesRoot) }

    private func liveModel() -> LibraryScreenModel {
        LibraryScreenModel(capturesRoot: capturesRoot, journalsContainerRoot: containerRoot)
    }

    private func revision(_ id: String, source: RevisionSource = .machineLive, secondsOffset: Double = 0,
                          text: String) -> TranscriptRevision {
        TranscriptRevision(id: id, source: source,
                           createdAt: Date(timeIntervalSince1970: 1_700_000_000 + secondsOffset),
                           spans: [TranscriptSpan(text: text, anchor: .none)])
    }

    private func canonicalFileCount() throws -> Int {
        guard case .present(let files) = TranscriptRevisionStore.listing(captureDirectory: captureDirectory) else {
            return 0
        }
        return files.count
    }

    private func currentRevision() -> TranscriptRevision? {
        guard let load = TranscriptRevisionStore.loadChain(captureDirectory: captureDirectory) else { return nil }
        return TranscriptChain.current(TranscriptChain.ordered(load.revisions))
    }

    private func writeDraftFile(text: String, openedAt: Date, lastWriteAt: Date,
                                parentID: String? = nil) throws {
        try FileManager.default.createDirectory(at: transcriptDirectory, withIntermediateDirectories: true)
        let draft = TranscriptDraft(captureID: captureID, parentID: parentID, basedOnMachineID: parentID,
                                    openedAt: openedAt, lastWriteAt: lastWriteAt, text: text)
        try CaptureCoding.encoder().encode(draft).write(to: draftURL)
    }

    /// A capture whose sidecar exists and is undecodable — `.readOnlyMetadataUnreadable`.
    private func corruptSidecar() throws {
        try Data("{ not json".utf8)
            .write(to: SegmentLayout.entryMetadataURL(captureDirectory: captureDirectory))
    }

    private func markTrashed() throws {
        var metadata = EntryMetadata()
        metadata.trashedAt = Date(timeIntervalSince1970: 1_700_000_500)
        try EntryMetadataStore.write(metadata,
                                     url: SegmentLayout.entryMetadataURL(captureDirectory: captureDirectory))
    }

    /// A `live.jsonl` with one committed record — the machine transcript the degraded-chain
    /// refusal offers read-only (Q5).
    private func writeLiveLog(text: String) throws {
        let writer = LiveTranscriptWriter(captureDirectory: captureDirectory)
        try writer.open()
        try writer.append(TranscriptRecord(seq: 0, text: text,
                                           captureFrameStart: 0, captureFrameEnd: 20_000,
                                           generator: "SpeechTranscriber", locale: "en_US"))
        try writer.close()
    }

    private func editor(_ store: any TranscriptEditorStore,
                        debounce: ManualDebounce = ManualDebounce(),
                        clock: TestClock = TestClock(1_700_001_000)) -> TranscriptEditorModel {
        TranscriptEditorModel(captureID: captureID, store: store, debounce: debounce,
                              debounceSeconds: 2, clock: clock.callable)
    }

    // MARK: - 4.1 open()

    func testOpenOnHealthyChainStartsEditingWithCurrentText() async throws {
        try await store().append(revision("R0", text: "the machine text"), captureID: captureID)

        let model = editor(liveModel())
        await model.open()

        XCTAssertEqual(model.state, .editing)
        XCTAssertEqual(model.text, "the machine text")
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertFalse(model.resumedFromDraft)
        XCTAssertNil(model.machineTranscript)
        XCTAssertTrue(model.showsTextEditor)
    }

    /// Resume beats reload: an open `draft.json` whose text differs from `current` is what
    /// the editor opens with. The fixture's draft and current text differ in BOTH directions
    /// (neither is a prefix or a truncation of the other), so returning `currentText` — the
    /// obvious wrong answer — cannot accidentally satisfy the assertion.
    func testOpenWithDraftResumesTheDraftTextNotCurrent() async throws {
        try await store().append(revision("R0", text: "the machine text"), captureID: captureID)
        try writeDraftFile(text: "my half-finished edit",
                           openedAt: Date(timeIntervalSince1970: 1_700_000_900),
                           lastWriteAt: Date(timeIntervalSince1970: 1_700_000_950),
                           parentID: "R0")

        let model = editor(liveModel())
        await model.open()

        XCTAssertEqual(model.state, .editing)
        XCTAssertEqual(model.text, "my half-finished edit")
        XCTAssertTrue(model.resumedFromDraft, "a draft differing from current is a resume")
        XCTAssertTrue(model.hasUnsavedChanges)
    }

    /// A draft whose text already equals `current` is not a "resume" to announce — there is
    /// nothing unsaved in it — even though the file is on disk and `done()` must still
    /// delete it.
    func testOpenWithDraftMatchingCurrentIsNotAnnouncedAsAResume() async throws {
        try await store().append(revision("R0", text: "the machine text"), captureID: captureID)
        try writeDraftFile(text: "the machine text",
                           openedAt: Date(timeIntervalSince1970: 1_700_000_900),
                           lastWriteAt: Date(timeIntervalSince1970: 1_700_000_950),
                           parentID: "R0")

        let model = editor(liveModel())
        await model.open()

        XCTAssertEqual(model.text, "the machine text")
        XCTAssertFalse(model.resumedFromDraft)
        XCTAssertFalse(model.hasUnsavedChanges)
    }

    /// Hazard (c), the `hasDraft` TOCTOU, going live now that the editor is the app's first
    /// real draft writer: `LibraryScreenModel.hasDraft` is a `nonisolated` existence check
    /// used by entry-open, and a draft written after it answers `false` is invisible to that
    /// caller. The behaviour pinned here is the editor's chosen answer — `open()` never
    /// consults `hasDraft`, it reads the draft itself through `chainSnapshot`, so a draft
    /// that appears after any such check is still resumed rather than silently discarded.
    func testOpenResumesADraftThatAppearedAfterHasDraftAnsweredFalse() async throws {
        try await store().append(revision("R0", text: "the machine text"), captureID: captureID)
        let model = liveModel()
        XCTAssertFalse(model.hasDraft(captureID), "precondition: no draft yet")

        try writeDraftFile(text: "written after the check",
                           openedAt: Date(timeIntervalSince1970: 1_700_000_900),
                           lastWriteAt: Date(timeIntervalSince1970: 1_700_000_950),
                           parentID: "R0")

        let editorModel = editor(model)
        await editorModel.open()

        XCTAssertEqual(editorModel.text, "written after the check")
    }

    /// Q4: trashed refuses outright — no text, no machine transcript, no edit-with-a-warning
    /// path. The fixture's chain is HEALTHY and non-empty (the snapshot still reports its
    /// `currentText` for the history panel), so "offers no text" is a real assertion rather
    /// than a fact about an empty fixture.
    func testOpenOnTrashedEntryRefusesAndOffersNoText() async throws {
        try await store().append(revision("R0", text: "the machine text"), captureID: captureID)
        try markTrashed()

        let model = editor(liveModel())
        await model.open()

        XCTAssertEqual(model.state, .readOnly(.readOnlyTrashed))
        XCTAssertEqual(model.text, "")
        XCTAssertNil(model.machineTranscript)
        XCTAssertFalse(model.showsTextEditor)
        XCTAssertTrue(TranscriptEditorModel.readOnlySentence(.readOnlyTrashed).contains("Restore it first"))
    }

    /// Q5: a degraded chain refuses AND offers the un-edited machine transcript read-only.
    /// The `live.jsonl` text differs from the corrupt revision's text, so the assertion
    /// cannot be satisfied by any accidental fallthrough to the chain.
    func testOpenOnUnreadableRevisionRefusesAndOffersTheMachineTranscript() async throws {
        try FileManager.default.createDirectory(at: transcriptDirectory, withIntermediateDirectories: true)
        try Data("{ truncated".utf8).write(
            to: SegmentLayout.canonicalTranscriptURL(captureDirectory: captureDirectory, revision: 0))
        try writeLiveLog(text: "what the machine heard")

        let model = editor(liveModel())
        await model.open()

        XCTAssertEqual(model.state, .readOnly(.readOnlyUnreadableRevision(file: 0)))
        XCTAssertEqual(model.text, "", "a degraded chain offers reading, never editing")
        XCTAssertEqual(model.machineTranscript, "what the machine heard")
        XCTAssertFalse(model.showsTextEditor)
        XCTAssertTrue(TranscriptEditorModel.readOnlySentence(.readOnlyUnreadableRevision(file: 7))
                        .contains("7"),
                      "the sentence must name the actual file")
    }

    /// The other degraded-chain shape (§4.5a). It takes the same Q5 branch, but the offer
    /// comes back EMPTY and must — `live.jsonl` lives inside the very folder we could not
    /// read, so "refuse, then offer the machine transcript" has nothing to offer here. Pinned
    /// rather than left implicit, so nobody later reads the nil as a missed case and "fixes"
    /// it into a claim the disk cannot support.
    func testOpenOnUnreadableListingRefusesWithNoMachineTranscriptToOffer() async throws {
        try Data("not a directory".utf8).write(to: transcriptDirectory)

        let model = editor(liveModel())
        await model.open()

        guard case .readOnly(.readOnlyListingUnreadable(let reason)) = model.state else {
            return XCTFail("expected .readOnlyListingUnreadable, got \(model.state)")
        }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertNil(model.machineTranscript, "the log lives inside the folder we cannot read")
        XCTAssertFalse(model.showsTextEditor)
        // Review finding 3: the diagnostic payload must reach the screen, not be swallowed by
        // a case that matched without binding it.
        XCTAssertTrue(TranscriptEditorModel.readOnlySentence(.readOnlyListingUnreadable(reason))
                        .contains(reason),
                      "the sentence must name the actual reason")
    }

    /// Re-opening the same model instance (navigate back into the editor) is a fresh session:
    /// a notice about a draft closed beneath the LAST session must not still be on screen.
    func testReopeningClearsTheBeneathSessionNotice() async throws {
        try await store().append(revision("R0", text: "the machine text"), captureID: captureID)
        let library = liveModel()
        let clock = TestClock(1_700_001_000)
        let model = editor(library, clock: clock)
        await model.open()
        model.text = "an edit"
        model.textChanged()
        await model.flush()
        _ = await library.revisionStore.closeStaleDraftIfNeeded(
            captureID: captureID, now: Date(timeIntervalSince1970: 1_700_001_200))
        clock.now = Date(timeIntervalSince1970: 1_700_001_400)
        model.text = "an edit, continued"
        model.textChanged()
        await model.flush()
        XCTAssertTrue(model.draftClosedBeneathSession, "precondition")

        await model.open()

        XCTAssertFalse(model.draftClosedBeneathSession)
    }

    /// Hazard (b): `.readOnlyNoTranscript` is the one case where the STORE would let the
    /// write through — `writeDraft` against a capture with no chain succeeds and creates a
    /// `draft.json`. The editor owns this guard, so it must gate on editability and never on
    /// "the write didn't throw".
    func testOpenWithNothingTranscribedRefusesAndNeverWrites() async throws {
        let live = liveModel()
        let model = editor(live)
        await model.open()

        XCTAssertEqual(model.state, .readOnly(.readOnlyNoTranscript))
        XCTAssertNil(model.machineTranscript)

        model.text = "typing into a refused editor"
        model.textChanged()
        await model.flush()
        let done = await model.done()

        XCTAssertEqual(model.text, "", "text is unmodifiable in a read-only state")
        XCTAssertTrue(done, "leaving a read-only editor is not a failure")
        XCTAssertFalse(FileManager.default.fileExists(atPath: draftURL.path),
                       "the store would have accepted this write — the editor must not make it")
        XCTAssertEqual(try canonicalFileCount(), 0)
    }

    /// The owner ruling from Task 2: an undecodable `entry.json` gets its OWN case, never
    /// `.readOnlyTrashed`. Pinned here because the editor's sentence for it must not offer
    /// restore/delete affordances for an entry that is not in the trash.
    func testOpenWithUndecodableSidecarReportsItsOwnCaseNotTrashed() async throws {
        try await store().append(revision("R0", text: "the machine text"), captureID: captureID)
        try corruptSidecar()

        let model = editor(liveModel())
        await model.open()

        guard case .readOnly(.readOnlyMetadataUnreadable(let reason)) = model.state else {
            return XCTFail("expected .readOnlyMetadataUnreadable, got \(model.state)")
        }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertNil(model.machineTranscript)
        let sentence = TranscriptEditorModel.readOnlySentence(.readOnlyMetadataUnreadable(reason))
        XCTAssertFalse(sentence.lowercased().contains("trash"),
                       "a corrupt sidecar is not a tombstone: \(sentence)")
        // Review finding 3.
        XCTAssertTrue(sentence.contains(reason), "the sentence must name the actual reason")
    }

    // MARK: - 4.2 debounce

    /// Change detector on §12.1's window (review finding 4). Every behavioural test injects
    /// its own debounce window — they drive an injected timer — so the initializer's default
    /// was exercised by nothing at all: changing it to 20 s left the whole suite green. Same
    /// shape as `RevisionGrowthAlarmTests.testThresholdIsFifty`.
    func testDebounceWindowDefaultsToTwoSeconds() {
        XCTAssertEqual(TranscriptEditorModel.defaultDebounceSeconds, 2)

        let model = TranscriptEditorModel(captureID: captureID,
                                          store: FakeEditorStore.editable(currentText: "x"))

        XCTAssertEqual(model.debounceSeconds, 2,
                       "the initializer default must be the named constant, not its own literal")
    }

    /// §12.1's 2 s debounce, cancelled and re-armed per keystroke. Five keystrokes inside
    /// one window write NOTHING until the window elapses, and then write exactly once — the
    /// latest text, not five snapshots of a word being typed.
    ///
    /// No `Task.sleep` anywhere: the timer is injected (`ManualDebounce`), so this is an
    /// assertion rather than a race. `armCount` is load-bearing, not mock-gazing — it is the
    /// only deterministic witness that the keystroke SCHEDULED rather than wrote, which is
    /// the whole behaviour under test.
    func testKeystrokesInsideTheDebounceWindowProduceExactlyOneWrite() async {
        let store = FakeEditorStore.editable(currentText: "the machine text")
        let debounce = ManualDebounce()
        let model = editor(store, debounce: debounce)
        await model.open()

        for typed in ["t", "th", "thi", "this", "this is mine"] {
            model.text = typed
            model.textChanged()
        }

        XCTAssertEqual(store.writeDraftCalls, [], "nothing may reach disk mid-word")
        XCTAssertEqual(debounce.armCount, 5, "every keystroke re-arms the window")
        XCTAssertTrue(debounce.isArmed)
        XCTAssertTrue(model.hasUnsavedChanges)

        await debounce.fire()

        XCTAssertEqual(store.writeDraftCalls, ["this is mine"],
                       "one write when the window elapses, of the latest text")
        XCTAssertFalse(model.hasUnsavedChanges)
    }

    /// The other half of the debounce, which no injected timer can pin: `TaskEditorDebounce`
    /// must CANCEL the window it already armed, or five keystrokes become five timers that
    /// all eventually fire. Tested directly on the shipping timer, so removing its
    /// `task?.cancel()` cannot pass the suite.
    ///
    /// The deliberate exception to "no sleeping in a debounce test": here the clock IS the
    /// subject. The window is 20 ms and the wait is an order of magnitude longer.
    func testTaskEditorDebounceCancelsThePreviouslyArmedWindow() async throws {
        let debounce = TaskEditorDebounce()
        let fired = Counter()

        for payload in ["first", "second", "third"] {
            debounce.arm(after: 0.02) { await fired.record(payload) }
        }
        try await Task.sleep(for: .milliseconds(400))

        let recorded = await fired.values
        XCTAssertEqual(recorded, ["third"], "re-arming must cancel the window it replaced")
    }

    /// Found while wiring the view (4.6). `TranscriptEditorView` observes the text with
    /// `.onChange(of: model.text)`, and SwiftUI compares values across body evaluations — so
    /// the moment `open()` fills the text and flips `state` to `.editing`, the body
    /// re-evaluates, the value has changed from `""`, and `textChanged()` fires for an edit
    /// nobody made. Left alone that arms the debounce and writes a `draft.json` for merely
    /// OPENING an entry to read it, and makes `hasUnsavedChanges` claim unsaved work.
    ///
    /// The editor must treat "the text is what I just loaded" as no change at all.
    func testOpeningAndLeavingWithoutTypingWritesNothing() async throws {
        try await store().append(revision("R0", text: "the machine text"), captureID: captureID)

        let debounce = ManualDebounce()
        let model = editor(liveModel(), debounce: debounce)
        await model.open()

        model.textChanged()                 // what .onChange(of:) does on the load itself

        XCTAssertFalse(model.hasUnsavedChanges, "loading text is not an edit")
        XCTAssertFalse(debounce.isArmed, "no window may be armed for an edit nobody made")

        await debounce.fire()
        let done = await model.done()

        XCTAssertTrue(done)
        XCTAssertFalse(FileManager.default.fileExists(atPath: draftURL.path),
                       "opening an entry to read it must not leave a draft behind")
        XCTAssertEqual(try canonicalFileCount(), 1)
    }

    /// The other half: a resumed draft's text is likewise not a fresh edit, but it IS
    /// genuinely unsaved, so `hasUnsavedChanges` must stay true while the debounce stays
    /// unarmed. Two properties that a single "reset everything on load" fix would conflate.
    func testResumedDraftTextIsUnsavedButNotAFreshEdit() async throws {
        try await store().append(revision("R0", text: "the machine text"), captureID: captureID)
        try writeDraftFile(text: "my half-finished edit",
                           openedAt: Date(timeIntervalSince1970: 1_700_000_900),
                           lastWriteAt: Date(timeIntervalSince1970: 1_700_000_950),
                           parentID: "R0")

        let debounce = ManualDebounce()
        let model = editor(liveModel(), debounce: debounce)
        await model.open()

        model.textChanged()

        XCTAssertTrue(model.hasUnsavedChanges, "the draft really is unsaved work")
        XCTAssertFalse(debounce.isArmed, "but loading it is still not a keystroke")
    }

    // MARK: - 4.3 done()

    /// §2.5: a draft whose text equals `current` closes to NOTHING — the file is deleted and
    /// no revision is minted. The store already does this; what is pinned here is that the
    /// editor does not work around it (by skipping `closeDraft` and leaving the file, or by
    /// forcing a mint of text nobody changed).
    ///
    /// The fixture is a REAL resumed draft on disk, not an absent one: with no draft at all
    /// the "draft was deleted" assertion would hold vacuously.
    func testDoneWithUnchangedTextMintsNothingAndDeletesTheDraft() async throws {
        try await store().append(revision("R0", text: "the machine text"), captureID: captureID)
        try writeDraftFile(text: "the machine text",
                           openedAt: Date(timeIntervalSince1970: 1_700_000_900),
                           lastWriteAt: Date(timeIntervalSince1970: 1_700_000_950),
                           parentID: "R0")
        XCTAssertTrue(FileManager.default.fileExists(atPath: draftURL.path), "precondition")

        let model = editor(liveModel())
        await model.open()
        let done = await model.done()

        XCTAssertTrue(done)
        XCTAssertEqual(try canonicalFileCount(), 1, "nothing may be minted for an unchanged edit")
        XCTAssertFalse(FileManager.default.fileExists(atPath: draftURL.path), "the draft is closed, not left")
    }

    /// The round-trip postcondition design §15b.11 makes law, through the real splice: after
    /// Done, `current` is a `.userEdit` revision whose flattened text IS what was typed.
    ///
    /// Deliberately edited in the MIDDLE (a word replaced, not appended): an implementation
    /// that concatenated, or that dropped the parent's spans, or that stored the whole text
    /// as one span, all differ here — where "append a suffix" would let several of them pass.
    func testDoneWithChangedTextMintsExactlyOneUserEditWhosePlainTextIsTheEdit() async throws {
        try await store().append(revision("R0", text: "the machine herd these words"),
                                 captureID: captureID)

        let model = editor(liveModel())
        await model.open()
        model.text = "the machine heard these words"
        model.textChanged()
        let done = await model.done()

        XCTAssertTrue(done)
        XCTAssertEqual(try canonicalFileCount(), 2, "exactly one new revision")
        let current = try XCTUnwrap(currentRevision())
        XCTAssertEqual(current.source, .userEdit)
        XCTAssertEqual(TranscriptChain.plainText(current), "the machine heard these words")
        XCTAssertEqual(current.parentID, "R0")
        XCTAssertEqual(current.basedOnMachineID, "R0")
        XCTAssertEqual(current.closedBy, .sessionEnd)
        XCTAssertFalse(FileManager.default.fileExists(atPath: draftURL.path))
        XCTAssertFalse(model.hasUnsavedChanges)
    }

    // MARK: - 4.4 failures are loud

    /// The 2026-08-03 detail-trash contract, applied to the editor: a save that failed says
    /// so and nothing dismisses. `chainSnapshot` still reports `.editable` here — the entry
    /// was trashed on another screen after this editor opened — which is precisely the
    /// disagreement a disk fixture cannot build.
    func testWriteDraftThrowSurfacesAsFailedAndKeepsTheText() async {
        let store = FakeEditorStore.editable(currentText: "the machine text")
        let debounce = ManualDebounce()
        let model = editor(store, debounce: debounce)
        await model.open()

        model.text = "an edit that cannot be saved"
        model.textChanged()
        store.writeDraftError = TranscriptRevisionStoreError.trashedCapture
        await debounce.fire()

        guard case .failed(let reason) = model.state else {
            return XCTFail("expected .failed, got \(model.state)")
        }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertEqual(model.text, "an edit that cannot be saved", "a failed save never eats the words")
        XCTAssertTrue(model.hasUnsavedChanges)
        XCTAssertTrue(model.isEditable, "the owner must be able to keep typing and try again")

        let done = await model.done()
        XCTAssertFalse(done, "the caller must not dismiss")
        XCTAssertEqual(store.closeDraftCalls, [], "a draft that never saved is not closed")
    }

    /// A later successful flush clears the failure — the banner must not outlive the problem.
    func testASuccessfulFlushAfterAFailureReturnsToEditing() async {
        let store = FakeEditorStore.editable(currentText: "the machine text")
        let debounce = ManualDebounce()
        let model = editor(store, debounce: debounce)
        await model.open()

        model.text = "first try"
        model.textChanged()
        store.writeDraftError = TranscriptRevisionStoreError.trashedCapture
        await debounce.fire()
        guard case .failed = model.state else { return XCTFail("expected .failed, got \(model.state)") }

        store.writeDraftError = nil
        model.text = "second try"
        model.textChanged()
        await debounce.fire()

        XCTAssertEqual(model.state, .editing)
        // Attempts, not successes (see `FakeEditorStore.writeDraftCalls`): the failed first
        // write is recorded too, which makes this the stronger claim — the editor really did
        // try, fail, and then try again, rather than never having attempted the first one.
        XCTAssertEqual(store.writeDraftCalls, ["first try", "second try"])
    }

    /// A `closeDraft` that throws makes `done()` return `false`. The draft itself saved fine,
    /// so the words are safe on disk — but the screen must not pretend the edit was closed.
    func testCloseDraftThrowMakesDoneReturnFalse() async {
        let store = FakeEditorStore.editable(currentText: "the machine text")
        let debounce = ManualDebounce()
        let model = editor(store, debounce: debounce)
        await model.open()

        model.text = "saved as a draft, but not closeable"
        model.textChanged()
        store.closeDraftError = TranscriptRevisionStoreError.revisionUnreadable(file: 3)

        let done = await model.done()

        XCTAssertFalse(done)
        XCTAssertEqual(store.writeDraftCalls, ["saved as a draft, but not closeable"],
                       "the flush still happened — only the close failed")
        guard case .failed = model.state else { return XCTFail("expected .failed, got \(model.state)") }
    }

    /// Review finding 1. The alert on a failed Done says "Try Done again" — so trying again
    /// must actually try. The failure mode this pins: the draft flushed successfully (so
    /// `hasUnsavedChanges` is false), then `closeDraft` threw. If the next `done()` decides
    /// whether to close by looking at `state`, the leftover `.failed` short-circuits it and
    /// the store is never reached again — the screen's own recovery affordance is dead
    /// against exactly the transient failures (I/O, a §15b.15 refusal that a re-promote
    /// clears) it exists for, and the only escape is typing a character.
    ///
    /// The store recovers between the two calls, so `closeDraftCalls.count` distinguishes
    /// "retried and succeeded" from "returned false without trying" — a single `done()`, as
    /// the original test made, cannot tell those apart.
    func testDoneRetriesTheCloseAfterATransientCloseFailure() async {
        let store = FakeEditorStore.editable(currentText: "the machine text")
        let debounce = ManualDebounce()
        let model = editor(store, debounce: debounce)
        await model.open()

        model.text = "an edit worth keeping"
        model.textChanged()
        await debounce.fire()
        XCTAssertEqual(store.writeDraftCalls, ["an edit worth keeping"], "precondition: the draft saved")
        XCTAssertFalse(model.hasUnsavedChanges, "precondition: nothing left to flush")

        store.closeDraftError = TranscriptRevisionStoreError.revisionUnreadable(file: 3)
        let first = await model.done()
        XCTAssertFalse(first)
        XCTAssertEqual(store.closeDraftCalls.count, 1)
        guard case .failed = model.state else { return XCTFail("expected .failed, got \(model.state)") }

        store.closeDraftError = nil
        let second = await model.done()

        XCTAssertTrue(second, "a transient close failure must be retryable without typing")
        XCTAssertEqual(store.closeDraftCalls.count, 2, "the retry has to reach the store")
        XCTAssertEqual(model.state, .editing, "the banner must not outlive the problem")
    }

    /// The other side of the same fix: a flush that genuinely fails must still block the
    /// close, so "retryable" never becomes "closes over a draft that never saved".
    func testDoneStillRefusesToCloseWhileTheFlushItselfIsFailing() async {
        let store = FakeEditorStore.editable(currentText: "the machine text")
        let model = editor(store)
        await model.open()

        model.text = "an edit that cannot be saved"
        model.textChanged()
        store.writeDraftError = TranscriptRevisionStoreError.trashedCapture

        let first = await model.done()
        let second = await model.done()

        XCTAssertFalse(first)
        XCTAssertFalse(second)
        XCTAssertEqual(store.closeDraftCalls, [], "never close over a draft that never saved")
    }

    // MARK: - Navigating away IS Done (review finding 2)

    /// Ruling Q1: "Navigating away, backgrounding past the store's stale rules, and the Done
    /// button are the same path." The editor is a `navigationDestination` push, so system Back
    /// and interactive swipe-back are always available — and took neither path.
    ///
    /// The keystrokes here are still INSIDE the debounce window (the timer is never fired),
    /// which is the losing case: on Back, the model's only strong reference is the detail
    /// screen's `@State`, and the armed window holds `[weak self]`, so popping both screens
    /// inside 2 s deallocated the model and the pending `writeDraft` simply never happened —
    /// last keystrokes gone, no error, no trace.
    func testFinishIfNeededFlushesPendingKeystrokesAndClosesExactlyOnce() async {
        let store = FakeEditorStore.editable(currentText: "the machine text")
        let debounce = ManualDebounce()
        let model = editor(store, debounce: debounce)
        await model.open()

        model.text = "typed, then backed out"
        model.textChanged()
        XCTAssertTrue(debounce.isArmed, "precondition: still inside the debounce window")

        let first = await model.finishIfNeeded()
        let second = await model.finishIfNeeded()

        XCTAssertTrue(first)
        XCTAssertTrue(second)
        XCTAssertEqual(store.writeDraftCalls, ["typed, then backed out"],
                       "the window's pending keystrokes must be written, not dropped")
        XCTAssertEqual(store.closeDraftCalls, [.sessionEnd],
                       "closed exactly once — the Done path and the pop path must not double-close")
    }

    /// The data-loss half, through the real store: back out inside the debounce window and the
    /// edit must be a minted revision, not a lost one. Without this, `EntryDetailView`'s
    /// `rescan()` + `refresh()` on dismissal re-renders the PRE-edit transcript, and the
    /// stale-draft sweep will not touch a seconds-old draft (`sessionEndSeconds = 90`) — so
    /// the owner backs out and watches their edit vanish.
    func testBackingOutInsideTheDebounceWindowMintsTheEdit() async throws {
        try await store().append(revision("R0", text: "the machine herd these words"),
                                 captureID: captureID)

        let debounce = ManualDebounce()
        let model = editor(liveModel(), debounce: debounce)
        await model.open()
        model.text = "the machine heard these words"
        model.textChanged()

        await model.finishIfNeeded()            // what popping the editor must do

        XCTAssertEqual(try canonicalFileCount(), 2)
        let current = try XCTUnwrap(currentRevision())
        XCTAssertEqual(TranscriptChain.plainText(current), "the machine heard these words")
        XCTAssertEqual(current.source, .userEdit)
        XCTAssertFalse(FileManager.default.fileExists(atPath: draftURL.path))
    }

    /// The idempotence guard is per SESSION, not per model. `EntryDetailView` holds ONE editor
    /// model in `@State` for the life of the screen, so a guard that never reset would make
    /// every visit after the first silently refuse to save.
    func testReopeningAllowsFinishingAgain() async {
        let store = FakeEditorStore.editable(currentText: "the machine text")
        let model = editor(store)
        await model.open()
        model.text = "first visit"
        model.textChanged()
        await model.finishIfNeeded()
        XCTAssertEqual(store.closeDraftCalls.count, 1, "precondition")

        await model.open()
        model.text = "second visit"
        model.textChanged()
        await model.finishIfNeeded()

        XCTAssertEqual(store.writeDraftCalls, ["first visit", "second visit"])
        XCTAssertEqual(store.closeDraftCalls.count, 2, "a second visit must be closeable too")
    }

    /// A finish that FAILED must not latch: the owner is gone, but the next attempt (a later
    /// visit, or the Done button after a failed Back) has to be able to try again.
    func testAFailedFinishDoesNotLatchAsFinished() async {
        let store = FakeEditorStore.editable(currentText: "the machine text")
        let model = editor(store)
        await model.open()
        model.text = "an edit"
        model.textChanged()
        store.closeDraftError = TranscriptRevisionStoreError.revisionUnreadable(file: 3)

        let failed = await model.finishIfNeeded()
        store.closeDraftError = nil
        let retried = await model.finishIfNeeded()

        XCTAssertFalse(failed)
        XCTAssertTrue(retried)
        XCTAssertEqual(store.closeDraftCalls.count, 2, "a failed finish must stay retryable")
    }

    // MARK: - 4.5 backgrounding

    /// `scenePhase` leaving `.active` calls `flush()`. What matters is the consequence: a
    /// SEPARATE editor opened afterwards resumes the flushed text, not the pre-edit text.
    /// Real store, so the resume travels through `draft.json` on disk exactly as it does on
    /// device after the app is backgrounded and comes back.
    func testBackgroundFlushIsResumedByASubsequentOpen() async throws {
        try await store().append(revision("R0", text: "the machine text"), captureID: captureID)

        let first = editor(liveModel())
        await first.open()
        first.text = "typed, then backgrounded"
        first.textChanged()
        await first.flush()                     // what .onChange(of: scenePhase) does

        XCTAssertTrue(FileManager.default.fileExists(atPath: draftURL.path))
        XCTAssertFalse(first.hasUnsavedChanges)

        let second = editor(liveModel())
        await second.open()

        XCTAssertEqual(second.text, "typed, then backgrounded")
        XCTAssertTrue(second.resumedFromDraft)
        XCTAssertEqual(try canonicalFileCount(), 1, "a flush is a draft write, never a mint")
    }

    /// Hazard (a): `EntryDetailView.refresh()` also runs after a backdate save/clear and a
    /// journal move, each closing drafts idle past `DraftPolicy.sessionEndSeconds` with
    /// reason `.recovered` — so an idle-but-open editor's draft really is minted and deleted
    /// beneath it. The editor must notice, keep every visible character, and write forward
    /// from the recovered revision rather than over it.
    func testADraftClosedBeneathTheSessionIsNoticedAndTheEditWritesForward() async throws {
        try await store().append(revision("R0", text: "the machine text"), captureID: captureID)
        let library = liveModel()
        let clock = TestClock(1_700_001_000)
        let model = editor(library, clock: clock)
        await model.open()

        model.text = "first pass of my edit"
        model.textChanged()
        await model.flush()

        // Two minutes idle, then an unrelated backdate save runs refresh() → the stale-draft
        // sweep closes THIS draft into a `.recovered` revision and deletes the file.
        let recovered = await library.revisionStore.closeStaleDraftIfNeeded(
            captureID: captureID, now: Date(timeIntervalSince1970: 1_700_001_200))
        clock.now = Date(timeIntervalSince1970: 1_700_001_400)
        XCTAssertNotNil(recovered, "precondition: the sweep really did close our draft")
        XCTAssertFalse(FileManager.default.fileExists(atPath: draftURL.path))
        XCTAssertFalse(model.draftClosedBeneathSession, "nothing has looked yet")

        model.text = "first pass of my edit, continued"
        model.textChanged()
        await model.flush()

        XCTAssertTrue(model.draftClosedBeneathSession, "the editor must notice, not carry on blind")
        XCTAssertEqual(model.text, "first pass of my edit, continued", "no visible character is lost")

        let draft = try XCTUnwrap(TranscriptRevisionStore.readDraft(captureDirectory: captureDirectory))
        XCTAssertEqual(draft.text, "first pass of my edit, continued")
        XCTAssertEqual(draft.parentID, recovered,
                       "the fresh draft is parented on the recovered revision, not on the one it replaced")

        let closed = await model.done()
        XCTAssertTrue(closed)
        let current = try XCTUnwrap(currentRevision())
        XCTAssertEqual(TranscriptChain.plainText(current), "first pass of my edit, continued")
        XCTAssertEqual(current.parentID, recovered)
        XCTAssertEqual(try canonicalFileCount(), 3, "R0, the recovered revision, and this one")
    }
}

// MARK: - Doubles

/// Records what a debounce actually fired, across actor boundaries.
actor Counter {
    private(set) var values: [String] = []
    func record(_ value: String) { values.append(value) }
}

/// A clock the test advances by hand. Revision order is `(createdAt, id)`, so a fixture
/// where the editor's own clock stands still while an unrelated sweep mints a revision
/// "later" would put the sweep's revision at the head of the chain — a fixture artifact, not
/// the behaviour under test. Advancing this makes the ordering the real one.
final class TestClock: @unchecked Sendable {
    var now: Date

    init(_ epochSeconds: TimeInterval) { self.now = Date(timeIntervalSince1970: epochSeconds) }

    var callable: @Sendable () -> Date { { [self] in now } }
}

/// A debounce whose timer only fires when the test says so — no `Task.sleep` anywhere, so
/// "N keystrokes produce one write" is a deterministic assertion, not a race.
@MainActor
final class ManualDebounce: EditorDebounce {
    private(set) var armCount = 0
    private(set) var cancelCount = 0
    private var pending: (@MainActor () async -> Void)?

    var isArmed: Bool { pending != nil }

    func arm(after seconds: TimeInterval, _ fire: @escaping @MainActor () async -> Void) {
        armCount += 1
        pending = fire
    }

    func cancel() {
        cancelCount += 1
        pending = nil
    }

    /// Fires the one armed action, if any — what a real 2 s window elapsing does.
    func fire() async {
        let action = pending
        pending = nil
        await action?()
    }
}

/// A store the test drives directly, for the disagreements disk cannot express: a
/// `chainSnapshot` that says `.editable` while `writeDraft`/`closeDraft` refuse.
@MainActor
final class FakeEditorStore: TranscriptEditorStore {
    var snapshot: EntryChainSnapshot
    var machineTranscriptText: String?
    var draftOnDisk: TranscriptDraft?
    var writeDraftError: (any Error)?
    var closeDraftError: (any Error)?

    /// ATTEMPTS, not successes — both are recorded before the configured error is thrown.
    /// Recording only what succeeded makes "did the retry reach the store at all?"
    /// unanswerable, which is exactly the question review finding 1 turns on.
    private(set) var writeDraftCalls: [String] = []
    private(set) var closeDraftCalls: [DraftCloseReason] = []
    private(set) var snapshotCalls = 0

    init(snapshot: EntryChainSnapshot) {
        self.snapshot = snapshot
    }

    static func editable(currentText: String, draft: TranscriptDraft? = nil) -> FakeEditorStore {
        FakeEditorStore(snapshot: EntryChainSnapshot(
            editability: .editable, currentRevisionID: "R0", currentText: currentText,
            currentSource: .machineLive, revisionCount: 1, isForked: false, openDraft: draft,
            detachedMachineRevisions: [], chainByteSize: 0))
    }

    func chainSnapshot(for captureID: String) async -> EntryChainSnapshot {
        snapshotCalls += 1
        return snapshot
    }

    func machineTranscript(for captureID: String) async -> String? { machineTranscriptText }

    func openDraft(for captureID: String) async -> TranscriptDraft? { draftOnDisk }

    func writeDraft(captureID: String, text: String, now: Date) async throws {
        writeDraftCalls.append(text)
        if let writeDraftError { throw writeDraftError }
        draftOnDisk = TranscriptDraft(captureID: captureID,
                                      parentID: draftOnDisk?.parentID ?? snapshot.currentRevisionID,
                                      basedOnMachineID: draftOnDisk?.basedOnMachineID,
                                      openedAt: draftOnDisk?.openedAt ?? now,
                                      lastWriteAt: now, text: text)
    }

    @discardableResult
    func closeDraft(captureID: String, reason: DraftCloseReason, now: Date) async throws -> String? {
        closeDraftCalls.append(reason)
        if let closeDraftError { throw closeDraftError }
        let hadDraft = draftOnDisk != nil
        draftOnDisk = nil
        return hadDraft ? "minted" : nil
    }
}
