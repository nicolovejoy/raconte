import XCTest
import CloudKit
@testable import Raconte

/// Image-capture plan Task 4: the `Image` record's wire shape, and the finalize-time
/// push list once an entry can carry images — including the one an entry can now be
/// made of ENTIRELY (an image-only entry, no audio at all).
///
/// **No server, no account, no `CKSyncEngine`** — same discipline as
/// `SyncEntryRecordTests`, whose fixtures these mirror deliberately.
final class SyncImageRecordBuilderTests: XCTestCase {

    private let zoneID = CKRecordZone.ID(zoneName: "RaconteZoneTest", ownerName: CKCurrentUserDefaultName)
    private let captureID = ULID.make()
    private let imageID = ULID.make()
    private var containerRoot: URL!

    override func setUpWithError() throws {
        containerRoot = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("RaconteSyncImageRecord-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: containerRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: containerRoot)
    }

    private var entryRecordID: CKRecord.ID {
        SyncCloudIdentifiers.recordID(.entry(captureID: captureID), zoneID: zoneID)
    }

    private func stamp(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(offset)
    }

    private func sidecar(width: Int? = 4032, height: Int? = 3024, capturedAt: Date? = nil) -> ImageSidecar {
        ImageSidecar(id: imageID, originalExtension: "heic", mime: "image/heic", bytes: 9,
                     sha256: "deadbeef", width: width, height: height,
                     capturedAt: capturedAt, addedAt: stamp(100))
    }

    /// The wire string itself (pinned, per `SyncRecordType`'s own doc comment: a typo
    /// here is a second, silently-empty schema in the owner's container, never a
    /// compile error).
    func testImageRecordTypeIsTheExactWireString() {
        XCTAssertEqual(SyncRecordType.image, "Image")
    }

    /// Names every field the design's Sync-mapping section lists. A builder that
    /// quietly stopped writing one would otherwise pass every other test here and that
    /// field would simply never sync — the rationale `SyncEntryRecordTests` states for
    /// its own field-coverage test.
    ///
    /// Mutation check (run by hand): commenting out the `originalExtension` line in
    /// `SyncRecordBuilders.imageRecord` fails this test, so the assertion is
    /// load-bearing.
    func testImageRecordCarriesEveryFieldAndReferencesItsEntryWithDeleteSelf() throws {
        let origURL = containerRoot.appendingPathComponent("\(imageID).heic")
        try Data("orig-byte".utf8).write(to: origURL)

        let record = SyncRecordBuilders.imageRecord(captureID: captureID, imageID: imageID,
                                                    sidecar: sidecar(capturedAt: stamp(50)),
                                                    fileURL: origURL, entryID: entryRecordID,
                                                    zoneID: zoneID)

        XCTAssertEqual(record.recordType, "Image")
        XCTAssertEqual(record.recordID.recordName, "i.\(captureID).\(imageID)",
                       "the record name embeds BOTH ids — an image is not addressable without its capture")
        XCTAssertEqual(record.recordID.zoneID, zoneID)
        XCTAssertEqual((record["file"] as? CKAsset)?.fileURL, origURL,
                       "the asset is the ORIGINAL bytes, never the derived thumbnail")
        XCTAssertEqual(record["sha256"] as? String, "deadbeef")
        XCTAssertEqual(record["bytes"] as? Int, 9)
        XCTAssertEqual(record["originalExtension"] as? String, "heic")
        XCTAssertEqual(record["width"] as? Int, 4032)
        XCTAssertEqual(record["height"] as? Int, 3024)
        XCTAssertEqual(record["capturedAt"] as? Date, stamp(50))

        let ref = try XCTUnwrap(record["entryRef"] as? CKRecord.Reference)
        XCTAssertEqual(ref.recordID, entryRecordID)
        XCTAssertEqual(ref.action, .deleteSelf,
                       "the cascade design §5 relies on: purging the Entry must take its images with it")
    }

    /// The three optional fields are absent KEYS when the sidecar has no value, never a
    /// zero/epoch stand-in a receiver would have to tell apart from a real reading.
    func testImageRecordOmitsDimensionsAndCapturedAtWhenTheSidecarHasNone() throws {
        let origURL = containerRoot.appendingPathComponent("\(imageID).heic")
        try Data("orig-byte".utf8).write(to: origURL)

        let record = SyncRecordBuilders.imageRecord(
            captureID: captureID, imageID: imageID,
            sidecar: sidecar(width: nil, height: nil, capturedAt: nil),
            fileURL: origURL, entryID: entryRecordID, zoneID: zoneID)

        XCTAssertNil(record["width"])
        XCTAssertNil(record["height"])
        XCTAssertNil(record["capturedAt"])
        XCTAssertFalse(record.allKeys().contains("capturedAt"),
                       "an image with no EXIF date has no capturedAt key at all")
        XCTAssertEqual(record["originalExtension"] as? String, "heic",
                       "the non-optional fields still travel")
    }
}

/// The push-list half of Task 4: `FinalizeArtifactPush.namesToPush` once `.audio` is
/// conditional and images exist. The adversarial case this whole task exists for — a
/// finalized capture with NO `final/recording.m4a` — is
/// `testNamesToPushOmitsAudioEntirelyForAnImageOnlyEntry`.
final class FinalizeArtifactPushImageTests: XCTestCase {

