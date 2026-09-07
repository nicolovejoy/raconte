import XCTest
@testable import Raconte

/// `UnknownItemResend.plan` is the pure decision behind #91: when a `.recreate`
/// disposition (`SaveFailureDisposition`) finds no archived server state for a child
/// record, is it still safe to resend it right now? Yes, iff its parent Entry is ALSO
/// being resent in this same failure event — the reference target will exist by the
/// time this batch lands. `handleFailedSaves` is private on a class the test suite
/// never constructs (`SyncCoordinatorTests.swift`), so this is tested in isolation:
/// plain `SyncRecordName` values in, a resend order out, no CloudKit type anywhere.
final class UnknownItemResendTests: XCTestCase {

    private let c = ULID.make()

    func testARecordWithServerStateIsResent() {
        let e = SyncRecordName.entry(captureID: c)
        XCTAssertEqual(UnknownItemResend.plan([.init(name: e, hadServerState: true, parent: nil)]), [e])
    }

    func testAChildWithoutServerStateWhoseParentIsResentIsResentAfterIt() {
        let e = SyncRecordName.entry(captureID: c)
        let a = SyncRecordName.audio(captureID: c)
        let plan = UnknownItemResend.plan([
            .init(name: a, hadServerState: false, parent: e),   // child FIRST in the event
            .init(name: e, hadServerState: true, parent: nil),
        ])
        XCTAssertEqual(plan, [e, a])
    }

    func testAChildWithoutServerStateWhoseParentIsNotInTheEventIsLeftForReconcile() {
        let a = SyncRecordName.audio(captureID: c)
        let e = SyncRecordName.entry(captureID: c)
        let plan = UnknownItemResend.plan([
            .init(name: a, hadServerState: false, parent: e),
        ])
        XCTAssertEqual(plan, [])
    }

    func testARevisionUsesTheEntryRefDerivedParent() {
        let e = SyncRecordName.entry(captureID: c)
        let r = SyncRecordName.revision(id: ULID.make())
        let plan = UnknownItemResend.plan([
            .init(name: r, hadServerState: false, parent: e),
            .init(name: e, hadServerState: true, parent: nil),
        ])
        XCTAssertEqual(plan, [e, r])
    }

    /// The parent itself found nothing archived either — its own `.recreate` reported
    /// `hadServerState: false` — so it is NOT in this event's resend set, and the child
    /// riding on it must not be either.
    func testAParentThatItselfHadNoServerStateDoesNotCarryItsChild() {
        let e = SyncRecordName.entry(captureID: c)
        let a = SyncRecordName.audio(captureID: c)
        let plan = UnknownItemResend.plan([
            .init(name: a, hadServerState: false, parent: e),
            .init(name: e, hadServerState: false, parent: nil),
        ])
        XCTAssertEqual(plan, [])
    }
}
