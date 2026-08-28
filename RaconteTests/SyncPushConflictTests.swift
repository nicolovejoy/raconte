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
}
