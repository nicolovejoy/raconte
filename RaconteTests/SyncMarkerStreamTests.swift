import XCTest
import CloudKit
@testable import Raconte

/// M4 T10: marker streams — record builder (wire shape), push (`recordToPush`,
/// gated on finalized + own-deviceID-only), and ingest (own-echo refusal, materialize
/// into an existing non-trashed capture, park for an unknown capture then apply after
/// commit, park for a trashed capture then rehydrate). Same four-layer split
/// `SyncRevisionTests` uses for the sibling T9 task.
final class SyncMarkerStreamTests: XCTestCase {

    private let zoneID = CKRecordZone.ID(zoneName: "RaconteZoneTest", ownerName: CKCurrentUserDefaultName)
    private let captureID = ULID.make()
    // `SyncRecordName.markerStream(captureID:deviceID:)` validates BOTH components as
    // well-formed ULIDs (`init?(rawValue:)`) — unlike `.revision(id:)`'s bare-id shape,
    // a marker stream's deviceID is part of the parsed record name, so a readable
    // literal like peerDeviceID would fail to parse and every ingest test would pass
    // vacuously (name-parse failure and the real refusal logic look identical from the
    // outside — both leave nothing on disk). Real ULIDs, minted once per test run.
    private let ownDeviceID = ULID.make()
    private let peerDeviceID = ULID.make()
    private let otherDeviceID = ULID.make()
    private let highDeviceID = ULID.make()
    private var containerRoot: URL!

