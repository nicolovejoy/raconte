import XCTest
@testable import Raconte

/// T7 Task 8: the revision-history panel's whole behaviour. `RevisionHistoryView` is a
/// thin binding over `RevisionHistoryModel`, so every rule lives here (SwiftUI body
/// rendering is not reachable from `RaconteTests`), per the editor's and
/// marker-correction screen's own precedent.
///
/// Two fixture styles, deliberately: `buildRows` (8.1) is pure and tested directly off
/// hand-built `EntryChainSnapshot` values (no disk at all — mirrors
/// `TranscriptMergeTests`' 6.1-6.4). `revert` (8.2-8.4) is tested through a REAL
/// `TranscriptRevisionStore`/`LibraryScreenModel` pair on a temp captures root — the
/// brief's own instruction (context note 5): the degraded-chain and trashed-capture
/// refusals must surface through the real store guard, never a parallel check
/// reimplemented in this test file or in the model.
@MainActor
final class RevisionHistoryModelTests: XCTestCase {

    // MARK: - 8.1 buildRows: ordering, labeling, detached marking (pure, no disk)

    private func summary(_ id: String, source: RevisionSource, secondsOffset: Double,
                         fileNumber: Int, text: String = "text") -> TranscriptHeadSummary {
        TranscriptHeadSummary(id: id, fileNumber: fileNumber, source: source,
                              createdAt: Date(timeIntervalSince1970: 1_700_000_000 + secondsOffset),
                              characterCount: text.count, firstLine: text, isForked: false, snippet: text)
    }

    private func snapshot(current: TranscriptHeadSummary?,
                          detached: [TranscriptHeadSummary]) -> EntryChainSnapshot {
        EntryChainSnapshot(editability: .editable, currentRevisionID: current?.id,
                           currentText: "", currentSource: current?.source,
                           revisionCount: detached.count + (current != nil ? 1 : 0),
                           isForked: false, openDraft: nil,
                           detachedMachineRevisions: detached, currentSummary: current,
                           chainByteSize: 0)
    }

    /// Non-degenerate fixture (standing rule): two detached machine revisions appended
    /// out of chronological order (`M_LATE` before `M_EARLY` in the array), plus a
    /// human `current` whose `createdAt` sits BETWEEN them. A wrong ordering —
    /// insertion order, file-number order, or "current always first/last" — is
    /// representable here and would produce a different row order than the real
    /// `(createdAt, id)` chain order, so this test can actually fail.
    func testBuildRowsOrdersByCreatedAtAcrossCurrentAndDetachedTogether() {
        let mEarly = summary("M_EARLY", source: .machineLive, secondsOffset: 0, fileNumber: 0, text: "raw")
        let current = summary("CUR", source: .userEdit, secondsOffset: 20, fileNumber: 2, text: "edited")
        let mLate = summary("M_LATE", source: .machineRetranscribe, secondsOffset: 30, fileNumber: 3, text: "late")

        let snap = snapshot(current: current, detached: [mLate, mEarly])
        let rows = RevisionHistoryModel.buildRows(from: snap)

        XCTAssertEqual(rows.map(\.id), ["M_EARLY", "CUR", "M_LATE"],
                       "(createdAt, id) order across current AND detached together, not insertion order")
    }

    /// Labeling: each row's `source` matches its own revision, `isCurrent`/`isDetached`
    /// are mutually exclusive across the two row shapes this panel ever shows, and
    /// §12.8's "not applied" label (`isDetached`) is reserved for the detached rows —
    /// never `current`, even when `current` itself is machine-sourced (pinned
    /// separately below, since this fixture's current is human).
    func testBuildRowsLabelsEachRowMachineVsHumanAndMarksOnlyDetachedRows() {
        let mEarly = summary("M_EARLY", source: .machineLive, secondsOffset: 0, fileNumber: 0)
        let current = summary("CUR", source: .userEdit, secondsOffset: 20, fileNumber: 2)

        let snap = snapshot(current: current, detached: [mEarly])
        let rows = RevisionHistoryModel.buildRows(from: snap)

        let currentRow = try? XCTUnwrap(rows.first { $0.id == "CUR" })
        let detachedRow = try? XCTUnwrap(rows.first { $0.id == "M_EARLY" })
        XCTAssertEqual(currentRow?.source, .userEdit)
        XCTAssertTrue(currentRow?.isCurrent ?? false)
        XCTAssertFalse(currentRow?.isDetached ?? true, "current must never carry the 'not applied' label")
        XCTAssertEqual(detachedRow?.source, .machineLive)
        XCTAssertFalse(detachedRow?.isCurrent ?? true)
        XCTAssertTrue(detachedRow?.isDetached ?? false)
    }

