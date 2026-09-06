import XCTest
@testable import Raconte

final class AtomicFileTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtomicFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func read(_ url: URL) throws -> Data { try Data(contentsOf: url) }
    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    struct SimulatedCrash: Error {}

    func testReplaceWritesFullContentAndCleansPart() throws {
        let target = dir.appendingPathComponent("f.txt")
        let part = SegmentLayout.partURL(for: target)

        try AtomicFile.replace(at: target, writing: Data("A".utf8))
        XCTAssertEqual(try read(target), Data("A".utf8))
        XCTAssertFalse(exists(part), "no stray .part after a clean replace")

        // Overwrite in place.
        try AtomicFile.replace(at: target, writing: Data("BBBB".utf8))
        XCTAssertEqual(try read(target), Data("BBBB".utf8))
        XCTAssertFalse(exists(part))
    }

    func testReplaceEmptyData() throws {
        let target = dir.appendingPathComponent("empty.bin")
        try AtomicFile.replace(at: target, writing: Data())
        XCTAssertTrue(exists(target))
        XCTAssertEqual(try read(target).count, 0)
    }

    func testReplaceNeverPartialUnderLargePayload() throws {
        let target = dir.appendingPathComponent("big.bin")
        let payload = Data((0..<(1 << 20)).map { UInt8($0 & 0xFF) })  // 1 MiB
        try AtomicFile.replace(at: target, writing: payload)
        XCTAssertEqual(try read(target), payload)
    }

    /// Interrupted-write simulation: the write happens but the rename never does.
    /// The original file must remain fully intact (design §1: reader sees old or new).
    func testInterruptedWriteLeavesOriginalIntact() throws {
        let target = dir.appendingPathComponent("f.txt")
        let part = SegmentLayout.partURL(for: target)

        try AtomicFile.replace(at: target, writing: Data("ORIGINAL".utf8))

        XCTAssertThrowsError(
            try AtomicFile.replace(at: target, writing: Data("NEWDATA".utf8),
                                   beforeRename: { throw SimulatedCrash() })
        ) { XCTAssertTrue($0 is SimulatedCrash) }

        // Original untouched; the new bytes are stranded in the .part sibling.
        XCTAssertEqual(try read(target), Data("ORIGINAL".utf8))
        XCTAssertTrue(exists(part), "crashed write leaves a stray .part (recovery deletes it)")
        XCTAssertEqual(try read(part), Data("NEWDATA".utf8))
    }

    /// A subsequent clean replace recovers over a stray .part.
    func testReplaceOverStrayPartSucceeds() throws {
        let target = dir.appendingPathComponent("f.txt")
        let part = SegmentLayout.partURL(for: target)

        try AtomicFile.replace(at: target, writing: Data("ORIGINAL".utf8))
        _ = try? AtomicFile.replace(at: target, writing: Data("NEWDATA".utf8),
                                    beforeRename: { throw SimulatedCrash() })
        XCTAssertTrue(exists(part))

        try AtomicFile.replace(at: target, writing: Data("FINAL".utf8))
        XCTAssertEqual(try read(target), Data("FINAL".utf8))
        XCTAssertFalse(exists(part), ".part consumed by the successful rename")
    }

    // MARK: createExclusively

    func testCreateExclusivelyWritesFullContentWithNoStrayPart() throws {
        let target = dir.appendingPathComponent("head.json")

        try AtomicFile.createExclusively(at: target, writing: Data("A".utf8))

        XCTAssertEqual(try read(target), Data("A".utf8))
        let stray = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".part") }
        XCTAssertTrue(stray.isEmpty, "no stray .part after a clean create")
    }

    func testCreateExclusivelyThrowsEEXISTAndLeavesExistingTargetUntouched() throws {
        let target = dir.appendingPathComponent("head.json")
        try AtomicFile.createExclusively(at: target, writing: Data("ORIGINAL".utf8))

        XCTAssertThrowsError(
            try AtomicFile.createExclusively(at: target, writing: Data("NEWDATA".utf8))
        ) { error in
            XCTAssertEqual(error as? AtomicFileError,
                           .posix(operation: "renamex_np", code: EEXIST))
        }

        XCTAssertEqual(try read(target), Data("ORIGINAL".utf8), "existing target must be untouched")
    }

    func testCreateExclusivelyCleansUpPartAfterEEXIST() throws {
        let target = dir.appendingPathComponent("head.json")
        try AtomicFile.createExclusively(at: target, writing: Data("ORIGINAL".utf8))

        _ = try? AtomicFile.createExclusively(at: target, writing: Data("NEWDATA".utf8))

        let stray = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".part") }
        XCTAssertTrue(stray.isEmpty, "the losing .part must be cleaned up, not stranded")
    }

    /// #43: two concurrent creates of the same target used to share ONE `.part` path, so
    /// the EEXIST loser's `unlink` deleted the winner's staging file mid-write. Each call
    /// now stages under its own name. Modelled with the `beforeRename` seam: call 1 is
    /// parked (throws) with its staging file written; call 2 must not truncate or remove
    /// it on its way to the target.
    func testEachCreateStagesUnderItsOwnNameSoALoserCannotClobberAWinner() throws {
        let target = dir.appendingPathComponent("head.json")
        struct Parked: Error {}
        XCTAssertThrowsError(try AtomicFile.createExclusively(at: target, writing: Data("A".utf8),
                                                              beforeRename: { throw Parked() }))
        let staged = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".part") }
        XCTAssertEqual(staged.count, 1, "the parked call must leave exactly its own staging file")
        let parkedURL = dir.appendingPathComponent(staged[0])
        XCTAssertEqual(try read(parkedURL), Data("A".utf8))

        try AtomicFile.createExclusively(at: target, writing: Data("B".utf8))

        XCTAssertEqual(try read(target), Data("B".utf8))
        XCTAssertEqual(try read(parkedURL), Data("A".utf8),
                       "the second create must stage under a different name — the parked writer's bytes are untouched")
    }
}
