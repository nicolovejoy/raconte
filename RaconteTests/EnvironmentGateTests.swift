import XCTest
@testable import Raconte

/// #90: the whole gate policy as a pure table. Every cell is pinned — this table
/// is what decides whether an owner's sync cache is deleted, so no cell is
/// "obvious enough" to skip.
final class EnvironmentGateTests: XCTestCase {

    func testMatchingTagProceeds() {
        XCTAssertEqual(EnvironmentGate.decide(tag: .production, detected: .production,
                                              bookkeepingExists: true), .proceed)
        XCTAssertEqual(EnvironmentGate.decide(tag: .development, detected: .development,
                                              bookkeepingExists: true), .proceed)
        // A matching tag with no other bookkeeping is still just "proceed".
        XCTAssertEqual(EnvironmentGate.decide(tag: .production, detected: .production,
                                              bookkeepingExists: false), .proceed)
    }

    func testFreshInstallWritesTagWithoutWiping() {
        XCTAssertEqual(EnvironmentGate.decide(tag: nil, detected: .production,
                                              bookkeepingExists: false), .writeTag)
        XCTAssertEqual(EnvironmentGate.decide(tag: nil, detected: .development,
                                              bookkeepingExists: false), .writeTag)
    }

    /// The migration cell that frees the dev-stranded archive: bookkeeping written
    /// before tagging existed is unknown provenance — wipe it.
    func testPreTagUpgradeWipes() {
        XCTAssertEqual(EnvironmentGate.decide(tag: nil, detected: .production,
                                              bookkeepingExists: true), .wipeAndWriteTag)
        XCTAssertEqual(EnvironmentGate.decide(tag: nil, detected: .development,
                                              bookkeepingExists: true), .wipeAndWriteTag)
    }

    func testMismatchWipesBothDirections() {
        XCTAssertEqual(EnvironmentGate.decide(tag: .development, detected: .production,
                                              bookkeepingExists: true), .wipeAndWriteTag)
        XCTAssertEqual(EnvironmentGate.decide(tag: .production, detected: .development,
                                              bookkeepingExists: true), .wipeAndWriteTag)
        // Mismatched tag but nothing else on disk: the tag itself is stale state — wipe.
        XCTAssertEqual(EnvironmentGate.decide(tag: .development, detected: .production,
                                              bookkeepingExists: false), .wipeAndWriteTag)
    }
}