    override func setUpWithError() throws {
        containerRoot = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("RaconteSyncMarkerStream-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: containerRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: containerRoot)
    }

    private func stamp(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(offset)
    }

    private var capturesRoot: URL { AppContainer.capturesRoot(containerRoot: containerRoot) }

    private var captureDirectory: URL {
        SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
    }

    private var entryRecordID: CKRecord.ID {
        SyncCloudIdentifiers.recordID(.entry(captureID: captureID), zoneID: zoneID)
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

    /// A finalized manifest — the eligibility gate every marker-stream push/scan shares
    /// (`FinalizeArtifactPush.isFinalized` / `SyncTreeScanner.scanCapture`).
    @discardableResult
    private func writeFinalizedManifest(at when: Date = Date(timeIntervalSince1970: 1_700_000_000)) throws -> Manifest {
        try mkCaptureDirectory()
        let manifest = Manifest(captureID: captureID, createdAt: when, state: .complete, stateSeq: 1,
                                stateUpdatedAt: when,
                                format: AudioFormatDescriptor(sampleRate: 48_000, channels: 1,
                                                              commonFormat: .pcmFormatFloat32,
                                                              interleaved: false, bytesPerFrame: 4),
                                final: FinalRef(verifiedAt: when, durationFrames: 480_000))
        try CaptureCoding.encoder().encode(manifest)
            .write(to: SegmentLayout.manifestURL(captureDirectory: captureDirectory))
        return manifest
    }

    private func writeOwnMarkersJSONL(_ text: String) throws {
        let transcriptDir = SegmentLayout.transcriptDirectory(captureDirectory: captureDirectory)
        try FileManager.default.createDirectory(at: transcriptDir, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: SegmentLayout.markerLogURL(captureDirectory: captureDirectory))
    }

    // MARK: markerStreamRecord — field coverage

    func testMarkerStreamRecordCarriesContentAndReferencesItsEntryWithDeleteSelf() {
        let record = SyncRecordBuilders.markerStreamRecord(captureID: captureID, deviceID: ownDeviceID,
                                                            content: "{\"seq\":0}\n",
                                                            entryID: entryRecordID, zoneID: zoneID)

        XCTAssertEqual(record.recordType, "MarkerStream")
        XCTAssertEqual(record.recordID.recordName, "m.\(captureID).\(ownDeviceID)")
        XCTAssertEqual(record["content"] as? String, "{\"seq\":0}\n")
        let ref = record["entryRef"] as? CKRecord.Reference
        XCTAssertEqual(ref?.recordID, entryRecordID)
        XCTAssertEqual(ref?.action, .deleteSelf)
    }

    // MARK: SyncRecordExchange orchestration

    private func exchange(deviceID: String,
                          localStoreDidChange: (@Sendable () async -> Void)? = nil) -> SyncRecordExchange {
        let journalStore = JournalStore(containerRoot: containerRoot)
        let covers = JournalCoverStore(containerRoot: containerRoot, journalStore: journalStore)
        return SyncRecordExchange(
            journalStore: journalStore, coverStore: covers,
            bookkeeping: SyncBookkeepingStore(root: AppContainer.syncRoot(containerRoot: containerRoot)),
            deviceID: deviceID, containerRoot: containerRoot,
            localStoreDidChange: localStoreDidChange)
    }

    // MARK: Push

    /// End to end through the orchestrator: this device's own `markers.jsonl` bytes,
    /// pushed verbatim as the record's `content` string.
    func testRecordToPushBuildsAMarkerStreamRecordWithContentBytesVerbatim() async throws {
        try writeFinalizedManifest()
        try writeOwnMarkersJSONL("{\"seq\":0,\"frame\":0,\"kind\":\"voice\",\"voice\":\"bn\"}\n")

        let ex = exchange(deviceID: ownDeviceID)
        let record = await ex.recordToPush(for: .markerStream(captureID: captureID, deviceID: ownDeviceID),
                                           zoneID: zoneID)

        let unwrapped = try XCTUnwrap(record)
        XCTAssertEqual(unwrapped.recordType, "MarkerStream")
        XCTAssertEqual(unwrapped["content"] as? String,
                       "{\"seq\":0,\"frame\":0,\"kind\":\"voice\",\"voice\":\"bn\"}\n")
    }

    /// A push request naming a deviceID other than this device's own must be refused —
    /// the scanner only ever produces artifacts for this device's own stream, so this
    /// path is a fail-safe against ever pushing someone else's content.
    func testRecordToPushRefusesForAMismatchedDeviceID() async throws {
        try writeFinalizedManifest()
        try writeOwnMarkersJSONL("{\"seq\":0,\"frame\":0,\"kind\":\"paragraph\"}\n")

        let ex = exchange(deviceID: ownDeviceID)
        let record = await ex.recordToPush(for: .markerStream(captureID: captureID, deviceID: otherDeviceID),
                                           zoneID: zoneID)

        XCTAssertNil(record)
    }

    /// The same eligibility gate every sibling push obeys: an un-finalized capture
    /// (no `final.verifiedAt`) must never push, even with markers already on disk.
    func testRecordToPushRefusesWhenNotYetFinalized() async throws {
        try mkCaptureDirectory()
        let manifest = Manifest(captureID: captureID, createdAt: stamp(0), state: .captured, stateSeq: 1,
                                stateUpdatedAt: stamp(0),
                                format: AudioFormatDescriptor(sampleRate: 48_000, channels: 1,
                                                              commonFormat: .pcmFormatFloat32,
                                                              interleaved: false, bytesPerFrame: 4))
        try CaptureCoding.encoder().encode(manifest)
            .write(to: SegmentLayout.manifestURL(captureDirectory: captureDirectory))
        try writeOwnMarkersJSONL("{\"seq\":0,\"frame\":0,\"kind\":\"paragraph\"}\n")

        let ex = exchange(deviceID: ownDeviceID)
        let record = await ex.recordToPush(for: .markerStream(captureID: captureID, deviceID: ownDeviceID),
                                           zoneID: zoneID)

        XCTAssertNil(record)
    }

    // MARK: Ingest — own stream, echoed back

    /// A fetched record naming THIS device's own deviceID must never be materialized as
    /// a foreign sibling (there is no other legitimate writer of it) and must never park.
    func testAcceptRemoteOfOwnMarkerStreamIsIgnored() async throws {
        try writeFinalizedManifest()
        let ex = exchange(deviceID: ownDeviceID)

        let record = SyncRecordBuilders.markerStreamRecord(captureID: captureID, deviceID: ownDeviceID,
                                                            content: "echo\n",
                                                            entryID: entryRecordID, zoneID: zoneID)
        await ex.acceptRemote(record)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SegmentLayout.foreignMarkerLogURL(captureDirectory: captureDirectory, deviceID: ownDeviceID).path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: AppContainer.syncStagingPendingMarkerStreamsURL(
                containerRoot: containerRoot, captureID: captureID).path))
    }

    // MARK: Ingest — existing, not trashed: materialize immediately

