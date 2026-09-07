import XCTest
@testable import Raconte

/// Fix wave finding 6: `RefetchChunking.chunks` is the pure helper
/// `CloudKitEngineControl.refetch` uses to keep each `database.records(for:)` call under
/// CloudKit's per-call id cap. Tested directly with plain arrays — no CloudKit, no IO.
final class RefetchChunkingTests: XCTestCase {

    func testTwoHundredFiftyNamesSplitIntoThreeChunksOfOneHundredOneHundredFifty() {
        let names = (0..<250).map { "n\($0)" }

        let chunks = RefetchChunking.chunks(names, size: 100)

        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks[0].count, 100)
        XCTAssertEqual(chunks[1].count, 100)
        XCTAssertEqual(chunks[2].count, 50)
        XCTAssertEqual(chunks.flatMap { $0 }, names, "order and membership preserved")
    }

    func testEmptyInputProducesNoChunks() {
        XCTAssertEqual(RefetchChunking.chunks([], size: 100), [])
    }
}
