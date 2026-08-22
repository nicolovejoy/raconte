import XCTest
import CloudKit
@testable import Raconte

/// M4 (marker-correction push hook): the T10 review's named-but-unwired chokepoint
/// (design §3) — a post-finalization marker correction (Mark-voices mode) must fire
/// `SyncHooks.noteLocalChange` naming this device's own marker stream, so it pushes on
/// the next sync round rather than waiting for a reconciliation scan. Same "fire only
/// after a durable write actually lands" discipline `SyncRevisionTests
/// .testAppendFiresTheSyncHookOncePerMintedRevision` pins for `TranscriptRevisionStore
/// .append` — this is that test's sibling for `LibraryScreenModel`'s `VoiceMarkingStore`
/// conformance, the two production call sites (`addVoiceBoundary`/`addOpeningVoice`)
/// that actually durably append to `markers.jsonl` after a capture is finalized.
///
/// `RecordingSyncHooks` is `SyncJournalIngestTests`'s shared fixture — same module test
/// target, reused rather than redefined.
@MainActor
final class MarkerStreamSyncHookTests: XCTestCase {

    private var containerRoot: URL!
    private var capturesRoot: URL { AppContainer.capturesRoot(containerRoot: containerRoot) }
    private let captureID = ULID.make()

    override func setUpWithError() throws {
        containerRoot = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("MarkerStreamSyncHook-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: capturesRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let containerRoot { try? FileManager.default.removeItem(at: containerRoot) }
    }

    private func model() -> LibraryScreenModel {
        LibraryScreenModel(capturesRoot: capturesRoot, journalsContainerRoot: containerRoot)
    }

    private var captureDirectory: URL {
        SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
    }

    private var markerLogURL: URL {
        SegmentLayout.markerLogURL(captureDirectory: captureDirectory)
    }

    /// A readable `canonical-0.json` with one placeable, three-word span — the
    /// prerequisite `addVoiceBoundary` needs (`currentSpans(for:)` reads it), same
    /// recipe `UITestVoiceMarkingSeed.writeSpans` uses (frame-bounded, `.inherited`
    /// anchor, non-zero length).
    @discardableResult
    private func writeSpans(revisionID: String = ULID.make()) throws -> [TranscriptSpan] {
        let spans = [
            TranscriptSpan(text: "one", anchor: .inherited, frameStart: 0, frameEnd: 10_000),
            TranscriptSpan(text: "two", anchor: .inherited, frameStart: 20_000, frameEnd: 30_000),
            TranscriptSpan(text: "three", anchor: .inherited, frameStart: 40_000, frameEnd: 50_000),
        ]
        let revision = TranscriptRevision(id: revisionID, source: .machineLive, createdAt: Date(), spans: spans)
        try FileManager.default.createDirectory(
            at: SegmentLayout.transcriptDirectory(captureDirectory: captureDirectory),
            withIntermediateDirectories: true)
        let data = try CaptureCoding.encoder().encode(revision)
        try data.write(to: SegmentLayout.canonicalTranscriptURL(captureDirectory: captureDirectory, revision: 0))
        return spans
    }

    // MARK: addVoiceBoundary — the flip/mark-range write path

    /// The recorder-hook test (brief 4a): a post-finalization voice-marking correction
    /// through the real store fires exactly one `noteLocalChange` naming the OWN
    /// device's marker stream. Mutation evidence: deleting the `syncHooks?.noteLocalChange`
    /// call in `LibraryScreenModel.addVoiceBoundary` makes this fail (`names` stays `[]`)
    /// — verified by hand per the brief.
    func testAddVoiceBoundaryFiresTheSyncHookOnceNamingTheOwnDeviceMarkerStream() async throws {
        try writeSpans()
        let hooks = RecordingSyncHooks()
        let library = model()
        library.attach(syncHooks: hooks)

        _ = try await library.addVoiceBoundary(atSpanIndex: 1, voice: "ln", captureID: captureID)

        let names = await hooks.names
        XCTAssertEqual(names, [.markerStream(captureID: captureID, deviceID: DeviceIdentity.stable())],
                       "exactly one notification, naming this device's own stream")
    }

    /// The second production writer on this path (brief: "frame 0, no span
    /// prerequisite") — same fire-after-durable-write discipline, no `writeSpans` needed.
    func testAddOpeningVoiceFiresTheSyncHookNamingTheOwnDeviceMarkerStream() async throws {
        try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
        let hooks = RecordingSyncHooks()
        let library = model()
        library.attach(syncHooks: hooks)

        try await library.addOpeningVoice(voice: "bn", captureID: captureID)

        let names = await hooks.names
        XCTAssertEqual(names, [.markerStream(captureID: captureID, deviceID: DeviceIdentity.stable())])
    }

    /// A nil hook (sync off) behaves exactly as before M4: no crash, nothing to check —
    /// same shape as `SyncRevisionTests.testAppendWithNoHookDoesNotCrash`.
    func testAddVoiceBoundaryWithNoHookDoesNotCrash() async throws {
        try writeSpans()
        _ = try await model().addVoiceBoundary(atSpanIndex: 0, voice: "ln", captureID: captureID)
        // No assertion beyond "did not throw" — there is no recorder to read.
    }

    // MARK: Failed appends fire nothing

    /// An `addOpeningVoice` whose append cannot durably land (an unreadable existing
    /// `markers.jsonl` — `MarkerLogWriter.open()`'s documented refuse-rather-than-
    /// renumber guard, same fixture `MarkerLogTests
    /// .testOpenOnAnUnreadableLogThrowsRatherThanRenumbering` uses) must fire nothing:
    /// the write never landed, so there is nothing to announce.
    func testAddOpeningVoiceWithAnUnreadableExistingLogFiresNothing() async throws {
        // Plant a readable log first, so the SECOND call is the one that hits the
        // already-exists-but-now-unreadable path, not a fresh-file create.
        try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
        let writer = MarkerLogWriter(captureDirectory: captureDirectory)
        try writer.open()
        try writer.append(StructureMarker(seq: 0, frame: 0, kind: .voice, voice: "bn"))
        try writer.close()

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: markerLogURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: markerLogURL.path) }
        try XCTSkipIf(FileManager.default.isReadableFile(atPath: markerLogURL.path),
                      "running as root — permissions cannot be made to bite")

