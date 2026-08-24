import XCTest
import CloudKit
@testable import Raconte

/// The self-heal for a push that came back `CKError.unknownItem` (server NOT_FOUND).
/// Seen for real 2026-08-23: records first synced under the dev CloudKit environment
/// carried dev change tags into the first production push and failed identically
/// forever. No server, no engine — the exchange and bookkeeping run on a throwaway
/// container root.
final class SyncUnknownItemTests: XCTestCase {

    private var containerRoot: URL!
    private let zoneID = CKRecordZone.ID(zoneName: "RaconteZoneTest", ownerName: CKCurrentUserDefaultName)
    private let deviceID = "AAAAAAAAAAAAAAAAAAAAAAAAAA"

    override func setUpWithError() throws {
        containerRoot = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("RaconteSyncUnknownItem-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: containerRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: containerRoot)
    }

    private struct Fixture {
        let store: JournalStore
        let bookkeeping: SyncBookkeepingStore
        let scanner: SyncTreeScanner
        let exchange: SyncRecordExchange
    }

    private func fixture() -> Fixture {
        let store = JournalStore(containerRoot: containerRoot)
        let covers = JournalCoverStore(containerRoot: containerRoot, journalStore: store)
        let bookkeeping = SyncBookkeepingStore(root: AppContainer.syncRoot(containerRoot: containerRoot))
        let scanner = SyncTreeScanner(containerRoot: containerRoot, deviceID: deviceID)
        let exchange = SyncRecordExchange(journalStore: store, coverStore: covers,
                                          bookkeeping: bookkeeping, deviceID: deviceID,
                                          containerRoot: containerRoot)
        return Fixture(store: store, bookkeeping: bookkeeping, scanner: scanner, exchange: exchange)
    }

    /// Pushes `name` once through the real exchange so its system fields are archived
    /// and its upload is ledgered — the exact state a record synced under the dev
    /// environment is in when the app first talks to production.
    private func pushOnce(_ name: SyncRecordName, through exchange: SyncRecordExchange) async throws {
        let built = await exchange.recordToPush(for: name, zoneID: zoneID)
        let record = try XCTUnwrap(built)
        await exchange.noteSaved(record)
    }

    /// The bug: stale archived state makes every push an UPDATE against an ID the
    /// server never had. After resolving, the record must read as never-uploaded — no
    /// system fields (next build is a CREATE), no ledger entry (reconciliation would
    /// re-enqueue it) — and the answer must be `true`, the caller's cue to re-enqueue
    /// at once rather than wait for a relaunch.
    func testStaleServerStateIsDroppedAndTheRecordReadsAsNeverUploaded() async throws {
        let f = fixture()
        let created = try await f.store.create(name: "Synced under dev")
        let name = SyncRecordName.journal(id: created.id)
        try await pushOnce(name, through: f.exchange)
        let fieldsBefore = await f.bookkeeping.systemFields(for: name.rawValue)
        XCTAssertNotNil(fieldsBefore, "fixture sanity: archived system fields exist")

        let hadServerState = await f.exchange.resolveUnknownItem(for: name)

        let fieldsAfter = await f.bookkeeping.systemFields(for: name.rawValue)
        let ledgerAfter = await f.bookkeeping.ledger()
        let plan = SyncPlanner.reconcile(scan: f.scanner.scan().artifacts, ledger: ledgerAfter)
        XCTAssertTrue(hadServerState, "there was stale state to drop, so the caller re-enqueues now")
        XCTAssertNil(fieldsAfter, "next push must be a create, not an update against a dev change tag")
        XCTAssertNil(ledgerAfter[name.rawValue], "reads as never-uploaded")
        XCTAssertTrue(plan.contains(name), "and reconciliation agrees: it would re-enqueue this journal")
        let rebuilt = await f.exchange.recordToPush(for: name, zoneID: zoneID)
        XCTAssertNotNil(rebuilt, "the local copy is still pushed — nothing local is dropped on a server's say-so")
    }

    /// A NOT_FOUND with nothing archived is not stale metadata — it is a child whose
    /// Entry has not landed (dangling `CKRecord.Reference`). Re-enqueueing it would fail
    /// the same way forever, so the answer must be `false`, and nothing local moves.
    func testARecordWithNoArchivedStateReportsFalseAndIsLeftToReconciliation() async throws {
        let f = fixture()
        let created = try await f.store.create(name: "Never pushed")
        let name = SyncRecordName.journal(id: created.id)

        let hadServerState = await f.exchange.resolveUnknownItem(for: name)

        let fields = await f.bookkeeping.systemFields(for: name.rawValue)
        let ledger = await f.bookkeeping.ledger()
        let survivor = try await f.store.journal(id: created.id)
        XCTAssertFalse(hadServerState)
        XCTAssertNil(fields)
        XCTAssertNil(ledger[name.rawValue])
        XCTAssertNotNil(survivor, "resolving is bookkeeping only — never touches the journal itself")
    }

    /// Batches fail atomically, so the poisoned record's siblings arrive in the same
    /// failure list. Only the name asked about may lose its archived state.
    func testResolvingOneNameLeavesEverySiblingsArchivedStateIntact() async throws {
        let f = fixture()
        let poisoned = try await f.store.create(name: "Poisoned")
        let sibling = try await f.store.create(name: "Healthy sibling")
        let poisonedName = SyncRecordName.journal(id: poisoned.id)
        let siblingName = SyncRecordName.journal(id: sibling.id)
        try await pushOnce(poisonedName, through: f.exchange)
        try await pushOnce(siblingName, through: f.exchange)

        _ = await f.exchange.resolveUnknownItem(for: poisonedName)

        let siblingFields = await f.bookkeeping.systemFields(for: siblingName.rawValue)
        let ledger = await f.bookkeeping.ledger()
        XCTAssertNotNil(siblingFields, "the sibling's change tag is valid and must be kept")
        XCTAssertNotNil(ledger[siblingName.rawValue])
        XCTAssertNil(ledger[poisonedName.rawValue])
    }
}
