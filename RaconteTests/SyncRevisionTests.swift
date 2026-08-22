import XCTest
import CloudKit
@testable import Raconte

/// M4 T9: revision sync — create-once push, next-free-n ingest, head rebuild (design §2
/// table, §6). Four layers, same split the sibling ingest test files use:
/// `SyncRecordBuilders.revisionRecord` (wire shape, pure, no server), `TranscriptRevisionStore
/// .append`'s sync hook (the push chokepoint) and `.ingestForeignRevision` (the create-once
/// ingest primitive — idempotence, next-free-n, no hook), the two-device fork fixture (THE
/// chain-is-the-conflict-resolution test), then `SyncRecordExchange` orchestration (real
/// `CKRecord`s, real filesystem, no CloudKit server).
final class SyncRevisionTests: XCTestCase {

    private let zoneID = CKRecordZone.ID(zoneName: "RaconteZoneTest", ownerName: CKCurrentUserDefaultName)
    private let captureID = ULID.make()
    private var containerRoot: URL!

    override func setUpWithError() throws {
        containerRoot = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("RaconteSyncRevision-\(UUID().uuidString)", isDirectory: true)
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

    private var transcriptDirectory: URL {
        SegmentLayout.transcriptDirectory(captureDirectory: captureDirectory)
    }

    private var entryRecordID: CKRecord.ID {
        SyncCloudIdentifiers.recordID(.entry(captureID: captureID), zoneID: zoneID)
    }

    private func revision(_ id: String, text: String = "hello", source: RevisionSource = .machineLive,
                          parentID: String? = nil, createdAt: Date? = nil) -> TranscriptRevision {
        TranscriptRevision(id: id, source: source, createdAt: createdAt ?? stamp(0),
                           spans: [TranscriptSpan(text: text, anchor: .none)], parentID: parentID)
    }

    private func makeStore() -> TranscriptRevisionStore { TranscriptRevisionStore(capturesRoot: capturesRoot) }

    @discardableResult
    private func mkCaptureDirectory() throws -> URL {
        try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
        return captureDirectory
    }

    /// Plants (or clears) `entry.json`'s `trashedAt`, straight through the documented
    /// test-only static write seam (`EntryMetadataStore.write(_:url:)`), never through
    /// `update`'s diff-and-log machinery — this test doesn't need an audit trail, just
    /// the sidecar state `guardWritable` reads.
    private func setTrashed(_ trashed: Bool, at date: Date = Date(timeIntervalSince1970: 1_700_000_100)) throws {
        try EntryMetadataStore.write(EntryMetadata(trashedAt: trashed ? date : nil),
                                     url: SegmentLayout.entryMetadataURL(captureDirectory: captureDirectory))
    }

    // MARK: revisionRecord — field coverage

    /// Names every field the design table lists, plus the association addition
    /// (`entryRef` — see `SyncRevisionField`'s doc comment for why this record kind
    /// needs it beyond the ordinary cascade-delete job it shares with `AudioAsset`/
    /// `LiveLog`). A builder that quietly stopped writing one of these would otherwise
    /// pass every other test here, and the field would simply never sync.
    func testRevisionRecordCarriesEveryFieldAndReferencesItsEntryWithDeleteSelf() throws {
        let revisionID = ULID.make()
        let fileURL = containerRoot.appendingPathComponent("canonical-0.json")
        try Data("revision-bytes".utf8).write(to: fileURL)

        let record = SyncRecordBuilders.revisionRecord(revisionID: revisionID, fileURL: fileURL,
                                                        sha256: "deadbeef", bytes: 14,
                                                        entryID: entryRecordID, zoneID: zoneID)

        XCTAssertEqual(record.recordType, "Revision")
        XCTAssertEqual(record.recordID.recordName, "r.\(revisionID)",
                       "the record name is the parseable SyncRecordName, not a bare ULID")
        XCTAssertEqual(record.recordID.zoneID, zoneID)
        XCTAssertEqual((record["body"] as? CKAsset)?.fileURL, fileURL)
        XCTAssertEqual(record["sha256"] as? String, "deadbeef")
        XCTAssertEqual(record["bytes"] as? Int, 14)

        let ref = try XCTUnwrap(record["entryRef"] as? CKRecord.Reference)
        XCTAssertEqual(ref.recordID, entryRecordID)
        XCTAssertEqual(ref.action, .deleteSelf,
                       "the cascade design §5 relies on: purging the Entry must take its revisions with it")
    }

    // MARK: TranscriptRevisionStore.append — the push chokepoint

    /// Push half (brief pin): `append` fires the hook exactly once per minted revision,
    /// naming the revision's own id — never the file number.
    func testAppendFiresTheSyncHookOncePerMintedRevision() async throws {
        try mkCaptureDirectory()
        let hooks = RecordingSyncHooks()
        let store = makeStore()
        await store.attach(syncHooks: hooks)

        let r0 = revision("R0")
        _ = try await store.append(r0, captureID: captureID)
        let r1 = revision("R1", parentID: "R0", createdAt: stamp(10))
        _ = try await store.append(r1, captureID: captureID)

        let names = await hooks.names
        XCTAssertEqual(names, [.revision(id: "R0"), .revision(id: "R1")],
                       "one notification per mint, in mint order")
    }

    /// A nil hook (sync off) behaves exactly as before M4: no crash, nothing to check.
    func testAppendWithNoHookDoesNotCrash() async throws {
        try mkCaptureDirectory()
        _ = try await makeStore().append(revision("R0"), captureID: captureID)
        // No assertion beyond "did not throw" — there is no recorder to read.
    }

    // MARK: TranscriptRevisionStore.ingestForeignRevision — idempotence + next-free-n

    /// File-number independence (brief pin): a local chain at `canonical-0..2` plus a
    /// foreign revision lands at `canonical-3`, bytes verbatim (byte-pin).
    func testIngestForeignRevisionWritesAtNextFreeNWithBytesVerbatim() async throws {
        try mkCaptureDirectory()
        let store = makeStore()
        _ = try await store.append(revision("R0"), captureID: captureID)
        _ = try await store.append(revision("R1", parentID: "R0", createdAt: stamp(10)), captureID: captureID)
        _ = try await store.append(revision("R2", parentID: "R1", createdAt: stamp(20)), captureID: captureID)

        let foreignBytes = try CaptureCoding.encoder().encode(
            revision("FOREIGN", parentID: "R2", createdAt: stamp(30)))
        try await store.ingestForeignRevision(captureID: captureID, revisionID: "FOREIGN", body: foreignBytes)

        let landedURL = SegmentLayout.canonicalTranscriptURL(captureDirectory: captureDirectory, revision: 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: landedURL.path),
                      "the foreign revision must land at the next free slot, n=3")
        XCTAssertEqual(try Data(contentsOf: landedURL), foreignBytes,
                       "bytes must be written verbatim, never re-encoded")
    }

