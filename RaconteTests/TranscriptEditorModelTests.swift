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
                        now: Date = Date(timeIntervalSince1970: 1_700_001_000)) -> TranscriptEditorModel {
        TranscriptEditorModel(captureID: captureID, store: store, debounce: debounce,
                              debounceSeconds: 2, clock: { now })
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
    }
}

// MARK: - Doubles

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
        if let writeDraftError { throw writeDraftError }
        writeDraftCalls.append(text)
        draftOnDisk = TranscriptDraft(captureID: captureID,
                                      parentID: draftOnDisk?.parentID ?? snapshot.currentRevisionID,
                                      basedOnMachineID: draftOnDisk?.basedOnMachineID,
                                      openedAt: draftOnDisk?.openedAt ?? now,
                                      lastWriteAt: now, text: text)
    }

    @discardableResult
    func closeDraft(captureID: String, reason: DraftCloseReason, now: Date) async throws -> String? {
        if let closeDraftError { throw closeDraftError }
        closeDraftCalls.append(reason)
        let hadDraft = draftOnDisk != nil
        draftOnDisk = nil
        return hadDraft ? "minted" : nil
    }
}
