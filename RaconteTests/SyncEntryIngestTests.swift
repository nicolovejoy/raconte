import XCTest
import CloudKit
@testable import Raconte

/// M4 T7: new-entry ingest — "assemble-then-commit" (design §6). Three layers, tested
/// separately per the repo's usual split: `RemoteEntryFields` (wire decode, pure),
/// `EntryIngest.plan` (the commit-set decision, pure), `EntryAssembler.assemble` (the
/// staged rename, IO but no CloudKit), then the orchestrator wiring through
/// `SyncRecordExchange.acceptRemote` (real CKRecords, real filesystem, no server).
final class SyncEntryIngestTests: XCTestCase {

    private var containerRoot: URL!
    private let zoneID = CKRecordZone.ID(zoneName: "RaconteZoneTest", ownerName: CKCurrentUserDefaultName)
    private let captureID = ULID.make()

    override func setUpWithError() throws {
        containerRoot = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("RaconteSyncEntryIngest-\(UUID().uuidString)", isDirectory: true)
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

    private var stagingDirectory: URL {
        AppContainer.syncStagingCaptureURL(containerRoot: containerRoot, captureID: captureID)
    }

    private func format() -> AudioFormatDescriptor {
        AudioFormatDescriptor(sampleRate: 48_000, channels: 1,
                              commonFormat: .pcmFormatFloat32, interleaved: false, bytesPerFrame: 4)
    }

    private func manifestJSON(state: CaptureState = .complete, verified: Bool = true, at when: Date) -> Data {
        let final = verified ? FinalRef(verifiedAt: when, durationFrames: 480_000) : FinalRef()
        let manifest = Manifest(captureID: captureID, createdAt: when, state: state,
                                stateSeq: 1, stateUpdatedAt: when, format: format(), final: final)
        return try! CaptureCoding.encoder().encode(manifest)
    }

    private func writeTempFile(_ data: Data, name: String) -> URL {
        let url = containerRoot.appendingPathComponent("wire-\(UUID().uuidString)-\(name)")
        try! data.write(to: url)
        return url
    }

    private func audioPiece(bytes: Data) -> (url: URL, sha256: String) {
        (url: writeTempFile(bytes, name: "recording.m4a"), sha256: SyncTreeScanner.sha256Hex(bytes))
    }

    private func liveLogPiece(bytes: Data) -> (url: URL, sha256: String) {
        (url: writeTempFile(bytes, name: "live.jsonl"), sha256: SyncTreeScanner.sha256Hex(bytes))
    }

    private var entryRecordID: CKRecord.ID {
        SyncCloudIdentifiers.recordID(.entry(captureID: captureID), zoneID: zoneID)
    }

    private func entryRecord(metadata: EntryMetadata, manifestJSON: Data, at when: Date) -> CKRecord {
        SyncRecordBuilders.entryRecord(captureID: captureID, metadata: metadata,
                                       manifestJSON: manifestJSON, capturedAt: when, zoneID: zoneID)
    }

    private func audioRecord(bytes: Data, sha256: String? = nil) -> CKRecord {
        let url = writeTempFile(bytes, name: "audio.m4a")
        return SyncRecordBuilders.audioRecord(
            captureID: captureID, m4aURL: url, sha256: sha256 ?? SyncTreeScanner.sha256Hex(bytes),
            bytes: bytes.count, frameCount: 480_000, sampleRate: 48_000,
            entryID: entryRecordID, zoneID: zoneID)
    }

    private func liveLogRecord(bytes: Data, sha256: String? = nil) -> CKRecord {
        let url = writeTempFile(bytes, name: "live.jsonl")
        return SyncRecordBuilders.liveLogRecord(
            captureID: captureID, fileURL: url, sha256: sha256 ?? SyncTreeScanner.sha256Hex(bytes),
            bytes: bytes.count, entryID: entryRecordID, zoneID: zoneID)
    }

    // MARK: RemoteEntryFields — wire decode

    func testRemoteEntryFieldsDecodesEveryFieldFromARecord() throws {
        let metadata = EntryMetadata(
            journalID: "J1",
            originalDate: try PartialDate(parsing: "1998-03-04"),
            trashedAt: stamp(30),
            detectedDate: try PartialDate(parsing: "1998-03"),
            detectionRan: true,
            multiVoice: true,
            modified: ["journalID": stamp(10), "trashedAt": stamp(30)])
        let record = entryRecord(metadata: metadata, manifestJSON: Data("{}".utf8), at: stamp(0))

        let fields = try XCTUnwrap(RemoteEntryFields(record: record))

        XCTAssertEqual(fields.captureID, captureID, "from the record NAME, never a field")
        XCTAssertEqual(fields.capturedAt, stamp(0))
        XCTAssertEqual(fields.journalID, "J1")
        XCTAssertEqual(fields.originalDate, try PartialDate(parsing: "1998-03-04"))
        XCTAssertEqual(fields.trashedAt, stamp(30))
        XCTAssertEqual(fields.multiVoice, true)
        XCTAssertEqual(fields.detectedDate, try PartialDate(parsing: "1998-03"))
        XCTAssertEqual(fields.detectionRan, true)
        XCTAssertEqual(fields.modified, ["journalID": stamp(10), "trashedAt": stamp(30)])
    }

    /// The "missing entry" commit-set piece: a record with no `capturedAt` at all is not
    /// a real Entry record — decode must refuse rather than default it, so the whole
    /// ingest never proceeds for a name that never really arrived.
    func testRemoteEntryFieldsFailsWithoutCapturedAt() {
        let record = CKRecord(recordType: SyncRecordType.entry, recordID: entryRecordID)
        XCTAssertNil(RemoteEntryFields(record: record))
    }

    func testRemoteEntryFieldsFailsOnAWrongRecordType() {
        let record = CKRecord(recordType: "NotEntry", recordID: entryRecordID)
        XCTAssertNil(RemoteEntryFields(record: record))
    }

    /// `originalDate` is user-authored content, same as `EntryMetadata.init(from:)`'s own
    /// rule — a present-but-unparseable value must not be silently treated as "never
    /// backdated".
    func testRemoteEntryFieldsFailsOnAnUnparseableOriginalDate() {
        let record = entryRecord(metadata: .defaults, manifestJSON: Data("{}".utf8), at: stamp(0))
        record[SyncEntryField.originalDate] = "not-a-partial-date"
        XCTAssertNil(RemoteEntryFields(record: record))
    }

    /// Every other optional field is additive/lenient: a damaged `detectedDate` costs
    /// only that field, and `detectionRan`'s own explicit key (independent of whether
    /// `detectedDate` itself parsed) keeps the latch's closed state intact — mirroring
    /// `EntryMetadata.init(from:)`'s reasoning for the same two fields.
    func testRemoteEntryFieldsToleratesADamagedDetectedDateWithoutFailingTheWholeDecode() throws {
        let metadata = EntryMetadata(detectedDate: try PartialDate(parsing: "1998"), detectionRan: true)
        let record = entryRecord(metadata: metadata, manifestJSON: Data("{}".utf8), at: stamp(0))
        record[SyncEntryField.detectedDate] = "garbage"

        let fields = try XCTUnwrap(RemoteEntryFields(record: record))
        XCTAssertNil(fields.detectedDate)
        XCTAssertTrue(fields.detectionRan, "the latch survives via its own explicit key")
    }

    /// The materialized sidecar must be byte-for-byte what a local capture with the same
    /// field values would write — `entry.json` is written from exactly this.
    func testRemoteEntryFieldsMetadataMatchesAnEquivalentEntryMetadata() throws {
        let fields = RemoteEntryFields(captureID: captureID, capturedAt: stamp(0), journalID: "J1",
                                       originalDate: try PartialDate(parsing: "1998-03-04"),
                                       multiVoice: true, modified: ["journalID": stamp(10)])
        let expected = EntryMetadata(journalID: "J1", originalDate: try PartialDate(parsing: "1998-03-04"),
                                     multiVoice: true, modified: ["journalID": stamp(10)])
        XCTAssertEqual(fields.metadata, expected)
    }

    // MARK: EntryIngest.plan — the commit-set decision

    /// Named test per missing piece (brief): the manifest half.
    func testPlanRefusesWhenTheManifestIsMissing() {
        let incoming = EntryIngest.Incoming(
            captureID: captureID, manifestJSON: Data(),
            metadata: RemoteEntryFields(captureID: captureID, capturedAt: stamp(0)),
            audio: (url: containerRoot, sha256: "irrelevant"), liveLog: nil)
        XCTAssertEqual(EntryIngest.plan(incoming: incoming, captureExists: false),
                       .refuse("manifest not yet fetched"))
    }

    /// Named test per missing piece (brief): the m4a half — a SEPARATE record
    /// (AudioAsset) that commonly has not arrived when the Entry record does.
    func testPlanRefusesWhenTheAudioIsMissing() {
        let incoming = EntryIngest.Incoming(
            captureID: captureID, manifestJSON: manifestJSON(at: stamp(0)),
            metadata: RemoteEntryFields(captureID: captureID, capturedAt: stamp(0)),
            audio: nil, liveLog: nil)
        XCTAssertEqual(EntryIngest.plan(incoming: incoming, captureExists: false),
                       .refuse("m4a not yet fetched"))
    }

    /// Transcript artifacts are optional riders: manifest + entry + m4a is a complete
    /// commit set with no `liveLog` at all.
    func testPlanAssemblesWithNoLiveLogAtAll() {
        let incoming = EntryIngest.Incoming(
            captureID: captureID, manifestJSON: manifestJSON(at: stamp(0)),
            metadata: RemoteEntryFields(captureID: captureID, capturedAt: stamp(0)),
            audio: (url: containerRoot, sha256: "x"), liveLog: nil)
        XCTAssertEqual(EntryIngest.plan(incoming: incoming, captureExists: false), .assembleNew)
    }

    /// `captureExists == true` → `.applyToExisting` unconditionally — the rename path is
    /// never taken (proven at the orchestrator level below), and a missing/empty
    /// manifest or m4a on the WIRE must not matter, because an existing capture's own
    /// content is what T8 merges against, not whatever happens to have arrived.
    func testPlanReturnsApplyToExistingRegardlessOfMissingPiecesWhenTheCaptureAlreadyExistsLocally() {
        let incoming = EntryIngest.Incoming(
            captureID: captureID, manifestJSON: Data(),
            metadata: RemoteEntryFields(captureID: captureID, capturedAt: stamp(0)),
            audio: nil, liveLog: nil)
        XCTAssertEqual(EntryIngest.plan(incoming: incoming, captureExists: true), .applyToExisting)
    }

    // MARK: EntryAssembler — the staged rename

    func testAssembleWritesManifestEntryAndAudioAndCommitsIntoCaptures() throws {
        let when = stamp(0)
        let manifest = manifestJSON(at: when)
        let audioBytes = Data("m4a-bytes".utf8)
        let incoming = EntryIngest.Incoming(
            captureID: captureID, manifestJSON: manifest,
            metadata: RemoteEntryFields(captureID: captureID, capturedAt: when, journalID: "J1"),
            audio: audioPiece(bytes: audioBytes), liveLog: nil)

        let committed = EntryAssembler.assemble(incoming: incoming, containerRoot: containerRoot)

        XCTAssertTrue(committed)
        XCTAssertEqual(try Data(contentsOf: SegmentLayout.manifestURL(captureDirectory: captureDirectory)),
                       manifest)
        let entry = try CaptureCoding.decoder().decode(
            EntryMetadata.self,
            from: Data(contentsOf: SegmentLayout.entryMetadataURL(captureDirectory: captureDirectory)))
        XCTAssertEqual(entry.journalID, "J1")
        XCTAssertEqual(try Data(contentsOf: SegmentLayout.finalRecordingURL(captureDirectory: captureDirectory)),
                       audioBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingDirectory.path),
                       "staging must not survive a successful commit")
    }

