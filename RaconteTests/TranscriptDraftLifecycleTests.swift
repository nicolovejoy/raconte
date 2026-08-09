import XCTest
@testable import Raconte

/// T6d: `TranscriptRevisionStore`'s draft API — `writeDraft`/`closeDraft`/
/// `closeStaleDrafts` (design §2.5).
final class TranscriptDraftLifecycleTests: XCTestCase {

    private var containerRoot: URL!
    private var capturesRoot: URL { AppContainer.capturesRoot(containerRoot: containerRoot) }
    private let captureID = "01KYX77KK5QM15915EZBVXTQZ4"

    override func setUpWithError() throws {
        containerRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RaconteDraftLifecycle-\(UUID().uuidString)", isDirectory: true)
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

    private var draftURL: URL {
        SegmentLayout.transcriptDraftURL(captureDirectory: captureDirectory)
    }

    private func store(policy: DraftPolicy = DraftPolicy()) -> TranscriptRevisionStore {
        TranscriptRevisionStore(capturesRoot: capturesRoot, policy: policy)
    }

    private let baseTime = Date(timeIntervalSince1970: 1_700_000_000)

    private func revision(_ id: String, text: String, source: RevisionSource = .machineLive,
                          parentID: String? = nil, basedOnMachineID: String? = nil) -> TranscriptRevision {
        TranscriptRevision(id: id, source: source, createdAt: baseTime,
                           spans: [TranscriptSpan(text: text, anchor: .none)],
                           parentID: parentID, basedOnMachineID: basedOnMachineID)
    }

    // MARK: - writeDraft / A2b

    func testWriteDraftEqualToCurrentOnFreshCaptureCreatesNoTranscriptDirectory() async throws {
        // No revision exists yet -> current's plainText is "". Writing an EMPTY
        // draft matches that baseline, so nothing should be created (A2b: only a
        // content-carrying write creates transcript/).
        XCTAssertFalse(FileManager.default.fileExists(atPath: transcriptDirectory.path))
        try await store().writeDraft(captureID: captureID, text: "", now: baseTime)
        XCTAssertFalse(FileManager.default.fileExists(atPath: transcriptDirectory.path),
                       "a draft matching current must not create transcript/ on a fresh capture")
    }

    func testWriteDraftDifferingFromCurrentCreatesTranscriptDirAndDraftFile() async throws {
        try await store().writeDraft(captureID: captureID, text: "hello", now: baseTime)
        XCTAssertTrue(FileManager.default.fileExists(atPath: draftURL.path))
        let draft = try CaptureCoding.decoder().decode(TranscriptDraft.self, from: try Data(contentsOf: draftURL))
        XCTAssertEqual(draft.text, "hello")
        XCTAssertEqual(draft.captureID, captureID)
        XCTAssertNil(draft.parentID, "no current revision exists yet")
    }

    func testSecondWriteDraftAtomicallyReplacesTheFirst() async throws {
        let s = store()
        try await s.writeDraft(captureID: captureID, text: "first", now: baseTime)
        try await s.writeDraft(captureID: captureID, text: "first draft continues", now: baseTime.addingTimeInterval(2))

        let draft = try CaptureCoding.decoder().decode(TranscriptDraft.self, from: try Data(contentsOf: draftURL))
        XCTAssertEqual(draft.text, "first draft continues")
        XCTAssertEqual(draft.openedAt, baseTime, "openedAt is preserved across rewrites of the same draft")
        XCTAssertEqual(draft.lastWriteAt, baseTime.addingTimeInterval(2))
    }

    func testWriteDraftOnTrashedCaptureThrows() async throws {
        var metadata = EntryMetadata.defaults
        metadata.trashedAt = Date()
        try EntryMetadataStore.write(metadata, url: SegmentLayout.entryMetadataURL(captureDirectory: captureDirectory))

        do {
            try await store().writeDraft(captureID: captureID, text: "hello", now: baseTime)
            XCTFail("expected .trashedCapture")
        } catch let error as TranscriptRevisionStoreError {
            XCTAssertEqual(error, .trashedCapture)
        }
    }

    // MARK: - closeDraft

    func testCloseDraftWithTextEqualToCurrentDeletesDraftAndMintsNothing() async throws {
        let s = store()
        try await s.append(revision("R0", text: "hello"), captureID: captureID)
        try await s.writeDraft(captureID: captureID, text: "goodbye", now: baseTime)
        // Now edit it back to match current before closing.
        try await s.writeDraft(captureID: captureID, text: "hello", now: baseTime.addingTimeInterval(5))

        let minted = try await s.closeDraft(captureID: captureID, reason: .sessionEnd, now: baseTime.addingTimeInterval(10))
        XCTAssertNil(minted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: draftURL.path))

        let ordered = TranscriptRevisionStore.loadChain(captureDirectory: captureDirectory)?.revisions ?? []
        XCTAssertEqual(ordered.count, 1, "no new revision must be minted")
    }