    private let captureID = ULID.make()
    private var containerRoot: URL!
    /// Two ids in known ULID order, so "images in ULID order" is an assertion and not
    /// a coin flip on `ULID.make()`'s within-the-same-millisecond suffix.
    private let imageA = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
    private let imageB = "01BRZ3NDEKTSV4RRFFQ69G5FAW"

    override func setUpWithError() throws {
        containerRoot = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("RaconteFinalizePushImage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: containerRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: containerRoot)
    }

    private var capturesRoot: URL { AppContainer.capturesRoot(containerRoot: containerRoot) }
    private var captureDirectory: URL {
        SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
    }

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

    private func writeFinalM4a() throws {
        let url = SegmentLayout.finalRecordingURL(captureDirectory: captureDirectory)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try Data("m4a-bytes".utf8).write(to: url)
    }

    /// The codebase's "exists but unreadable" technique (a directory at the file's own
    /// path): `fileExists` reads true, `Data(contentsOf:)` throws.
    private func writeFinalM4aAsUnreadableDirectory() throws {
        let url = SegmentLayout.finalRecordingURL(captureDirectory: captureDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
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
        try Data("{\"t\":0}\n".utf8).write(to: url)
    }

    @discardableResult
    private func writeImage(_ imageID: String) throws -> ImageSidecar {
        let bytes = Data("image-bytes-\(imageID)".utf8)
        let sidecar = ImageSidecar(id: imageID, originalExtension: "jpeg", mime: "image/jpeg",
                                   bytes: bytes.count, sha256: ImageStore.sha256Hex(bytes),
                                   width: 12, height: 9, capturedAt: nil,
                                   addedAt: Date(timeIntervalSince1970: 1_700_000_500))
        try ImageStore.writeOriginal(bytes, captureDirectory: captureDirectory,
                                     imageID: imageID, ext: "jpeg")
        try ImageStore.writeSidecar(sidecar, captureDirectory: captureDirectory)
        return sidecar
    }

    private func names(deviceID: String = "device-under-test") -> [SyncRecordName] {
        FinalizeArtifactPush.namesToPush(capturesRoot: capturesRoot, captureID: captureID,
                                         deviceID: deviceID)
    }

    // MARK: The regression guard — an audio-bearing entry is untouched

    /// **Zero behavior change for an audio-bearing entry with no images**: exactly the
    /// list this function returned before `.audio` became conditional, in exactly that
    /// order, including the liveLog/markerStream riders.
    func testAnAudioBearingCaptureWithNoImagesPushesExactlyWhatItAlwaysDid() throws {
        try writeVerifiedManifest()
        try writeFinalM4a()

        XCTAssertEqual(names(), [.entry(captureID: captureID), .audio(captureID: captureID)],
                       "a degraded capture (no transcript, no markers, no images) still pushes its recording")

        try writeLiveLog()
        try writeMarkerLog()
        XCTAssertEqual(names(), [.entry(captureID: captureID), .audio(captureID: captureID),
                                 .liveLog(captureID: captureID),
                                 .markerStream(captureID: captureID, deviceID: "device-under-test")],
                       "entry, audio, liveLog, markerStream — the pre-image order, unchanged")
    }

    // MARK: Images alongside audio

    func testAudioBearingCaptureWithTwoImagesPushesEntryAudioThenImagesInULIDOrder() throws {
        try writeVerifiedManifest()
        try writeFinalM4a()
        // Written B-first, so a passing ULID-order assertion cannot be an accident of
        // the order the files happened to be created in.
        try writeImage(imageB)
        try writeImage(imageA)

        XCTAssertEqual(names(), [.entry(captureID: captureID), .audio(captureID: captureID),
                                 .image(captureID: captureID, imageID: imageA),
                                 .image(captureID: captureID, imageID: imageB)],
                       "entry, audio, then one Image per sidecar in ULID (== display) order")
    }

    /// Images ride ALONGSIDE the transcript artifacts, never in place of them, and
    /// always last — the property that keeps an audio-bearing entry's existing names in
    /// their existing order.
    func testImagesAreAppendedAfterTheTranscriptArtifacts() throws {
        try writeVerifiedManifest()
        try writeFinalM4a()
        try writeLiveLog()
        try writeMarkerLog()
        try writeImage(imageA)

        XCTAssertEqual(names(), [.entry(captureID: captureID), .audio(captureID: captureID),
                                 .liveLog(captureID: captureID),
                                 .markerStream(captureID: captureID, deviceID: "device-under-test"),
                                 .image(captureID: captureID, imageID: imageA)])
    }

    // MARK: The adversarial case — an image-only entry

    /// **The case the task exists for.** A blank entry (`BlankEntryMinter`) is
    /// finalized with no `final/recording.m4a` at all; naming `.audio` for it would
    /// enqueue a push `audioRecordToPush` can only ever answer nil to, forever.
    ///
    /// Mutation check (run by hand): restoring `namesToPush`'s unconditional
    /// `.audio(captureID:)` seed fails this test on the first assertion.
    func testNamesToPushOmitsAudioEntirelyForAnImageOnlyEntry() throws {
        try writeVerifiedManifest()
        try writeImage(imageA)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SegmentLayout.finalRecordingURL(captureDirectory: captureDirectory).path),
                       "fixture sanity: there is genuinely no recording here")
        XCTAssertEqual(names(), [.entry(captureID: captureID),
                                 .image(captureID: captureID, imageID: imageA)],
                       "an image-only entry pushes its Entry and its image — never an AudioAsset")
    }