        let hooks = RecordingSyncHooks()
        let library = model()
        library.attach(syncHooks: hooks)

        do {
            try await library.addOpeningVoice(voice: "ln", captureID: captureID)
            XCTFail("expected the unreadable-log open() to throw")
        } catch {
            // Expected — MarkerLogError.unreadableExistingLog, matching
            // MarkerLogTests's own pin on that behavior.
        }

        let names = await hooks.names
        XCTAssertEqual(names, [], "a write that never landed must never be announced")
    }

    /// `addVoiceBoundary`'s own refusal path (no readable `current` revision at all —
    /// `MarkerCorrectionWriter.BoundaryAddError.noUsableBounds`) is likewise a write that
    /// never reached `MarkerCorrectionWriter.appendOne` — nothing to announce.
    func testAddVoiceBoundaryWithNoReadableCurrentRevisionFiresNothing() async throws {
        try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
        let hooks = RecordingSyncHooks()
        let library = model()
        library.attach(syncHooks: hooks)

        do {
            _ = try await library.addVoiceBoundary(atSpanIndex: 0, voice: "ln", captureID: captureID)
            XCTFail("expected .noUsableBounds — no canonical-0.json exists")
        } catch MarkerCorrectionWriter.BoundaryAddError.noUsableBounds {
            // Expected.
        }

        let names = await hooks.names
        XCTAssertEqual(names, [])
    }

    // MARK: Foreign-stream ingest must never fire this hook

    /// Structural confirmation of brief 4b: ingest materializes a foreign device's
    /// stream through `SyncRecordExchange`/`materializeMarkerStream`, writing to
    /// `foreignMarkerLogURL` — a different file, through a completely different type,
    /// with no reference to this model's `syncHooks` at all. Wires `RecordingSyncHooks`
    /// into the SAME `LibraryScreenModel` over the SAME `capturesRoot` the exchange
    /// writes into, then runs the real `acceptRemote` ingest path, and confirms nothing
    /// fired — demonstrating the new wiring cannot echo even when the hook is reachable
    /// in the same process.
    func testForeignMarkerStreamIngestNeverFiresTheHookEvenWhenTheSameLibraryHasOneAttached() async throws {
        let zoneID = CKRecordZoneTestID.raconteZone
        let ownDeviceID = ULID.make()
        let peerDeviceID = ULID.make()

        // Finalized manifest — the eligibility gate `materializeMarkerStream`'s caller
        // (`ingestMarkerStream`) shares with every other push/ingest path.
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
        let manifest = Manifest(captureID: captureID, createdAt: when, state: .complete, stateSeq: 1,
                                stateUpdatedAt: when,
                                format: AudioFormatDescriptor(sampleRate: 48_000, channels: 1,
                                                              commonFormat: .pcmFormatFloat32,
                                                              interleaved: false, bytesPerFrame: 4),
                                final: FinalRef(verifiedAt: when, durationFrames: 480_000))
        try CaptureCoding.encoder().encode(manifest)
            .write(to: SegmentLayout.manifestURL(captureDirectory: captureDirectory))

        let hooks = RecordingSyncHooks()
        let library = model()
        library.attach(syncHooks: hooks)

        let journalStore = JournalStore(containerRoot: containerRoot)
        let covers = JournalCoverStore(containerRoot: containerRoot, journalStore: journalStore)
        let exchange = SyncRecordExchange(
            journalStore: journalStore, coverStore: covers,
            bookkeeping: SyncBookkeepingStore(root: AppContainer.syncRoot(containerRoot: containerRoot)),
            deviceID: ownDeviceID, containerRoot: containerRoot)

        let entryID = SyncCloudIdentifiers.recordID(.entry(captureID: captureID), zoneID: zoneID)
        let record = SyncRecordBuilders.markerStreamRecord(
            captureID: captureID, deviceID: peerDeviceID, content: "{\"seq\":0,\"frame\":0,\"kind\":\"paragraph\"}\n",
            entryID: entryID, zoneID: zoneID)
        await exchange.acceptRemote(record)

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: SegmentLayout.foreignMarkerLogURL(captureDirectory: captureDirectory, deviceID: peerDeviceID).path),
            "sanity: the ingest actually materialized the foreign stream")

        let names = await hooks.names
        XCTAssertEqual(names, [], "ingest must never notify sync of a foreign device's own write")
    }
}

/// A real zone id, matching every sibling sync test's fixture — see `SyncMarkerStreamTests`.
private enum CKRecordZoneTestID {
    static let raconteZone = CKRecordZone.ID(zoneName: "RaconteZoneTest", ownerName: CKCurrentUserDefaultName)
}
