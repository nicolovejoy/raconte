import XCTest
@testable import Raconte

/// The ULID minter moved out of `CaptureCoordinator`; its behaviour must not have.
final class ULIDTests: XCTestCase {
    func testShapeAndSortability() {
        let early = ULID.make(now: Date(timeIntervalSince1970: 1_000))
        let late = ULID.make(now: Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(early.count, 26)
        XCTAssertTrue(ULID.isWellFormed(early))
        XCTAssertTrue(early < late, "time-prefixed IDs sort chronologically")
        XCTAssertNotEqual(ULID.make(), ULID.make())
    }

    func testCaptureCoordinatorStillMintsTheSameThing() {
        let now = Date(timeIntervalSince1970: 1_234_567.891)
        let head = { (id: String) in String(id.prefix(10)) }
        XCTAssertEqual(head(CaptureCoordinator.makeULID(now: now)), head(ULID.make(now: now)))
        XCTAssertEqual(ULID.timestamp(from: ULID.make(now: now))
                        .map { ($0.timeIntervalSince1970 * 1000).rounded() },
                       (now.timeIntervalSince1970 * 1000).rounded())
    }

    func testMalformedIDsAreRejected() {
        XCTAssertFalse(ULID.isWellFormed("short"))
        XCTAssertFalse(ULID.isWellFormed("UUUUUUUUUU0000000000000000"))   // U not in Crockford
        XCTAssertFalse(ULID.isWellFormed(String(repeating: "0", count: 27)))
    }
}
