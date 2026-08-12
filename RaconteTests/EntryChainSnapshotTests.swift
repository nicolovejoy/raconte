import XCTest
@testable import Raconte

/// T7 Task 2: `EntryChainSnapshot` — the editor's read model, shared by the editor, the
/// revision-history panel, and the storage stat. Pure read; `TranscriptRevisionStore`'s
/// append/draft API only appears here to build fixtures on disk.
///
/// `@MainActor` because `model()` builds a `LibraryScreenModel` (itself `@MainActor`),
/// for the one test that checks `chainSnapshot(for:)`'s wiring — same reasoning as
/// `LibraryScreenModelTests`.
@MainActor
final class EntryChainSnapshotTests: XCTestCase {

    private var containerRoot: URL!
    private var capturesRoot: URL { AppContainer.capturesRoot(containerRoot: containerRoot) }
    private let captureID = "01KYX77KK5QM15915EZBVXTQZ4"

    override func setUpWithError() throws {
        containerRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("EntryChainSnapshot-\(UUID().uuidString)", isDirectory: true)
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

    private func revision(_ id: String, source: RevisionSource = .machineLive, secondsOffset: Double = 0,
                          parentID: String? = nil, basedOnMachineID: String? = nil,
                          text: String = "hello") -> TranscriptRevision {
        TranscriptRevision(id: id, source: source,
                           createdAt: Date(timeIntervalSince1970: 1_700_000_000 + secondsOffset),
                           spans: [TranscriptSpan(text: text, anchor: .none)],
                           parentID: parentID, basedOnMachineID: basedOnMachineID)
    }

    @discardableResult
    private func writeRawCanonical(_ n: Int, _ json: String) throws -> URL {
        try FileManager.default.createDirectory(at: transcriptDirectory, withIntermediateDirectories: true)
        let url = SegmentLayout.canonicalTranscriptURL(captureDirectory: captureDirectory, revision: n)
        try Data(json.utf8).write(to: url)
        return url
    }

    private func validJSON(for revision: TranscriptRevision) throws -> String {
        String(data: try CaptureCoding.encoder().encode(revision), encoding: .utf8)!
    }

    private func markTrashed() throws {
        var metadata = EntryMetadata()
        metadata.trashedAt = Date(timeIntervalSince1970: 1_700_000_500)
        try EntryMetadataStore.write(metadata, url: sidecarURL)
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let number = attrs[.size] as? NSNumber else { return 0 }
        return number.int64Value
    }

    // MARK: - 2.1 One fixture per Editability case

    func testHealthyChainIsEditable() async throws {
        try await store().append(revision("R0", text: "hello world"), captureID: captureID)

        let snapshot = EntryChainSnapshot.build(captureDirectory: captureDirectory)

        XCTAssertEqual(snapshot.editability, .editable)
        XCTAssertEqual(snapshot.currentRevisionID, "R0")
        XCTAssertEqual(snapshot.currentText, "hello world")
        XCTAssertEqual(snapshot.currentSource, .machineLive)
        XCTAssertEqual(snapshot.revisionCount, 1)
        XCTAssertFalse(snapshot.isForked)
        XCTAssertNil(snapshot.openDraft)
        XCTAssertEqual(snapshot.detachedMachineRevisions, [])
    }

    /// Trashed sidecar wins the precedence race even over an otherwise perfectly healthy
    /// chain (the store's write guards check `trashedAt` before anything else) — AND the
    /// content fields stay fully populated, so the history panel / storage stat can still
    /// show a trashed entry's revisions during the 30-day trash window. A fixture with an
    /// EMPTY chain would trivially satisfy `.readOnlyTrashed` without proving that; this
    /// one has real revisions so the assertion is load-bearing.
    func testTrashedSidecarIsReadOnlyTrashedButChainContentStillReads() async throws {
        try await store().append(revision("R0", text: "hello world"), captureID: captureID)
        try markTrashed()

        let snapshot = EntryChainSnapshot.build(captureDirectory: captureDirectory)

        XCTAssertEqual(snapshot.editability, .readOnlyTrashed)
        XCTAssertEqual(snapshot.currentRevisionID, "R0", "trashed blocks editing, not reading")
        XCTAssertEqual(snapshot.currentText, "hello world")
        XCTAssertEqual(snapshot.revisionCount, 1)
    }

    /// Minor 6 (fix round 1): bind the associated reason and assert it is non-empty —
    /// a bare `guard case .readOnlyListingUnreadable = …` (no binding) would also pass
    /// for `.readOnlyListingUnreadable("")`, which is not what `TranscriptRevisionStore
    /// .listing` ever actually produces.
    func testTranscriptDirAsAFileIsReadOnlyListingUnreadable() throws {
        try Data("not a directory".utf8).write(to: transcriptDirectory)

        let snapshot = EntryChainSnapshot.build(captureDirectory: captureDirectory)

        guard case .readOnlyListingUnreadable(let reason) = snapshot.editability else {
            return XCTFail("expected .readOnlyListingUnreadable, got \(snapshot.editability)")
        }
        XCTAssertFalse(reason.isEmpty, "the reason string must actually describe the failure")
        XCTAssertNil(snapshot.currentRevisionID)
        XCTAssertEqual(snapshot.currentText, "")
        XCTAssertEqual(snapshot.revisionCount, 0)
        XCTAssertEqual(snapshot.chainByteSize, 0)
    }

    /// Minor 5 (fix round 1): a trashed sidecar over a chain whose `transcript/` is ALSO
    /// damaged — pins that the trashed check really does run first, ahead of the damage
    /// checks, as the precedence rule states, rather than the two merely never having
    /// been exercised together.
    func testTrashedAndDamagedChainStillReportsTrashedNotDamage() throws {
        try markTrashed()
        try Data("not a directory".utf8).write(to: transcriptDirectory)

        let snapshot = EntryChainSnapshot.build(captureDirectory: captureDirectory)

        XCTAssertEqual(snapshot.editability, .readOnlyTrashed,
                       "trashed must win over an unreadable transcript/ listing")
    }

    func testOneUndecodableCanonicalFileIsReadOnlyUnreadableRevision() throws {
        try writeRawCanonical(0, try validJSON(for: revision("R0")))
        try writeRawCanonical(1, "{ not valid json at all, corrupted")

        let snapshot = EntryChainSnapshot.build(captureDirectory: captureDirectory)

        XCTAssertEqual(snapshot.editability, .readOnlyUnreadableRevision(file: 1))
        XCTAssertNil(snapshot.currentRevisionID, "the whole chain is untrustworthy once one file fails to decode")
        XCTAssertEqual(snapshot.revisionCount, 0)
        XCTAssertGreaterThan(snapshot.chainByteSize, 0, "a corrupt revision still occupies real bytes")
    }

    /// `transcript/` never created at all — a capture that was never promoted.
    func testAbsentTranscriptDirIsReadOnlyNoTranscript() throws {
        let snapshot = EntryChainSnapshot.build(captureDirectory: captureDirectory)

        XCTAssertEqual(snapshot.editability, .readOnlyNoTranscript)
        XCTAssertNil(snapshot.currentRevisionID)
        XCTAssertEqual(snapshot.currentText, "")
        XCTAssertEqual(snapshot.revisionCount, 0)
        XCTAssertEqual(snapshot.chainByteSize, 0)
    }

    /// `transcript/` exists (so listing is `.present`, not `.absent`) but holds no
    /// canonical revision files — the OTHER path to the same editability, exercised
    /// separately since it is a genuinely different code branch.
    func testPresentButEmptyTranscriptDirIsAlsoReadOnlyNoTranscript() throws {
        try FileManager.default.createDirectory(at: transcriptDirectory, withIntermediateDirectories: true)

        let snapshot = EntryChainSnapshot.build(captureDirectory: captureDirectory)

        XCTAssertEqual(snapshot.editability, .readOnlyNoTranscript)
        XCTAssertEqual(snapshot.revisionCount, 0)
    }

    // MARK: - 2.2 Fork/detached

    /// rev0 machine (root) → rev1 userEdit (parent rev0) → M machineRetranscribe,
    /// disconnected from rev1's lineage entirely (no parentID/basedOnMachineID) ⇒
    /// current == rev1, revisionCount == 3.
    ///
    /// Fix round 1, owner ruling: `detachedMachineRevisions` is now "not applied" =
    /// neither `current` nor one of its ancestors (`TranscriptChain.ancestry(of:
    /// current, among: ordered)`), machine-sourced only — NOT the plan's original
    /// `!TranscriptChain.isAttached` shorthand, which also caught REV0 (see this test's
    /// history / the task report for why: `isAttached` requires the human tip to be
    /// among a CANDIDATE's own ancestors, which a root can never satisfy). REV0 is
    /// REV1's own parent — i.e. IS in `ancestry(of: REV1)` — so it correctly does NOT
    /// appear here under the new rule: `detachedMachineRevisions == [M]`.
    func testDetachedMachineRetranscribeIsListedSeparatelyFromAttachedCurrent() async throws {
        try await store().append(revision("REV0", source: .machineLive, secondsOffset: 0, text: "raw"),
                                 captureID: captureID)
        try await store().append(revision("REV1", source: .userEdit, secondsOffset: 10,
                                          parentID: "REV0", text: "edited"), captureID: captureID)
        try await store().append(revision("M", source: .machineRetranscribe, secondsOffset: 20,
                                          text: "retranscribed"), captureID: captureID)

        let snapshot = EntryChainSnapshot.build(captureDirectory: captureDirectory)

        XCTAssertEqual(snapshot.editability, .editable)
        XCTAssertEqual(snapshot.currentRevisionID, "REV1")
        XCTAssertEqual(snapshot.currentText, "edited")
        XCTAssertEqual(snapshot.revisionCount, 3)
        XCTAssertFalse(snapshot.isForked)

        // Ordered comparison (Minor 8), not a Set: chain (createdAt, id) order, since
        // Task 8 renders this list and needs a deterministic order.
        XCTAssertEqual(snapshot.detachedMachineRevisions.map(\.id), ["M"],
                       "REV0 is REV1's own ancestor and must NOT be labeled 'not applied'")
        let detachedIDs = Set(snapshot.detachedMachineRevisions.map(\.id))
        XCTAssertFalse(detachedIDs.contains("REV0"),
                       "the whole point of the owner ruling: the root machine baseline a human edit was built on is not 'unapplied'")
        XCTAssertFalse(detachedIDs.contains("REV1"), "current must never appear as detached")

        let mSummary = snapshot.detachedMachineRevisions.first { $0.id == "M" }
        XCTAssertEqual(mSummary?.source, .machineRetranscribe)
        XCTAssertEqual(mSummary?.fileNumber, 2)
        XCTAssertEqual(mSummary?.firstLine, "retranscribed")
    }

    /// Fix round 2: the order documented on `detachedMachineRevisions` (chain
    /// `(createdAt, id)`, see the field's own doc comment) had ZERO test coverage that
    /// could actually detect an ordering bug — every prior detached fixture yields
    /// exactly one element, so `.map(\.id) == [singleID]` passes under ANY ordering.
    /// Probe-confirmed by the reviewer: swapping `ordered.filter` for
    /// `ordered.reversed().filter` at the detached-revisions filter site passed the
    /// entire 958-test suite.
    ///
    /// Two genuinely detached machine revisions off the same REV0/REV1 shape as the
    /// test above — `M_EARLY`/`M_LATE` are named for their `createdAt`, not their append
    /// order, and are appended to the store in REVERSE chronological order (`M_LATE`
    /// first) so this test cannot pass by accident off insertion/file-number order
    /// either — only the real `(createdAt, id)` order produces `[M_EARLY, M_LATE]`.
    /// Neither has a `parentID`/`basedOnMachineID` at all, so both are, individually,
    /// neither `current` (REV1) nor in `ancestry(of: REV1) == {REV0}` — genuinely
    /// detached, the same reasoning the test above already established for a single `M`,
    /// so this test is testing ORDER, not re-testing the filter.
    func testDetachedMachineRevisionsOrderIsChronologicalNotInsertionOrder() async throws {
        try await store().append(revision("REV0", source: .machineLive, secondsOffset: 0, text: "raw"),
                                 captureID: captureID)
        try await store().append(revision("REV1", source: .userEdit, secondsOffset: 10,
                                          parentID: "REV0", text: "edited"), captureID: captureID)
        // Appended out of chronological order on purpose — see doc comment above.
        try await store().append(revision("M_LATE", source: .machineRetranscribe, secondsOffset: 30,
                                          text: "late"), captureID: captureID)
        try await store().append(revision("M_EARLY", source: .machineRetranscribe, secondsOffset: 20,
                                          text: "early"), captureID: captureID)

        let snapshot = EntryChainSnapshot.build(captureDirectory: captureDirectory)

        XCTAssertEqual(snapshot.currentRevisionID, "REV1")
        XCTAssertEqual(snapshot.revisionCount, 4)
        XCTAssertEqual(snapshot.detachedMachineRevisions.map(\.id), ["M_EARLY", "M_LATE"],
                       "chain (createdAt, id) order — M_EARLY's createdAt is smaller despite being appended second")
    }

    /// Important 1 (fix round 1): `isForked` had zero behavioural coverage — a hardcoded
    /// `false` passed every existing test. Fork shape from
    /// `TranscriptChainTests.testA1DivergenceWalk`: rev0 machine (root), editA and editB
    /// both userEdit off rev0, neither in the other's ancestry. Also folds in a fully
    /// disconnected machine revision `M` (no parent at all) so this ONE fixture proves
    /// `isForked` on BOTH surfaces the reviewer named: `EntryChainSnapshot.isForked`
    /// itself, and the `isForked` field threaded onto every `TranscriptHeadSummary` in
    /// `detachedMachineRevisions`.
    func testForkedHumanLineageSetsIsForkedOnSnapshotAndOnDetachedSummaries() async throws {
        try await store().append(revision("REV0", source: .machineLive, secondsOffset: 0, text: "raw"),
                                 captureID: captureID)
        try await store().append(revision("EDITA", source: .userEdit, secondsOffset: 10,
                                          parentID: "REV0", text: "edit a"), captureID: captureID)
        try await store().append(revision("EDITB", source: .userEdit, secondsOffset: 20,
                                          parentID: "REV0", text: "edit b"), captureID: captureID)
        try await store().append(revision("M", source: .machineRetranscribe, secondsOffset: 30,
                                          text: "retranscribed"), captureID: captureID)

        let snapshot = EntryChainSnapshot.build(captureDirectory: captureDirectory)

        XCTAssertTrue(snapshot.isForked, "EDITA/EDITB neither is in the other's ancestry")
        XCTAssertEqual(snapshot.currentRevisionID, "EDITB", "later by (createdAt, id)")
        XCTAssertEqual(snapshot.detachedMachineRevisions.map(\.id), ["M"])
        XCTAssertEqual(snapshot.detachedMachineRevisions.first?.isForked, true,
                       "the chain-wide forked flag must be threaded onto the summary too")
    }

    // MARK: - 2.3 Draft passthrough

    func testOpenDraftIsReturned() async throws {
        try await store().append(revision("R0", text: "hello"), captureID: captureID)
        let opened = Date(timeIntervalSince1970: 1_700_000_100)
        try await store().writeDraft(captureID: captureID, text: "hello, edited", now: opened)

        let snapshot = EntryChainSnapshot.build(captureDirectory: captureDirectory)

        XCTAssertEqual(snapshot.openDraft?.text, "hello, edited")
        XCTAssertEqual(snapshot.openDraft?.captureID, captureID)
        XCTAssertEqual(snapshot.openDraft?.parentID, "R0")
    }

    func testCaptureWithNoDraftReturnsNil() async throws {
        try await store().append(revision("R0", text: "hello"), captureID: captureID)

        let snapshot = EntryChainSnapshot.build(captureDirectory: captureDirectory)

        XCTAssertNil(snapshot.openDraft)
    }

    // MARK: - 2.4 THE read-path test

    /// Copied pattern from `TranscriptRevisionStoreTests`' 3.6 (T6 Task 3.6): every
    /// static read must leave the whole capture directory byte- and mtime-identical.
    /// Includes revisions, a stray draft.json, AND an `entry.json` (Minor 7, fix round
    /// 1 — the one file `build` reads through a store API, `EntryMetadataStore.read`,
    /// that the original fixture omitted entirely).
    func testReadPathWritesNothing() async throws {
        try await store().append(revision("R0", text: "hello"), captureID: captureID)
        try await store().append(revision("R1", source: .userEdit, secondsOffset: 10,
                                          parentID: "R0", text: "hello there"), captureID: captureID)
        let draft = TranscriptDraft(captureID: captureID, parentID: "R1",
                                    openedAt: Date(timeIntervalSince1970: 1_700_000_100),
                                    lastWriteAt: Date(timeIntervalSince1970: 1_700_000_200),
                                    text: "in progress")
        try CaptureCoding.encoder().encode(draft)
            .write(to: SegmentLayout.transcriptDraftURL(captureDirectory: captureDirectory))
        try EntryMetadataStore.write(EntryMetadata(journalID: "J1"), url: sidecarURL)

        let before = try snapshotTree(captureDirectory)

        _ = EntryChainSnapshot.build(captureDirectory: captureDirectory)

        let after = try snapshotTree(captureDirectory)
        XCTAssertEqual(before, after, "EntryChainSnapshot.build must never write")
    }

    // MARK: - chainByteSize definition (#39)

    /// Pins the FULL definition (Important 1, fix round 1: the original test only pinned
    /// the exclusion half — head.json/draft.json out — via `XCTAssertGreaterThan(…, 0)`,
    /// which a "sum only decodable files" bug would also satisfy). Two canonical files,
    /// ONE of them undecodable garbage — `chainByteSize` must equal their combined raw
    /// size regardless, matching the doc comment's "readable or not".
    func testChainByteSizeCountsOnlyCanonicalRevisionFilesExcludingHeadAndDraftEvenWhenOneIsCorrupt() async throws {
        let url0 = try writeRawCanonical(0, try validJSON(for: revision("R0")))
        let url1 = try writeRawCanonical(1, "{ not valid json at all, corrupted")
        let expected = try fileSize(url0) + fileSize(url1)

        // No head.json in this fixture (writeRawCanonical doesn't mint one — only
        // `append` does); pad a draft.json to a known, large, nonzero size so a bug that
        // swept it in would be caught too.
        try Data(repeating: 0, count: 999).write(
            to: SegmentLayout.transcriptDraftURL(captureDirectory: captureDirectory))

        let snapshot = EntryChainSnapshot.build(captureDirectory: captureDirectory)

        XCTAssertEqual(snapshot.chainByteSize, expected,
                       "must equal BOTH canonical files' combined raw size (one is corrupt), excluding the 999-byte draft.json")
    }

    /// T7 Task 3 ruling 2: `DirectorySnapshot.revisionsByteSize` (the diagnostics
    /// screen's cheap, corpus-wide stat) and `chainByteSize` (the revision-history
    /// panel's per-entry read) are two INDEPENDENTLY computed directory listings over
    /// the same `transcript/` — this pins that they can never silently disagree about
    /// one entry's chain size, using the same "one readable + one corrupt" fixture the
    /// test above already established as load-bearing (a "sum only decodable files" bug
    /// in either implementation would be caught here too).
    func testRevisionsByteSizeOnDirectorySnapshotMatchesChainByteSizeExactly() throws {
        try writeRawCanonical(0, try validJSON(for: revision("R0")))
        try writeRawCanonical(1, "{ not valid json at all, corrupted")

        let chainSnapshot = EntryChainSnapshot.build(captureDirectory: captureDirectory)
        let directorySnapshot = DirectorySnapshot.gather(capturesRoot: capturesRoot)
        let capture = try XCTUnwrap(directorySnapshot.captures.first { $0.captureID == captureID })

        XCTAssertGreaterThan(chainSnapshot.chainByteSize, 0, "sanity: the fixture must actually carry bytes")
        XCTAssertEqual(Int64(try XCTUnwrap(capture.revisionsByteSize)), chainSnapshot.chainByteSize,
                       "the history panel and the diagnostics screen must never disagree about one entry's chain size")
    }

    // MARK: - orderedChain (T7 Task 8, fix round 1)

    /// The panel's whole content list: EVERY revision, `(createdAt, id)` order, each
    /// labeled machine vs human by its own `source`, and marked detached ONLY when
    /// genuinely orphaned — never re-derived by a caller (Task 8's own view consumes
    /// this as-is).
    ///
    /// Non-degenerate fixture (standing rule), all three properties at once:
    /// - **Ordering**: appended in an order where FILE NUMBER does not match
    ///   `createdAt` order (DETACHED is file 0 but the middle revision by time; ROOT is
    ///   file 1 but the earliest), so file-number order (or insertion order) would
    ///   produce a different sequence than the real `(createdAt, id)` order.
    /// - **Labeling**: three DIFFERENT sources (`.machineLive`, `.machineRetranscribe`,
    ///   `.userEdit`) so a transposed or hardcoded label is representable.
    /// - **Detachment**: ROOT is `current`'s own ancestor (must NOT be detached — the
    ///   whole point of the fix round 1, Task 2 owner ruling) AND DETACHED is genuinely
    ///   orphaned (must BE detached) — both poles present in one fixture, so marking
    ///   either one wrong is representable.
    func testOrderedChainOrdersLabelsAndMarksDetachmentOverTheWholeChain() async throws {
        try await store().append(revision("DETACHED", source: .machineRetranscribe, secondsOffset: 20,
                                          text: "detached"), captureID: captureID)              // file 0
        try await store().append(revision("ROOT", source: .machineLive, secondsOffset: 0,
                                          text: "root"), captureID: captureID)                  // file 1
        try await store().append(revision("CUR", source: .userEdit, secondsOffset: 30,
                                          parentID: "ROOT", text: "current"), captureID: captureID) // file 2

        let snapshot = EntryChainSnapshot.build(captureDirectory: captureDirectory)

        XCTAssertEqual(snapshot.currentRevisionID, "CUR")
        XCTAssertEqual(snapshot.orderedChain.map { $0.summary.id }, ["ROOT", "DETACHED", "CUR"],
                       "(createdAt, id) order — ROOT is earliest by time despite being file 1, "
                       + "not file-number order (which would be DETACHED, ROOT, CUR)")
        XCTAssertEqual(snapshot.orderedChain.map { $0.summary.source },
                       [.machineLive, .machineRetranscribe, .userEdit],
                       "each row labeled by its OWN revision's source")
        XCTAssertEqual(snapshot.orderedChain.map(\.isDetached), [false, true, false],
                       "ROOT is CUR's own ancestor (not detached); DETACHED is genuinely orphaned "
                       + "(detached); CUR is current (never detached)")
        XCTAssertEqual(snapshot.orderedChain.map { $0.summary.fileNumber }, [1, 0, 2],
                       "each row still carries its OWN file number after reordering by time")
    }

    /// `detachedMachineRevisions` (Task 2's original, narrower field) must be exactly
    /// the `orderedChain` rows with `isDetached == true` — a FILTER of the same list,
    /// never a second independent computation that could disagree with it.
    func testDetachedMachineRevisionsIsExactlyTheDetachedSubsetOfOrderedChain() async throws {
        try await store().append(revision("DETACHED", source: .machineRetranscribe, secondsOffset: 20,
                                          text: "detached"), captureID: captureID)
        try await store().append(revision("ROOT", source: .machineLive, secondsOffset: 0,
                                          text: "root"), captureID: captureID)
        try await store().append(revision("CUR", source: .userEdit, secondsOffset: 30,
                                          parentID: "ROOT", text: "current"), captureID: captureID)

        let snapshot = EntryChainSnapshot.build(captureDirectory: captureDirectory)

        XCTAssertEqual(snapshot.detachedMachineRevisions.map(\.id),
                       snapshot.orderedChain.filter(\.isDetached).map { $0.summary.id })
        XCTAssertEqual(snapshot.detachedMachineRevisions.map(\.id), ["DETACHED"])
    }

    /// Every branch that collapses `currentRevisionID` to `nil` must leave
    /// `orderedChain` empty too — it is derived from the same readable chain, never
    /// independently.
    func testOrderedChainIsEmptyWhenThereIsNoCurrentRevision() throws {
        let snapshot = EntryChainSnapshot.build(captureDirectory: captureDirectory)

        XCTAssertNil(snapshot.currentRevisionID)
        XCTAssertEqual(snapshot.orderedChain, [])
    }

    // MARK: - Sidecar-unreadable edge case (beyond the 5 required fixtures)

    /// Not one of the brief's 5 required Editability fixtures, but a real read-path edge
    /// case worth pinning: a present-but-undecodable `entry.json` must not read as
    /// `.editable` even over an otherwise perfectly healthy chain, because
    /// `TranscriptRevisionStore`'s own write guards (`guardWritable`) throw outright on
    /// exactly this sidecar — an `.editable` reading here would reproduce the "editor let
    /// me start typing, then the save refused" bug the precedence rule exists to prevent.
    ///
    /// Important 4 (fix round 1, owner ruling): pins the SPECIFIC case now —
    /// `.readOnlyMetadataUnreadable`, not the false `.readOnlyTrashed` label the entry
    /// used to get.
    func testUndecodableSidecarIsMetadataUnreadableNotTrashed() async throws {
        try await store().append(revision("R0", text: "hello"), captureID: captureID)
        try Data("{ not a valid sidecar at all".utf8).write(to: sidecarURL)

        let snapshot = EntryChainSnapshot.build(captureDirectory: captureDirectory)

        guard case .readOnlyMetadataUnreadable(let reason) = snapshot.editability else {
            return XCTFail("expected .readOnlyMetadataUnreadable, got \(snapshot.editability)")
        }
        XCTAssertFalse(reason.isEmpty)
    }

    // MARK: - LibraryScreenModel wiring

    func testModelChainSnapshotWiresThroughToTheSameBuild() async throws {
        try await store().append(revision("R0", text: "hello"), captureID: captureID)

        let direct = EntryChainSnapshot.build(captureDirectory: captureDirectory)
        let viaModel = await model().chainSnapshot(for: captureID)

        XCTAssertEqual(direct, viaModel)
    }

    // MARK: - Helpers

    private struct FileSnapshot: Equatable {
        var relativePath: String
        var contents: Data
        var modificationDate: Date?
    }

    private func snapshotTree(_ root: URL) throws -> [FileSnapshot] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                             options: [], errorHandler: nil) else {
            return []
        }
        var snapshots: [FileSnapshot] = []
        for case let url as URL in enumerator {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            let attrs = try fm.attributesOfItem(atPath: url.path)
            snapshots.append(FileSnapshot(
                relativePath: url.path.replacingOccurrences(of: root.path, with: ""),
                contents: try Data(contentsOf: url),
                modificationDate: attrs[.modificationDate] as? Date))
        }
        return snapshots.sorted { $0.relativePath < $1.relativePath }
    }
}
