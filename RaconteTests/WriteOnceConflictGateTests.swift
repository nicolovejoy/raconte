import XCTest
@testable import Raconte

/// Decision table for a `serverRecordChanged` rejection of a WRITE-ONCE record
/// (sync investigation RESOLVED section): the server copy's `sha256` field is
/// available without downloading its asset, so a byte-identical copy can be settled
/// as already-uploaded; anything else is a divergence write-once records must not
/// paper over.
final class WriteOnceConflictGateTests: XCTestCase {

    private let digest = UploadedDigest(sha256: "abc123", bytes: 42)

    func testMatchingSHASettlesWithTheLocalDigest() {
        XCTAssertEqual(WriteOnceConflictGate.decide(serverSHA256: "abc123", local: digest),
                       .settleAsUploaded(digest))
    }

    func testMismatchedSHAIsDivergent() {
        guard case .divergent = WriteOnceConflictGate.decide(serverSHA256: "def456",
                                                             local: digest) else {
            return XCTFail("a differing server sha must never settle")
        }
    }

    func testServerCopyWithoutSHAIsDivergent() {
        guard case .divergent = WriteOnceConflictGate.decide(serverSHA256: nil,
                                                             local: digest) else {
            return XCTFail("a server copy missing its sha256 field must never settle")
        }
    }

    func testEmptyServerSHAIsDivergent() {
        guard case .divergent = WriteOnceConflictGate.decide(serverSHA256: "",
                                                             local: digest) else {
            return XCTFail("an empty sha256 must never settle")
        }
    }

    func testUnreadableLocalArtifactIsDivergent() {
        guard case .divergent = WriteOnceConflictGate.decide(serverSHA256: "abc123",
                                                             local: nil) else {
            return XCTFail("no local digest must never settle — nothing to credit the ledger with")
        }
    }

    func testWriteOnceMembershipCoversAllSevenNameShapes() {
        XCTAssertTrue(WriteOnceConflictGate.isWriteOnce(.audio(captureID: "C")))
        XCTAssertTrue(WriteOnceConflictGate.isWriteOnce(.liveLog(captureID: "C")))
        XCTAssertTrue(WriteOnceConflictGate.isWriteOnce(.revision(id: "R")))
        XCTAssertTrue(WriteOnceConflictGate.isWriteOnce(.image(captureID: "C", imageID: "I")))
        XCTAssertFalse(WriteOnceConflictGate.isWriteOnce(.journal(id: "J")))
        XCTAssertFalse(WriteOnceConflictGate.isWriteOnce(.entry(captureID: "C")))
        XCTAssertFalse(WriteOnceConflictGate.isWriteOnce(.markerStream(captureID: "C", deviceID: "D")))
    }
}