    /// A blank entry with nothing attached at all yet: the Entry alone. It is finalized
    /// (that is what makes it visible and syncable), so refusing to push anything would
    /// leave a real, owner-created entry stranded on one device.
    func testNamesToPushForABlankEntryIsTheEntryAlone() throws {
        try writeVerifiedManifest()

        XCTAssertEqual(names(), [.entry(captureID: captureID)])
    }

    /// The readability probe, not `fileExists`: an existing-but-unreadable m4a must
    /// read exactly like an absent one — the identical rule (and the identical
    /// expression) `SyncTreeScanner.audioArtifact` applies on the reconciliation side.
    ///
    /// Mutation check (run by hand): changing the probe to
    /// `FileManager.default.fileExists(atPath: m4aURL.path)` fails this test.
    func testNamesToPushTreatsAnUnreadableM4aAsAbsentNotPresent() throws {
        try writeVerifiedManifest()
        try writeFinalM4aAsUnreadableDirectory()

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: SegmentLayout.finalRecordingURL(captureDirectory: captureDirectory).path),
                      "sanity: something really is at that path — this is not just a missing file")
        XCTAssertEqual(names(), [.entry(captureID: captureID)],
                       "an unreadable m4a must never be queued for a push that can only fail")
    }

    /// An undecodable sidecar reads as no image — `imageRecordToPush` could not build a
    /// record from it, so queueing the name would be a push that can only answer nil.
    func testNamesToPushSkipsAnUndecodableSidecar() throws {
        try writeVerifiedManifest()
        try writeFinalM4a()
        try writeImage(imageA)
        try Data("{ not json".utf8).write(
            to: SegmentLayout.imageSidecarURL(captureDirectory: captureDirectory, imageID: imageB))

        XCTAssertEqual(names(), [.entry(captureID: captureID), .audio(captureID: captureID),
                                 .image(captureID: captureID, imageID: imageA)],
                       "the good image still pushes; the damaged sidecar is simply not named")
    }

    /// A `.json` file under `images/` whose stem is not a ULID cannot round-trip
    /// through `SyncRecordName.init?`, so a record pushed under it would come back
    /// unparseable at `noteSaved` — no ledger entry, re-enqueued on every launch
    /// forever. Skipped, exactly as `SyncTreeScanner.scanCaptures` skips a capture
    /// directory whose name is not a ULID.
    func testNamesToPushSkipsASidecarWhoseFilenameIsNotAULID() throws {
        try writeVerifiedManifest()
        try writeImage(imageA)
        let stray = SegmentLayout.imagesDirectory(captureDirectory: captureDirectory)
            .appendingPathComponent("not-a-ulid.json")
        try Data(#"{"id":"not-a-ulid"}"#.utf8).write(to: stray)

        XCTAssertEqual(names(), [.entry(captureID: captureID),
                                 .image(captureID: captureID, imageID: imageA)])
    }

    /// The id in a record name is the sidecar's FILENAME stem, not whatever `id` its
    /// JSON claims — every path the push then reads (`images/<id>.json`,
    /// `images/<id>.<ext>`) is derived from the name, so naming the content's id would
    /// address a file that isn't there.
    func testTheImageIDComesFromTheFilenameNotTheSidecarsOwnIDField() throws {
        try writeVerifiedManifest()
        let sidecar = ImageSidecar(id: imageB, originalExtension: "jpeg", mime: "image/jpeg",
                                   bytes: 3, sha256: "abc", width: nil, height: nil, capturedAt: nil,
                                   addedAt: Date(timeIntervalSince1970: 1_700_000_500))
        try FileManager.default.createDirectory(
            at: SegmentLayout.imagesDirectory(captureDirectory: captureDirectory),
            withIntermediateDirectories: true)
        // Filed under imageA, but its own `id` field says imageB — a disagreement only
        // a hand-edited or damaged sidecar can produce.
        try ImageStore.encodeSidecar(sidecar).write(
            to: SegmentLayout.imageSidecarURL(captureDirectory: captureDirectory, imageID: imageA))

        XCTAssertEqual(names(), [.entry(captureID: captureID),
                                 .image(captureID: captureID, imageID: imageA)],
                       "the file's own name wins — that is what the push path reads")
    }

    /// An unfinalized capture names nothing, images or not — the eligibility gate is
    /// unchanged by this task.
    func testAnUnfinalizedCaptureWithImagesStillPushesNothing() throws {
        try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let format = AudioFormatDescriptor(sampleRate: 48_000, channels: 1,
                                           commonFormat: .pcmFormatFloat32, interleaved: false,
                                           bytesPerFrame: 4)
        let manifest = Manifest(captureID: captureID, createdAt: when, state: .captured,
                                stateSeq: 1, stateUpdatedAt: when, format: format, final: FinalRef())
        try CaptureCoding.encoder().encode(manifest)
            .write(to: SegmentLayout.manifestURL(captureDirectory: captureDirectory))
        try writeImage(imageA)

        XCTAssertEqual(names(), [])
    }

    // MARK: Through the real chokepoint

    func testPushNotifiesTheHookForEveryImageOnAnImageOnlyEntry() async throws {
        try writeVerifiedManifest()
        try writeImage(imageA)
        try writeImage(imageB)
        let hooks = RecordingSyncHooks()

        await FinalizeArtifactPush.push(capturesRoot: capturesRoot, captureID: captureID,
                                        syncHooks: hooks, deviceID: "device-under-test")

        let fired = await hooks.names
        XCTAssertEqual(fired, [.entry(captureID: captureID),
                               .image(captureID: captureID, imageID: imageA),
                               .image(captureID: captureID, imageID: imageB)])
    }

    // MARK: SyncRecordFamily — the trash-purge retirement list

    /// Purging an entry must retire its images' ledger/system-fields bookkeeping too.
    /// `SyncRecordFamily.names` is the one place that list is built (the Trash Sweeper
    /// and the staged-removal path both read it), so an image missing from here is a
    /// stale local record surviving its parent.
    func testRecordFamilyNamesIncludeEveryImage() throws {
        try writeVerifiedManifest()
        try writeFinalM4a()
        try writeImage(imageB)
        try writeImage(imageA)

        let family = SyncRecordFamily.names(captureID: captureID, captureDirectory: captureDirectory)
        XCTAssertTrue(family.contains(.image(captureID: captureID, imageID: imageA)))
        XCTAssertTrue(family.contains(.image(captureID: captureID, imageID: imageB)))
        XCTAssertTrue(family.contains(.audio(captureID: captureID)),
                      "sanity: the pre-existing family members are still there")
    }

    /// The one place the two enumerations deliberately DISAGREE, and the reason each is
    /// right: a damaged sidecar is not pushable (so `namesToPush` omits it) but its
    /// record may well be on the server already, so the retirement list must still
    /// name it. Permissive where retiring costs nothing; strict where a push would fail.
    func testRecordFamilyNamesIncludeAnImageWhoseSidecarIsUndecodable() throws {
        try writeVerifiedManifest()
        try FileManager.default.createDirectory(
            at: SegmentLayout.imagesDirectory(captureDirectory: captureDirectory),
            withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(
            to: SegmentLayout.imageSidecarURL(captureDirectory: captureDirectory, imageID: imageA))

        let family = SyncRecordFamily.names(captureID: captureID, captureDirectory: captureDirectory)
        XCTAssertTrue(family.contains(.image(captureID: captureID, imageID: imageA)),
                      "retiring a name that was never pushed costs nothing; missing one leaves a stale record")
        XCTAssertEqual(names(), [.entry(captureID: captureID)],
                       "…while the push list, which has to build a record, still refuses it")
    }
}
