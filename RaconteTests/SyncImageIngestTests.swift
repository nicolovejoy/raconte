import XCTest
import CloudKit
@testable import Raconte

/// Image-capture plan Task 5: the inbound half of image sync — `RemoteImageFields`
/// (wire decode, pure), the parked-queue round trip, and the orchestrator's own
/// land-or-park behaviour through `SyncRecordExchange.acceptRemote`. Same layered split
/// `SyncRevisionTests`/`SyncMarkerStreamTests` use for the two sibling park mechanisms.
///
/// The standing rule these tests exist to pin (`inbound-sync-must-land-or-park`, issue
/// #85): `CKSyncEngine` advances its change token the instant a fetched record is handed
/// to the delegate and never redelivers it, so an inbound Image that cannot be applied
/// right now must be PARKED, never dropped. An image has no second source — it is ground
/// truth exactly the way the audio is.
final class SyncImageIngestTests: XCTestCase {

    private var containerRoot: URL!
    private let zoneID = CKRecordZone.ID(zoneName: "RaconteZoneTest", ownerName: CKCurrentUserDefaultName)
    private let captureID = ULID.make()
    private let imageID = ULID.make()
    private let secondImageID = ULID.make()

    override func setUpWithError() throws {
        containerRoot = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("RaconteSyncImageIngest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: containerRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: containerRoot)
    }

    private func stamp(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(offset)
    }

    // MARK: Fixtures

    private var capturesRoot: URL { AppContainer.capturesRoot(containerRoot: containerRoot) }

    private var captureDirectory: URL {
        SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
    }

    private var parkURL: URL {
        AppContainer.syncStagingPendingImagesURL(containerRoot: containerRoot, captureID: captureID)
    }

    private var entryRecordID: CKRecord.ID {
        SyncCloudIdentifiers.recordID(.entry(captureID: captureID), zoneID: zoneID)
    }

    /// Real PNG bytes, through the suite's shared fixture maker — `ImageThumbnailer`
    /// runs on the ingest path, and a fixture ImageIO cannot decode would exercise only
    /// the degraded "no thumbnail" branch.
    private func pngBytes(width: Int = 12, height: Int = 8) -> Data {
        ImageThumbnailerTests.makePNG(width: width, height: height, color: (20, 140, 220))
    }

    private func writeTempFile(_ data: Data, name: String) throws -> URL {
        let url = containerRoot.appendingPathComponent("wire-\(UUID().uuidString)-\(name)")
        try data.write(to: url)
        return url
    }

    private func sidecar(id: String, bytes: Data, ext: String = "png") -> ImageSidecar {
        ImageSidecar(id: id, originalExtension: ext, mime: "image/png", bytes: bytes.count,
                     sha256: ImageStore.sha256Hex(bytes), width: 3, height: 2,
                     capturedAt: stamp(-500), addedAt: stamp(-100))
    }

    private func imageRecord(id: String, bytes: Data, ext: String = "png") throws -> CKRecord {
        let url = try writeTempFile(bytes, name: "image.\(ext)")
        return SyncRecordBuilders.imageRecord(captureID: captureID, imageID: id,
                                              sidecar: sidecar(id: id, bytes: bytes, ext: ext),
                                              fileURL: url, entryID: entryRecordID, zoneID: zoneID)
    }

    private func format() -> AudioFormatDescriptor {
        AudioFormatDescriptor(sampleRate: 48_000, channels: 1,
                              commonFormat: .pcmFormatFloat32, interleaved: false, bytesPerFrame: 4)
    }

    /// An audio-bearing capture's manifest (`durationFrames != 0`) — the ordinary case.
    private func manifestJSON(at when: Date, durationFrames: Int? = 480_000) -> Data {
        let manifest = Manifest(captureID: captureID, createdAt: when, state: .complete,
                                stateSeq: 1, stateUpdatedAt: when, format: format(),
                                final: FinalRef(verifiedAt: when, durationFrames: durationFrames))
        return try! CaptureCoding.encoder().encode(manifest)
    }

    /// A blank/image-only entry's manifest, straight from the production minter — the
    /// exact bytes an origin device pushes as `manifestSnapshot` for such an entry.
    private func blankManifestJSON(at when: Date) -> Data {
        try! CaptureCoding.encoder().encode(BlankEntryMinter.manifest(captureID: captureID, createdAt: when))
    }

    @discardableResult
    private func mkCaptureDirectory() throws -> URL {
        try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
        return captureDirectory
    }

    private func setTrashed(_ trashed: Bool, at date: Date = Date(timeIntervalSince1970: 1_700_000_100)) throws {
        try EntryMetadataStore.write(EntryMetadata(trashedAt: trashed ? date : nil),
                                     url: SegmentLayout.entryMetadataURL(captureDirectory: captureDirectory))
    }

    private func exchange(localStoreDidChange: (@Sendable () async -> Void)? = nil,
                          withImageStore: Bool = true) -> SyncRecordExchange {
        let store = JournalStore(containerRoot: containerRoot)
        let covers = JournalCoverStore(containerRoot: containerRoot, journalStore: store)
        return SyncRecordExchange(
            journalStore: store, coverStore: covers,
            bookkeeping: SyncBookkeepingStore(root: AppContainer.syncRoot(containerRoot: containerRoot)),
            deviceID: "device-low", containerRoot: containerRoot,
            // Wired because two tests here drive an inbound Entry record against an
            // ALREADY-LOCAL capture: without a store the T8 field merge is skipped
            // entirely, and a test asserting on the merge's effect would pass or fail
            // for reasons that have nothing to do with images.
            entryMetadataStore: EntryMetadataStore(capturesRoot: capturesRoot),
            imageStore: withImageStore ? ImageStore(capturesRoot: capturesRoot) : nil,
            localStoreDidChange: localStoreDidChange)
    }

    private func landedImages() async -> [ImageSidecar] {
        await ImageStore(capturesRoot: capturesRoot).images(captureID: captureID)
    }

    // MARK: RemoteImageFields — wire decode

    func testRemoteImageFieldsDecodesEveryFieldFromARecord() throws {
        let bytes = pngBytes()
        let record = try imageRecord(id: imageID, bytes: bytes)

        let fields = try XCTUnwrap(RemoteImageFields(record: record))

        XCTAssertEqual(fields.captureID, captureID, "from the record NAME, never a field")
        XCTAssertEqual(fields.imageID, imageID, "from the record NAME, never a field")
        XCTAssertEqual(fields.sha256, ImageStore.sha256Hex(bytes))
        XCTAssertEqual(fields.originalExtension, "png")
        XCTAssertEqual(fields.width, 3)
        XCTAssertEqual(fields.height, 2)
        XCTAssertEqual(fields.capturedAt, stamp(-500))
    }

    func testRemoteImageFieldsFailsOnAWrongRecordType() throws {
        let record = CKRecord(recordType: "NotImage",
                              recordID: SyncCloudIdentifiers.recordID(
                                .image(captureID: captureID, imageID: imageID), zoneID: zoneID))
        XCTAssertNil(RemoteImageFields(record: record))
    }

    /// Identity-strict: with no asset there are no bytes to write, so the whole decode
    /// refuses rather than producing a record that would name a file it cannot create.
    func testRemoteImageFieldsFailsWithoutTheAsset() throws {
        let record = try imageRecord(id: imageID, bytes: pngBytes())
        record[SyncChildAssetField.file] = nil
        XCTAssertNil(RemoteImageFields(record: record))
    }

    /// Identity-strict the other way: bytes with no digest to check them against cannot
    /// be verified, and this ingest never writes unverified bytes.
    func testRemoteImageFieldsFailsWithoutTheSha256() throws {
        let record = try imageRecord(id: imageID, bytes: pngBytes())
        record[SyncChildAssetField.sha256] = nil
        XCTAssertNil(RemoteImageFields(record: record))
    }

    /// Lenient about everything with a sane default: a record whose optional metadata
    /// was never written (or was damaged) still decodes, and costs only those fields.
    func testRemoteImageFieldsDegradesOnMissingOptionalMetadataWithoutFailingTheDecode() throws {
        let record = try imageRecord(id: imageID, bytes: pngBytes())
        record[SyncImageField.width] = nil
        record[SyncImageField.height] = nil
        record[SyncImageField.capturedAt] = nil
        record[SyncImageField.originalExtension] = nil

        let fields = try XCTUnwrap(RemoteImageFields(record: record))
        XCTAssertNil(fields.width)
        XCTAssertNil(fields.height)
        XCTAssertNil(fields.capturedAt)
        XCTAssertEqual(fields.originalExtension, RemoteImageFields.fallbackExtension,
                       "an absent extension degrades to the same fallback ImageStore uses locally")
    }

    /// `originalExtension` is the one decoded field that becomes part of a path this
    /// device writes, so a lenient pass-through would be an arbitrary-path write
    /// primitive handed to whatever wrote the record.
    func testRemoteImageFieldsRefusesAPathEscapingExtension() {
        XCTAssertEqual(RemoteImageFields.sanitizedExtension("../../evil"),
                       RemoteImageFields.fallbackExtension)
        XCTAssertEqual(RemoteImageFields.sanitizedExtension("a/b"), RemoteImageFields.fallbackExtension)
        XCTAssertEqual(RemoteImageFields.sanitizedExtension(String(repeating: "x", count: 64)),
                       RemoteImageFields.fallbackExtension)
        XCTAssertEqual(RemoteImageFields.sanitizedExtension(""), RemoteImageFields.fallbackExtension)
        XCTAssertEqual(RemoteImageFields.sanitizedExtension("jpeg"), "jpeg", "a real extension survives")
    }

    /// `images/<id>.json` is the sidecar's own path — honoring `originalExtension:
    /// "json"` would have the original's bytes and its sidecar fight over one file.
    func testRemoteImageFieldsRefusesTheSidecarsOwnExtension() {
        XCTAssertEqual(RemoteImageFields.sanitizedExtension("json"), RemoteImageFields.fallbackExtension)
        XCTAssertEqual(RemoteImageFields.sanitizedExtension("JSON"), RemoteImageFields.fallbackExtension)
    }

    /// The two fields the `Image` record does not carry are re-derived, not invented:
    /// `mime` from the extension, `addedAt` from the imageID's own ULID timestamp (the
    /// instant the ORIGIN device minted it), so two devices agree on when the owner
    /// added the image instead of each stamping its own arrival time.
    func testRemoteImageFieldsRebuildsTheSidecarsOffWireFields() throws {
        let mintedAt = stamp(-750)
        let id = ULID.make(now: mintedAt)
        let fields = RemoteImageFields(captureID: captureID, imageID: id,
                                       fileURL: containerRoot, sha256: "abc",
                                       originalExtension: "png", width: 3, height: 2,
                                       capturedAt: stamp(-500))

        let rebuilt = fields.sidecar(bytes: 41)

        XCTAssertEqual(rebuilt.id, id)
        XCTAssertEqual(rebuilt.mime, "image/png")
        XCTAssertEqual(rebuilt.bytes, 41, "the count of what actually arrived, never the record's claim")
        XCTAssertEqual(rebuilt.sha256, "abc")
        XCTAssertEqual(rebuilt.addedAt.timeIntervalSince1970, mintedAt.timeIntervalSince1970, accuracy: 0.001)
    }

    // MARK: Ingest — existing, live capture: lands directly

    func testAnImageForAnExistingLiveCaptureLandsImmediatelyAndIsReadableThroughImageStore() async throws {
        try mkCaptureDirectory()
        let bytes = pngBytes()
        let signals = SignalCounter()
        let ex = exchange(localStoreDidChange: { await signals.increment() })

        await ex.acceptRemote(try imageRecord(id: imageID, bytes: bytes))

        let landed = await landedImages()
        XCTAssertEqual(landed.map(\.id), [imageID])
        XCTAssertEqual(landed.first?.sha256, ImageStore.sha256Hex(bytes))
        XCTAssertEqual(
            try Data(contentsOf: SegmentLayout.imageOriginalURL(captureDirectory: captureDirectory,
                                                                 imageID: imageID, ext: "png")),
            bytes, "the fetched bytes must land verbatim")
        XCTAssertFalse(FileManager.default.fileExists(atPath: parkURL.path),
                       "an image that landed must leave no park behind")
        let count = await signals.count
        XCTAssertEqual(count, 1)
    }

    /// The digest is never trusted as a description of the bytes: a record whose claimed
    /// sha256 does not match what arrived is refused outright — and, unlike every other
    /// failure here, NOT parked, since bytes already known to be wrong can only ever
    /// fail the same check again.
    func testAnImageWhoseSha256DoesNotMatchIsRefusedAndNeverPersisted() async throws {
        try mkCaptureDirectory()
        let record = try imageRecord(id: imageID, bytes: pngBytes())
        record[SyncChildAssetField.sha256] = "0000000000000000000000000000000000000000000000000000000000000000"

        await exchange().acceptRemote(record)

        let landed = await landedImages()
        XCTAssertTrue(landed.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: parkURL.path))
    }