    /// Ingest idempotence (brief pin): the SAME revision delivered twice lands ONE file
    /// — pinned by directory listing COUNT, not merely the absence of a thrown error
    /// (a silent overwrite at the same `n` would also throw nothing).
    func testIngestForeignRevisionOfTheSameIDTwiceLandsExactlyOneFile() async throws {
        try mkCaptureDirectory()
        let store = makeStore()
        let bytes = try CaptureCoding.encoder().encode(revision("DUP"))

        try await store.ingestForeignRevision(captureID: captureID, revisionID: "DUP", body: bytes)
        try await store.ingestForeignRevision(captureID: captureID, revisionID: "DUP", body: bytes)

        let files = try FileManager.default.contentsOfDirectory(atPath: transcriptDirectory.path)
            .filter { SegmentLayout.canonicalRevision(fromFileName: $0) != nil }
        XCTAssertEqual(files.count, 1, "a redelivered revision must land nowhere new")
    }

    /// Never fires the sync hook (brief pin d): an ingest must not echo back as a local
    /// change, or two devices would trade the same revision's arrival forever.
    func testIngestForeignRevisionDoesNotFireTheSyncHook() async throws {
        try mkCaptureDirectory()
        let hooks = RecordingSyncHooks()
        let store = makeStore()
        await store.attach(syncHooks: hooks)

        let bytes = try CaptureCoding.encoder().encode(revision("FOREIGN"))
        try await store.ingestForeignRevision(captureID: captureID, revisionID: "FOREIGN", body: bytes)

        let names = await hooks.names
        XCTAssertEqual(names, [], "ingest must never notify sync of its own write")
    }

