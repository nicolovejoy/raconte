import XCTest
import CloudKit
@testable import Raconte

/// Tripwire for #70: every stored field of `Journal` must survive the full
/// sync round trip (journalRecord → RemoteJournal(record:) → adopted(remote:)).
/// When `Journal` gains a field, the Mirror pin fails FIRST — bump the count,
/// give the new field a NON-DEFAULT value in `fullyPopulatedJournal`, and the
/// equality test below stays red until SyncRecordBuilders and SyncIngest both
/// carry the field. Bumping the count alone must never be enough.
final class SyncJournalRoundTripTests: XCTestCase {

    private static let zoneID = CKRecordZone.ID(zoneName: "RaconteZoneTest", ownerName: CKCurrentUserDefaultName)

    /// A well-formed Crockford-base32 ULID (no I/L/O/U) — `RemoteJournal.init?(record:)`
    /// derives the journal id from the record name via `ULID.isWellFormed`, so an id
    /// spelling that merely *looks* like a ULID (e.g. containing an "O") would fail to
    /// round-trip for a reason that has nothing to do with the fields under test.
    static let fullyPopulatedJournal = Journal(
        id: "01JTESTRNDTRP0000000000001",
        name: "Round Trip",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        voiceLabels: ["bn": "Big Nico", "ln": "Little Nico"],
        modified: ["name": Date(timeIntervalSince1970: 1_700_000_100),
                   "voiceLabels": Date(timeIntervalSince1970: 1_700_000_200)]
    )

    func testJournalFieldCountMatchesTheSyncFixture() {
        XCTAssertEqual(
            Mirror(reflecting: Self.fullyPopulatedJournal).children.count, 5,
            "Journal gained or lost a field. Bump this count, add a NON-DEFAULT value for the field to fullyPopulatedJournal, then wire the field through SyncRecordBuilders.journalRecord, RemoteJournal, JournalMerge.merge, and JournalMerge.adopted until testEveryJournalFieldSurvivesTheSyncRoundTrip passes."
        )
    }

    func testEveryJournalFieldSurvivesTheSyncRoundTrip() throws {
        let journal = Self.fullyPopulatedJournal
        let record = SyncRecordBuilders.journalRecord(
            journal: journal, coverFileURL: nil,
            deviceID: "device-a", zoneID: Self.zoneID, base: nil)
        let remote = try XCTUnwrap(RemoteJournal(record: record),
            "a record this build just wrote must be ingestible by the same build")
        let adopted = JournalMerge.adopted(remote: remote)
        XCTAssertEqual(adopted, journal,
            "a field was dropped somewhere in journalRecord → RemoteJournal → adopted")
    }
}
