import XCTest
@testable import Raconte

/// T6a: the ONE join rule (design rule 8), factored out of `TranscriptConsolidator`
/// so revision assembly (later T6a tasks) can share it instead of reimplementing it.
final class TranscriptTextTests: XCTestCase {

    func testJoinFiltersEmptyPiecesAndSpaceSeparates() {
        XCTAssertEqual(TranscriptText.join(["a", "", "b"]), "a b")
    }

    func testJoinOfEmptyArrayIsEmptyString() {
        XCTAssertEqual(TranscriptText.join([]), "")
    }
}
