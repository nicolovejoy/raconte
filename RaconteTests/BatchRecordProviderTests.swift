import XCTest
import CloudKit
@testable import Raconte

/// #94 cause 1: a nil from the batch's recordProvider does NOT remove the pending
/// change — `RecordZoneChangeBatch.init` is a value init with no State access, so
/// the provider itself must call `state.remove` before answering nil, or the name
/// retries forever across launches via `engine-state.bin`.
///
/// `CloudKitEngineControl` cannot be unit-tested with a live `CKSyncEngine`
/// (`PendingEngineChangesTests` precedent), so the provider body is the static
/// `CloudKitEngineControl.provideRecord`, driven here with a fake exchange and a
/// recording remove closure; `nextRecordZoneChangeBatch` routes through it.
final class BatchRecordProviderTests: XCTestCase {

    private let zoneID = CKRecordZone.ID(zoneName: "RaconteZone")

    /// Minimal fake: answers `recordToPush` from a closure; every other member is
    /// an unreachable-in-these-tests no-op.
    private final class FakeExchange: CloudRecordExchange, @unchecked Sendable {
        var record: (@Sendable (SyncRecordName) -> CKRecord?) = { _ in nil }
        func recordToPush(for name: SyncRecordName, zoneID: CKRecordZone.ID) async -> CKRecord? {
            record(name)
        }
        func acceptRemote(_ record: CKRecord) async {}
        func noteSaved(_ record: CKRecord) async {}
        func noteSaveFailed(for name: SyncRecordName) async {}
        func resolveUnknownItem(for name: SyncRecordName) async -> Bool { false }
        func resolvePushConflicts(_ serverRecords: [CKRecord]) async -> [SyncRecordName] { [] }
        func acceptRemoteJournalDeletion(id: String) async {}
        func acceptRemoteEntryDeletion(captureID: String) async {}
    }

    private final class RemoveRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _removed: [CKRecord.ID] = []
        var removed: [CKRecord.ID] { lock.withLock { _removed } }
        func callAsFunction(_ id: CKRecord.ID) { lock.withLock { _removed.append(id) } }
    }

    func testABuildableRecordIsReturnedAndNothingIsRemoved() async {
        let name = SyncRecordName.journal(id: "01J00000000000000000000001")
        let recordID = SyncCloudIdentifiers.recordID(name, zoneID: zoneID)
        let exchange = FakeExchange()
        exchange.record = { _ in CKRecord(recordType: "Journal", recordID: recordID) }
        let remover = RemoveRecorder()

        let record = await CloudKitEngineControl.provideRecord(
            for: recordID, exchange: exchange, zoneID: zoneID,
            removePendingSave: { remover($0) })

        XCTAssertNotNil(record)
        XCTAssertEqual(remover.removed, [], "a buildable record must not touch pending state")
    }

    func testAnUnbuildableRecordIsRemovedFromPendingAndAnsweredNil() async {
        let name = SyncRecordName.entry(captureID: "01J00000000000000000000002")
        let recordID = SyncCloudIdentifiers.recordID(name, zoneID: zoneID)
        let exchange = FakeExchange()   // recordToPush answers nil
        let remover = RemoveRecorder()

        let record = await CloudKitEngineControl.provideRecord(
            for: recordID, exchange: exchange, zoneID: zoneID,
            removePendingSave: { remover($0) })

        XCTAssertNil(record)
        XCTAssertEqual(remover.removed, [recordID],
                       "nil alone removes nothing — the provider must remove the pending save itself")
    }

    func testAnUnparseableRecordNameIsRemovedFromPendingAndAnsweredNil() async {
        let recordID = CKRecord.ID(recordName: "not-a-raconte-name", zoneID: zoneID)
        let exchange = FakeExchange()
        let remover = RemoveRecorder()

        let record = await CloudKitEngineControl.provideRecord(
            for: recordID, exchange: exchange, zoneID: zoneID,
            removePendingSave: { remover($0) })

        XCTAssertNil(record)
        XCTAssertEqual(remover.removed, [recordID])
    }
}