    func testAcceptRemoteOfAForeignMarkerStreamForAnExistingCaptureMaterializesImmediately() async throws {
        try writeFinalizedManifest()
        let signals = SignalCounter()
        let ex = exchange(deviceID: ownDeviceID, localStoreDidChange: { await signals.increment() })

        let record = SyncRecordBuilders.markerStreamRecord(captureID: captureID, deviceID: peerDeviceID,
                                                            content: "{\"seq\":0,\"frame\":0,\"kind\":\"voice\",\"voice\":\"bn\"}\n",
                                                            entryID: entryRecordID, zoneID: zoneID)
        await ex.acceptRemote(record)

        let landedURL = SegmentLayout.foreignMarkerLogURL(captureDirectory: captureDirectory, deviceID: peerDeviceID)
        XCTAssertEqual(try Data(contentsOf: landedURL),
                       Data("{\"seq\":0,\"frame\":0,\"kind\":\"voice\",\"voice\":\"bn\"}\n".utf8))
        let count = await signals.count
        XCTAssertEqual(count, 1)
    }

    /// A second delivery for the SAME deviceID must REPLACE, not fail or duplicate —
    /// "whole-field replace is safe" (design §2), since the file is a monotonically
    /// growing single-writer snapshot, not an accumulating list.
    func testASecondDeliveryForTheSameForeignDeviceReplacesTheFirst() async throws {
        try writeFinalizedManifest()
        let ex = exchange(deviceID: ownDeviceID)

        let first = SyncRecordBuilders.markerStreamRecord(captureID: captureID, deviceID: peerDeviceID,
                                                           content: "line-one\n",
                                                           entryID: entryRecordID, zoneID: zoneID)
        await ex.acceptRemote(first)
        let second = SyncRecordBuilders.markerStreamRecord(captureID: captureID, deviceID: peerDeviceID,
                                                            content: "line-one\nline-two\n",
                                                            entryID: entryRecordID, zoneID: zoneID)
        await ex.acceptRemote(second)

        let landedURL = SegmentLayout.foreignMarkerLogURL(captureDirectory: captureDirectory, deviceID: peerDeviceID)
        XCTAssertEqual(try Data(contentsOf: landedURL), Data("line-one\nline-two\n".utf8))
    }

    // MARK: Ingest — unknown capture: park, then apply once the commit lands