    /// F7 crash-duplicate rule: the revision is ALREADY minted and durable, and the
    /// draft merely failed to be deleted before a crash. A retried close must compare
    /// against CURRENT (which now equals the draft's text, since the mint already
    /// incorporated it) — not the draft's snapshot parent — and produce nothing new.
    func testCloseDraftAfterCrashBetweenMintAndDraftDeleteMintsNothing() async throws {
        let s = store()
        try await s.append(revision("R0", text: "hello"), captureID: captureID)
        try await s.writeDraft(captureID: captureID, text: "hello world", now: baseTime)

        // Simulate the crash: mint the revision exactly as closeDraft would, but leave
        // the draft file on disk (skip its deletion).
        let mintedID = "01BBBBBBBBBBBBBBBBBBBBBBBB"
        try await s.append(TranscriptRevision(id: mintedID, source: .userEdit, createdAt: baseTime.addingTimeInterval(1),
                                              spans: [TranscriptSpan(text: "hello world", anchor: .none)],
                                              parentID: "R0"),
                           captureID: captureID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: draftURL.path), "draft survives the simulated crash")

        let minted = try await s.closeDraft(captureID: captureID, reason: .sessionEnd, now: baseTime.addingTimeInterval(20))
        XCTAssertNil(minted, "current already equals the draft's text — nothing new to mint")
        XCTAssertFalse(FileManager.default.fileExists(atPath: draftURL.path), "the stale draft is cleaned up")