    /// Revert eligibility: offered for a detached MACHINE row, refused for current
    /// itself even when current is machine-sourced (the flag under test is
    /// `isDetached`, not merely `!isHumanLineage` — a fixture where current is machine
    /// makes that distinction representable; a human-`current` fixture like the tests
    /// above would pass under either rule).
    func testBuildRowsOffersRevertOnlyForDetachedMachineRowsNeverForCurrentEvenWhenMachineSourced() {
        let machineCurrent = summary("CUR", source: .machineLive, secondsOffset: 0, fileNumber: 0)
        let detachedMachine = summary("M1", source: .machineRetranscribe, secondsOffset: 10, fileNumber: 1)

        let snap = snapshot(current: machineCurrent, detached: [detachedMachine])
        let rows = RevisionHistoryModel.buildRows(from: snap)

        XCTAssertEqual(rows.first { $0.id == "CUR" }?.canRevert, false,
                       "current must never offer revert, even when it is itself machine-sourced")
        XCTAssertEqual(rows.first { $0.id == "M1" }?.canRevert, true)
    }

    func testBuildRowsOnAChainWithNoCurrentAndNoDetachedIsEmpty() {
        let snap = snapshot(current: nil, detached: [])
        XCTAssertEqual(RevisionHistoryModel.buildRows(from: snap), [])
    }

    // MARK: - open(): revisionCount / chainByteSize / isForked pass through unchanged

