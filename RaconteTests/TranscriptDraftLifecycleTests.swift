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

    // MARK: - #40.2 (T7 Task 3): bound writeDraft's per-write cost

    /// **3.3a — seam-counted.** Once `transcript/` already exists (the overwhelmingly
    /// common case: the entry was already promoted before the editor ever opened), the
    /// `plainText` flatten + `text != currentText` comparison are moot — the guard they
    /// feed lets the write through unconditionally in that case — and must not run.
    /// `currentTextComparisonRan` is a test-only seam (mirrors `append`'s `beforeWrite`)
    /// proving the skip actually happens, since the write's own outcome (draft written)
    /// is identical whether or not the comparison ran and so cannot prove this by itself.
    /// **Mutation:** delete the `if !transcriptDirectoryExists` guard around the seam
    /// call (always run the flatten+compare) -> `hitCount` becomes 1 and this fails.
    func testWriteDraftSkipsCurrentTextComparisonWhenTranscriptDirectoryAlreadyExists() async throws {
        let s = store()
        try await s.append(revision("R0", text: "hello"), captureID: captureID)   // transcript/ now exists

        final class HitCounter: @unchecked Sendable {
            var count = 0
            func hit() { count += 1 }
        }
        let counter = HitCounter()

        try await s.writeDraft(captureID: captureID, text: "goodbye", now: baseTime,
                               currentTextComparisonRan: { counter.hit() })

        XCTAssertEqual(counter.count, 0,
                       "#40.2: once transcript/ already exists the A2b comparison is moot and must not run")
        XCTAssertTrue(FileManager.default.fileExists(atPath: draftURL.path))
        let draft = try CaptureCoding.decoder().decode(TranscriptDraft.self, from: try Data(contentsOf: draftURL))
        XCTAssertEqual(draft.text, "goodbye")
    }

    /// **3.3a, other half.** On a FRESH capture (`transcript/` absent) the comparison
    /// still must run — it is the only thing deciding whether A2b's "never create
    /// transcript/ for a no-op draft" rule applies.
    func testWriteDraftRunsCurrentTextComparisonWhenTranscriptDirectoryIsAbsent() async throws {
        final class HitCounter: @unchecked Sendable {
            var count = 0
            func hit() { count += 1 }
        }
        let counter = HitCounter()

        try await store().writeDraft(captureID: captureID, text: "hello", now: baseTime,
                                     currentTextComparisonRan: { counter.hit() })

        XCTAssertEqual(counter.count, 1, "with no transcript/ yet, the comparison is the ONLY way to know")
    }

    /// **3.3b — the safety property the mutation check in 3.3a's doc comment guards.**
    /// §15b.15: even in the identical "transcript/ already exists" shape as 3.3a — where
    /// the flatten+compare are skipped — the decode-and-refuse in
    /// `readableOrderedRevisions` still runs UNCONDITIONALLY and still throws on a
    /// degraded chain. This is the same SCENARIO shape as
    /// `testWriteDraftRefusesWhenChainHasAnUndecodableRevision` further down this file
    /// (transcript/ exists via `append`, then a sibling is corrupted, then `writeDraft`
    /// is called) — restated here under the #40.2 section so the "still throws" half of
    /// the ruling has its own name and is not merely inherited by coincidence.
    /// **Deliberately near-duplicate, not dead code to consolidate** (fix round 1
    /// note, Task 3 report's deferred-minors list): that other test predates #40.2 and
    /// pins Critical 2/F5 in general; THIS one exists specifically so #40.2's own
    /// section has a self-contained pin that doesn't depend on a reader also finding
    /// the older test. **Mutation check (performed manually, not re-run by CI):**
    /// moving `readableOrderedRevisions` BELOW the `transcriptDirectoryExists` check
    /// (i.e. deciding "skip the decode when transcript/ exists" instead of "skip the
    /// flatten+compare") makes this fail — exactly the bug the issue's wording invites
    /// (brief work item 2).
    func testWriteDraftStillRefusesOnADegradedChainWhenTranscriptDirectoryAlreadyExists() async throws {
        let s = store()
        try await s.append(revision("R0", text: "hello"), captureID: captureID)
        try writeRawCanonical(1, "not valid json")   // transcript/ still exists; chain now degraded

        do {
            try await s.writeDraft(captureID: captureID, text: "goodbye", now: baseTime)
            XCTFail("expected a refusal, not a silent write against a degraded chain")
        } catch let error as TranscriptRevisionStoreError {
            XCTAssertEqual(error, .revisionUnreadable(file: 1))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: draftURL.path),
                       "a refused writeDraft must not create draft.json")
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

    // MARK: - closeStaleDraftIfNeeded (T7 prereq #41: sibling to closeStaleDrafts,
    // same rules, one capture — the entry-open call site needs a per-capture variant
    // rather than paying for the whole corpus walk on every screen open).

    private let otherCaptureID = "01YYYYYYYYYYYYYYYYYYYYYYYY"

    private var otherCaptureDirectory: URL {
        SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: otherCaptureID)
    }

    private var otherDraftURL: URL {
        SegmentLayout.transcriptDraftURL(captureDirectory: otherCaptureDirectory)
    }

    func testCloseStaleDraftIfNeededClosesAStaleDraftWithRecovered() async throws {
        let s = store(policy: DraftPolicy(sessionEndSeconds: 90, hourCapSeconds: 3600))
        try await s.writeDraft(captureID: captureID, text: "abandoned mid-sitting", now: baseTime)

        let minted = await s.closeStaleDraftIfNeeded(captureID: captureID, now: baseTime.addingTimeInterval(200))
        XCTAssertNotNil(minted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: draftURL.path), "a stale draft must be closed")

        let ordered = TranscriptRevisionStore.loadChain(captureDirectory: captureDirectory)?.revisions ?? []
        XCTAssertEqual(ordered.first?.closedBy, .recovered)
        XCTAssertEqual(ordered.first?.id, minted)
    }

    func testCloseStaleDraftIfNeededLeavesAFreshDraftUntouched() async throws {
        let s = store(policy: DraftPolicy(sessionEndSeconds: 90, hourCapSeconds: 3600))
        try await s.writeDraft(captureID: captureID, text: "still typing", now: baseTime)

        let minted = await s.closeStaleDraftIfNeeded(captureID: captureID, now: baseTime.addingTimeInterval(10))
        XCTAssertNil(minted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: draftURL.path), "a fresh draft must survive the call")
    }

    func testCloseStaleDraftIfNeededOnOneCaptureNeverTouchesAnotherCapturesStaleDraft() async throws {
        // The whole point of the per-capture variant, vs. closeStaleDrafts' corpus walk.
        try FileManager.default.createDirectory(at: otherCaptureDirectory, withIntermediateDirectories: true)
        let s = store(policy: DraftPolicy(sessionEndSeconds: 90, hourCapSeconds: 3600))
        try await s.writeDraft(captureID: captureID, text: "X's abandoned edit", now: baseTime)
        try await s.writeDraft(captureID: otherCaptureID, text: "Y's abandoned edit", now: baseTime)

        _ = await s.closeStaleDraftIfNeeded(captureID: captureID, now: baseTime.addingTimeInterval(200))

        XCTAssertFalse(FileManager.default.fileExists(atPath: draftURL.path), "X's stale draft is closed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherDraftURL.path),
                     "Y's stale draft must be untouched by the call scoped to X")
    }

    // MARK: - Critical 2: an unreadable revision refuses draft ops rather than
    // collapsing into "no such revision" (F5)

    @discardableResult
    private func writeRawCanonical(_ n: Int, _ json: String) throws -> URL {
        try FileManager.default.createDirectory(at: transcriptDirectory, withIntermediateDirectories: true)
        let url = SegmentLayout.canonicalTranscriptURL(captureDirectory: captureDirectory, revision: n)
        try Data(json.utf8).write(to: url)
        return url
    }

    /// Near-duplicate in shape to `testWriteDraftStillRefusesOnADegradedChainWhen
    /// TranscriptDirectoryAlreadyExists` above (T7 Task 3 §40.2) — deliberately, see
    /// that test's doc comment for why both are kept rather than one being folded into
    /// the other.
    func testWriteDraftRefusesWhenChainHasAnUndecodableRevision() async throws {
        try await store().append(revision("R0", text: "hello"), captureID: captureID)
        // Corrupt a LATER file number so the chain has an undecodable revision above
        // R0 — current must not silently fall back to R0's text.
        try writeRawCanonical(1, "not valid json")

        do {
            try await store().writeDraft(captureID: captureID, text: "goodbye", now: baseTime)
            XCTFail("expected a refusal, not a silent write against a degraded chain")
        } catch let error as TranscriptRevisionStoreError {
            XCTAssertEqual(error, .revisionUnreadable(file: 1))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: draftURL.path),
                       "a refused writeDraft must not create draft.json")
    }

    func testCloseDraftRefusesWhenChainHasAnUndecodableRevisionAndLeavesDraftInPlace() async throws {
        let s = store()
        try await s.append(revision("R0", text: "hello"), captureID: captureID)
        try await s.writeDraft(captureID: captureID, text: "hello world", now: baseTime.addingTimeInterval(1))
        // Corrupt the chain AFTER the draft was opened (e.g. iCloud eviction between
        // sessions) — closeDraft must refuse rather than mint a revision that silently
        // drops R0's undecodable-sibling content forever.
        try writeRawCanonical(1, "not valid json")

        do {
            _ = try await s.closeDraft(captureID: captureID, reason: .sessionEnd,
                                       now: baseTime.addingTimeInterval(100))
            XCTFail("expected a refusal, not a mint against a degraded chain")
        } catch let error as TranscriptRevisionStoreError {
            XCTAssertEqual(error, .revisionUnreadable(file: 1))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: draftURL.path),
                     "the draft must survive a refused close — nothing was minted")
        let ordered = TranscriptRevisionStore.loadChain(captureDirectory: captureDirectory)?.revisions ?? []
        XCTAssertEqual(ordered.count, 1, "no revision must be minted while the chain is degraded")
    }

    func testCloseStaleDraftsSkipsACaptureWithAnUndecodableRevisionLeavingItsDraftInPlace() async throws {
        let s = store(policy: DraftPolicy(sessionEndSeconds: 90, hourCapSeconds: 3600))
        try await s.append(revision("R0", text: "hello"), captureID: captureID)
        try await s.writeDraft(captureID: captureID, text: "hello world", now: baseTime)
        try writeRawCanonical(1, "not valid json")

        await s.closeStaleDrafts(now: baseTime.addingTimeInterval(200))
        XCTAssertTrue(FileManager.default.fileExists(atPath: draftURL.path),
                     "closeStaleDrafts must skip a capture with a degraded chain, not mint over it")
    }

    /// §15b.15: a degraded chain must leave the draft on disk and mint nothing, even
    /// though the draft is stale by the clock. `closeStaleDraftIfNeeded` swallows
    /// `closeDraft`'s throw into `nil` rather than propagating it — the caller (launch,
    /// entry-open) has no one to show an error to.
    func testCloseStaleDraftIfNeededReturnsNilAndLeavesDraftWhenChainHasAnUndecodableRevision() async throws {
        let s = store(policy: DraftPolicy(sessionEndSeconds: 90, hourCapSeconds: 3600))
        try await s.append(revision("R0", text: "hello"), captureID: captureID)
        try await s.writeDraft(captureID: captureID, text: "hello world", now: baseTime)
        try writeRawCanonical(1, "not valid json")

        let minted = await s.closeStaleDraftIfNeeded(captureID: captureID, now: baseTime.addingTimeInterval(200))
        XCTAssertNil(minted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: draftURL.path),
                     "the draft must survive — a degraded chain mints nothing (§15b.15)")
        let ordered = TranscriptRevisionStore.loadChain(captureDirectory: captureDirectory)?.revisions ?? []
        XCTAssertEqual(ordered.count, 1, "no revision must be minted while the chain is degraded")
    }

    // MARK: - Important 4: the draft snapshot fields are captured atomically

    func testWriteDraftDoesNotReparentAnOpenDraftOntoAMachineRevisionPromotedMidDraft() async throws {
        let s = store()
        // Open the draft with NO revision existing yet — parentID/basedOnMachineID
        // are both nil at this point.
        try await s.writeDraft(captureID: captureID, text: "first words", now: baseTime)
        let openedDraft = try CaptureCoding.decoder().decode(TranscriptDraft.self,
                                                              from: try Data(contentsOf: draftURL))
        XCTAssertNil(openedDraft.parentID)
        XCTAssertNil(openedDraft.basedOnMachineID)

        // A machine revision arrives mid-draft (e.g. a delayed promotion pass).
        try await s.append(revision("M0", text: "promoted machine text", source: .machineLive),
                           captureID: captureID)

        // Continue writing the SAME draft — it must stay parented on nothing (its own
        // original open-time snapshot), not silently pick up M0.
        try await s.writeDraft(captureID: captureID, text: "first words continued",
                               now: baseTime.addingTimeInterval(5))
        let continuedDraft = try CaptureCoding.decoder().decode(TranscriptDraft.self,
                                                                 from: try Data(contentsOf: draftURL))
        XCTAssertNil(continuedDraft.parentID,
                    "an already-open draft must never be silently re-parented onto a revision that arrived after it opened")
        XCTAssertNil(continuedDraft.basedOnMachineID)
        XCTAssertEqual(continuedDraft.openedAt, baseTime, "openedAt must stay the ORIGINAL open time")
    }
}