    func testAssembleWritesTheOptionalLiveLogWhenPresent() throws {
        let when = stamp(0)
        let liveBytes = Data("{\"seq\":0}\n".utf8)
        let incoming = EntryIngest.Incoming(
            captureID: captureID, manifestJSON: manifestJSON(at: when),
            metadata: RemoteEntryFields(captureID: captureID, capturedAt: when),
            audio: audioPiece(bytes: Data("m4a-bytes".utf8)), liveLog: liveLogPiece(bytes: liveBytes))

        XCTAssertTrue(EntryAssembler.assemble(incoming: incoming, containerRoot: containerRoot))

        XCTAssertEqual(
            try Data(contentsOf: SegmentLayout.liveTranscriptURL(captureDirectory: captureDirectory)),
            liveBytes)
    }

    /// Data-integrity pin: a sha256 mismatch on the audio refuses the WHOLE commit — the
    /// manifest/entry bytes already written into staging this call must not survive
    /// either, and `captures/` must never see a rename.
    func testAssembleRefusesOnAudioSha256MismatchAndDiscardsStaging() throws {
        let when = stamp(0)
        let incoming = EntryIngest.Incoming(
            captureID: captureID, manifestJSON: manifestJSON(at: when),
            metadata: RemoteEntryFields(captureID: captureID, capturedAt: when),
            audio: (url: writeTempFile(Data("m4a-bytes".utf8), name: "a.m4a"), sha256: "wrong-hash"),
            liveLog: nil)

        let committed = EntryAssembler.assemble(incoming: incoming, containerRoot: containerRoot)

        XCTAssertFalse(committed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: captureDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingDirectory.path))
    }

    /// Same pin, the liveLog side: an optional rider whose bytes don't check out must
    /// still refuse the ENTIRE commit, not silently drop just the transcript.
    func testAssembleRefusesOnLiveLogSha256MismatchAndDiscardsStaging() throws {
        let when = stamp(0)
        let incoming = EntryIngest.Incoming(
            captureID: captureID, manifestJSON: manifestJSON(at: when),
            metadata: RemoteEntryFields(captureID: captureID, capturedAt: when),
            audio: audioPiece(bytes: Data("m4a-bytes".utf8)),
            liveLog: (url: writeTempFile(Data("{}\n".utf8), name: "live.jsonl"), sha256: "wrong-hash"))

        let committed = EntryAssembler.assemble(incoming: incoming, containerRoot: containerRoot)

        XCTAssertFalse(committed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: captureDirectory.path),
                       "a bad liveLog must refuse the whole entry, not just skip the transcript")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingDirectory.path))
    }

    /// Interrupted-assembly recovery: a stale staging directory from a crashed prior
    /// attempt must be DISCARDED, not merged into — otherwise a garbage leftover file
    /// would ride along into `captures/` on the next successful assembly.
    func testAssembleDiscardsAStaleStagingDirectoryRatherThanMergingIntoIt() throws {
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        try Data("stale garbage from a crashed attempt".utf8)
            .write(to: stagingDirectory.appendingPathComponent("garbage.txt"))

        let when = stamp(0)
        let incoming = EntryIngest.Incoming(
            captureID: captureID, manifestJSON: manifestJSON(at: when),
            metadata: RemoteEntryFields(captureID: captureID, capturedAt: when),
            audio: audioPiece(bytes: Data("m4a-bytes".utf8)), liveLog: nil)

        let committed = EntryAssembler.assemble(incoming: incoming, containerRoot: containerRoot)

        XCTAssertTrue(committed)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: captureDirectory.appendingPathComponent("garbage.txt").path),
            "the stale staging directory must be rebuilt from scratch, not merged into")
    }

    func testAssembleWithNoAudioAtAllReturnsFalseAndTouchesNothing() {
        let incoming = EntryIngest.Incoming(
            captureID: captureID, manifestJSON: manifestJSON(at: stamp(0)),
            metadata: RemoteEntryFields(captureID: captureID, capturedAt: stamp(0)),
            audio: nil, liveLog: nil)

        let committed = EntryAssembler.assemble(incoming: incoming, containerRoot: containerRoot)

        XCTAssertFalse(committed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: captureDirectory.path))
    }

    /// THE critical safety test: the rename must land a directory whose recovery-scan
    /// classification is already settled — never something that reads as needing rescue.
    ///
    /// Mutation check (run by hand, per the brief): corrupting `manifestJSON`'s `state`
    /// to `.recording` (instead of `.complete`) makes this fail — `RecoveryPlanner`
    /// reads no `segments/` at all (nothing assembled here ever creates one) and
    /// `hasData` is false, so `decide` would answer `.deleteCaptureDirectory`, upgraded
    /// by the #8 guard (real `final/recording.m4a` on disk) to
    /// `.quarantineCaptureDirectory` — a DIFFERENT action than the `.finishRawDelete`
    /// asserted below, so the exact-equality assertion catches it.
    func testAssembledCaptureIsAlreadySettledForRecovery() throws {
        let when = stamp(0)
        let incoming = EntryIngest.Incoming(
            captureID: captureID, manifestJSON: manifestJSON(state: .complete, verified: true, at: when),
            metadata: RemoteEntryFields(captureID: captureID, capturedAt: when),
            audio: audioPiece(bytes: Data("m4a-bytes-not-real-audio".utf8)), liveLog: nil)
        XCTAssertTrue(EntryAssembler.assemble(incoming: incoming, containerRoot: containerRoot))

        let snapshot = DirectorySnapshot.gather(capturesRoot: capturesRoot, captureID: captureID)
        let action = RecoveryPlanner.plan(for: snapshot)

        XCTAssertEqual(action, .finishRawDelete(captureID: captureID),
                       "a synced-in finalized capture must read as settled/complete, "
                       + "never as something that needs recovery")
    }

    // MARK: Orchestrator wiring — through SyncRecordExchange.acceptRemote

    private func exchange(localStoreDidChange: (@Sendable () async -> Void)? = nil) -> SyncRecordExchange {
        let store = JournalStore(containerRoot: containerRoot)
        let covers = JournalCoverStore(containerRoot: containerRoot, journalStore: store)
        return SyncRecordExchange(
            journalStore: store, coverStore: covers,
            bookkeeping: SyncBookkeepingStore(root: AppContainer.syncRoot(containerRoot: containerRoot)),
            deviceID: "device-low", containerRoot: containerRoot,
            localStoreDidChange: localStoreDidChange)
    }

    func testIngestOfEntryThenAudioAssemblesAndCommits() async throws {
        let when = stamp(0)
        let ex = exchange()

        await ex.acceptRemote(entryRecord(metadata: .defaults, manifestJSON: manifestJSON(at: when), at: when))
        XCTAssertFalse(FileManager.default.fileExists(atPath: captureDirectory.path),
                       "the entry alone must not commit — the m4a has not arrived")

        let audioBytes = Data("m4a-bytes".utf8)
        await ex.acceptRemote(audioRecord(bytes: audioBytes))

        XCTAssertTrue(FileManager.default.fileExists(atPath: captureDirectory.path))
        XCTAssertEqual(try Data(contentsOf: SegmentLayout.finalRecordingURL(captureDirectory: captureDirectory)),
                       audioBytes)
    }

    /// Records can arrive in either order — CKSyncEngine gives no ordering guarantee
    /// across different record types.
    func testIngestOfAudioThenEntryAssemblesAndCommits() async throws {
        let when = stamp(0)
        let ex = exchange()
        let audioBytes = Data("m4a-bytes".utf8)

        await ex.acceptRemote(audioRecord(bytes: audioBytes))
        XCTAssertFalse(FileManager.default.fileExists(atPath: captureDirectory.path),
                       "audio alone must not commit — there is no Entry/manifest yet")

        await ex.acceptRemote(entryRecord(metadata: .defaults, manifestJSON: manifestJSON(at: when), at: when))

        XCTAssertTrue(FileManager.default.fileExists(atPath: captureDirectory.path))
        XCTAssertEqual(try Data(contentsOf: SegmentLayout.finalRecordingURL(captureDirectory: captureDirectory)),
                       audioBytes)
    }

    func testIngestPokesTheLibraryRescanExactlyOnceOnCommit() async throws {
        let when = stamp(0)
        let signals = SignalCounter()
        let ex = exchange(localStoreDidChange: { await signals.increment() })

        await ex.acceptRemote(entryRecord(metadata: .defaults, manifestJSON: manifestJSON(at: when), at: when))
        let countAfterEntryOnly = await signals.count
        XCTAssertEqual(countAfterEntryOnly, 0, "not committed yet — nothing to announce")

        await ex.acceptRemote(audioRecord(bytes: Data("m4a-bytes".utf8)))
        let countAfterCommit = await signals.count
        XCTAssertEqual(countAfterCommit, 1)
    }

    /// The rename path is never taken when the capture already exists locally (brief
    /// pin): an existing directory's content must survive entirely untouched, proving
    /// no rename landed on top of it.
    func testIngestWithCaptureAlreadyExistingLocallyNeverRenamesOverIt() async throws {
        try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
        let sentinel = Data("local-sentinel-content".utf8)
        try sentinel.write(to: SegmentLayout.entryMetadataURL(captureDirectory: captureDirectory))

        let when = stamp(0)
        let ex = exchange()
        await ex.acceptRemote(entryRecord(metadata: .defaults, manifestJSON: manifestJSON(at: when), at: when))
        await ex.acceptRemote(audioRecord(bytes: Data("m4a-bytes".utf8)))

        XCTAssertEqual(
            try Data(contentsOf: SegmentLayout.entryMetadataURL(captureDirectory: captureDirectory)),
            sentinel, "an existing local capture must never be overwritten by the rename path")
    }

    /// With no container root wired (mirrors the pre-T7 "no builder/ingest yet" degrade),
    /// nothing crashes and nothing is written — there is no `captures/` to check at all.
    func testIngestWithNoContainerRootWiredDoesNotCrash() async throws {
        let store = JournalStore(containerRoot: containerRoot)
        let covers = JournalCoverStore(containerRoot: containerRoot, journalStore: store)
        let ex = SyncRecordExchange(
            journalStore: store, coverStore: covers,
            bookkeeping: SyncBookkeepingStore(root: AppContainer.syncRoot(containerRoot: containerRoot)),
            deviceID: "device-low")   // no containerRoot

        let when = stamp(0)
        await ex.acceptRemote(entryRecord(metadata: .defaults, manifestJSON: manifestJSON(at: when), at: when))
        await ex.acceptRemote(audioRecord(bytes: Data("m4a-bytes".utf8)))
        // No assertion beyond "did not crash" — there is nothing to check without a root.
    }
}
