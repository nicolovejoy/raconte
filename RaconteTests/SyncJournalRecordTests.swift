import XCTest
import CloudKit
@testable import Raconte

/// M4 T5: the Journal record's wire shape (design §2), both directions.
///
/// **No server, no account, no `CKSyncEngine`.** `CKRecord`, `CKRecord.ID` and `CKAsset`
/// are all constructible offline, which is exactly why the record *content* decisions live
/// in `SyncRecordBuilders`/`RemoteJournal` rather than inside `CloudKitEngineControl` —
/// everything asserted here would otherwise be device-smoke-only.
final class SyncJournalRecordTests: XCTestCase {

    private let zoneID = CKRecordZone.ID(zoneName: "RaconteZoneTest", ownerName: CKCurrentUserDefaultName)
    private let deviceID = ULID.make()
    private let journalID = ULID.make()
    private var containerRoot: URL!

    override func setUpWithError() throws {
        containerRoot = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("RaconteSyncJournalRecord-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: containerRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: containerRoot)
    }

    /// Dates that survive `CaptureCoding`'s ISO8601-with-milliseconds encoding exactly, so
    /// a comparison failure means the merge is wrong rather than the clock.
    private func stamp(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(offset)
    }

    private func journal(voiceLabels: [String: String] = [:],
                         modified: [String: Date]? = nil) -> Journal {
        Journal(id: journalID, name: "1987 Journal", createdAt: stamp(0),
                voiceLabels: voiceLabels, modified: modified)
    }

    // MARK: Builder — field coverage

    /// Names every field the design table lists, plus the two as-built additions. A
    /// builder that quietly stopped writing one of them would otherwise pass every other
    /// test in this file, and the field would simply never sync.
    func testJournalRecordCarriesEveryFieldInTheDesignTable() {
        let source = journal(voiceLabels: ["bn": "Grandpa"],
                             modified: ["name": stamp(10), "voiceLabels": stamp(20)])
        let coverURL = containerRoot.appendingPathComponent("cover.jpg")
        try! Data("jpeg-bytes".utf8).write(to: coverURL)

        let record = SyncRecordBuilders.journalRecord(journal: source, coverFileURL: coverURL,
                                                      deviceID: deviceID, zoneID: zoneID)

        XCTAssertEqual(record.recordType, "Journal")
        XCTAssertEqual(record.recordID.recordName, "j.\(journalID)",
                       "the record name is the parseable SyncRecordName, not a bare ULID")
        XCTAssertEqual(record.recordID.zoneID, zoneID)
        XCTAssertEqual(record["name"] as? String, "1987 Journal")
        XCTAssertEqual(record["createdAt"] as? Date, stamp(0))
        XCTAssertEqual(record["voiceLabels"] as? String, #"{"bn":"Grandpa"}"#)
        XCTAssertEqual(record["deviceID"] as? String, deviceID)
        XCTAssertNotNil(record["cover"] as? CKAsset)
        XCTAssertEqual((record["cover"] as? CKAsset)?.fileURL, coverURL)

        // The stamps themselves — without them the receiving device cannot do per-field
        // LWW at all and silently falls back to whole-record.
        let stamps: [String: Date] = SyncRecordBuilders.decodeJSON(record["modified"] as? String)
        XCTAssertEqual(stamps, ["name": stamp(10), "voiceLabels": stamp(20)])
    }

    func testVoiceLabelsTravelAsASortedKeysJSONString() {
        let source = journal(voiceLabels: ["ln": "Ellen", "bn": "Grandpa"])
        let record = SyncRecordBuilders.journalRecord(journal: source, coverFileURL: nil,
                                                      deviceID: deviceID, zoneID: zoneID)
        // Sorted keys, not dictionary order: two devices building the same labels must
        // produce byte-identical strings, or every push looks like a change.
        XCTAssertEqual(record["voiceLabels"] as? String, #"{"bn":"Grandpa","ln":"Ellen"}"#)
    }

    func testAbsentCoverProducesNoAssetFieldAtAll() {
        let record = SyncRecordBuilders.journalRecord(journal: journal(), coverFileURL: nil,
                                                      deviceID: deviceID, zoneID: zoneID)
        XCTAssertNil(record["cover"])
        XCTAssertFalse(record.allKeys().contains("cover"))
    }

    /// The opposite of the rule `Journal`'s own encoder follows on disk. Omitting an empty
    /// map keeps an untouched journal's bytes stable in `journals.json`; omitting it from
    /// a *record* would leave the server's previous value in place, so "I removed every
    /// voice label" would be the one journal edit that never syncs.
    func testEmptyVoiceLabelsAndStampsTravelAsEmptyObjectsRatherThanAbsentFields() {
        let record = SyncRecordBuilders.journalRecord(journal: journal(), coverFileURL: nil,
                                                      deviceID: deviceID, zoneID: zoneID)
        XCTAssertEqual(record["voiceLabels"] as? String, "{}")
        XCTAssertEqual(record["modified"] as? String, "{}")
    }

    /// Rebuilding onto archived system fields is what makes a push carry the server's
    /// change tag — without it CloudKit can never answer "the server copy moved", and
    /// every conflict silently resolves as a clobber.
    func testRebuildingOnArchivedSystemFieldsKeepsRecordIdentityAndAppliesNewValues() throws {
        let first = SyncRecordBuilders.journalRecord(journal: journal(), coverFileURL: nil,
                                                     deviceID: deviceID, zoneID: zoneID)
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        first.encodeSystemFields(with: archiver)
        archiver.finishEncoding()

        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData)
        unarchiver.requiresSecureCoding = true
        let base = try XCTUnwrap(CKRecord(coder: unarchiver))
        unarchiver.finishDecoding()

        var renamed = journal()
        renamed.name = "1987 Journal, renamed"
        let second = SyncRecordBuilders.journalRecord(journal: renamed, coverFileURL: nil,
                                                     deviceID: deviceID, zoneID: zoneID, base: base)

        XCTAssertEqual(second.recordID, first.recordID)
        XCTAssertEqual(second.recordType, "Journal")
        XCTAssertEqual(second["name"] as? String, "1987 Journal, renamed")
    }

    // MARK: RemoteJournal — decode

    func testRemoteJournalDecodesEveryFieldTheBuilderWrote() throws {
        let coverURL = containerRoot.appendingPathComponent("cover.jpg")
        try Data("jpeg-bytes".utf8).write(to: coverURL)
        let source = journal(voiceLabels: ["bn": "Grandpa"],
                             modified: ["name": stamp(10), "cover": stamp(30)])
        let record = SyncRecordBuilders.journalRecord(journal: source, coverFileURL: coverURL,
                                                      deviceID: deviceID, zoneID: zoneID)

        let remote = try XCTUnwrap(RemoteJournal(record: record))
        XCTAssertEqual(remote.id, journalID)
        XCTAssertEqual(remote.name, "1987 Journal")
        XCTAssertEqual(remote.createdAt, stamp(0))
        XCTAssertEqual(remote.voiceLabels, ["bn": "Grandpa"])
        XCTAssertEqual(remote.modified, ["name": stamp(10), "cover": stamp(30)])
        XCTAssertEqual(remote.coverAsset, coverURL)
        XCTAssertEqual(remote.deviceID, deviceID)
    }

    /// The load-bearing one. `journals.json` stores stamps at millisecond resolution
    /// (`CaptureCoding`'s ISO8601), and the record carries them through the same encoder —
    /// if the two disagreed by so much as a microsecond, a value that had merely made a
    /// round trip through the cloud would compare as strictly newer than itself, and the
    /// two devices would push the same journal at each other forever.
    func testStampsRoundTripAtExactlyTheResolutionJournalsJSONStores() throws {
        let odd = Date(timeIntervalSince1970: 1_700_000_000.123)
        let source = journal(modified: ["name": odd])

        let record = SyncRecordBuilders.journalRecord(journal: source, coverFileURL: nil,
                                                      deviceID: deviceID, zoneID: zoneID)
        let remote = try XCTUnwrap(RemoteJournal(record: record))

        // What the disk would hold, through the same encoder `JournalStore.save` uses.
        let onDisk = try CaptureCoding.decoder()
            .decode(Journal.self, from: try CaptureCoding.lineEncoder().encode(source))

        XCTAssertEqual(remote.modified["name"], onDisk.modified?["name"])
        XCTAssertEqual(LWWResolve.winner(localStamp: onDisk.modified?["name"],
                                         remoteStamp: remote.modified["name"],
                                         localDeviceID: "AAA", remoteDeviceID: "AAA"),
                       .local,
                       "a stamp that merely round-tripped must not read as newer than itself")
    }

    func testRemoteJournalRefusesRecordsMissingAnIdentityField() {
        let recordID = CKRecord.ID(recordName: "j.\(journalID)", zoneID: zoneID)

        let noName = CKRecord(recordType: "Journal", recordID: recordID)
        noName["createdAt"] = stamp(0)
        XCTAssertNil(RemoteJournal(record: noName), "a nameless journal cannot be filed under a name")

        let blankName = CKRecord(recordType: "Journal", recordID: recordID)
        blankName["name"] = "   "
        blankName["createdAt"] = stamp(0)
        XCTAssertNil(RemoteJournal(record: blankName), "whitespace is the same as no name (JournalError.emptyName)")

        let noCreatedAt = CKRecord(recordType: "Journal", recordID: recordID)
        noCreatedAt["name"] = "1987 Journal"
        XCTAssertNil(RemoteJournal(record: noCreatedAt))
    }

    func testRemoteJournalRefusesTheWrongRecordTypeOrAnUnparseableName() {
        let wrongType = CKRecord(recordType: "Entry",
                                 recordID: CKRecord.ID(recordName: "j.\(journalID)", zoneID: zoneID))
        wrongType["name"] = "1987 Journal"
        wrongType["createdAt"] = stamp(0)
        XCTAssertNil(RemoteJournal(record: wrongType))

        let wrongName = CKRecord(recordType: "Journal",
                                 recordID: CKRecord.ID(recordName: "e.\(journalID)", zoneID: zoneID))
        wrongName["name"] = "1987 Journal"
        wrongName["createdAt"] = stamp(0)
        XCTAssertNil(RemoteJournal(record: wrongName),
                     "an Entry record name must never decode as a journal")

        let garbage = CKRecord(recordType: "Journal",
                               recordID: CKRecord.ID(recordName: "not-a-record-name", zoneID: zoneID))
        garbage["name"] = "1987 Journal"
        garbage["createdAt"] = stamp(0)
        XCTAssertNil(RemoteJournal(record: garbage))
    }

    /// Lenient exactly where `Journal.init(from:)` is lenient, and for the same reason: a
    /// damaged additive field must cost that field, never the journal.
    func testRemoteJournalDegradesDamagedVoiceLabelsAndStampsToEmpty() throws {
        let record = CKRecord(recordType: "Journal",
                              recordID: CKRecord.ID(recordName: "j.\(journalID)", zoneID: zoneID))
        record["name"] = "1987 Journal"
        record["createdAt"] = stamp(0)
        record["voiceLabels"] = "not json at all"
        record["modified"] = "{{{"

        let remote = try XCTUnwrap(RemoteJournal(record: record))
        XCTAssertEqual(remote.name, "1987 Journal")
        XCTAssertEqual(remote.voiceLabels, [:])
        XCTAssertEqual(remote.modified, [:])
    }
}
