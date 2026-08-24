import XCTest
import CloudKit
@testable import Raconte

/// The routing table `CloudKitEngineControl.handleFailedSaves` switches on. The delegate
/// method itself takes `CKSyncEngine` failure types nothing outside CloudKit can build,
/// so the decision is pulled out here where a plain `CKError.Code` drives it.
final class SaveFailureDispositionTests: XCTestCase {

    func testAConflictWithAServerCopyMerges() {
        XCTAssertEqual(SaveFailureDisposition.decide(code: .serverRecordChanged, hasServerRecord: true),
                       .mergeConflict)
    }

    /// The pre-existing rule: a conflict that hands back no server copy has nothing to
    /// merge and was always dropped to the next reconciliation.
    func testAConflictWithoutAServerCopyDrops() {
        XCTAssertEqual(SaveFailureDisposition.decide(code: .serverRecordChanged, hasServerRecord: false),
                       .drop)
    }

    func testUnknownItemRecreates() {
        XCTAssertEqual(SaveFailureDisposition.decide(code: .unknownItem, hasServerRecord: false),
                       .recreate)
    }

    /// A sibling taken down by another record's failure in the same atomic batch did
    /// nothing wrong: it goes out again untouched.
    func testBatchRequestFailedRetries() {
        XCTAssertEqual(SaveFailureDisposition.decide(code: .batchRequestFailed, hasServerRecord: false),
                       .retry)
    }

    /// Everything else — including `.zoneNotFound`, deliberately left out of this plan
    /// because the zone is re-saved on every engine start — is logged and dropped.
    func testEverythingElseDrops() {
        for code in [CKError.Code.zoneNotFound, .quotaExceeded, .networkFailure, .internalError] {
            XCTAssertEqual(SaveFailureDisposition.decide(code: code, hasServerRecord: false), .drop,
                           "\(code)")
        }
    }
}
