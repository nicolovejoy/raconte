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
}