    /// #85 part 2: an image record whose file asset is missing entirely must be PARKED
    /// (in the bookkeeping store's diagnostic sense, distinct from the
    /// `pending-images.json` staging mechanism above) rather than dropped — the same
    /// land-or-park guarantee `SyncEntryIngestTests` pins for audio/liveLog/revision.
    func testAnImageMissingItsFileAssetIsParked() async throws {
        let record = try imageRecord(id: imageID, bytes: pngBytes())
        record[SyncChildAssetField.file] = nil

        await exchange().acceptRemote(record)

        let bookkeeping = SyncBookkeepingStore(root: AppContainer.syncRoot(containerRoot: containerRoot))
        let parked = await bookkeeping.parkedRecords()
        XCTAssertEqual(parked[record.recordID.recordName]?.reason, "missing file asset")
    }

    /// Fix round 1 (Critical 3): the sha256-present guard only checks non-nil, but
    /// `RemoteImageFields.init?` also requires non-EMPTY — a record whose sha256 is `""`
    /// passed the guard and fell into `RemoteImageFields`'s own failure, which used to
    /// drop unparked. An empty sha256 names nothing to verify against, so it is treated
    /// as the same sub-cause as an absent field.
    func testAnImageWithAnEmptySHA256IsParkedAsMissing() async throws {
        let record = try imageRecord(id: imageID, bytes: pngBytes())
        record[SyncChildAssetField.sha256] = ""

        await exchange().acceptRemote(record)

        let bookkeeping = SyncBookkeepingStore(root: AppContainer.syncRoot(containerRoot: containerRoot))
        let parked = await bookkeeping.parkedRecords()
        XCTAssertEqual(parked[record.recordID.recordName]?.reason, "missing sha256 field")
    }

