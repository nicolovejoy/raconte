import XCTest
import CloudKit
@testable import Raconte

/// Image-capture plan Task 4, exchange level: `SyncRecordExchange.recordToPush` for an
/// `.image` name — the `revisionRecordToPush`/`audioRecordToPush` sibling. Fixtures
/// mirror `SyncChildHoldbackTests`/`SyncRevisionTests` deliberately.
///
/// No server and no `CKSyncEngine`: `recordToPush` reads local files and hands back a
/// `CKRecord`, all of which is constructible offline.
final class SyncRecordExchangeImagePushTests: XCTestCase {

    private let zoneID = CKRecordZone.ID(zoneName: "RaconteZoneTest", ownerName: CKCurrentUserDefaultName)
    private let captureID = ULID.make()
    private let imageID = ULID.make()
    private let deviceID = "device-low"
    private var containerRoot: URL!

    override func setUpWithError() throws {
        containerRoot = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("RaconteSyncImagePush-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: containerRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: containerRoot)
    }

    private var capturesRoot: URL { AppContainer.capturesRoot(containerRoot: containerRoot) }
    private var captureDirectory: URL {
        SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
    }
    private var entryRecordID: CKRecord.ID {
        SyncCloudIdentifiers.recordID(.entry(captureID: captureID), zoneID: zoneID)
    }
    private var imageName: SyncRecordName { .image(captureID: captureID, imageID: imageID) }

    private func writeVerifiedManifest() throws {
        try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let format = AudioFormatDescriptor(sampleRate: 48_000, channels: 1,
                                           commonFormat: .pcmFormatFloat32, interleaved: false,
                                           bytesPerFrame: 4)
        let manifest = Manifest(captureID: captureID, createdAt: when, state: .complete,
                                stateSeq: 1, stateUpdatedAt: when, format: format,
                                final: FinalRef(verifiedAt: when, durationFrames: 480_000))
        try CaptureCoding.encoder().encode(manifest)
            .write(to: SegmentLayout.manifestURL(captureDirectory: captureDirectory))
    }

    private let imageBytes = Data("the-original-image-bytes".utf8)

    @discardableResult
    private func writeImage(sha256Override: String? = nil, bytesOverride: Int? = nil) throws -> ImageSidecar {
        let sidecar = ImageSidecar(id: imageID, originalExtension: "jpeg", mime: "image/jpeg",
                                   bytes: bytesOverride ?? imageBytes.count,
                                   sha256: sha256Override ?? ImageStore.sha256Hex(imageBytes),
                                   width: 16, height: 9,
                                   capturedAt: Date(timeIntervalSince1970: 1_600_000_000),
                                   addedAt: Date(timeIntervalSince1970: 1_700_000_500))
        try ImageStore.writeOriginal(imageBytes, captureDirectory: captureDirectory,
                                     imageID: imageID, ext: "jpeg")
        try ImageStore.writeSidecar(sidecar, captureDirectory: captureDirectory)
        return sidecar
    }

    private func exchange() -> (SyncRecordExchange, SyncBookkeepingStore) {
        let journalStore = JournalStore(containerRoot: containerRoot)
        let covers = JournalCoverStore(containerRoot: containerRoot, journalStore: journalStore)
        let bookkeeping = SyncBookkeepingStore(root: AppContainer.syncRoot(containerRoot: containerRoot))
        let ex = SyncRecordExchange(journalStore: journalStore, coverStore: covers,
                                    bookkeeping: bookkeeping, deviceID: deviceID,
                                    containerRoot: containerRoot)
        return (ex, bookkeeping)
    }

    /// The happy path, end to end through the orchestrator: the record carries the
    /// ORIGINAL file as its asset, the sidecar's metadata, and a `.deleteSelf`
    /// reference to its Entry. Deliberately on an IMAGE-ONLY capture (no m4a at all) —
    /// the state this whole task exists to make pushable.
    func testRecordToPushBuildsAnImageRecordFromTheOriginalBytes() async throws {
        try writeVerifiedManifest()
        try writeImage()
        let (ex, _) = exchange()

        let answer = await ex.recordToPush(for: imageName, zoneID: zoneID)
        let record = try XCTUnwrap(answer)

        XCTAssertEqual(record.recordType, "Image")
        XCTAssertEqual(record.recordID.recordName, "i.\(captureID).\(imageID)")
        let asset = try XCTUnwrap(record["file"] as? CKAsset)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(asset.fileURL)), imageBytes,
                       "the asset is the original file itself, verbatim")
        XCTAssertEqual(record["sha256"] as? String, ImageStore.sha256Hex(imageBytes))
        XCTAssertEqual(record["bytes"] as? Int, imageBytes.count)
        XCTAssertEqual(record["originalExtension"] as? String, "jpeg")
        XCTAssertEqual(record["width"] as? Int, 16)
        XCTAssertEqual(record["capturedAt"] as? Date, Date(timeIntervalSince1970: 1_600_000_000))
        let ref = try XCTUnwrap(record["entryRef"] as? CKRecord.Reference)
        XCTAssertEqual(ref.recordID, entryRecordID)
        XCTAssertEqual(ref.action, .deleteSelf)
    }

    /// The ledger half: a built record is `note(build:)`-ed, so the save confirmation
    /// has something to credit. Without it `SyncPlanner.reconcile` could never tell
    /// "already uploaded" from "never uploaded" and would re-enqueue this immutable
    /// image on every launch forever (the T9 lesson, restated for this record type).
    func testAConfirmedImageSaveIsRecordedInTheUploadLedger() async throws {
        try writeVerifiedManifest()
        try writeImage()
        let (ex, bookkeeping) = exchange()

        let answer = await ex.recordToPush(for: imageName, zoneID: zoneID)
        let record = try XCTUnwrap(answer)
        await ex.noteSaved(record)

        let ledger = await bookkeeping.ledger()
        XCTAssertEqual(ledger[imageName.rawValue],
                       UploadedDigest(sha256: ImageStore.sha256Hex(imageBytes), bytes: imageBytes.count))
    }

    /// The "file vanished" case, mirroring `revisionRecordToPush`'s: nil, and — the
    /// half that actually matters — NOTHING written to the ledger, so a later
    /// confirmation can never be credited to a record that was never built.
    func testRecordToPushReturnsNilAndLedgersNothingWhenTheOriginalIsMissing() async throws {
        try writeVerifiedManifest()
        try writeImage()
        try FileManager.default.removeItem(
            at: SegmentLayout.imageOriginalURL(captureDirectory: captureDirectory,
                                                imageID: imageID, ext: "jpeg"))
        let (ex, bookkeeping) = exchange()

        let record = await ex.recordToPush(for: imageName, zoneID: zoneID)

        XCTAssertNil(record)
        let ledger = await bookkeeping.ledger()
        XCTAssertNil(ledger[imageName.rawValue], "nothing was built, so nothing may be ledgered")
    }

    /// Existing-but-unreadable original (a directory at the file's path) — the same
    /// "unreadable reads as absent" rule every sibling push applies.
    func testRecordToPushReturnsNilWhenTheOriginalIsUnreadable() async throws {
        try writeVerifiedManifest()
        try writeImage()
        let origURL = SegmentLayout.imageOriginalURL(captureDirectory: captureDirectory,
                                                      imageID: imageID, ext: "jpeg")
        try FileManager.default.removeItem(at: origURL)
        try FileManager.default.createDirectory(at: origURL, withIntermediateDirectories: true)
        let (ex, _) = exchange()

        let record = await ex.recordToPush(for: imageName, zoneID: zoneID)

        XCTAssertNil(record)
    }

    func testRecordToPushReturnsNilWhenTheSidecarIsAbsent() async throws {
        try writeVerifiedManifest()
        let (ex, _) = exchange()

        let record = await ex.recordToPush(for: imageName, zoneID: zoneID)

        XCTAssertNil(record, "an image this device does not have cannot be pushed")
    }

    func testRecordToPushReturnsNilWhenTheSidecarIsUndecodable() async throws {
        try writeVerifiedManifest()
        try writeImage()
        try Data("{ not json".utf8).write(
            to: SegmentLayout.imageSidecarURL(captureDirectory: captureDirectory, imageID: imageID))
        let (ex, _) = exchange()

        let record = await ex.recordToPush(for: imageName, zoneID: zoneID)

        XCTAssertNil(record, "the metadata fields cannot be fabricated from the bytes alone")
    }

    /// An unfinalized capture's image is refused before any file is read — the same
    /// eligibility gate every other child push is behind.
    func testRecordToPushRefusesAnImageOnAnUnfinalizedCapture() async throws {
        try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let format = AudioFormatDescriptor(sampleRate: 48_000, channels: 1,
                                           commonFormat: .pcmFormatFloat32, interleaved: false,
                                           bytesPerFrame: 4)
        let manifest = Manifest(captureID: captureID, createdAt: when, state: .captured,
                                stateSeq: 1, stateUpdatedAt: when, format: format, final: FinalRef())
        try CaptureCoding.encoder().encode(manifest)
            .write(to: SegmentLayout.manifestURL(captureDirectory: captureDirectory))
        try writeImage()
        let (ex, _) = exchange()

        let record = await ex.recordToPush(for: imageName, zoneID: zoneID)

        XCTAssertNil(record)
    }

    /// The bytes are the artifact; the sidecar is derived metadata. If the two ever
    /// disagree, the record must describe the bytes actually travelling — a record
    /// whose `sha256` named some other content would fail verification on the
    /// receiving device permanently and never land.
    func testTheRecordCarriesTheFilesOwnDigestNotAStaleSidecarClaim() async throws {
        try writeVerifiedManifest()
        try writeImage(sha256Override: "0000stale0000", bytesOverride: 1)
        let (ex, bookkeeping) = exchange()

        let answer = await ex.recordToPush(for: imageName, zoneID: zoneID)
        let record = try XCTUnwrap(answer)

        XCTAssertEqual(record["sha256"] as? String, ImageStore.sha256Hex(imageBytes))
        XCTAssertEqual(record["bytes"] as? Int, imageBytes.count)
        await ex.noteSaved(record)
        let ledger = await bookkeeping.ledger()
        XCTAssertEqual(ledger[imageName.rawValue]?.sha256, ImageStore.sha256Hex(imageBytes),
                       "the ledger and the record agree — one digest, taken once, used twice")
    }
}