    /// Head rebuild (brief pin c): after a foreign ingest, `head.json` reflects the new
    /// revision as `current` through the ordinary `persistHead` machinery — no separate
    /// rebuild path invented for the foreign case.
    func testIngestForeignRevisionRefreshesHeadJSON() async throws {
        try mkCaptureDirectory()
        let store = makeStore()
        _ = try await store.append(revision("R0", source: .machineLive), captureID: captureID)

        let bytes = try CaptureCoding.encoder().encode(
            revision("H0", source: .userEdit, parentID: "R0", createdAt: stamp(10)))
        try await store.ingestForeignRevision(captureID: captureID, revisionID: "H0", body: bytes)

        let head = TranscriptRevisionStore.validatedHead(captureDirectory: captureDirectory)
        XCTAssertEqual(head?.current?.id, "H0", "the ingested human revision must be current")
        XCTAssertEqual(head?.revisionFiles.sorted(), [0, 1])
    }

    /// Mutation check (brief-required, run by hand): forcing `ingestForeignRevision` to
    /// write at a FIXED slot (e.g. always `n=0`, simulating overwrite semantics instead
    /// of next-free-`n`) makes this test fail — the second, DISTINCT revision's bytes
    /// would clobber the first at `canonical-0.json` instead of landing at
    /// `canonical-1.json`, so the directory would hold one file with the wrong content
    /// rather than two. Verified by hand per the brief; reported in the task report,
    /// not left as a second permanent fixture beyond this one.
    func testIngestForeignRevisionOfADistinctSecondRevisionLandsAtANewFileNotOverwritingTheFirst() async throws {
        try mkCaptureDirectory()
        let store = makeStore()
        let firstBytes = try CaptureCoding.encoder().encode(revision("FIRST"))
        let secondBytes = try CaptureCoding.encoder().encode(
            revision("SECOND", parentID: "FIRST", createdAt: stamp(10)))

        try await store.ingestForeignRevision(captureID: captureID, revisionID: "FIRST", body: firstBytes)
        try await store.ingestForeignRevision(captureID: captureID, revisionID: "SECOND", body: secondBytes)

        let file0 = SegmentLayout.canonicalTranscriptURL(captureDirectory: captureDirectory, revision: 0)
        let file1 = SegmentLayout.canonicalTranscriptURL(captureDirectory: captureDirectory, revision: 1)
        XCTAssertEqual(try Data(contentsOf: file0), firstBytes, "the first revision must survive untouched")
        XCTAssertEqual(try Data(contentsOf: file1), secondBytes, "the second must land at its own new slot")
    }

