import XCTest
@testable import Raconte

/// M4 T3: `SyncPlanner.reconcile` is pure — a scan vs. the upload ledger, no IO.
/// Governing rule under test throughout: it enqueues exactly (new) ∪ (digest-changed),
/// and NEVER infers a delete from a ledger entry with no surviving scan artifact —
/// that path belongs to Task 11's explicit CloudKit-delete flow.
final class SyncPlannerTests: XCTestCase {

    private let idA = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
    private let idB = "01BRZ3NDEKTSV4RRFFQ69G5FAW"

    private func artifact(_ name: SyncRecordName, sha256: String, bytes: Int) -> SyncArtifactState {
        SyncArtifactState(name: name, sha256: sha256, bytes: bytes)
    }

    // MARK: New artifacts

    func testArtifactAbsentFromLedgerIsEnqueued() {
        let artifact = artifact(.entry(captureID: idA), sha256: "aaa", bytes: 10)
        let result = SyncPlanner.reconcile(scan: [artifact], ledger: [:])
        XCTAssertEqual(result, [.entry(captureID: idA)])
    }

    func testMultipleNewArtifactsAllEnqueued() {
        let entry = artifact(.entry(captureID: idA), sha256: "aaa", bytes: 10)
        let audio = artifact(.audio(captureID: idA), sha256: "bbb", bytes: 20)
        let result = SyncPlanner.reconcile(scan: [entry, audio], ledger: [:])
        XCTAssertEqual(Set(result), Set([.entry(captureID: idA), .audio(captureID: idA)]))
    }

    // MARK: Unchanged artifacts

    func testArtifactMatchingTheLedgerExactlyIsNotEnqueued() {
        let name = SyncRecordName.entry(captureID: idA)
        let artifact = artifact(name, sha256: "aaa", bytes: 10)
        let ledger = [name.rawValue: UploadedDigest(sha256: "aaa", bytes: 10)]
        XCTAssertEqual(SyncPlanner.reconcile(scan: [artifact], ledger: ledger), [])
    }

    // MARK: Digest-changed artifacts

    func testArtifactWithChangedSha256IsEnqueuedEvenWhenBytesMatch() {
        // The named mutation-check scenario: same size, different content. A planner
        // that compares only `bytes` must fail this.
        let name = SyncRecordName.entry(captureID: idA)
        let artifact = artifact(name, sha256: "new-content-hash", bytes: 10)
        let ledger = [name.rawValue: UploadedDigest(sha256: "old-content-hash", bytes: 10)]
        XCTAssertEqual(SyncPlanner.reconcile(scan: [artifact], ledger: ledger), [name])
    }

    func testArtifactWithChangedBytesIsEnqueued() {
        let name = SyncRecordName.entry(captureID: idA)
        let artifact = artifact(name, sha256: "aaa", bytes: 99)
        let ledger = [name.rawValue: UploadedDigest(sha256: "aaa", bytes: 10)]
        XCTAssertEqual(SyncPlanner.reconcile(scan: [artifact], ledger: ledger), [name])
    }

    // MARK: Deletes are never inferred from absence

    func testLedgerEntryWithNoSurvivingArtifactProducesNothing() {
        // A scan racing against an in-flight staged removal (#25) could observe a
        // capture briefly missing from `captures/` on its way to `trash-pending/` —
        // the scan here reports zero artifacts for it, exactly that race. The ledger
        // still remembers it was uploaded. Reconcile must produce NOTHING for it:
        // deletes are Task 11's explicit CloudKit-delete path, never inferred here.
        let name = SyncRecordName.entry(captureID: idA)
        let ledger = [name.rawValue: UploadedDigest(sha256: "aaa", bytes: 10)]
        let result = SyncPlanner.reconcile(scan: [], ledger: ledger)
        XCTAssertTrue(result.isEmpty)
        XCTAssertFalse(result.contains(name))
    }

    func testLedgerEntryForOneArtifactDoesNotAffectAnUnrelatedNewOne() {
        // A vanished (ledger-only) entry alongside a genuinely new one: only the new
        // one is enqueued, and the vanished one produces no delete or any other entry.
        let vanished = SyncRecordName.entry(captureID: idA)
        let newOne = artifact(.entry(captureID: idB), sha256: "ccc", bytes: 5)
        let ledger = [vanished.rawValue: UploadedDigest(sha256: "aaa", bytes: 10)]
        let result = SyncPlanner.reconcile(scan: [newOne], ledger: ledger)
        XCTAssertEqual(result, [.entry(captureID: idB)])
    }

    // MARK: Mixed scan, cardinality check

    func testMixOfNewChangedAndUnchangedResolvesEachIndependently() {
        let unchangedName = SyncRecordName.entry(captureID: idA)
        let changedName = SyncRecordName.audio(captureID: idA)
        let newName = SyncRecordName.liveLog(captureID: idA)

        let scan = [
            artifact(unchangedName, sha256: "same", bytes: 1),
            artifact(changedName, sha256: "new-hash", bytes: 2),
            artifact(newName, sha256: "brand-new", bytes: 3),
        ]
        let ledger = [
            unchangedName.rawValue: UploadedDigest(sha256: "same", bytes: 1),
            changedName.rawValue: UploadedDigest(sha256: "old-hash", bytes: 2),
        ]

        let result = SyncPlanner.reconcile(scan: scan, ledger: ledger)
        XCTAssertEqual(Set(result), Set([changedName, newName]))
    }

    func testEmptyScanAndEmptyLedgerProducesNothing() {
        XCTAssertTrue(SyncPlanner.reconcile(scan: [], ledger: [:]).isEmpty)
    }
}
