import XCTest
import CloudKit
@testable import Raconte

/// A child record (AudioAsset/LiveLog/MarkerStream/Revision) references its Entry with
/// `.deleteSelf`; CloudKit rejects the save if the Entry is not on the server. The
/// children must therefore hold back whenever the Entry can neither be found there
/// (archived system fields) nor built right now. Fixtures mirror `SyncEntryRecordTests`.
final class SyncChildHoldbackTests: XCTestCase {

    private let zoneID = CKRecordZone.ID(zoneName: "RaconteZoneTest", ownerName: CKCurrentUserDefaultName)
    private let captureID = ULID.make()
    private let imageID = ULID.make()
    private let deviceID = "device-low"
    private var containerRoot: URL!

    override func setUpWithError() throws {
        containerRoot = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("RaconteSyncChildHoldback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: containerRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: containerRoot)
    }

    private var capturesRoot: URL { AppContainer.capturesRoot(containerRoot: containerRoot) }
    private var captureDirectory: URL {
        SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
    }
    private var entryURL: URL { SegmentLayout.entryMetadataURL(captureDirectory: captureDirectory) }

    private func format() -> AudioFormatDescriptor {
        AudioFormatDescriptor(sampleRate: 48_000, channels: 1,
                              commonFormat: .pcmFormatFloat32, interleaved: false, bytesPerFrame: 4)
    }

    private func writeVerifiedManifest() throws {
        try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let manifest = Manifest(captureID: captureID, createdAt: when, state: .complete,
                                stateSeq: 1, stateUpdatedAt: when, format: format(),
                                final: FinalRef(verifiedAt: when, durationFrames: 480_000))
        try CaptureCoding.encoder().encode(manifest)
            .write(to: SegmentLayout.manifestURL(captureDirectory: captureDirectory))
    }

    private func writeFinalM4a() throws {
        let url = SegmentLayout.finalRecordingURL(captureDirectory: captureDirectory)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try Data("m4a-bytes".utf8).write(to: url)
    }

    private func writeLiveLog() throws {
        let dir = SegmentLayout.transcriptDirectory(captureDirectory: captureDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: SegmentLayout.liveTranscriptURL(captureDirectory: captureDirectory))
    }

    private func writeMarkerLog() throws {
        let url = SegmentLayout.markerLogURL(captureDirectory: captureDirectory)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: url)
    }

    /// The codebase's "exists but unreadable" technique: a directory at the file's path.
    private func makeEntryMetadataUnreadable() throws {
        try? FileManager.default.removeItem(at: entryURL)
        try FileManager.default.createDirectory(at: entryURL, withIntermediateDirectories: true)
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

    /// An attached image (image-capture plan Task 4) — a child record exactly like the
    /// three above: it carries the same `.deleteSelf` `entryRef`, so it is subject to
    /// the same holdback rule and must not be a separate, untested path.
    private func writeImage() throws {
        let bytes = Data("image-bytes".utf8)
        let sidecar = ImageSidecar(id: imageID, originalExtension: "jpeg", mime: "image/jpeg",
                                   bytes: bytes.count, sha256: ImageStore.sha256Hex(bytes),
                                   width: 16, height: 9, capturedAt: nil,
                                   addedAt: Date(timeIntervalSince1970: 1_700_000_500))
        try ImageStore.writeOriginal(bytes, captureDirectory: captureDirectory,
                                     imageID: imageID, ext: "jpeg")
        try ImageStore.writeSidecar(sidecar, captureDirectory: captureDirectory)
    }

    private func children() -> [SyncRecordName] {
        [.audio(captureID: captureID), .liveLog(captureID: captureID),
         .markerStream(captureID: captureID, deviceID: deviceID),
         .image(captureID: captureID, imageID: imageID)]
    }

    /// The defect: Entry build fails (unreadable entry.json), children still built and
    /// shipped a reference to nothing.
    func testChildrenHoldBackWhenTheEntryCannotBeBuiltAndHasNeverLanded() async throws {
        try writeVerifiedManifest()
        try writeFinalM4a()
        try writeLiveLog()
        try writeMarkerLog()
        try writeImage()
        try makeEntryMetadataUnreadable()
        let (ex, _) = exchange()

        let entry = await ex.recordToPush(for: .entry(captureID: captureID), zoneID: zoneID)
        XCTAssertNil(entry, "fixture sanity: the Entry itself refuses")
        for child in children() {
            let record = await ex.recordToPush(for: child, zoneID: zoneID)
            XCTAssertNil(record, "\(child.rawValue) must not ship a reference to an Entry that is not on the server")
        }
    }

    /// Once the Entry has landed (system fields archived), a later transient failure to
    /// rebuild it must NOT hold the children back — the reference target exists.
    func testChildrenStillPushWhenTheEntryAlreadyLandedEvenIfItCannotBeRebuiltNow() async throws {
        try writeVerifiedManifest()
        try writeFinalM4a()
        try writeLiveLog()
        try writeMarkerLog()
        try writeImage()
        try EntryMetadataStore.write(EntryMetadata(journalID: ULID.make()), url: entryURL)
        let (ex, bookkeeping) = exchange()
        let answer = await ex.recordToPush(for: .entry(captureID: captureID), zoneID: zoneID)
        let landed = try XCTUnwrap(answer)
        await ex.noteSaved(landed)
        let archived = await bookkeeping.systemFields(for: SyncRecordName.entry(captureID: captureID).rawValue)
        XCTAssertNotNil(archived, "fixture sanity: the Entry is on the server")
        try makeEntryMetadataUnreadable()

        for child in children() {
            let record = await ex.recordToPush(for: child, zoneID: zoneID)
            XCTAssertNotNil(record, "\(child.rawValue) references an Entry the server already holds")
        }
    }

    /// An ABSENT entry.json is the ordinary untouched-entry case: the Entry builds from
    /// `.defaults`, so the children go out with it.
    func testChildrenPushAlongsideAnEntryWithNoMetadataFile() async throws {
        try writeVerifiedManifest()
        try writeFinalM4a()
        try writeLiveLog()
        try writeMarkerLog()
        try writeImage()
        let (ex, _) = exchange()

        let entry = await ex.recordToPush(for: .entry(captureID: captureID), zoneID: zoneID)
        XCTAssertNotNil(entry)
        for child in children() {
            let record = await ex.recordToPush(for: child, zoneID: zoneID)
            XCTAssertNotNil(record, "\(child.rawValue)")
        }
    }
}
