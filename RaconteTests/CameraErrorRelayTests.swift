import XCTest
@testable import Raconte

/// #182: a failed camera add raises its alert exactly once, on THIS round-trip,
/// whichever lands first — the cover's dismissal or the add's verdict. The old relay
/// (a flag set after `await onPick`, consumed by `.onChange(of: showingCamera)`)
/// only worked when the verdict came first, which it never does: the cover is told
/// to dismiss in the same closure that starts the write, so the `onChange` has fired
/// before the flag exists and the alert waited for the NEXT camera round-trip.
final class CameraErrorRelayTests: XCTestCase {

    /// The real-world order: dismissal first, verdict after the disk write.
    func testVerdictAfterDismissalRaisesImmediately() {
        var relay = CameraErrorRelay()
        relay.cameraPresented()
        XCTAssertFalse(relay.coverDismissed(), "nothing has failed yet")
        XCTAssertTrue(relay.addFailed(), "the cover is down, so the alert can go up now")
    }

    /// The order the old relay assumed: verdict first, dismissal after.
    func testVerdictBeforeDismissalIsParkedUntilTheCoverIsDown() {
        var relay = CameraErrorRelay()
        relay.cameraPresented()
        XCTAssertFalse(relay.addFailed(), "the cover is still up — presenting now would be dropped")
        XCTAssertTrue(relay.coverDismissed(), "the parked failure is raised once the cover is down")
    }

    func testARaisedFailureIsNotRaisedAgainOnTheNextDismissal() {
        var relay = CameraErrorRelay()
        relay.cameraPresented()
        _ = relay.addFailed()
        XCTAssertTrue(relay.coverDismissed())
        relay.cameraPresented()
        XCTAssertFalse(relay.coverDismissed(), "#182's symptom: a stale failure alerting against a later shot")
    }

    func testASuccessfulRoundTripRaisesNothing() {
        var relay = CameraErrorRelay()
        relay.cameraPresented()
        XCTAssertFalse(relay.coverDismissed())
        relay.cameraPresented()
        XCTAssertFalse(relay.coverDismissed())
    }

    /// Presenting the camera again discards anything parked from before — a failure
    /// that never got raised belongs to a round-trip the owner has moved past.
    func testPresentingTheCameraClearsAParkedFailure() {
        var relay = CameraErrorRelay()
        relay.cameraPresented()
        _ = relay.addFailed()
        relay.cameraPresented()
        XCTAssertFalse(relay.coverDismissed())
    }

    /// Before any presentation the cover is down by definition, so a verdict
    /// arriving with no round-trip in flight raises straight away rather than parking.
    func testFreshRelayTreatsTheCoverAsDown() {
        var relay = CameraErrorRelay()
        XCTAssertTrue(relay.addFailed())
    }
}