    // MARK: Ingest — unknown capture: park, then rehydrate in the SAME commit

    func testAnImageForAnUnknownCaptureParksAndLeavesCapturesUntouched() async throws {
        await exchange().acceptRemote(try imageRecord(id: imageID, bytes: pngBytes()))

        XCTAssertTrue(FileManager.default.fileExists(atPath: parkURL.path),
                      "the image must be parked, never dropped")
        XCTAssertFalse(FileManager.default.fileExists(atPath: captureDirectory.path),
                       "an image alone must never create the capture directory")
    }

    /// The shape the sibling park mechanisms already pin: the parked image is applied by
    /// the SAME commit that makes the capture exist, not by a later pass.
    func testAParkedImageRehydratesIntoTheCommittedDirectoryInTheSameCommit() async throws {
        let when = stamp(0)
        let bytes = pngBytes()
        let signals = SignalCounter()
        let ex = exchange(localStoreDidChange: { await signals.increment() })

        await ex.acceptRemote(try imageRecord(id: imageID, bytes: bytes))
        var count = await signals.count
        XCTAssertEqual(count, 0)

        // The Entry + Audio pair now arrives, completing the commit set.
        await ex.acceptRemote(SyncRecordBuilders.entryRecord(
            captureID: captureID, metadata: .defaults, manifestJSON: manifestJSON(at: when),
            capturedAt: when, deviceID: "device-high", zoneID: zoneID))
        let audioBytes = Data("m4a-bytes".utf8)
        await ex.acceptRemote(SyncRecordBuilders.audioRecord(
            captureID: captureID, m4aURL: try writeTempFile(audioBytes, name: "audio.m4a"),
            sha256: SyncTreeScanner.sha256Hex(audioBytes), bytes: audioBytes.count,
            frameCount: 480_000, sampleRate: 48_000, entryID: entryRecordID, zoneID: zoneID))

        let landed = await landedImages()
        XCTAssertEqual(landed.map(\.id), [imageID], "the parked image must land with the commit")
        XCTAssertEqual(
            try Data(contentsOf: SegmentLayout.imageOriginalURL(captureDirectory: captureDirectory,
                                                                 imageID: imageID, ext: "png")),
            bytes)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: captureDirectory.appendingPathComponent(
                AppContainer.syncStagingPendingImagesFileName).path),
            "the internal staging artifact must not linger inside a committed capture directory")
        XCTAssertFalse(FileManager.default.fileExists(atPath: parkURL.path))
        count = await signals.count
        XCTAssertEqual(count, 1, "exactly one announcement, once the commit (with its parked image) lands")
    }

    /// Content-addressed by `imageID`, like a revision and unlike a marker stream: a
    /// redelivery of the same id (a change-token reset, a full resync) must not
    /// accumulate a second copy in the queue.
    func testARedeliveredImageIDReplacesRatherThanAccumulatingInTheParkedQueue() async throws {
        let ex = exchange()
        let bytes = pngBytes()

        await ex.acceptRemote(try imageRecord(id: imageID, bytes: bytes))
        await ex.acceptRemote(try imageRecord(id: imageID, bytes: bytes))
        await ex.acceptRemote(try imageRecord(id: secondImageID, bytes: pngBytes(width: 20, height: 16)))

        // Read the park file back through the same decoder the production path uses.
        let raw = try Data(contentsOf: parkURL)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let images = try XCTUnwrap(json["images"] as? [[String: Any]])
        XCTAssertEqual(images.compactMap { $0["id"] as? String }, [imageID, secondImageID],
                       "the same imageID twice is one queue entry, and a different one appends")
    }

    // MARK: Ingest — trashed capture: park with knownToHaveExisted, land on restore

    func testAnImageForALocallyTrashedCaptureParksRatherThanLanding() async throws {
        try mkCaptureDirectory()
        try setTrashed(true)

        await exchange().acceptRemote(try imageRecord(id: imageID, bytes: pngBytes()))

        let landed = await landedImages()
        XCTAssertTrue(landed.isEmpty, "nothing must land in images/ while the capture is trashed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: parkURL.path),
                      "the image must be parked, not discarded")
    }

    func testAnImageParkedForATrashedCaptureLandsAfterRestoreAndRehydration() async throws {
        try mkCaptureDirectory()
        try setTrashed(true)
        let bytes = pngBytes()
        await exchange().acceptRemote(try imageRecord(id: imageID, bytes: bytes))

        try setTrashed(false)

        // Cold rebuild: nothing carried over in memory — everything the recovery reads
        // comes off disk, the "simulated relaunch" idiom the sibling suites use.
        await exchange().rehydrateParkedImages()

        let landed = await landedImages()
        XCTAssertEqual(landed.map(\.id), [imageID])
        XCTAssertEqual(
            try Data(contentsOf: SegmentLayout.imageOriginalURL(captureDirectory: captureDirectory,
                                                                 imageID: imageID, ext: "png")),
            bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: parkURL.path),
                       "the parking must clear once applied")
    }

    /// Design §5's delete-wins: an image parked for a capture that gets PURGED (not
    /// merely trashed) is discarded on the next rehydration, never resurrecting the
    /// purged directory. `knownToHaveExisted: true` is what makes this distinguishable
    /// from the in-flight case below.
    func testAParkedImageForAPurgedCaptureIsDiscardedOnRehydration() async throws {
        try mkCaptureDirectory()
        try setTrashed(true)
        await exchange().acceptRemote(try imageRecord(id: imageID, bytes: pngBytes()))

        try FileManager.default.removeItem(at: captureDirectory)

        await exchange().rehydrateParkedImages()

        XCTAssertFalse(FileManager.default.fileExists(atPath: parkURL.path),
                       "the parking must be discarded once the capture is gone")
        XCTAssertFalse(FileManager.default.fileExists(atPath: captureDirectory.path),
                       "rehydration must never resurrect a purged capture")
    }

    /// The other half of `knownToHaveExisted`: an ordinary in-flight "unknown capture"
    /// park must never be discarded by rehydration just because the directory happens to
    /// be absent right now — its Entry simply has not arrived yet.
    func testRehydrationLeavesAnInFlightUnknownCaptureImageParkUntouched() async throws {
        let ex = exchange()
        await ex.acceptRemote(try imageRecord(id: imageID, bytes: pngBytes()))
        XCTAssertTrue(FileManager.default.fileExists(atPath: parkURL.path), "sanity: it parked")

        await ex.rehydrateParkedImages()

        XCTAssertTrue(FileManager.default.fileExists(atPath: parkURL.path),
                      "an in-flight unknown-capture park must never be discarded by rehydration")
        XCTAssertFalse(FileManager.default.fileExists(atPath: captureDirectory.path))
    }

    /// A permanent local delete of the entry takes the parked image with it — the park
    /// describes content whose parent is gone, and design §5 says the delete wins.
    func testAnInboundEntryDeletionDiscardsTheParkedImage() async throws {
        try mkCaptureDirectory()
        try setTrashed(true)
        let ex = exchange()
        await ex.acceptRemote(try imageRecord(id: imageID, bytes: pngBytes()))
        XCTAssertTrue(FileManager.default.fileExists(atPath: parkURL.path), "sanity: it parked")

        await ex.acceptRemoteEntryDeletion(captureID: captureID)

        XCTAssertFalse(FileManager.default.fileExists(atPath: parkURL.path),
                       "a purged entry's park must not be orphaned forever")
    }

    // MARK: Ingest — no ImageStore wired: park, never drop

    /// An optional dependency being absent is not a reason to lose an owner's
    /// photograph. The bytes park and land on the next launch that does have a store.
    func testAnImageForALiveCaptureWithNoImageStoreWiredParksRatherThanDropping() async throws {
        try mkCaptureDirectory()
        let bytes = pngBytes()

        await exchange(withImageStore: false).acceptRemote(try imageRecord(id: imageID, bytes: bytes))

        XCTAssertTrue(FileManager.default.fileExists(atPath: parkURL.path),
                      "no store wired must mean parked, never dropped")

        await exchange().rehydrateParkedImages()

        let landed = await landedImages()
        XCTAssertEqual(landed.map(\.id), [imageID])
    }

    /// The asymmetry this task introduces, pinned rather than assumed: a park that rode
    /// the commit rename while NO `ImageStore` was wired is left sitting inside
    /// `captures/<captureID>/`, where the staging-root sweep would never look. That is
    /// why `rehydrateParkedImages()` enumerates BOTH locations — without the second
    /// sweep those bytes would be unreachable forever.
    func testAParkThatRodeTheCommitWithNoImageStoreWiredIsRecoveredFromInsideCaptures() async throws {
        let when = stamp(0)
        let bytes = pngBytes()
        let ex = exchange(withImageStore: false)

        await ex.acceptRemote(try imageRecord(id: imageID, bytes: bytes))
        await ex.acceptRemote(SyncRecordBuilders.entryRecord(
            captureID: captureID, metadata: .defaults, manifestJSON: blankManifestJSON(at: when),
            capturedAt: when, deviceID: "device-high", zoneID: zoneID))

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: captureDirectory.appendingPathComponent(
                AppContainer.syncStagingPendingImagesFileName).path),
            "sanity: with no store the park rides the rename and stops inside captures/")
        XCTAssertFalse(FileManager.default.fileExists(atPath: parkURL.path),
                       "sanity: nothing is left at the staging location the sibling sweeps read")

        // A launch that DOES have a store must find and apply it.
        await exchange().rehydrateParkedImages()

        let landed = await landedImages()
        XCTAssertEqual(landed.map(\.id), [imageID])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: captureDirectory.appendingPathComponent(
                AppContainer.syncStagingPendingImagesFileName).path),
            "and must clear the artifact out of the committed directory once applied")
    }

    // MARK: The allow-list — pending-images.json must survive the commit rename

    /// The exact bug class `pending-revisions.json` and `pending-marker-streams.json`
    /// were EACH separately added to `pruneUnexpectedStagingContents` for, now pinned
    /// rather than trusted: a park sitting in `sync/staging/<captureID>/` when the
    /// commit rename runs must ride it into `captures/`, not be swept a microsecond
    /// before. Driven through `EntryAssembler.assemble` directly so the prune step is
    /// the only thing under test.
    func testAParkedImageFileSurvivesTheCommitPruneAndRename() throws {
        let stagingDir = AppContainer.syncStagingCaptureURL(containerRoot: containerRoot, captureID: captureID)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let parkBytes = Data("{\"knownToHaveExisted\":false,\"images\":[]}".utf8)
        try parkBytes.write(to: stagingDir.appendingPathComponent(
            AppContainer.syncStagingPendingImagesFileName))
        // A stray file beside it, to prove the prune is still actively removing things
        // — an allow-list that let everything through would pass this test vacuously.
        try Data("garbage".utf8).write(to: stagingDir.appendingPathComponent("garbage.txt"))

        let when = stamp(0)
        let audioBytes = Data("m4a-bytes".utf8)
        let incoming = EntryIngest.Incoming(
            captureID: captureID, manifestJSON: manifestJSON(at: when),
            metadata: RemoteEntryFields(captureID: captureID, capturedAt: when),
            audio: (url: try writeTempFile(audioBytes, name: "a.m4a"),
                    sha256: SyncTreeScanner.sha256Hex(audioBytes)),
            liveLog: nil)

        XCTAssertTrue(EntryAssembler.assemble(incoming: incoming, containerRoot: containerRoot))

        XCTAssertEqual(
            try Data(contentsOf: captureDirectory.appendingPathComponent(
                AppContainer.syncStagingPendingImagesFileName)),
            parkBytes,
            "pending-images.json must ride the commit rename — sweeping it is permanent image loss")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: captureDirectory.appendingPathComponent("garbage.txt").path),
            "sanity: the prune is still removing what is genuinely unexpected")
    }

    /// The same requirement at the OTHER sweep site: an inbound Entry record for a
    /// capture that already exists clears the staging directory, and must preserve the
    /// park exactly as the commit prune does (the C1 defect, for the third file).
    func testAnExistingCaptureEntryMergeDoesNotSweepTheParkedImage() async throws {
        try mkCaptureDirectory()
        try setTrashed(true)
        let ex = exchange()
        await ex.acceptRemote(try imageRecord(id: imageID, bytes: pngBytes()))
        XCTAssertTrue(FileManager.default.fileExists(atPath: parkURL.path), "sanity: it parked")

        // An Entry record that leaves the capture trashed: the merge runs, staging is
        // cleared, and the rehydration kick re-parks (the capture is still trashed).
        let when = stamp(0)
        await ex.acceptRemote(SyncRecordBuilders.entryRecord(
            captureID: captureID, metadata: EntryMetadata(trashedAt: stamp(50)),
            manifestJSON: manifestJSON(at: when), capturedAt: when,
            deviceID: "device-high", zoneID: zoneID))

        XCTAssertTrue(FileManager.default.fileExists(atPath: parkURL.path),
                      "the entry-merge cleanup must preserve the park, not sweep it")
    }

    /// And the payoff: the same inbound Entry record that UN-trashes the capture lands
    /// the parked image immediately, rather than leaving it for the next launch.
    func testAnEntryMergeThatUntrashesTheCaptureLandsTheParkedImageAtOnce() async throws {
        try mkCaptureDirectory()
        try setTrashed(true)
        let ex = exchange()
        await ex.acceptRemote(try imageRecord(id: imageID, bytes: pngBytes()))

        let when = stamp(0)
        await ex.acceptRemote(SyncRecordBuilders.entryRecord(
            captureID: captureID, metadata: EntryMetadata(modified: ["trashedAt": stamp(900)]),
            manifestJSON: manifestJSON(at: when), capturedAt: when,
            deviceID: "device-high", zoneID: zoneID))

        let landed = await landedImages()
        XCTAssertEqual(landed.map(\.id), [imageID],
                       "a remote restore must land the park in the same pass, not a launch later")
        XCTAssertFalse(FileManager.default.fileExists(atPath: parkURL.path))
    }

    // MARK: The commit-set gap — an image-only entry with no audio at all

    /// **The escalated part of this task.** Before it, `EntryIngest.plan` hard-required
    /// audio to commit ANY new entry, so an image-only entry (`BlankEntryMinter` — no
    /// `final/recording.m4a`, and Task 4's now-conditional `.audio` means no AudioAsset
    /// record is ever pushed for it) could NEVER assemble on a second device. It would
    /// have waited forever for a record that does not exist.
    func testAnImageOnlyEntryAssemblesWithNoAudioAtAll() async throws {
        let when = stamp(0)
        let bytes = pngBytes()
        let ex = exchange()

        await ex.acceptRemote(try imageRecord(id: imageID, bytes: bytes))
        await ex.acceptRemote(SyncRecordBuilders.entryRecord(
            captureID: captureID, metadata: EntryMetadata(journalID: "J1"),
            manifestJSON: blankManifestJSON(at: when), capturedAt: when,
            deviceID: "device-high", zoneID: zoneID))

        XCTAssertTrue(FileManager.default.fileExists(atPath: captureDirectory.path),
                      "an entry whose manifest says it never had audio must commit without one")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SegmentLayout.finalDirectory(captureDirectory: captureDirectory).path),
            "no audio rider means no final/ directory at all — not an empty one")
        let landed = await landedImages()
        XCTAssertEqual(landed.map(\.id), [imageID], "its image lands with the same commit")
        XCTAssertEqual(
            try Data(contentsOf: SegmentLayout.imageOriginalURL(captureDirectory: captureDirectory,
                                                                 imageID: imageID, ext: "png")),
            bytes)
    }

    /// A committed image-only entry must read as SETTLED to the recovery scanner —
    /// exactly the pin `SyncEntryIngestTests` applies to the audio-bearing case. A
    /// directory that reads as needing rescue would be quarantined or deleted on the
    /// next launch.
    func testACommittedImageOnlyEntryIsAlreadySettledForRecovery() async throws {
        let when = stamp(0)
        let ex = exchange()
        await ex.acceptRemote(try imageRecord(id: imageID, bytes: pngBytes()))
        await ex.acceptRemote(SyncRecordBuilders.entryRecord(
            captureID: captureID, metadata: .defaults, manifestJSON: blankManifestJSON(at: when),
            capturedAt: when, deviceID: "device-high", zoneID: zoneID))

        let snapshot = DirectorySnapshot.gather(capturesRoot: capturesRoot, captureID: captureID)
        XCTAssertEqual(RecoveryPlanner.plan(for: snapshot), .finishRawDelete(captureID: captureID),
                       "a synced-in image-only entry must read as settled/complete")
    }

    /// **The non-negotiable regression check (this task's own done-when):** an
    /// AUDIO-BEARING entry's ingest must be byte-for-byte what it was before the
    /// commit-set contract changed — the Entry alone still refuses, and only the arrival
    /// of the AudioAsset commits. No images anywhere in this test.
    func testAnAudioBearingNewEntryIngestIsUnchangedByTheOptionalAudioRule() async throws {
        let when = stamp(0)
        let ex = exchange()

        await ex.acceptRemote(SyncRecordBuilders.entryRecord(
            captureID: captureID, metadata: .defaults, manifestJSON: manifestJSON(at: when),
            capturedAt: when, deviceID: "device-high", zoneID: zoneID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: captureDirectory.path),
                       "an audio-bearing entry must STILL wait for its m4a — the whole point of the check")

        let audioBytes = Data("m4a-bytes".utf8)
        await ex.acceptRemote(SyncRecordBuilders.audioRecord(
            captureID: captureID, m4aURL: try writeTempFile(audioBytes, name: "audio.m4a"),
            sha256: SyncTreeScanner.sha256Hex(audioBytes), bytes: audioBytes.count,
            frameCount: 480_000, sampleRate: 48_000, entryID: entryRecordID, zoneID: zoneID))

        XCTAssertTrue(FileManager.default.fileExists(atPath: captureDirectory.path))
        XCTAssertEqual(try Data(contentsOf: SegmentLayout.finalRecordingURL(captureDirectory: captureDirectory)),
                       audioBytes)
    }

    /// The same rule at the pure layer, exhaustively: only an explicit, decodable
    /// `durationFrames == 0` reads as "this entry never had audio". Every uncertain
    /// case — a nil frame count, an undecodable manifest — keeps waiting, because
    /// committing a real recording's entry without its audio is unrecoverable while
    /// waiting is not.
    func testPlanRequiresAudioForEverythingExceptAnExplicitZeroFrameManifest() {
        func plan(_ manifest: Data) -> EntryIngest.IngestAction {
            EntryIngest.plan(incoming: EntryIngest.Incoming(
                captureID: captureID, manifestJSON: manifest,
                metadata: RemoteEntryFields(captureID: captureID, capturedAt: stamp(0)),
                audio: nil, liveLog: nil), captureExists: false)
        }

        XCTAssertEqual(plan(blankManifestJSON(at: stamp(0))), .assembleNew,
                       "durationFrames == 0 is the one manifest that commits with no audio")
        XCTAssertEqual(plan(manifestJSON(at: stamp(0))), .refuse("m4a not yet fetched"))
        XCTAssertEqual(plan(manifestJSON(at: stamp(0), durationFrames: nil)),
                       .refuse("m4a not yet fetched"),
                       "a verified manifest with no frame count is anomalous, not blank")
        XCTAssertEqual(plan(Data("not a manifest".utf8)), .refuse("m4a not yet fetched"),
                       "an undecodable manifest must never read as 'never had audio'")
    }

    /// `EntryAssembler.assemble` re-derives the same rule rather than trusting its
    /// caller — the identical defense-in-depth the sha256 comparisons already are. A
    /// direct caller handing it an audio-bearing entry with no audio still gets a
    /// refusal and an untouched `captures/`.
    func testAssembleStillRefusesAnAudioBearingEntryWithNoAudio() {
        let incoming = EntryIngest.Incoming(
            captureID: captureID, manifestJSON: manifestJSON(at: stamp(0)),
            metadata: RemoteEntryFields(captureID: captureID, capturedAt: stamp(0)),
            audio: nil, liveLog: nil)

        XCTAssertFalse(EntryAssembler.assemble(incoming: incoming, containerRoot: containerRoot))
        XCTAssertFalse(FileManager.default.fileExists(atPath: captureDirectory.path))
    }
}
