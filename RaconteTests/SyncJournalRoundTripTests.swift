import XCTest
import CloudKit
@testable import Raconte

/// Tripwire for #70: every stored field of `Journal` must survive the full
/// sync round trip, through BOTH paths a fetched record can take —
/// journalRecord → RemoteJournal(record:) → adopted(remote:) (a journal this device has
/// never seen) AND journalRecord → RemoteJournal(record:) → JournalMerge.merge (a journal
/// that already exists locally too, which is the common case). When `Journal` gains a
/// field, the Mirror pin fails FIRST — bump the count, give the new field a NON-DEFAULT
/// value in `fullyPopulatedJournal`, and BOTH round-trip tests below must pass before the
/// field is considered wired through: SyncRecordBuilders, RemoteJournal,
/// JournalMerge.merge, and JournalMerge.adopted. Bumping the count alone must never be
/// enough, and passing only one of the two round trips must never be enough either — see
/// gate finding F1 on 2026-08-20's m4-sync-takes-main plan for why `merge` needed its own
/// leg: `adopted` only runs for a journal the receiving device has never seen, so a field
/// wired into `adopted` and forgotten in `merge` would still pass a count bump and this
/// file's first test while never actually merging on every device that already has the
/// journal.
final class SyncJournalRoundTripTests: XCTestCase {

    private static let zoneID = CKRecordZone.ID(zoneName: "RaconteZoneTest", ownerName: CKCurrentUserDefaultName)

    /// A well-formed Crockford-base32 ULID (no I/L/O/U) — `RemoteJournal.init?(record:)`
    /// derives the journal id from the record name via `ULID.isWellFormed`, so an id
    /// spelling that merely *looks* like a ULID (e.g. containing an "O") would fail to
    /// round-trip for a reason that has nothing to do with the fields under test.
    ///
    /// `modified` carries a stamp for every LWW-eligible field (name, voiceLabels, span,
    /// cover) — not just the two `Journal` happens to declare doc comments for — because
    /// `testEveryJournalFieldSurvivesAMergeAdoption` needs the remote to out-stamp a local
    /// on every field to prove `merge` actually pulls the remote's value across; a field
    /// with no stamp in either fixture can only ever keep local's own value (LWWResolve's
    /// "no stamps at all → local" rule), which would make that leg of the test pass
    /// vacuously regardless of whether `merge` really wires the field.
    static let fullyPopulatedJournal = Journal(
        id: "01JTESTRNDTRP0000000000001",
        name: "Round Trip",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        voiceLabels: ["bn": "Big Nico", "ln": "Little Nico"],
        span: try! JournalSpan(start: PartialDate(year: 1998), end: PartialDate(year: 2001)),
        modified: ["name": Date(timeIntervalSince1970: 1_700_000_100),
                   "voiceLabels": Date(timeIntervalSince1970: 1_700_000_200),
                   "span": Date(timeIntervalSince1970: 1_700_000_300),
                   "cover": Date(timeIntervalSince1970: 1_700_000_400)]
    )

    func testJournalFieldCountMatchesTheSyncFixture() {
        XCTAssertEqual(
            Mirror(reflecting: Self.fullyPopulatedJournal).children.count, 7,
            "Journal gained or lost a field. Bump this count, add a NON-DEFAULT value for the field to fullyPopulatedJournal, then wire the field through SyncRecordBuilders.journalRecord, RemoteJournal, JournalMerge.merge, and JournalMerge.adopted until BOTH testEveryJournalFieldSurvivesTheSyncRoundTrip and testEveryJournalFieldSurvivesAMergeAdoption pass. EXCEPTION (#84): `provisionalDefault` is the one field deliberately left OUT of every one of those — it describes only this device's local push state (never pushed yet), which by construction can never be true of anything that reached this test's round trip through a CKRecord at all. It stays at its default (`false`) in `fullyPopulatedJournal` on purpose, which is why the count bumped to 7 here without also touching the sync sites this comment names."
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

    /// Gate F2 (for #70): `adopted(remote:)` alone never exercises `JournalMerge.merge` —
    /// the path every already-known journal actually takes. Merge the same fully-populated
    /// remote against a LOCAL counterpart whose every field is older and different, so
    /// `merge` must pull every field across from the remote (not just keep what happened
    /// to already match), and assert whole-value equality with the fixture.
    func testEveryJournalFieldSurvivesAMergeAdoption() throws {
        let journal = Self.fullyPopulatedJournal
        let record = SyncRecordBuilders.journalRecord(
            journal: journal, coverFileURL: nil,
            deviceID: "device-a", zoneID: Self.zoneID, base: nil)
        let remote = try XCTUnwrap(RemoteJournal(record: record),
            "a record this build just wrote must be ingestible by the same build")

        // Same journal id (a merge is two devices' copies of ONE journal); every other
        // field differs from the remote's, and every stamp predates the remote's, so
        // `merge` must resolve `.remote` on all four LWW fields for the assertion below to
        // hold — a merge that silently kept any local field would fail it.
        let staleStamp = Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(-1)
        let local = Journal(
            id: journal.id,
            name: "Stale Local Name",
            createdAt: journal.createdAt,
            voiceLabels: ["bn": "Stale"],
            span: try JournalSpan(start: PartialDate(year: 1970), end: nil),
            modified: ["name": staleStamp, "voiceLabels": staleStamp,
                       "span": staleStamp, "cover": staleStamp])

        let merged = JournalMerge.merge(local: local, remote: remote,
                                        localDeviceID: "device-b",
                                        remoteDeviceID: remote.deviceID)
        XCTAssertEqual(merged, journal,
            "a field was dropped somewhere in journalRecord → RemoteJournal → merge")
    }
}