        let ordered = TranscriptRevisionStore.loadChain(captureDirectory: captureDirectory)?.revisions ?? []
        XCTAssertEqual(ordered.count, 2, "still exactly R0 + the one already-minted revision — no duplicate")
    }

    func testCloseDraftWithChangedTextMintsUserEditRevisionWithCorrectParentage() async throws {
        let s = store()
        try await s.append(revision("R0", text: "hello", source: .machineLive), captureID: captureID)
        try await s.writeDraft(captureID: captureID, text: "hello world", now: baseTime.addingTimeInterval(1))

        let mintedID = try await s.closeDraft(captureID: captureID, reason: .sessionEnd,
                                              now: baseTime.addingTimeInterval(100))
        XCTAssertNotNil(mintedID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: draftURL.path))

        let ordered = TranscriptRevisionStore.loadChain(captureDirectory: captureDirectory)?.revisions ?? []
        guard let minted = ordered.first(where: { $0.id == mintedID }) else {
            return XCTFail("minted revision must be readable back")
        }
        XCTAssertEqual(minted.source, .userEdit)
        XCTAssertEqual(minted.parentID, "R0")
        // §6.4: parent (R0) IS a machine revision -> basedOnMachineID takes the
        // parent's own id.
        XCTAssertEqual(minted.basedOnMachineID, "R0")
        XCTAssertEqual(minted.closedBy, .sessionEnd)
        XCTAssertEqual(TranscriptChain.plainText(minted), "hello world")
    }

    func testCloseDraftBasedOnMachineIDCopiesParentsWhenParentIsHumanLineage() async throws {
        let s = store()
        try await s.append(revision("M0", text: "hello", source: .machineLive), captureID: captureID)
        try await s.append(revision("H0", text: "hello there", source: .userEdit,
                                    parentID: "M0", basedOnMachineID: "M0"), captureID: captureID)
        try await s.writeDraft(captureID: captureID, text: "hello there friend", now: baseTime.addingTimeInterval(1))

        let mintedID = try await s.closeDraft(captureID: captureID, reason: .sessionEnd,
                                              now: baseTime.addingTimeInterval(100))
        let ordered = TranscriptRevisionStore.loadChain(captureDirectory: captureDirectory)?.revisions ?? []
        guard let minted = ordered.first(where: { $0.id == mintedID }) else {
            return XCTFail("minted revision must be readable back")
        }
        XCTAssertEqual(minted.parentID, "H0")
        // §6.4: parent (H0) is human-lineage -> basedOnMachineID is COPIED from the
        // parent's own basedOnMachineID (M0), not recomputed as "nearest machine
        // ancestor".
        XCTAssertEqual(minted.basedOnMachineID, "M0")
    }

    // MARK: - Hour cap

    func testCloseDraftOlderThanHourCapClosesWithHourCapRegardlessOfRequestedReason() async throws {
        let s = store(policy: DraftPolicy(sessionEndSeconds: 90, hourCapSeconds: 3600))
        try await s.writeDraft(captureID: captureID, text: "a long sitting", now: baseTime)

        // openedAt was baseTime; ask now 61 minutes later, requesting a totally
        // different reason — the hour cap must override it.
        let mintedID = try await s.closeDraft(captureID: captureID, reason: .machineArrival,
                                              now: baseTime.addingTimeInterval(61 * 60))
        let ordered = TranscriptRevisionStore.loadChain(captureDirectory: captureDirectory)?.revisions ?? []
        guard let minted = ordered.first(where: { $0.id == mintedID }) else {
            return XCTFail("minted revision must be readable back")
        }
        XCTAssertEqual(minted.closedBy, .hourCap)
    }

    func testCloseDraftWithinHourCapUsesTheRequestedReason() async throws {
        let s = store()
        try await s.writeDraft(captureID: captureID, text: "a short edit", now: baseTime)
        let mintedID = try await s.closeDraft(captureID: captureID, reason: .machineArrival,
                                              now: baseTime.addingTimeInterval(30))
        let ordered = TranscriptRevisionStore.loadChain(captureDirectory: captureDirectory)?.revisions ?? []
        let minted = ordered.first { $0.id == mintedID }
        XCTAssertEqual(minted?.closedBy, .machineArrival)
    }

    // MARK: - closeStaleDrafts

    func testCloseStaleDraftsSkipsFreshDrafts() async throws {
        let s = store(policy: DraftPolicy(sessionEndSeconds: 90, hourCapSeconds: 3600))
        try await s.writeDraft(captureID: captureID, text: "still typing", now: baseTime)

        await s.closeStaleDrafts(now: baseTime.addingTimeInterval(10))
        XCTAssertTrue(FileManager.default.fileExists(atPath: draftURL.path), "a fresh draft must survive the pass")
    }

    func testCloseStaleDraftsClosesStaleWithRecovered() async throws {
        let s = store(policy: DraftPolicy(sessionEndSeconds: 90, hourCapSeconds: 3600))
        try await s.writeDraft(captureID: captureID, text: "abandoned mid-sitting", now: baseTime)

        await s.closeStaleDrafts(now: baseTime.addingTimeInterval(200))
        XCTAssertFalse(FileManager.default.fileExists(atPath: draftURL.path), "a stale draft must be closed")

        let ordered = TranscriptRevisionStore.loadChain(captureDirectory: captureDirectory)?.revisions ?? []
        XCTAssertEqual(ordered.first?.closedBy, .recovered)
    }

    func testCloseStaleDraftsSkipsTrashedCaptures() async throws {
        let s = store(policy: DraftPolicy(sessionEndSeconds: 90, hourCapSeconds: 3600))
        try await s.writeDraft(captureID: captureID, text: "in progress", now: baseTime)

        var metadata = EntryMetadata.defaults
        metadata.trashedAt = Date()
        try EntryMetadataStore.write(metadata, url: SegmentLayout.entryMetadataURL(captureDirectory: captureDirectory))

        await s.closeStaleDrafts(now: baseTime.addingTimeInterval(200))
        XCTAssertTrue(FileManager.default.fileExists(atPath: draftURL.path),
                     "a trashed capture's draft must be left untouched, not closed")
    }

    func testCloseStaleDraftsToleratesACaptureWithNoDraft() async throws {
        // No draft ever written for this capture — the pass must not throw or crash.
        await store().closeStaleDrafts(now: baseTime)
    }
}
