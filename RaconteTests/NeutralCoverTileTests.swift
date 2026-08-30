import XCTest
@testable import Raconte

final class NeutralCoverTileTests: XCTestCase {
    func testMonogramTakesFirstCharacterUppercased() {
        XCTAssertEqual(NeutralCoverTile.monogramText("blue rabbit 2026"), "B")
    }

    func testMonogramTrimsLeadingWhitespace() {
        XCTAssertEqual(NeutralCoverTile.monogramText("  journal"), "J")
    }

    func testMonogramNilForBlankOrMissingName() {
        XCTAssertNil(NeutralCoverTile.monogramText("   "))
        XCTAssertNil(NeutralCoverTile.monogramText(""))
        XCTAssertNil(NeutralCoverTile.monogramText(nil))
    }
}
