import XCTest
@testable import Raconte

/// #83: the two-second undo window behind swipe-to-trash, as pure state. The model owns
/// the clock and the timer; this pins what arm / undo / expiry mean.
final class TrashLingerTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000)
    private let a = "01AAAAAAAAAAAAAAAAAAAAAAAA"
    private let b = "01BBBBBBBBBBBBBBBBBBBBBBBB"

    func testArmMakesTheEntryLingerAndASecondArmIsANoOp() {
        var linger = TrashLinger(window: 2)
        XCTAssertFalse(linger.isLingering(a))
        XCTAssertTrue(linger.arm(a, now: t0))
        XCTAssertTrue(linger.isLingering(a))
        XCTAssertFalse(linger.arm(a, now: t0.addingTimeInterval(1)),
                       "a second swipe during the window must not re-arm (and must not restart the clock)")
    }

    func testUndoDuringTheWindowClearsItAndNothingExpiresLater() {
        var linger = TrashLinger(window: 2)
        _ = linger.arm(a, now: t0)
        XCTAssertTrue(linger.undo(a))
        XCTAssertFalse(linger.isLingering(a))
        XCTAssertEqual(linger.expire(now: t0.addingTimeInterval(10)), [])
    }

    func testExpireReturnsOnlyEntriesWhoseWindowHasPassed() {
        var linger = TrashLinger(window: 2)
        _ = linger.arm(a, now: t0)
        _ = linger.arm(b, now: t0.addingTimeInterval(1.5))
        XCTAssertEqual(linger.expire(now: t0.addingTimeInterval(1.999)), [],
                       "nothing has reached its window yet")
        XCTAssertEqual(linger.expire(now: t0.addingTimeInterval(2)), [a],
                       "the window is inclusive at exactly 2 s")
        XCTAssertTrue(linger.isLingering(b))
        XCTAssertEqual(linger.expire(now: t0.addingTimeInterval(3.5)), [b])
        XCTAssertTrue(linger.isEmpty)
    }

    func testUndoAfterExpiryIsFalse() {
        var linger = TrashLinger(window: 2)
        _ = linger.arm(a, now: t0)
        _ = linger.expire(now: t0.addingTimeInterval(2))
        XCTAssertFalse(linger.undo(a), "once the window has closed the Trash view is the only way back")
    }

    func testASecondArmDoesNotRestartTheClock() {
        var linger = TrashLinger(window: 2)
        _ = linger.arm(a, now: t0)
        _ = linger.arm(a, now: t0.addingTimeInterval(1.9))
        XCTAssertEqual(linger.expire(now: t0.addingTimeInterval(2)), [a],
                       "the original arm time governs; the ignored re-arm must not extend the window")
    }

    func testUndoOfAnUnknownIDIsFalse() {
        var linger = TrashLinger(window: 2)
        XCTAssertFalse(linger.undo(a))
    }
}
