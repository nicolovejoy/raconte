import XCTest
import CloudKit
@testable import Raconte

/// Build-10 fix (docs/2026-08-26-sync-investigation-state.md RESOLVED section): the
/// `serverRecordChanged` short-circuit for write-once records. Two layers, same split
/// the sibling sync test files use: `localWriteOnceDigest` (this task — the local
/// half of the comparison), then `resolvePushConflicts` end to end (Task 3).
final class SyncPushConflictTests: XCTestCase {

    private let zoneID = CKRecordZone.ID(zoneName: "RaconteZoneTest", ownerName: CKCurrentUserDefaultName)
    private let captureID = ULID.make()
    private var containerRoot: URL!

    override func setUpWithError() throws {
        containerRoot = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("RacontePushConflict-\(UUID().uuidString)", isDirectory: true)
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

    private func makeBookkeeping() -> SyncBookkeepingStore {
        SyncBookkeepingStore(root: AppContainer.syncRoot(containerRoot: containerRoot))
    }

    private func exchange(transcriptRevisionStore: TranscriptRevisionStore? = nil,
                          bookkeeping: SyncBookkeepingStore? = nil) -> SyncRecordExchange {
        let journalStore = JournalStore(containerRoot: containerRoot)
        let covers = JournalCoverStore(containerRoot: containerRoot, journalStore: journalStore)
        return SyncRecordExchange(
            journalStore: journalStore, coverStore: covers,
            bookkeeping: bookkeeping ?? makeBookkeeping(),
            deviceID: "device-test", containerRoot: containerRoot,
            entryMetadataStore: nil,
            transcriptRevisionStore: transcriptRevisionStore,
            localStoreDidChange: nil)
    }

    /// Verified-manifest + on-disk final m4a fixture — the file state every
    /// write-once push presumes.
    private func writeFinalizedCapture(m4aBytes: Data) throws {
        try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: SegmentLayout.finalDirectory(captureDirectory: captureDirectory),
                                                 withIntermediateDirectories: true)
        let when = stamp(0)
        let manifest = Manifest(captureID: captureID, createdAt: when, state: .complete, stateSeq: 1,
                                stateUpdatedAt: when,
                                format: AudioFormatDescriptor(sampleRate: 48_000, channels: 1,
                                                              commonFormat: .pcmFormatFloat32,
                                                              interleaved: false, bytesPerFrame: 4),
                                final: FinalRef(verifiedAt: when, durationFrames: 480_000))
        try CaptureCoding.encoder().encode(manifest)
            .write(to: SegmentLayout.manifestURL(captureDirectory: captureDirectory))
        try m4aBytes.write(to: SegmentLayout.finalRecordingURL(captureDirectory: captureDirectory))
    }

    // MARK: localWriteOnceDigest

    func testAudioDigestHashesTheFinalM4A() async throws {
        let bytes = Data("final-m4a-bytes".utf8)
        try writeFinalizedCapture(m4aBytes: bytes)
        let digest = await exchange().localWriteOnceDigest(for: .audio(captureID: captureID))
        XCTAssertEqual(digest, SyncTreeScanner.rawDigest(bytes))
    }

    func testRevisionDigestHashesTheCanonicalFile() async throws {
        try writeFinalizedCapture(m4aBytes: Data("m4a".utf8))
        let store = TranscriptRevisionStore(capturesRoot: capturesRoot)
        let minted = TranscriptRevision(id: "R0", source: .machineLive, createdAt: stamp(0),
                                        spans: [TranscriptSpan(text: "hello", anchor: .none)],
                                        parentID: nil)
        _ = try await store.append(minted, captureID: captureID)
        let digest = await exchange(transcriptRevisionStore: store)
            .localWriteOnceDigest(for: .revision(id: "R0"))
        let expected = SyncTreeScanner.rawDigest(try CaptureCoding.encoder().encode(minted))
        XCTAssertEqual(digest, expected)
    }

    func testMissingArtifactAnswersNil() async throws {
        let digest = await exchange().localWriteOnceDigest(for: .audio(captureID: captureID))
        XCTAssertNil(digest, "no capture directory at all — nothing to hash, never a crash")
    }

    func testMutableNameAnswersNil() async throws {
        let digest = await exchange().localWriteOnceDigest(for: .journal(id: "J"))
        XCTAssertNil(digest, "mutable types have no single-artifact digest; refuse rather than invent one")
    }

    // MARK: resolvePushConflicts — the short-circuit end to end

