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

    func testTranscriptDirAsAFileIsReadOnlyListingUnreadable() throws {
        try Data("not a directory".utf8).write(to: transcriptDirectory)

        let snapshot = EntryChainSnapshot.build(captureDirectory: captureDirectory)

        guard case .readOnlyListingUnreadable = snapshot.editability else {
            return XCTFail("expected .readOnlyListingUnreadable, got \(snapshot.editability)")
        }
        XCTAssertNil(snapshot.currentRevisionID)
        XCTAssertEqual(snapshot.currentText, "")
        XCTAssertEqual(snapshot.revisionCount, 0)
        XCTAssertEqual(snapshot.chainByteSize, 0)
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
    /// The brief's own illustrative outcome for this shape says
    /// `detachedMachineRevisions == [M]`. Traced against the ALREADY-SHIPPED
    /// `TranscriptChain.isAttached` (verified here, and matching the pattern in
    /// `TranscriptChainTests.testF1MachineAfterMachineIsDetached` /
    /// `.testA1DataLossWalk`): `isAttached` requires the human tip to be among a
    /// candidate's OWN ancestors, and rev0 — being the chain's literal root — has NO
    /// ancestors at all, so it can never satisfy that once ANY human tip exists anywhere
    /// in the chain. Applying the brief's own literal rule
    /// (`detachedMachineRevisions = every revision where !isAttached`) to this exact
    /// scenario therefore yields REV0 *and* M, not M alone. This test pins the real,
    /// verified behavior of the shipped primitive rather than silently "fixing" it —
    /// flagged in the task report as a brief/code disagreement for owner attention.
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

        let detachedIDs = Set(snapshot.detachedMachineRevisions.map(\.id))
        XCTAssertEqual(detachedIDs, ["REV0", "M"],
                       "verified TranscriptChain.isAttached behavior — see task report")
        XCTAssertFalse(detachedIDs.contains("REV1"), "current/attached must never appear as detached")

        let mSummary = snapshot.detachedMachineRevisions.first { $0.id == "M" }
        XCTAssertEqual(mSummary?.source, .machineRetranscribe)
        XCTAssertEqual(mSummary?.fileNumber, 2)
        XCTAssertEqual(mSummary?.firstLine, "retranscribed")
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
    /// Includes revisions AND a stray draft.json, so both files the build might be
    /// tempted to "fix" are present.
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

        let before = try snapshotTree(captureDirectory)

        _ = EntryChainSnapshot.build(captureDirectory: captureDirectory)

        let after = try snapshotTree(captureDirectory)
        XCTAssertEqual(before, after, "EntryChainSnapshot.build must never write")
    }

    // MARK: - chainByteSize definition (#39)

    /// Pins the definition (implementer's call, per the brief): only the canonical
    /// revision files count, never `head.json` or `draft.json`.
    func testChainByteSizeCountsOnlyCanonicalRevisionFilesExcludingHeadAndDraft() async throws {
        try await store().append(revision("R0", text: "hello"), captureID: captureID)
        let canonicalURL = SegmentLayout.canonicalTranscriptURL(captureDirectory: captureDirectory, revision: 0)
        let expected = try fileSize(canonicalURL)

        // head.json already exists (persisted by `append`); pad a draft.json to a known,
        // large, nonzero size too — a bug that swept either in would be caught here.
        try Data(repeating: 0, count: 999).write(
            to: SegmentLayout.transcriptDraftURL(captureDirectory: captureDirectory))

        let snapshot = EntryChainSnapshot.build(captureDirectory: captureDirectory)

        XCTAssertEqual(snapshot.chainByteSize, expected,
                       "must equal canonical-0.json's own size, excluding head.json and the 999-byte draft.json")
    }

    // MARK: - Sidecar-unreadable edge case (beyond the 5 required fixtures)

    /// Not one of the brief's 5 required Editability fixtures, but a real read-path edge
    /// case worth pinning: a present-but-undecodable `entry.json` must not read as
    /// `.editable` even over an otherwise perfectly healthy chain, because
    /// `TranscriptRevisionStore`'s own write guards (`guardWritable`) throw outright on
    /// exactly this sidecar — an `.editable` reading here would reproduce the "editor let
    /// me start typing, then the save refused" bug the precedence rule exists to prevent.
    func testUndecodableSidecarIsNeverEditable() async throws {
        try await store().append(revision("R0", text: "hello"), captureID: captureID)
        try Data("{ not a valid sidecar at all".utf8).write(to: sidecarURL)

        let snapshot = EntryChainSnapshot.build(captureDirectory: captureDirectory)

        XCTAssertNotEqual(snapshot.editability, .editable)
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