    /// A foreign revision for a capture whose directory does not exist at all refuses
    /// (`.captureMissing`) rather than resurrecting it — the same guard `append`
    /// already applies, inherited via `guardWritable` rather than re-derived.
    func testIngestForeignRevisionRefusesForAMissingCaptureDirectory() async {
        let bytes = try! CaptureCoding.encoder().encode(revision("R0"))
        do {
            try await makeStore().ingestForeignRevision(captureID: captureID, revisionID: "R0", body: bytes)
            XCTFail("must refuse rather than create the capture directory")
        } catch TranscriptRevisionStoreError.captureMissing {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: The chain-is-the-conflict-resolution test (both device-order permutations)

    /// File-number independence + fork convergence (brief pin, cardinality: BOTH
    /// orders): two children of one parent, minted on two different "devices" with
    /// distinct `createdAt` (frozen-clock trap: never equal, or the tiebreak is a coin
    /// flip). Regardless of which child a device minted LOCALLY and which arrived as a
    /// FOREIGN ingest, `current` converges to the same, newer child everywhere.
    func testForkedRevisionsConvergeToTheSameCurrentRegardlessOfIngestOrder() async throws {
        let parent = revision("PARENT", source: .machineLive, createdAt: stamp(0))
        let childOlder = revision("CHILD-OLDER", source: .userEdit, parentID: "PARENT", createdAt: stamp(10))
        let childNewer = revision("CHILD-NEWER", source: .userEdit, parentID: "PARENT", createdAt: stamp(20))
        let parentBytes = try CaptureCoding.encoder().encode(parent)
        let childOlderBytes = try CaptureCoding.encoder().encode(childOlder)
        let childNewerBytes = try CaptureCoding.encoder().encode(childNewer)

        // Device A: mints parent + the OLDER child locally, ingests the NEWER child as foreign.
        let deviceARoot = containerRoot.appendingPathComponent("deviceA", isDirectory: true)
        let deviceACapturesRoot = AppContainer.capturesRoot(containerRoot: deviceARoot)
        let deviceACaptureDirectory = SegmentLayout.captureDirectory(capturesRoot: deviceACapturesRoot,
                                                                      captureID: captureID)
        try FileManager.default.createDirectory(at: deviceACaptureDirectory, withIntermediateDirectories: true)
        let storeA = TranscriptRevisionStore(capturesRoot: deviceACapturesRoot)
        _ = try await storeA.append(parent, captureID: captureID)
        _ = try await storeA.append(childOlder, captureID: captureID)
        try await storeA.ingestForeignRevision(captureID: captureID, revisionID: "CHILD-NEWER",
                                               body: childNewerBytes)

        // Device B: mints parent + the NEWER child locally, ingests the OLDER child as
        // foreign — the reverse order.
        let deviceBRoot = containerRoot.appendingPathComponent("deviceB", isDirectory: true)
        let deviceBCapturesRoot = AppContainer.capturesRoot(containerRoot: deviceBRoot)
        let deviceBCaptureDirectory = SegmentLayout.captureDirectory(capturesRoot: deviceBCapturesRoot,
                                                                      captureID: captureID)
        try FileManager.default.createDirectory(at: deviceBCaptureDirectory, withIntermediateDirectories: true)
        let storeB = TranscriptRevisionStore(capturesRoot: deviceBCapturesRoot)
        _ = try await storeB.append(parent, captureID: captureID)
        _ = try await storeB.append(childNewer, captureID: captureID)
        try await storeB.ingestForeignRevision(captureID: captureID, revisionID: "CHILD-OLDER",
                                               body: childOlderBytes)

        // Sanity: the bytes each device holds for the shared parent are byte-identical
        // (verifying "verbatim" actually round-trips the same value both ways).
        XCTAssertEqual(
            try Data(contentsOf: SegmentLayout.canonicalTranscriptURL(
                captureDirectory: deviceACaptureDirectory, revision: 0)),
            parentBytes)

        let chainA = TranscriptRevisionStore.loadChain(captureDirectory: deviceACaptureDirectory)!
        let chainB = TranscriptRevisionStore.loadChain(captureDirectory: deviceBCaptureDirectory)!
        let currentA = TranscriptChain.current(TranscriptChain.ordered(chainA.revisions))
        let currentB = TranscriptChain.current(TranscriptChain.ordered(chainB.revisions))

        XCTAssertEqual(currentA?.id, "CHILD-NEWER", "the newer human revision must win on device A")
        XCTAssertEqual(currentB?.id, "CHILD-NEWER",
                       "and converge to the SAME answer on device B despite the reversed arrival order")
        XCTAssertEqual(chainA.revisions.count, 3)
        XCTAssertEqual(chainB.revisions.count, 3)
    }

    // MARK: SyncRecordExchange orchestration — push + ingest, through real CKRecords

    private func exchange(transcriptRevisionStore: TranscriptRevisionStore? = nil,
                          localStoreDidChange: (@Sendable () async -> Void)? = nil) -> SyncRecordExchange {
        let journalStore = JournalStore(containerRoot: containerRoot)
        let covers = JournalCoverStore(containerRoot: containerRoot, journalStore: journalStore)
        return SyncRecordExchange(
            journalStore: journalStore, coverStore: covers,
            bookkeeping: SyncBookkeepingStore(root: AppContainer.syncRoot(containerRoot: containerRoot)),
            deviceID: "device-low", containerRoot: containerRoot,
            transcriptRevisionStore: transcriptRevisionStore,
            localStoreDidChange: localStoreDidChange)
    }

    /// Push, end to end through the orchestrator: a locally-minted revision's
    /// `recordToPush` answer carries the exact file bytes as its `body` asset.
    func testRecordToPushBuildsARevisionRecordWithBodyBytesVerbatim() async throws {
        try mkCaptureDirectory()
        let store = makeStore()
        let minted = revision("R0")
        _ = try await store.append(minted, captureID: captureID)

        let ex = exchange(transcriptRevisionStore: store)
        let record = await ex.recordToPush(for: .revision(id: "R0"), zoneID: zoneID)

        let record0 = try XCTUnwrap(record)
        XCTAssertEqual(record0.recordType, "Revision")
        let asset = try XCTUnwrap(record0["body"] as? CKAsset)
        let assetBytes = try Data(contentsOf: XCTUnwrap(asset.fileURL))
        XCTAssertEqual(assetBytes, try CaptureCoding.encoder().encode(minted))
        let ref = try XCTUnwrap(record0["entryRef"] as? CKRecord.Reference)
        XCTAssertEqual(ref.recordID, entryRecordID)
    }

    /// `recordToPush` for a revision id this device does not have (e.g. purged) drops
    /// the change rather than crashing.
    func testRecordToPushForAnUnknownRevisionIDReturnsNil() async throws {
        let ex = exchange()
        let record = await ex.recordToPush(for: .revision(id: "GHOST"), zoneID: zoneID)
        XCTAssertNil(record)
    }

    private func revisionRecord(id: String, revision: TranscriptRevision) throws -> CKRecord {
        let bytes = try CaptureCoding.encoder().encode(revision)
        let fileURL = containerRoot.appendingPathComponent("wire-\(UUID().uuidString)-\(id).json")
        try bytes.write(to: fileURL)
        return SyncRecordBuilders.revisionRecord(revisionID: id, fileURL: fileURL,
                                                 sha256: SyncTreeScanner.sha256Hex(bytes), bytes: bytes.count,
                                                 entryID: entryRecordID, zoneID: zoneID)
    }

    /// Ingest into an ALREADY-LOCAL capture: writes through
    /// `TranscriptRevisionStore.ingestForeignRevision`, at next-free-`n`, and pokes the
    /// library rescan.
    func testAcceptRemoteOfARevisionForAnExistingCaptureIngestsAtNextFreeN() async throws {
        try mkCaptureDirectory()
        let store = makeStore()
        _ = try await store.append(revision("R0"), captureID: captureID)

        let signals = SignalCounter()
        let ex = exchange(transcriptRevisionStore: store, localStoreDidChange: { await signals.increment() })
        // A well-formed ULID (brief pin, and required here for a different reason than
        // usual): `SyncRecordName.revision(id:)`'s parser rejects a non-ULID id, so
        // `acceptRemote` — unlike a direct `ingestForeignRevision` call — would
        // silently drop a human-readable placeholder like "R1" before it ever reached
        // the store.
        let incomingID = ULID.make()
        let incoming = revision(incomingID, source: .userEdit, parentID: "R0", createdAt: stamp(10))
        await ex.acceptRemote(try revisionRecord(id: incomingID, revision: incoming))

        let landedURL = SegmentLayout.canonicalTranscriptURL(captureDirectory: captureDirectory, revision: 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: landedURL.path))
        let count = await signals.count
        XCTAssertEqual(count, 1)
    }

    /// Unknown-capture parking (brief pin): a foreign revision for a captureID this
    /// device has not committed yet parks durably rather than erroring, then applies
    /// once the Entry/Audio pair arrives and the capture actually commits — ordering
    /// between fetched record types is not guaranteed (design §6).
    func testAcceptRemoteOfARevisionForAnUnknownCaptureParksThenAppliesAfterTheEntryCommits() async throws {
        let when = stamp(0)
        let store = makeStore()
        let signals = SignalCounter()
        let ex = exchange(transcriptRevisionStore: store, localStoreDidChange: { await signals.increment() })

        // Well-formed ULID: see the note on the sibling "existing capture" test above —
        // `acceptRemote` parses the record name through `SyncRecordName.revision(id:)`.
        let parkedID = ULID.make()
        let parked = revision(parkedID, source: .machineLive, createdAt: when)
        await ex.acceptRemote(try revisionRecord(id: parkedID, revision: parked))

        XCTAssertFalse(FileManager.default.fileExists(atPath: captureDirectory.path),
                       "a revision alone must never create the capture directory")
        var count = await signals.count
        XCTAssertEqual(count, 0, "nothing committed yet — nothing to announce")

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
                                                       deviceID: "device-high", zoneID: zoneID)
        await ex.acceptRemote(entryRec)

        let audioBytes = Data("m4a-bytes".utf8)
        let audioURL = containerRoot.appendingPathComponent("audio.m4a")
        try audioBytes.write(to: audioURL)
        let audioRec = SyncRecordBuilders.audioRecord(captureID: captureID, m4aURL: audioURL,
                                                       sha256: SyncTreeScanner.sha256Hex(audioBytes),
                                                       bytes: audioBytes.count, frameCount: 480_000,
                                                       sampleRate: 48_000, entryID: entryRecordID, zoneID: zoneID)
        await ex.acceptRemote(audioRec)

        XCTAssertTrue(FileManager.default.fileExists(atPath: captureDirectory.path),
                      "the commit set is now complete")
        let landedURL = SegmentLayout.canonicalTranscriptURL(captureDirectory: captureDirectory, revision: 0)
        XCTAssertEqual(try Data(contentsOf: landedURL), try CaptureCoding.encoder().encode(parked),
                       "the parked revision must apply once the capture exists, bytes verbatim")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: captureDirectory.appendingPathComponent("pending-revisions.json").path),
            "the internal staging artifact must not linger inside a committed capture directory")
        count = await signals.count
        XCTAssertEqual(count, 1, "exactly one announcement, once the commit (with its parked revision) lands")
    }

    /// A redelivered park (e.g. after a change-token reset re-fetches the same record)
    /// must not accumulate duplicate parked entries.
    func testParkingTheSameRevisionTwiceForAnUnknownCaptureStillLandsOnlyOneFileAfterCommit() async throws {
        let when = stamp(0)
        let store = makeStore()
        let ex = exchange(transcriptRevisionStore: store)

        let parkedID = ULID.make()
        let parked = revision(parkedID, source: .machineLive, createdAt: when)
        let record = try revisionRecord(id: parkedID, revision: parked)
        await ex.acceptRemote(record)
        await ex.acceptRemote(record)

        let manifest = Manifest(captureID: captureID, createdAt: when, state: .complete, stateSeq: 1,
                                stateUpdatedAt: when,
                                format: AudioFormatDescriptor(sampleRate: 48_000, channels: 1,
                                                              commonFormat: .pcmFormatFloat32,
                                                              interleaved: false, bytesPerFrame: 4),
                                final: FinalRef(verifiedAt: when, durationFrames: 480_000))
        let manifestJSON = try CaptureCoding.encoder().encode(manifest)
        await ex.acceptRemote(SyncRecordBuilders.entryRecord(captureID: captureID, metadata: .defaults,
                                                              manifestJSON: manifestJSON, capturedAt: when,
                                                              deviceID: "device-high", zoneID: zoneID))
        let audioBytes = Data("m4a-bytes".utf8)
        let audioURL = containerRoot.appendingPathComponent("audio.m4a")
        try audioBytes.write(to: audioURL)
        await ex.acceptRemote(SyncRecordBuilders.audioRecord(
            captureID: captureID, m4aURL: audioURL, sha256: SyncTreeScanner.sha256Hex(audioBytes),
            bytes: audioBytes.count, frameCount: 480_000, sampleRate: 48_000,
            entryID: entryRecordID, zoneID: zoneID))

        let files = try FileManager.default.contentsOfDirectory(
            atPath: SegmentLayout.transcriptDirectory(captureDirectory: captureDirectory).path)
            .filter { SegmentLayout.canonicalRevision(fromFileName: $0) != nil }
        XCTAssertEqual(files.count, 1, "a redelivered park must not duplicate the committed revision")
    }

    /// With no `transcriptRevisionStore` wired (mirrors the pre-T9 degrade), an ingest
    /// for an EXISTING capture does not crash and writes nothing.
    func testIngestWithNoTranscriptRevisionStoreWiredDoesNotCrash() async throws {
        try mkCaptureDirectory()
        let ex = exchange()   // no transcriptRevisionStore
        let incomingID = ULID.make()
        let incoming = revision(incomingID)
        await ex.acceptRemote(try revisionRecord(id: incomingID, revision: incoming))
        // No assertion beyond "did not crash" — there is no store to check.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SegmentLayout.canonicalTranscriptURL(captureDirectory: captureDirectory, revision: 0).path))
    }

    /// A sha256-mismatched revision is refused at arrival and never persisted anywhere
    /// — same discipline as `ingestAudio`/`ingestLiveLog`.
    func testAcceptRemoteOfARevisionWithAMismatchedSHA256IsRefused() async throws {
        try mkCaptureDirectory()
        let store = makeStore()
        let ex = exchange(transcriptRevisionStore: store)

        let badID = ULID.make()
        let bytes = try CaptureCoding.encoder().encode(revision(badID))
        let fileURL = containerRoot.appendingPathComponent("bad.json")
        try bytes.write(to: fileURL)
        let badRecord = SyncRecordBuilders.revisionRecord(revisionID: badID, fileURL: fileURL,
                                                           sha256: "not-the-real-hash", bytes: bytes.count,
                                                           entryID: entryRecordID, zoneID: zoneID)
        await ex.acceptRemote(badRecord)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SegmentLayout.canonicalTranscriptURL(captureDirectory: captureDirectory, revision: 0).path),
            "the mismatched bytes must never be persisted")
    }

    // MARK: Fix round — a revision for a TRASHED (not purged) capture parks, not vanishes

    /// (a) The gate finding, pinned directly: a revision fetched for a capture that is
    /// currently soft-trashed must be parked, never discarded — CKSyncEngine will never
    /// redeliver a record it has already handed over.
    func testAcceptRemoteOfARevisionForATrashedCaptureParksRatherThanVanishing() async throws {
        try mkCaptureDirectory()
        try setTrashed(true)
        let store = makeStore()
        let ex = exchange(transcriptRevisionStore: store)

        let revisionID = ULID.make()
        let incoming = revision(revisionID, source: .userEdit, createdAt: stamp(10))
        await ex.acceptRemote(try revisionRecord(id: revisionID, revision: incoming))

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SegmentLayout.canonicalTranscriptURL(captureDirectory: captureDirectory, revision: 0).path),
            "nothing must land in transcript/ while the capture is trashed")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: AppContainer.syncStagingPendingRevisionsURL(
                containerRoot: containerRoot, captureID: captureID).path),
            "the revision must be parked, not discarded")
    }

    /// (b) THE headline recovery pin: restore the capture (flip the sidecar), then
    /// rehydrate against a brand-new, cold `SyncRecordExchange`/`TranscriptRevisionStore`
    /// pair over the SAME container root — the identical "simulated relaunch" idiom
    /// `SyncEntryIngestTests.testPiecesSplitAcrossASimulatedRelaunchStillCommit` uses —
    /// and the parked revision lands, bytes verbatim.
    ///
    /// Mutation check (ruled, run by hand — see the fix report): reverting the
    /// `.trashedCapture` catch in `SyncRecordExchange.ingestRevision` back to the
    /// pre-fix "log and discard" behavior makes this test fail — the revision is gone
    /// before it is ever parked, so rehydration has nothing to find and the assertion
    /// below fails with "file does not exist" rather than a content mismatch.
    func testARevisionParkedForATrashedCaptureLandsAfterRestoreAndRehydration() async throws {
        try mkCaptureDirectory()
        try setTrashed(true)
        let store = makeStore()
        let ex = exchange(transcriptRevisionStore: store)

        let revisionID = ULID.make()
        let incoming = revision(revisionID, source: .userEdit, createdAt: stamp(10))
        await ex.acceptRemote(try revisionRecord(id: revisionID, revision: incoming))

        // An ordinary restore-from-trash within the 30-day window — a local edit, no
        // CloudKit round trip needed for it to take effect here.
        try setTrashed(false)

        // Cold rebuild: neither the store nor the exchange carries any in-memory state
        // from the first pass — everything the recovery reads comes off disk.
        let coldStore = makeStore()
        let coldExchange = exchange(transcriptRevisionStore: coldStore)
        await coldExchange.rehydrateParkedRevisions()

        let landedURL = SegmentLayout.canonicalTranscriptURL(captureDirectory: captureDirectory, revision: 0)
        XCTAssertEqual(try Data(contentsOf: landedURL), try CaptureCoding.encoder().encode(incoming),
                       "the parked revision must land, bytes verbatim, once restored")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: AppContainer.syncStagingPendingRevisionsURL(
                containerRoot: containerRoot, captureID: captureID).path),
            "the parking must clear once applied")
    }

    /// (c) The other side of the same coin: a parked revision for a capture that gets
    /// PURGED (not merely trashed) while parked is correctly discarded on the next
    /// rehydration — design §5's actual delete-wins rule, applied without error and
    /// without ever resurrecting the purged directory.
    func testAParkedRevisionForAPurgedCaptureIsDiscardedOnRehydrationWithoutError() async throws {
        try mkCaptureDirectory()
        try setTrashed(true)
        let store = makeStore()
        let ex = exchange(transcriptRevisionStore: store)

        let revisionID = ULID.make()
        let incoming = revision(revisionID, source: .userEdit, createdAt: stamp(10))
        await ex.acceptRemote(try revisionRecord(id: revisionID, revision: incoming))

        // Purge: this test only needs the end state a real 30-day sweep or Delete Now
        // leaves behind (the capture directory gone), not `StagedRemover`'s own
        // staged-rename machinery.
        try FileManager.default.removeItem(at: captureDirectory)

        await ex.rehydrateParkedRevisions()

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: AppContainer.syncStagingPendingRevisionsURL(
                containerRoot: containerRoot, captureID: captureID).path),
            "the parking must be discarded once the capture is gone")
        XCTAssertFalse(FileManager.default.fileExists(atPath: captureDirectory.path),
                       "rehydration must never resurrect a purged capture")
    }

    /// Regression guard for the disambiguation `ParkedRevisions.knownToHaveExisted`
    /// exists to make possible: an ordinary in-flight "unknown capture" park (case A —
    /// a revision arrived before its capture's Entry/Audio ever did) must NEVER be
    /// discarded by rehydration just because the capture directory happens to be
    /// absent right now — that state is not "purged", it is "not created yet", and the
    /// ordinary assembly-attempt path is what owns it.
    func testRehydrationLeavesAnInFlightUnknownCaptureParkUntouched() async throws {
        let store = makeStore()
        let ex = exchange(transcriptRevisionStore: store)
        let revisionID = ULID.make()
        let incoming = revision(revisionID, source: .machineLive, createdAt: stamp(0))
        await ex.acceptRemote(try revisionRecord(id: revisionID, revision: incoming))

        let parkURL = AppContainer.syncStagingPendingRevisionsURL(containerRoot: containerRoot,
                                                                   captureID: captureID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: parkURL.path), "sanity: it parked")

        await ex.rehydrateParkedRevisions()

        XCTAssertTrue(FileManager.default.fileExists(atPath: parkURL.path),
                      "an in-flight unknown-capture park must never be discarded by rehydration — "
                      + "the ordinary assembly-attempt path owns it")
        XCTAssertFalse(FileManager.default.fileExists(atPath: captureDirectory.path))
    }

    /// The symmetric edge case the fix round also closed: a brand-new capture can
    /// itself arrive ALREADY trashed (the remote Entry record's own `trashedAt` was set
    /// before this device ever saw it) — so a revision parked while the capture was
    /// still unknown must not be lost at the moment of commit either. It re-parks
    /// (`ingestParkedRevisions`'s own leftover handling) and is picked up by the same
    /// rehydration path once restored.
    func testARevisionParkedForAnUnknownCaptureThatCommitsAlreadyTrashedReParksRatherThanBeingLost() async throws {
        let when = stamp(0)
        let store = makeStore()
        let ex = exchange(transcriptRevisionStore: store)

        let revisionID = ULID.make()
        let parked = revision(revisionID, source: .machineLive, createdAt: when)
        await ex.acceptRemote(try revisionRecord(id: revisionID, revision: parked))

        let manifest = Manifest(captureID: captureID, createdAt: when, state: .complete, stateSeq: 1,
                                stateUpdatedAt: when,
                                format: AudioFormatDescriptor(sampleRate: 48_000, channels: 1,
                                                              commonFormat: .pcmFormatFloat32,
                                                              interleaved: false, bytesPerFrame: 4),
                                final: FinalRef(verifiedAt: when, durationFrames: 480_000))
        let manifestJSON = try CaptureCoding.encoder().encode(manifest)
        let trashedMetadata = EntryMetadata(trashedAt: stamp(5))
        await ex.acceptRemote(SyncRecordBuilders.entryRecord(captureID: captureID, metadata: trashedMetadata,
                                                              manifestJSON: manifestJSON, capturedAt: when,
                                                              deviceID: "device-high", zoneID: zoneID))
        let audioBytes = Data("m4a-bytes".utf8)
        let audioURL = containerRoot.appendingPathComponent("audio.m4a")
        try audioBytes.write(to: audioURL)
        await ex.acceptRemote(SyncRecordBuilders.audioRecord(
            captureID: captureID, m4aURL: audioURL, sha256: SyncTreeScanner.sha256Hex(audioBytes),
            bytes: audioBytes.count, frameCount: 480_000, sampleRate: 48_000,
            entryID: entryRecordID, zoneID: zoneID))

        XCTAssertTrue(FileManager.default.fileExists(atPath: captureDirectory.path), "the capture committed")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SegmentLayout.canonicalTranscriptURL(captureDirectory: captureDirectory, revision: 0).path),
            "the revision must not land while the just-committed capture is already trashed")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: AppContainer.syncStagingPendingRevisionsURL(
                containerRoot: containerRoot, captureID: captureID).path),
            "it must be re-parked, not lost")

        try setTrashed(false)
        await ex.rehydrateParkedRevisions()

        XCTAssertEqual(
            try Data(contentsOf: SegmentLayout.canonicalTranscriptURL(
                captureDirectory: captureDirectory, revision: 0)),
            try CaptureCoding.encoder().encode(parked))
    }
}