    /// A conflict server copy is exactly what CloudKit hands back on a rejected push:
    /// same sha256 FIELD, but its asset never downloaded. Strip the asset to match.
    ///
    /// `revisionID` must be a well-formed ULID, not the brief snippet's human-readable
    /// "R0": `resolvePushConflicts` reaches this record only through
    /// `SyncCloudIdentifiers.name(of:)`, which round-trips the recordName through
    /// `SyncRecordName.init(rawValue:)` — same well-formed-ULID requirement documented
    /// at `SyncRevisionTests.swift`'s "existing capture" test. "R0" parses to nil and
    /// the record is silently skipped before the gate ever runs.
    private func serverRevisionCopy(revisionID: String, sha256: String, bodyURL: URL) -> CKRecord {
        let entryID = SyncCloudIdentifiers.recordID(.entry(captureID: captureID), zoneID: zoneID)
        let record = SyncRecordBuilders.revisionRecord(revisionID: revisionID, fileURL: bodyURL,
                                                       sha256: sha256, bytes: 1,
                                                       entryID: entryID, zoneID: zoneID)
        record[SyncRevisionField.body] = nil   // push-error serverRecord has no asset
        return record
    }

    func testByteIdenticalServerCopySettlesWritesLedgerAndArchivesTag() async throws {
        try writeFinalizedCapture(m4aBytes: Data("m4a".utf8))
        let store = TranscriptRevisionStore(capturesRoot: capturesRoot)
        let revisionID = ULID.make()
        let minted = TranscriptRevision(id: revisionID, source: .machineLive, createdAt: stamp(0),
                                        spans: [TranscriptSpan(text: "hello", anchor: .none)],
                                        parentID: nil)
        _ = try await store.append(minted, captureID: captureID)
        let localSHA = SyncTreeScanner.rawDigest(try CaptureCoding.encoder().encode(minted)).sha256
        let bookkeeping = makeBookkeeping()
        let ex = exchange(transcriptRevisionStore: store, bookkeeping: bookkeeping)

        let bodyURL = FileManager.default.temporaryDirectory.appendingPathComponent("stub-body")
        try Data("x".utf8).write(to: bodyURL)
        let resolution = await ex.resolvePushConflicts([serverRevisionCopy(revisionID: revisionID,
                                                                           sha256: localSHA,
                                                                           bodyURL: bodyURL)])

        XCTAssertEqual(resolution.settled, [.revision(id: revisionID)])
        XCTAssertTrue(resolution.resend.isEmpty, "a settled record must not be re-enqueued")
        let name = SyncRecordName.revision(id: revisionID).rawValue
        let ledgerSHA = await bookkeeping.ledger()[name]?.sha256
        XCTAssertEqual(ledgerSHA, localSHA,
                       "the ledger credit is what stops reconcile re-enqueueing it forever")
        let archivedSystemFields = await bookkeeping.systemFields(for: name)
        XCTAssertNotNil(archivedSystemFields,
                        "the server change tag must be archived for any future legitimate update")
    }

    func testDivergentServerCopyIsSettledWithoutALedgerEntry() async throws {
        try writeFinalizedCapture(m4aBytes: Data("m4a".utf8))
        let store = TranscriptRevisionStore(capturesRoot: capturesRoot)
        let revisionID = ULID.make()
        let minted = TranscriptRevision(id: revisionID, source: .machineLive, createdAt: stamp(0),
                                        spans: [TranscriptSpan(text: "hello", anchor: .none)],
                                        parentID: nil)
        _ = try await store.append(minted, captureID: captureID)
        let bookkeeping = makeBookkeeping()
        let ex = exchange(transcriptRevisionStore: store, bookkeeping: bookkeeping)

        let bodyURL = FileManager.default.temporaryDirectory.appendingPathComponent("stub-body-2")
        try Data("x".utf8).write(to: bodyURL)
        let resolution = await ex.resolvePushConflicts([serverRevisionCopy(revisionID: revisionID,
                                                                           sha256: "not-the-local-sha",
                                                                           bodyURL: bodyURL)])

        XCTAssertEqual(resolution.settled, [.revision(id: revisionID)],
                       "divergence retires the pending save too — loud once per launch, never a hot loop")
        XCTAssertTrue(resolution.resend.isEmpty)
        let ledgerEntry = await bookkeeping.ledger()[SyncRecordName.revision(id: revisionID).rawValue]
        XCTAssertNil(ledgerEntry,
                     "no ledger credit — reconcile must keep resurfacing a divergent record")
    }

    func testMutableTypeStillResends() async throws {
        // Same well-formed-ULID requirement as `serverRevisionCopy` above — the brief
        // snippet's "J-1" would parse to nil and vanish before the mutable branch ever ran.
        let journalID = ULID.make()
        let journal = Journal(id: journalID, name: "Server name", createdAt: stamp(0),
                              voiceLabels: [:], modified: ["name": stamp(10)])
        let record = SyncRecordBuilders.journalRecord(journal: journal, coverFileURL: nil,
                                                      deviceID: "device-other", zoneID: zoneID)
        let resolution = await exchange().resolvePushConflicts([record])
        XCTAssertEqual(resolution.resend, [.journal(id: journalID)],
                       "mutable types keep the merge-then-resend path verbatim")
        XCTAssertTrue(resolution.settled.isEmpty)
    }
}