    func testAcceptRemoteOfAForeignMarkerStreamForAnUnknownCaptureParksThenAppliesAfterTheEntryCommits() async throws {
        let when = stamp(0)
        let signals = SignalCounter()
        let ex = exchange(deviceID: ownDeviceID, localStoreDidChange: { await signals.increment() })

        let record = SyncRecordBuilders.markerStreamRecord(captureID: captureID, deviceID: peerDeviceID,
                                                            content: "parked-content\n",
                                                            entryID: entryRecordID, zoneID: zoneID)
        await ex.acceptRemote(record)

        XCTAssertFalse(FileManager.default.fileExists(atPath: captureDirectory.path),
                       "a marker stream alone must never create the capture directory")
        var count = await signals.count
        XCTAssertEqual(count, 0)

        // Now the Entry + Audio pair arrives, completing the commit set.
        let manifest = Manifest(captureID: captureID, createdAt: when, state: .complete, stateSeq: 1,
                                stateUpdatedAt: when,
                                format: AudioFormatDescriptor(sampleRate: 48_000, channels: 1,
                                                              commonFormat: .pcmFormatFloat32,
                                                              interleaved: false, bytesPerFrame: 4),
                                final: FinalRef(verifiedAt: when, durationFrames: 480_000))
        let manifestJSON = try CaptureCoding.encoder().encode(manifest)
        let entryRec = SyncRecordBuilders.entryRecord(captureID: captureID, metadata: .defaults,
                                                       manifestJSON: manifestJSON, capturedAt: when,
                                                       deviceID: highDeviceID, zoneID: zoneID)
        await ex.acceptRemote(entryRec)

        let audioBytes = Data("m4a-bytes".utf8)
        let audioURL = containerRoot.appendingPathComponent("audio.m4a")
        try audioBytes.write(to: audioURL)
        let audioRec = SyncRecordBuilders.audioRecord(captureID: captureID, m4aURL: audioURL,
                                                       sha256: SyncTreeScanner.sha256Hex(audioBytes),
                                                       bytes: audioBytes.count, frameCount: 480_000,
                                                       sampleRate: 48_000, entryID: entryRecordID, zoneID: zoneID)
        await ex.acceptRemote(audioRec)

        let landedURL = SegmentLayout.foreignMarkerLogURL(captureDirectory: captureDirectory, deviceID: peerDeviceID)
        XCTAssertEqual(try Data(contentsOf: landedURL), Data("parked-content\n".utf8),
                       "the parked stream must materialize once the capture exists, bytes verbatim")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: captureDirectory.appendingPathComponent("pending-marker-streams.json").path),
            "the internal staging artifact must not linger inside a committed capture directory")
        count = await signals.count
        XCTAssertEqual(count, 1, "exactly one announcement, once the commit (with its parked stream) lands")
    }

    // MARK: Ingest — trashed capture: park, recover on restore + rehydration

    func testAcceptRemoteOfAForeignMarkerStreamForATrashedCaptureParksRatherThanMaterializing() async throws {
        try writeFinalizedManifest()
        try setTrashed(true)
        let ex = exchange(deviceID: ownDeviceID)

        let record = SyncRecordBuilders.markerStreamRecord(captureID: captureID, deviceID: peerDeviceID,
                                                            content: "trashed-content\n",
                                                            entryID: entryRecordID, zoneID: zoneID)
        await ex.acceptRemote(record)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SegmentLayout.foreignMarkerLogURL(captureDirectory: captureDirectory, deviceID: peerDeviceID).path),
            "nothing must land in transcript/ while the capture is trashed")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: AppContainer.syncStagingPendingMarkerStreamsURL(
                containerRoot: containerRoot, captureID: captureID).path),
            "the stream must be parked, not discarded")
    }

    func testAForeignMarkerStreamParkedForATrashedCaptureLandsAfterRestoreAndRehydration() async throws {
        try writeFinalizedManifest()
        try setTrashed(true)
        let ex = exchange(deviceID: ownDeviceID)

        let record = SyncRecordBuilders.markerStreamRecord(captureID: captureID, deviceID: peerDeviceID,
                                                            content: "trashed-content\n",
                                                            entryID: entryRecordID, zoneID: zoneID)
        await ex.acceptRemote(record)

        try setTrashed(false)

        // Cold rebuild: nothing carried over in memory — everything the recovery reads
        // comes off disk, the identical "simulated relaunch" idiom `SyncRevisionTests` uses.
        let coldExchange = exchange(deviceID: ownDeviceID)
        await coldExchange.rehydrateParkedMarkerStreams()

        let landedURL = SegmentLayout.foreignMarkerLogURL(captureDirectory: captureDirectory, deviceID: peerDeviceID)
        XCTAssertEqual(try Data(contentsOf: landedURL), Data("trashed-content\n".utf8))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: AppContainer.syncStagingPendingMarkerStreamsURL(
                containerRoot: containerRoot, captureID: captureID).path),
            "the parking must clear once applied")
    }

    /// Design §5's delete-wins, applied without error: a parked stream for a capture
    /// that gets PURGED (not merely trashed) while parked is discarded on the next
    /// rehydration, never resurrecting the purged directory.
    func testAParkedForeignMarkerStreamForAPurgedCaptureIsDiscardedOnRehydrationWithoutError() async throws {
        try writeFinalizedManifest()
        try setTrashed(true)
        let ex = exchange(deviceID: ownDeviceID)

        let record = SyncRecordBuilders.markerStreamRecord(captureID: captureID, deviceID: peerDeviceID,
                                                            content: "will-be-purged\n",
                                                            entryID: entryRecordID, zoneID: zoneID)
        await ex.acceptRemote(record)

        try FileManager.default.removeItem(at: captureDirectory)

        await ex.rehydrateParkedMarkerStreams()

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: AppContainer.syncStagingPendingMarkerStreamsURL(
                containerRoot: containerRoot, captureID: captureID).path),
            "the parking must be discarded once the capture is gone")
        XCTAssertFalse(FileManager.default.fileExists(atPath: captureDirectory.path),
                       "rehydration must never resurrect a purged capture")
    }

    /// An ordinary in-flight "unknown capture" park (the capture's Entry/Audio simply
    /// have not arrived yet) must never be discarded by rehydration just because the
    /// directory happens to be absent right now — `knownToHaveExisted` disambiguates
    /// this from a genuine purge, mirroring `ParkedRevisions`' own regression guard.
    func testRehydrationLeavesAnInFlightUnknownCaptureMarkerStreamParkUntouched() async throws {
        let ex = exchange(deviceID: ownDeviceID)
        let record = SyncRecordBuilders.markerStreamRecord(captureID: captureID, deviceID: peerDeviceID,
                                                            content: "still-unknown\n",
                                                            entryID: entryRecordID, zoneID: zoneID)
        await ex.acceptRemote(record)

        let parkURL = AppContainer.syncStagingPendingMarkerStreamsURL(containerRoot: containerRoot,
                                                                       captureID: captureID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: parkURL.path), "sanity: it parked")

        await ex.rehydrateParkedMarkerStreams()

        XCTAssertTrue(FileManager.default.fileExists(atPath: parkURL.path),
                      "an in-flight unknown-capture park must never be discarded by rehydration")
        XCTAssertFalse(FileManager.default.fileExists(atPath: captureDirectory.path))
    }

    // MARK: Fix wave finding 4 — the three unparked returns

    private func bookkeeping() -> SyncBookkeepingStore {
        SyncBookkeepingStore(root: AppContainer.syncRoot(containerRoot: containerRoot))
    }

    /// With no container root wired, the record name — the only thing left to hold onto
    /// — must be parked (`SyncBookkeepingStore`'s `parked.json`, the same durable park
    /// every sibling ingest function uses for this exact branch), never merely logged
    /// and dropped.
    func testAMarkerStreamWithNoContainerRootWiredIsParked() async throws {
        let journalStore = JournalStore(containerRoot: containerRoot)
        let covers = JournalCoverStore(containerRoot: containerRoot, journalStore: journalStore)
        let ex = SyncRecordExchange(
            journalStore: journalStore, coverStore: covers,
            bookkeeping: SyncBookkeepingStore(root: AppContainer.syncRoot(containerRoot: containerRoot)),
            deviceID: ownDeviceID)   // no containerRoot

        let record = SyncRecordBuilders.markerStreamRecord(captureID: captureID, deviceID: peerDeviceID,
                                                            content: "no-root\n",
                                                            entryID: entryRecordID, zoneID: zoneID)
        await ex.acceptRemote(record)

        let parked = await bookkeeping().parkedRecords()
        XCTAssertEqual(parked[record.recordID.recordName]?.reason, "no container root wired")
    }

    /// A record missing `content` (or whose `entryRef` disagrees with its own name) is
    /// not a real MarkerStream record — `CKSyncEngine` never redelivers it, so refusing
    /// without parking would lose the stream permanently the moment it arrived malformed
    /// even once.
    func testAMarkerStreamRecordMissingContentIsParkedNotIgnored() async throws {
        try writeFinalizedManifest()
        let ex = exchange(deviceID: ownDeviceID)

        let record = SyncRecordBuilders.markerStreamRecord(captureID: captureID, deviceID: peerDeviceID,
                                                            content: "will-be-removed\n",
                                                            entryID: entryRecordID, zoneID: zoneID)
        record[SyncMarkerStreamField.content] = nil
        await ex.acceptRemote(record)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SegmentLayout.foreignMarkerLogURL(captureDirectory: captureDirectory, deviceID: peerDeviceID).path))
        let parked = await bookkeeping().parkedRecords()
        XCTAssertEqual(parked[record.recordID.recordName]?.reason,
                       "marker stream content could not be decoded")
    }

    /// A `materializeMarkerStream` write failure — forced here by occupying
    /// `transcript/` with a plain file, so `createDirectory` throws — must park rather
    /// than silently drop the bytes, mirroring every other durable-write failure in this
    /// file (`testALocalWriteFailureForEntryIsParked` and siblings).
    func testALocalWriteFailureForAMarkerStreamIsParked() async throws {
        try writeFinalizedManifest()
        try Data("blocks the transcript directory".utf8).write(
            to: captureDirectory.appendingPathComponent(SegmentLayout.transcriptDirName))
        let ex = exchange(deviceID: ownDeviceID)

        let record = SyncRecordBuilders.markerStreamRecord(captureID: captureID, deviceID: peerDeviceID,
                                                            content: "blocked\n",
                                                            entryID: entryRecordID, zoneID: zoneID)
        await ex.acceptRemote(record)

        let parked = await bookkeeping().parkedRecords()
        XCTAssertEqual(parked[record.recordID.recordName]?.reason, "local write failed")
    }

    /// The success path must unpark — mirroring `testACleanEntryIngestUnparksThatName`
    /// — or a name parked by any of the three branches above is refetched and
    /// re-ingested on every launch and foreground forever.
    func testACleanMarkerStreamIngestUnparksThatName() async throws {
        try writeFinalizedManifest()
        let ex = exchange(deviceID: ownDeviceID)

        let record = SyncRecordBuilders.markerStreamRecord(captureID: captureID, deviceID: peerDeviceID,
                                                            content: "{\"seq\":0}\n",
                                                            entryID: entryRecordID, zoneID: zoneID)
        await bookkeeping().park(record.recordID.recordName, reason: "local write failed")

        await ex.acceptRemote(record)

        let parked = await bookkeeping().parkedRecords()
        XCTAssertNil(parked[record.recordID.recordName])
    }
}