    func testOpenSurfacesRevisionCountChainByteSizeAndIsForkedFromTheSnapshot() async {
        let store = FakeRevisionHistoryStore()
        store.snapshot = snapshot(current: summary("CUR", source: .userEdit, secondsOffset: 0, fileNumber: 0),
                                  detached: [])
        store.snapshot.revisionCount = 7
        store.snapshot.chainByteSize = 12_345
        store.snapshot.isForked = true

        let model = RevisionHistoryModel(captureID: "cap", store: store)
        await model.open()

        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.revisionCount, 7)
        XCTAssertEqual(model.chainByteSize, 12_345)
        XCTAssertTrue(model.isForked)
    }

    /// #39's growth alarm (`RevisionGrowthAlarm.threshold`) — both sides of the
    /// boundary, so a fencepost error (`>` vs `>=`) is representable and would flip one
    /// of these two assertions.
    func testGrowthAlarmElevatedAtAndAboveThresholdNotBelowIt() async {
        let store = FakeRevisionHistoryStore()
        store.snapshot = snapshot(current: nil, detached: [])
        store.snapshot.revisionCount = RevisionGrowthAlarm.threshold - 1
        let model = RevisionHistoryModel(captureID: "cap", store: store)
        await model.open()
        XCTAssertFalse(model.isGrowthElevated)

        store.snapshot.revisionCount = RevisionGrowthAlarm.threshold
        await model.open()
        XCTAssertTrue(model.isGrowthElevated)
    }

    // MARK: - revert(): success re-opens, failure surfaces a message

    func testRevertSuccessCallsTheStoreWithTheRowsIDAndReopens() async {
        let store = FakeRevisionHistoryStore()
        let mEarly = summary("M1", source: .machineLive, secondsOffset: 0, fileNumber: 0)
        store.snapshot = snapshot(current: summary("CUR", source: .userEdit, secondsOffset: 10, fileNumber: 1),
                                  detached: [mEarly])
        let model = RevisionHistoryModel(captureID: "cap", store: store)
        await model.open()
        let row = try! XCTUnwrap(model.rows.first { $0.id == "M1" })

        // After a successful revert, the store's OWN chain has moved on — a fresh
        // snapshot with a new current and no more detached M1 — proving `revert`
        // re-reads rather than assuming what it just wrote.
        store.snapshot = snapshot(current: summary("MG1", source: .merge, secondsOffset: 20, fileNumber: 2),
                                  detached: [])
        await model.revert(row)

        XCTAssertEqual(store.revertCalls.count, 1)
        XCTAssertEqual(store.revertCalls.first?.captureID, "cap")
        XCTAssertEqual(store.revertCalls.first?.toRevisionID, "M1")
        XCTAssertEqual(model.rows.map(\.id), ["MG1"], "reopened after a successful revert")
        XCTAssertNil(model.errorMessage)
    }

    func testRevertFailureSetsAnErrorMessageAndLeavesRowsUnchanged() async {
        let store = FakeRevisionHistoryStore()
        let mEarly = summary("M1", source: .machineLive, secondsOffset: 0, fileNumber: 0)
        store.snapshot = snapshot(current: summary("CUR", source: .userEdit, secondsOffset: 10, fileNumber: 1),
                                  detached: [mEarly])
        let model = RevisionHistoryModel(captureID: "cap", store: store)
        await model.open()
        let row = try! XCTUnwrap(model.rows.first { $0.id == "M1" })
        store.revertError = TranscriptRevisionStoreError.trashedCapture

        await model.revert(row)

        XCTAssertEqual(model.errorMessage, "This entry is in the trash, so it can’t be reverted. Restore it first.")
        XCTAssertEqual(model.rows.map(\.id).sorted(), ["CUR", "M1"], "a failed revert must not reopen with lost rows")

        model.acknowledgeError()
        XCTAssertNil(model.errorMessage)
    }

    func testRevertNotMachineLineageErrorMessage() async {
        let store = FakeRevisionHistoryStore()
        store.snapshot = snapshot(current: summary("CUR", source: .userEdit, secondsOffset: 0, fileNumber: 0),
                                  detached: [])
        let model = RevisionHistoryModel(captureID: "cap", store: store)
        await model.open()
        store.revertError = TranscriptMergeError.notMachineLineage("H1")

        await model.revert(RevisionHistoryModel.Row(id: "H1", fileNumber: 0, source: .userEdit,
                                                     createdAt: Date(), firstLine: "", isCurrent: false,
                                                     isDetached: false, canRevert: false))

        XCTAssertEqual(model.errorMessage, "That revision can’t be reverted to.")
    }

    // MARK: - 8.2/8.3/8.4 — real store, real guards (no parallel check in the model)

    private var containerRoot: URL!
    private var capturesRoot: URL { AppContainer.capturesRoot(containerRoot: containerRoot) }
    private let captureID = "01KYX77KK5QM15915EZBVXTQZ4"
    private let baseTime = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        containerRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RevisionHistoryModel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: containerRoot)
    }

    private var captureDirectory: URL {
        SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
    }

    private var transcriptDirectory: URL {
        SegmentLayout.transcriptDirectory(captureDirectory: captureDirectory)
    }

    private var sidecarURL: URL {
        SegmentLayout.entryMetadataURL(captureDirectory: captureDirectory)
    }

    private func store() -> TranscriptRevisionStore { TranscriptRevisionStore(capturesRoot: capturesRoot) }

    private func model() -> LibraryScreenModel {
        LibraryScreenModel(capturesRoot: capturesRoot, journalsContainerRoot: containerRoot)
    }

    private func revision(_ id: String, source: RevisionSource, secondsOffset: Double,
                          spans: [TranscriptSpan], parentID: String? = nil) -> TranscriptRevision {
        TranscriptRevision(id: id, source: source,
                           createdAt: baseTime.addingTimeInterval(secondsOffset),
                           spans: spans, parentID: parentID)
    }

    @discardableResult
    private func writeRawCanonical(_ n: Int, _ json: String) throws -> URL {
        try FileManager.default.createDirectory(at: transcriptDirectory, withIntermediateDirectories: true)
        let url = SegmentLayout.canonicalTranscriptURL(captureDirectory: captureDirectory, revision: n)
        try Data(json.utf8).write(to: url)
        return url
    }

    /// 8.2: revert to rev0 mints a `.merge` whose spans are byte-equal rev0's (anchors
    /// included, §15b.13 — `.exact` frames carried across unmodified) and becomes
    /// `current`; the reverted-from revision (REV1) still exists on disk, untouched.
    func testRevertToRev0MintsMergeByteEqualToRev0SpansAndBecomesCurrentRevertedFromStillExists() async throws {
        let rev0Spans = [TranscriptSpan(text: "original words", anchor: .exact, frameStart: 0, frameEnd: 200)]
        try await store().append(revision("REV0", source: .machineLive, secondsOffset: 0, spans: rev0Spans),
                                 captureID: captureID)
        let rev1Spans = [TranscriptSpan(text: "edited words", anchor: .none)]
        try await store().append(revision("REV1", source: .userEdit, secondsOffset: 10, spans: rev1Spans,
                                          parentID: "REV0"), captureID: captureID)

        let mintedID = try await model().revert(captureID: captureID, toRevisionID: "REV0",
                                                 now: baseTime.addingTimeInterval(20))

        let ordered = TranscriptChain.ordered(TranscriptRevisionStore.loadChain(captureDirectory: captureDirectory)!.revisions)
        XCTAssertEqual(ordered.count, 3, "REV0, REV1, and the new merge — nothing removed")
        let current = try XCTUnwrap(TranscriptChain.current(ordered))
        XCTAssertEqual(current.id, mintedID)
        XCTAssertEqual(current.source, .merge)
        XCTAssertEqual(current.parentID, "REV1")
        XCTAssertEqual(current.basedOnMachineID, "REV0")
        XCTAssertEqual(current.spans, [TranscriptSpan(text: "original words", anchor: .exact,
                                                       frameStart: 0, frameEnd: 200, sourceRevisionID: "REV0")],
                       "spans byte-equal REV0's, anchors included (§15b.13); sourceRevisionID made explicit "
                       + "per the adopt rule since it now lives in a different revision")

        let rev1OnDisk = try XCTUnwrap(ordered.first { $0.id == "REV1" })
        XCTAssertEqual(rev1OnDisk.spans, rev1Spans, "the reverted-from revision is untouched, still on disk")
    }

    /// 8.3a: refuses on a degraded chain — the SAME `§15b.15` guard `writeDraft`/
    /// `closeDraft` already refuse on, exercised through `revert` for the first time.
    /// Fixture: REV0 readable, file 1 corrupted — the negation (a silent revert that
    /// ignores the corrupt file) is representable and would leave 2 revisions on disk
    /// instead of 1.
    func testRevertRefusesOnADegradedChain() async throws {
        try await store().append(revision("REV0", source: .machineLive, secondsOffset: 0,
                                          spans: [TranscriptSpan(text: "raw", anchor: .none)]),
                                 captureID: captureID)
        try writeRawCanonical(1, "not valid json at all")

        do {
            _ = try await model().revert(captureID: captureID, toRevisionID: "REV0", now: baseTime)
            XCTFail("expected a refusal, not a revert against a degraded chain")
        } catch let error as TranscriptRevisionStoreError {
            XCTAssertEqual(error, .revisionUnreadable(file: 1))
        }
        let ordered = TranscriptRevisionStore.loadChain(captureDirectory: captureDirectory)?.revisions ?? []
        XCTAssertEqual(ordered.count, 1, "no revision must be minted while the chain is degraded")
    }

    /// 8.3b: refuses on a trashed capture.
    func testRevertRefusesOnATrashedCapture() async throws {
        try await store().append(revision("REV0", source: .machineLive, secondsOffset: 0,
                                          spans: [TranscriptSpan(text: "raw", anchor: .none)]),
                                 captureID: captureID)
        try await store().append(revision("REV1", source: .userEdit, secondsOffset: 10,
                                          spans: [TranscriptSpan(text: "edited", anchor: .none)],
                                          parentID: "REV0"), captureID: captureID)
        var metadata = EntryMetadata.defaults
        metadata.trashedAt = Date()
        try EntryMetadataStore.write(metadata, url: sidecarURL)

        do {
            _ = try await model().revert(captureID: captureID, toRevisionID: "REV0", now: baseTime)
            XCTFail("expected .trashedCapture")
        } catch let error as TranscriptRevisionStoreError {
            XCTAssertEqual(error, .trashedCapture)
        }
        let ordered = TranscriptRevisionStore.loadChain(captureDirectory: captureDirectory)?.revisions ?? []
        XCTAssertEqual(ordered.count, 2, "no revision must be minted against a trashed capture")
    }

    /// 8.4: attempting to revert to a HUMAN revision throws `.notMachineLineage`,
    /// exercised through the real production caller (`LibraryScreenModel.revert` →
    /// `TranscriptRevisionStore.revert` → `TranscriptMerge.revert`) — Task 1's guard on
    /// `basedOnMachineID`, never previously reachable from a production code path.
    func testRevertToAHumanRevisionThrowsNotMachineLineageThroughTheRealCallerPath() async throws {
        try await store().append(revision("REV0", source: .machineLive, secondsOffset: 0,
                                          spans: [TranscriptSpan(text: "raw", anchor: .none)]),
                                 captureID: captureID)
        try await store().append(revision("REV1", source: .userEdit, secondsOffset: 10,
                                          spans: [TranscriptSpan(text: "edited", anchor: .none)],
                                          parentID: "REV0"), captureID: captureID)
        try await store().append(revision("REV2", source: .userEdit, secondsOffset: 20,
                                          spans: [TranscriptSpan(text: "edited again", anchor: .none)],
                                          parentID: "REV1"), captureID: captureID)

        do {
            _ = try await model().revert(captureID: captureID, toRevisionID: "REV1", now: baseTime)
            XCTFail("expected .notMachineLineage")
        } catch let error as TranscriptMergeError {
            XCTAssertEqual(error, .notMachineLineage("REV1"))
        }
        let ordered = TranscriptRevisionStore.loadChain(captureDirectory: captureDirectory)?.revisions ?? []
        XCTAssertEqual(ordered.count, 3, "no revision must be minted when the target is human-lineage")
    }

    /// `revert` refuses a target id that names no revision in the readable chain —
    /// distinct from every case above (nothing is DEGRADED; the id is simply wrong),
    /// exercised because it is the one guard in the store method with no direct
    /// precedent in `writeDraft`/`closeDraft` to copy.
    func testRevertToAnUnknownRevisionIDThrowsRevisionNotFound() async throws {
        try await store().append(revision("REV0", source: .machineLive, secondsOffset: 0,
                                          spans: [TranscriptSpan(text: "raw", anchor: .none)]),
                                 captureID: captureID)

        do {
            _ = try await model().revert(captureID: captureID, toRevisionID: "NOPE", now: baseTime)
            XCTFail("expected .revisionNotFound")
        } catch let error as TranscriptRevisionStoreError {
            XCTAssertEqual(error, .revisionNotFound("NOPE"))
        }
    }
}

/// Fake `RevisionHistoryStore` for the pure model-behaviour tests (`open()`'s
/// pass-through fields, `revert()`'s success/failure branches) — mirrors
/// `FakeMarkerCorrectionStore`/`FakeEditorStore`'s own shape.
@MainActor
private final class FakeRevisionHistoryStore: RevisionHistoryStore {
    var snapshot = EntryChainSnapshot(editability: .editable, currentRevisionID: nil, currentText: "",
                                      currentSource: nil, revisionCount: 0, isForked: false, openDraft: nil,
                                      detachedMachineRevisions: [], currentSummary: nil, chainByteSize: 0)
    var revertError: (any Error)?
    private(set) var revertCalls: [(captureID: String, toRevisionID: String)] = []

    func chainSnapshot(for captureID: String) async -> EntryChainSnapshot {
        snapshot
    }

    func revert(captureID: String, toRevisionID: String, now: Date) async throws -> String {
        revertCalls.append((captureID, toRevisionID))
        if let revertError { throw revertError }
        return "MINTED"
    }
}
