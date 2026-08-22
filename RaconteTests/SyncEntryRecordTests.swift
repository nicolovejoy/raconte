import XCTest
import CloudKit
@testable import Raconte

/// M4 T6: the Entry/AudioAsset/LiveLog records' wire shape (design §2), and the
/// finalize-completion choke point that decides whether/what to push for one capture.
///
/// **No server, no account, no `CKSyncEngine`** — same discipline as
/// `SyncJournalRecordTests` (T5): `CKRecord`/`CKRecord.ID`/`CKAsset`/`CKRecord.Reference`
/// are all constructible offline, and `FinalizeArtifactPush`'s eligibility decision reads
/// nothing but a manifest and a file-existence check, so every assertion here runs with
/// zero CloudKit traffic.
final class SyncEntryRecordTests: XCTestCase {

    private let zoneID = CKRecordZone.ID(zoneName: "RaconteZoneTest", ownerName: CKCurrentUserDefaultName)
    private let captureID = ULID.make()
    private let journalID = ULID.make()
    private var containerRoot: URL!

    override func setUpWithError() throws {
        containerRoot = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("RaconteSyncEntryRecord-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: containerRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: containerRoot)
    }

    /// Dates that survive `CaptureCoding`'s ISO8601-with-milliseconds encoding exactly —
    /// mirrors `SyncJournalRecordTests.stamp(_:)`.
    private func stamp(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(offset)
    }

    private var entryRecordID: CKRecord.ID {
        SyncCloudIdentifiers.recordID(.entry(captureID: captureID), zoneID: zoneID)
    }

    // MARK: entryRecord — field coverage

    /// Names every field the design table lists, plus `modified`. A builder that quietly
    /// stopped writing one of them would otherwise pass every other test in this file,
    /// and the field would simply never sync — the same rationale
    /// `SyncJournalRecordTests.testJournalRecordCarriesEveryFieldInTheDesignTable` states.
    ///
    /// Mutation check (brief-required, run by hand): commenting out the `trashedAt` line
    /// in `SyncRecordBuilders.entryRecord` and re-running this test fails it —
    /// `record["trashedAt"] as? Date` becomes nil against the asserted `stamp(30)` — so
    /// the assertion is load-bearing, not decorative. Reported in the task report, not
    /// left as a permanent second test (the brief calls this a check, not a fixture).
    func testEntryRecordCarriesEveryFieldInTheDesignTable() throws {
        let metadata = EntryMetadata(
            journalID: journalID,
            originalDate: try PartialDate(parsing: "1998-03-04"),
            trashedAt: stamp(30),
            detectedDate: try PartialDate(parsing: "1998-03"),
            detectionRan: true,
            multiVoice: true,
            modified: ["journalID": stamp(10), "trashedAt": stamp(30)])
        let manifestJSON = Data(#"{"captureID":"\#(captureID)"}"#.utf8)

        let record = SyncRecordBuilders.entryRecord(captureID: captureID, metadata: metadata,
                                                     manifestJSON: manifestJSON, capturedAt: stamp(0),
                                                     deviceID: "device-low", zoneID: zoneID)

        XCTAssertEqual(record.recordType, "Entry")
        XCTAssertEqual(record.recordID.recordName, "e.\(captureID)",
                       "the record name is the parseable SyncRecordName, not a bare captureID")
        XCTAssertEqual(record.recordID.zoneID, zoneID)
        XCTAssertEqual(record["journalID"] as? String, journalID)
        XCTAssertEqual(record["originalDate"] as? String, "1998-03-04")
        XCTAssertEqual(record["trashedAt"] as? Date, stamp(30))
        XCTAssertEqual(record["multiVoice"] as? Bool, true)
        XCTAssertEqual(record["detectedDate"] as? String, "1998-03")
        XCTAssertEqual(record["detectionRan"] as? Bool, true)
        XCTAssertEqual(record["manifestSnapshot"] as? String, String(data: manifestJSON, encoding: .utf8))
        XCTAssertEqual(record["capturedAt"] as? Date, stamp(0))
        XCTAssertEqual(record["deviceID"] as? String, "device-low")

        let stamps: [String: Date] = SyncRecordBuilders.decodeJSON(record["modified"] as? String)
        XCTAssertEqual(stamps, ["journalID": stamp(10), "trashedAt": stamp(30)])
    }

    /// An entry nobody has ever edited still builds a complete, valid record: optional
    /// fields read `nil`, the two Bools read `false`, and `modified` reads `"{}"` rather
    /// than the record being unbuildable or missing keys entirely.
    func testUntouchedEntryStillBuildsAValidRecord() {
        let record = SyncRecordBuilders.entryRecord(captureID: captureID, metadata: .defaults,
                                                     manifestJSON: Data("{}".utf8), capturedAt: stamp(0),
                                                     deviceID: "device-low", zoneID: zoneID)

        XCTAssertEqual(record.recordType, "Entry")
        XCTAssertNil(record["journalID"])
        XCTAssertNil(record["originalDate"])
        XCTAssertNil(record["trashedAt"])
        XCTAssertEqual(record["multiVoice"] as? Bool, false)
        XCTAssertNil(record["detectedDate"])
        XCTAssertEqual(record["detectionRan"] as? Bool, false)
        XCTAssertEqual(record["manifestSnapshot"] as? String, "{}")
        XCTAssertEqual(record["modified"] as? String, "{}")
    }

    // MARK: audioRecord

    func testAudioRecordCarriesEveryFieldAndReferencesItsEntryWithDeleteSelf() throws {
        let m4aURL = containerRoot.appendingPathComponent("recording.m4a")
        try Data("m4a-bytes".utf8).write(to: m4aURL)

        let record = SyncRecordBuilders.audioRecord(captureID: captureID, m4aURL: m4aURL,
                                                     sha256: "deadbeef", bytes: 9,
                                                     frameCount: 480_000, sampleRate: 48_000,
                                                     entryID: entryRecordID, zoneID: zoneID)

        XCTAssertEqual(record.recordType, "AudioAsset")
        XCTAssertEqual(record.recordID.recordName, "a.\(captureID).0")
        XCTAssertEqual((record["file"] as? CKAsset)?.fileURL, m4aURL)
        XCTAssertEqual(record["sha256"] as? String, "deadbeef")
        XCTAssertEqual(record["bytes"] as? Int, 9)
        XCTAssertEqual(record["frameCount"] as? Int64, 480_000)
        XCTAssertEqual(record["sampleRate"] as? Double, 48_000)

        let ref = try XCTUnwrap(record["entryRef"] as? CKRecord.Reference)
        XCTAssertEqual(ref.recordID, entryRecordID)
        XCTAssertEqual(ref.action, .deleteSelf,
                       "the cascade design §5 relies on: purging the Entry must take its audio with it")
    }

    // MARK: liveLogRecord

    func testLiveLogRecordCarriesEveryFieldAndReferencesItsEntryWithDeleteSelf() throws {
        let logURL = containerRoot.appendingPathComponent("live.jsonl")
        try Data("{}\n".utf8).write(to: logURL)

        let record = SyncRecordBuilders.liveLogRecord(captureID: captureID, fileURL: logURL,
                                                       sha256: "feedface", bytes: 3,
                                                       entryID: entryRecordID, zoneID: zoneID)

        XCTAssertEqual(record.recordType, "LiveLog")
        XCTAssertEqual(record.recordID.recordName, "l.\(captureID)")
        XCTAssertEqual((record["file"] as? CKAsset)?.fileURL, logURL)
        XCTAssertEqual(record["sha256"] as? String, "feedface")
        XCTAssertEqual(record["bytes"] as? Int, 3)

        let ref = try XCTUnwrap(record["entryRef"] as? CKRecord.Reference)
        XCTAssertEqual(ref.recordID, entryRecordID)
        XCTAssertEqual(ref.action, .deleteSelf)
    }

    // MARK: FinalizeArtifactPush — eligibility + three-answer honesty

    private var capturesRoot: URL { containerRoot.appendingPathComponent("captures", isDirectory: true) }

    private var captureDirectory: URL {
        SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
    }

    private func format() -> AudioFormatDescriptor {
        AudioFormatDescriptor(sampleRate: 48_000, channels: 1,
                              commonFormat: .pcmFormatFloat32, interleaved: false, bytesPerFrame: 4)
    }

    /// Writes `manifest.json`, `final.verifiedAt` set iff `verified`. Mirrors the
    /// fixture shape `LibraryTrashTests.writeCapture` already uses.
    @discardableResult
    private func writeManifest(verified: Bool, at when: Date = Date(timeIntervalSince1970: 1_700_000_000))
    throws -> URL {
        try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
        let final = verified ? FinalRef(verifiedAt: when, durationFrames: 480_000) : FinalRef()
        let manifest = Manifest(captureID: captureID, createdAt: when,
                                state: verified ? .complete : .captured,
                                stateSeq: 1, stateUpdatedAt: when, format: format(), final: final)
        let url = SegmentLayout.manifestURL(captureDirectory: captureDirectory)
        try CaptureCoding.encoder().encode(manifest).write(to: url)
        return url
    }

    private func writeLiveLog() throws {
        let dir = SegmentLayout.transcriptDirectory(captureDirectory: captureDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: SegmentLayout.liveTranscriptURL(captureDirectory: captureDirectory))
    }

    /// The codebase's usual technique for "exists but unreadable" (see
    /// `SyncTreeScannerTests.writeEntryMetadataAsUnreadableDirectory`): a directory sits
    /// at the exact path `live.jsonl` would occupy. `FileManager.fileExists` reads this
    /// as present; `Data(contentsOf:)` throws — exactly the divergence `namesToPush`
    /// must resolve the same way `SyncTreeScanner.liveLogArtifact` does.
    private func writeLiveLogAsUnreadableDirectory() throws {
        let url = SegmentLayout.liveTranscriptURL(captureDirectory: captureDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Eligibility pin: an in-flight (not yet verified) capture is not finalized — no
    /// manifest at all, and a manifest with no `final.verifiedAt`, both read false.
    func testAnInFlightCaptureIsNeverFinalized() throws {
        XCTAssertFalse(FinalizeArtifactPush.isFinalized(capturesRoot: capturesRoot, captureID: captureID),
                       "no manifest on disk at all — the capture directory does not even exist yet")

        try writeManifest(verified: false)
        XCTAssertFalse(FinalizeArtifactPush.isFinalized(capturesRoot: capturesRoot, captureID: captureID),
                       "a manifest exists but final.verifiedAt is nil — still recording/interrupted/retrying")
    }

    func testAVerifiedManifestIsFinalized() throws {
        try writeManifest(verified: true)
        XCTAssertTrue(FinalizeArtifactPush.isFinalized(capturesRoot: capturesRoot, captureID: captureID))
    }

    /// Three-answer honesty, named: not finalized → nothing; finalized with a
    /// `live.jsonl` → all three; finalized WITHOUT one (transcription never ran, or
    /// never produced a log) → Entry + AudioAsset only, never a LiveLog record standing
    /// in for "none".
    func testNamesToPushIsThreeAnswerHonestAboutTheLiveLog() throws {
        XCTAssertEqual(FinalizeArtifactPush.namesToPush(capturesRoot: capturesRoot, captureID: captureID), [],
                       "not finalized at all — nothing pushes yet")

        try writeManifest(verified: true)
        XCTAssertEqual(FinalizeArtifactPush.namesToPush(capturesRoot: capturesRoot, captureID: captureID),
                       [.entry(captureID: captureID), .audio(captureID: captureID)],
                       "finalized but no transcript/live.jsonl — a degraded capture still pushes its recording")

        try writeLiveLog()
        XCTAssertEqual(FinalizeArtifactPush.namesToPush(capturesRoot: capturesRoot, captureID: captureID),
                       [.entry(captureID: captureID), .audio(captureID: captureID), .liveLog(captureID: captureID)])
    }

    /// Review finding (task-6 gate): `namesToPush` must treat an EXISTING-BUT-UNREADABLE
    /// `live.jsonl` the same as an absent one — never queuing `.liveLog` for a file
    /// nothing can actually read the bytes of — because that is exactly what
    /// `SyncTreeScanner.liveLogArtifact` (the reconciliation scan this is meant to
    /// agree with) already does via its own `try? Data(contentsOf:)` read. A bare
    /// `fileExists` check would disagree here: the directory below exists, so
    /// `fileExists` reads true while `Data(contentsOf:)` throws.
    ///
    /// Mutation check (run by hand): reverting `namesToPush`'s LiveLog check to
    /// `FileManager.default.fileExists(atPath: liveLogURL.path)` makes this test fail —
    /// `.liveLog(captureID:)` gets queued for a directory nothing can hash or upload.
    func testNamesToPushTreatsAnUnreadableLiveLogAsAbsentNotPresent() throws {
        try writeManifest(verified: true)
        try writeLiveLogAsUnreadableDirectory()

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: SegmentLayout.liveTranscriptURL(captureDirectory: captureDirectory).path),
                      "sanity: something really is at that path — this is not just a missing file")

        XCTAssertEqual(FinalizeArtifactPush.namesToPush(capturesRoot: capturesRoot, captureID: captureID),
                       [.entry(captureID: captureID), .audio(captureID: captureID)],
                       "an unreadable live.jsonl must read exactly like an absent one, never like a present one")
    }

    // MARK: FinalizeArtifactPush.push — the choke point itself, with a fake hook recorder

    /// The eligibility pin at the actual choke point (not just the pure predicate above):
    /// an in-flight capture's `push` call reaches the fake hook recorder with NOTHING.
    func testPushNeverNotifiesTheHookForAnInFlightCapture() async throws {
        try writeManifest(verified: false)
        let hooks = RecordingSyncHooks()

        await FinalizeArtifactPush.push(capturesRoot: capturesRoot, captureID: captureID, syncHooks: hooks)

        let names = await hooks.names
        XCTAssertEqual(names, [], "an in-flight capture must never reach noteLocalChange")
    }

    func testPushNotifiesTheHookForEveryEligibleNameOnceFinalized() async throws {
        try writeManifest(verified: true)
        try writeLiveLog()
        let hooks = RecordingSyncHooks()

        await FinalizeArtifactPush.push(capturesRoot: capturesRoot, captureID: captureID, syncHooks: hooks)

        let names = await hooks.names
        XCTAssertEqual(names, [.entry(captureID: captureID), .audio(captureID: captureID),
                               .liveLog(captureID: captureID)])
    }

    /// A nil hook (sync off — unit tests, the UI-test harness, an unentitled build)
    /// behaves exactly as it did before M4: no crash, nothing recorded anywhere to check.
    func testPushWithNoHookIsANoOp() async throws {
        try writeManifest(verified: true)
        await FinalizeArtifactPush.push(capturesRoot: capturesRoot, captureID: captureID, syncHooks: nil)
        // Nothing to assert beyond "did not throw/crash" — there is no recorder to read.
    }

    // MARK: EntryMetadataStore's own choke point — the SAME eligibility gate, live

    /// `EntryMetadataStore.update`'s post-write hook shares `FinalizeArtifactPush
    /// .isFinalized` — this exercises the REAL chokepoint (not the pure helper above),
    /// through a real store and a real capture directory, with a fake hook recorder.
    /// A mid-capture metadata write (journal/backdate, before any `.m4a` exists) must
    /// never reach `noteLocalChange`; the identical edit on an already-finalized entry
    /// must.
    func testEntryMetadataStoreOnlyNotifiesTheHookOnceTheCaptureIsFinalized() async throws {
        try writeManifest(verified: false)
        let hooks = RecordingSyncHooks()
        let store = EntryMetadataStore(capturesRoot: capturesRoot, syncHooks: hooks)

        _ = try await store.update(captureID: captureID) { $0.journalID = "J1" }
        var names = await hooks.names
        XCTAssertEqual(names, [], "an in-flight capture's metadata write must never notify sync")

        try writeManifest(verified: true)
        _ = try await store.update(captureID: captureID) { $0.journalID = "J2" }
        names = await hooks.names
        XCTAssertEqual(names, [.entry(captureID: captureID)],
                       "the same store, the same entry, now finalized — the edit must notify sync")
    }

    /// A mutation that changes nothing (`changes.isEmpty`) must not notify sync either —
    /// the same condition that already gates the audit-log append.
    func testEntryMetadataStoreDoesNotNotifyOnANoOpUpdate() async throws {
        try writeManifest(verified: true)
        let hooks = RecordingSyncHooks()
        let store = EntryMetadataStore(capturesRoot: capturesRoot, syncHooks: hooks)
        _ = try await store.update(captureID: captureID) { $0.journalID = "J1" }
        await hooks.reset()

        _ = try await store.update(captureID: captureID) { $0.journalID = "J1" }

        let names = await hooks.names
        XCTAssertEqual(names, [], "re-setting the same value changed nothing — no notification")
    }
}
