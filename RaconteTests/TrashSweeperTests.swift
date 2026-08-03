import XCTest
@testable import Raconte

/// The sweep against a real `captures/` tree (M3 T5): what it gathers, what it removes,
/// and — the part that matters — everything it refuses to touch.
final class TrashSweeperTests: XCTestCase {

    private var containerRoot: URL!
    private var capturesRoot: URL { AppContainer.capturesRoot(containerRoot: containerRoot) }
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        containerRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrashSweeper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: capturesRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let containerRoot { try? FileManager.default.removeItem(at: containerRoot) }
    }

    private func captureDir(_ id: String) -> URL {
        SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: id)
    }

    private func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    private func sweeper() -> TrashSweeper {
        TrashSweeper(capturesRoot: capturesRoot, now: { [now] in now })
    }

    private func exists(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: captureDir(id).path)
    }

    /// A finalized capture: an `.m4a` and a transcript, i.e. everything
    /// `holdsIrreplaceableArtifacts` protects.
    @discardableResult
    private func writeCapture(_ id: String, trashedAt: Date?) throws -> URL {
        let dir = captureDir(id)
        let final = SegmentLayout.finalDirectory(captureDirectory: dir)
        try FileManager.default.createDirectory(at: final, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 64)
            .write(to: SegmentLayout.finalRecordingURL(captureDirectory: dir))
        let transcript = SegmentLayout.transcriptDirectory(captureDirectory: dir)
        try FileManager.default.createDirectory(at: transcript, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: SegmentLayout.liveTranscriptURL(captureDirectory: dir))
        if let trashedAt {
            try EntryMetadataStore.write(EntryMetadata(trashedAt: trashedAt),
                                         url: SegmentLayout.entryMetadataURL(captureDirectory: dir))
        }
        return dir
    }

    private func writeRawSidecar(_ id: String, bytes: Data) throws {
        let dir = captureDir(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try bytes.write(to: SegmentLayout.entryMetadataURL(captureDirectory: dir))
    }

    // MARK: - Gather

    func testGatherReportsAbsentUnreadableAndPresentSeparately() throws {
        try writeCapture("A", trashedAt: nil)                      // no sidecar at all
        try writeCapture("B", trashedAt: daysAgo(1))
        try writeRawSidecar("C", bytes: Data("{ not json".utf8))

        let candidates = TrashSweeper.gather(capturesRoot: capturesRoot)

        XCTAssertEqual(candidates.map(\.captureID), ["A", "B", "C"])
        XCTAssertEqual(candidates[0].sidecar, .absent)
        XCTAssertEqual(candidates[1].sidecar, .present(EntryMetadata(trashedAt: daysAgo(1))))
        XCTAssertEqual(candidates[2].sidecar, .unreadable)
    }

    func testGatherOverAMissingRootIsEmpty() {
        let missing = containerRoot.appendingPathComponent("nope", isDirectory: true)
        XCTAssertEqual(TrashSweeper.gather(capturesRoot: missing), [])
    }

    // MARK: - Run

    func testExpiredCaptureIsRemovedWholeEvenThoughItHoldsIrreplaceableArtifacts() async throws {
        try writeCapture("A", trashedAt: daysAgo(31))

        // Precondition: this is exactly the tree recovery would refuse to delete.
        let snapshot = DirectorySnapshot.gather(capturesRoot: capturesRoot)
        XCTAssertTrue(snapshot.captures[0].holdsIrreplaceableArtifacts)

        let result = await sweeper().run()

        XCTAssertEqual(result.deleted, ["A"])
        XCTAssertTrue(result.skipped.isEmpty)
        XCTAssertFalse(exists("A"))
    }

    func testRecentlyTrashedCaptureIsKeptWithItsCountdown() async throws {
        try writeCapture("A", trashedAt: daysAgo(3))

        let result = await sweeper().run()

        XCTAssertTrue(result.deleted.isEmpty)
        XCTAssertEqual(result.skipped,
                       [SkippedSweep(captureID: "A", reason: .withinRetention(daysRemaining: 27))])
        XCTAssertTrue(exists("A"))
    }

    func testUntrashedCaptureIsNeitherDeletedNorReported() async throws {
        try writeCapture("A", trashedAt: nil)

        let result = await sweeper().run()

        XCTAssertTrue(result.isEmpty)
        XCTAssertTrue(exists("A"))
    }

    /// The guard, end to end. An unreadable sidecar survives the sweep **byte for byte**:
    /// the directory is still there and nothing wrote defaults over the file it failed to
    /// parse. Both halves matter — writing `{}` back would silently un-delete a trashed
    /// entry (or, next month, delete a live one).
    func testUnreadableSidecarIsSkippedAndLeftByteForByte() async throws {
        try writeCapture("A", trashedAt: nil)
        let corrupt = Data("{ \"trashedAt\": ".utf8)
        try writeRawSidecar("A", bytes: corrupt)

        let result = await sweeper().run()

        XCTAssertTrue(result.deleted.isEmpty)
        XCTAssertEqual(result.skipped,
                       [SkippedSweep(captureID: "A", reason: .metadataUnreadable)])
        XCTAssertTrue(exists("A"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: SegmentLayout.finalRecordingURL(captureDirectory: captureDir("A")).path))
        XCTAssertEqual(
            try Data(contentsOf: SegmentLayout.entryMetadataURL(captureDirectory: captureDir("A"))),
            corrupt)
    }

    /// A sidecar whose `trashedAt` is present with the wrong *type* is unreadable too,
    /// not "no tombstone". `EntryMetadata`'s decoder is lenient about absent keys and
    /// strict about malformed ones, and the sweep inherits exactly that line.
    func testWrongTypedTombstoneIsUnreadableNotUntrashed() async throws {
        try writeCapture("A", trashedAt: nil)
        try writeRawSidecar("A", bytes: Data("{\"trashedAt\":\"not-a-date\"}".utf8))

        let result = await sweeper().run()

        XCTAssertEqual(result.skipped,
                       [SkippedSweep(captureID: "A", reason: .metadataUnreadable)])
        XCTAssertTrue(exists("A"))
    }

    func testMixedTreeDeletesOnlyTheExpiredOnes() async throws {
        try writeCapture("A", trashedAt: daysAgo(45))
        try writeCapture("B", trashedAt: daysAgo(5))
        try writeCapture("C", trashedAt: nil)
        try writeCapture("D", trashedAt: daysAgo(30))
        try writeRawSidecar("E", bytes: Data("nope".utf8))

        let result = await sweeper().run()

        XCTAssertEqual(result.deleted, ["A", "D"])
        XCTAssertFalse(exists("A"))
        XCTAssertTrue(exists("B"))
        XCTAssertTrue(exists("C"))
        XCTAssertFalse(exists("D"))
        XCTAssertTrue(exists("E"))
    }

    /// Applying the same sweep twice reaches the same place — the second pass simply
    /// finds nothing to do, the way `RecoveryExecutor` tolerates already-applied state.
    func testSweepIsIdempotent() async throws {
        try writeCapture("A", trashedAt: daysAgo(31))

        _ = await sweeper().run()
        let second = await sweeper().run()

        XCTAssertTrue(second.isEmpty)
        XCTAssertFalse(exists("A"))
    }
}
