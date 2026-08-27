import XCTest
import CloudKit
@testable import Raconte

/// #85 observability: the ingest-drop guards' compound conditions, split into a pure
/// reason table so the drop log line can say WHICH required piece was missing (a
/// genuinely field-less record vs. a failed asset download are different bugs) and
/// which record it dropped. Fixtures are the REAL builders with one field knocked out
/// — never hand-rolled records — so a renamed field fails here, not silently on-device.
final class IngestDropReasonTests: XCTestCase {

    private var scratch: URL!
    private let zoneID = CKRecordZone.ID(zoneName: "RaconteZoneTest", ownerName: CKCurrentUserDefaultName)
    private let captureID = ULID.make()
    private let revisionID = ULID.make()

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("RaconteIngestDropReason-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private var entryID: CKRecord.ID {
        SyncCloudIdentifiers.recordID(.entry(captureID: captureID), zoneID: zoneID)
    }

    private func payloadURL() throws -> URL {
        let url = scratch.appendingPathComponent("payload-\(UUID().uuidString)")
        try Data("payload".utf8).write(to: url)
        return url
    }

    private func audioRecord() throws -> CKRecord {
        SyncRecordBuilders.audioRecord(captureID: captureID, m4aURL: try payloadURL(),
                                       sha256: "abc", bytes: 7, frameCount: 1, sampleRate: 48_000,
                                       entryID: entryID, zoneID: zoneID)
    }

    private func revisionRecord() throws -> CKRecord {
        SyncRecordBuilders.revisionRecord(revisionID: revisionID, fileURL: try payloadURL(),
                                          sha256: "abc", bytes: 7,
                                          entryID: entryID, zoneID: zoneID)
    }

    // MARK: childAsset (AudioAsset / LiveLog)

    func testACompleteChildAssetRecordHasNoDropReason() throws {
        XCTAssertNil(IngestDropReason.childAsset(try audioRecord()))
    }

    func testAChildAssetRecordWithoutItsFileAssetNamesThatField() throws {
        let record = try audioRecord()
        record[SyncChildAssetField.file] = nil
        XCTAssertEqual(IngestDropReason.childAsset(record), "no file asset")
    }

    func testAChildAssetRecordWithoutItsSHA256NamesThatField() throws {
        let record = try audioRecord()
        record[SyncChildAssetField.sha256] = nil
        XCTAssertEqual(IngestDropReason.childAsset(record), "no sha256")
    }

    // MARK: revision

    func testACompleteRevisionRecordHasNoDropReason() throws {
        XCTAssertNil(IngestDropReason.revision(try revisionRecord()))
    }

    func testARevisionRecordWithoutItsBodyAssetNamesThatField() throws {
        let record = try revisionRecord()
        record[SyncRevisionField.body] = nil
        XCTAssertEqual(IngestDropReason.revision(record), "no body asset")
    }

    func testARevisionRecordWithoutItsSHA256NamesThatField() throws {
        let record = try revisionRecord()
        record[SyncChildAssetField.sha256] = nil
        XCTAssertEqual(IngestDropReason.revision(record), "no sha256")
    }

    func testARevisionRecordWithoutItsEntryRefNamesThatField() throws {
        let record = try revisionRecord()
        record[SyncChildAssetField.entryRef] = nil
        XCTAssertEqual(IngestDropReason.revision(record), "no entryRef")
    }

    func testARevisionRecordWhoseEntryRefIsNotAnEntryNameSaysSo() throws {
        let record = try revisionRecord()
        let alienID = CKRecord.ID(recordName: "not-a-parseable-name", zoneID: zoneID)
        record[SyncChildAssetField.entryRef] = CKRecord.Reference(recordID: alienID, action: .deleteSelf)
        XCTAssertEqual(IngestDropReason.revision(record), "entryRef does not name an Entry")
    }
}
