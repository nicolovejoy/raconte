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
        // The `.m4a` is part of the fixture (image-capture plan Task 4): `.audio` is no
        // longer named unconditionally for a finalized capture — it is named when a
        // readable `final/recording.m4a` is actually there, because an entry can now be
        // finalized with no audio at all. This fixture is an AUDIO-BEARING capture, so it
        // writes one, and the assertions below are unchanged from before that change.
        try writeFinalM4a()
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
        // Audio-bearing fixture — see `testNamesToPushIsThreeAnswerHonestAboutTheLiveLog`.
        try writeFinalM4a()
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
        // Audio-bearing fixture — see `testNamesToPushIsThreeAnswerHonestAboutTheLiveLog`.
        try writeFinalM4a()
        try writeLiveLog()
        let hooks = RecordingSyncHooks()

        await FinalizeArtifactPush.push(capturesRoot: capturesRoot, captureID: captureID, syncHooks: hooks)

        let names = await hooks.names
        XCTAssertEqual(names, [.entry(captureID: captureID), .audio(captureID: captureID),
                               .liveLog(captureID: captureID)])
    }

    // MARK: Final review I1 — the initial marker stream must push AT finalize

    private func writeMarkerLog() throws {
        try FileManager.default.createDirectory(
            at: SegmentLayout.transcriptDirectory(captureDirectory: captureDirectory),
            withIntermediateDirectories: true)
        try Data("{\"t\":0}\n".utf8).write(to: SegmentLayout.markerLogURL(captureDirectory: captureDirectory))
    }

    /// Same "exists but unreadable" technique `writeLiveLogAsUnreadableDirectory` uses,
    /// for the same reason — see that helper's doc comment.
    private func writeMarkerLogAsUnreadableDirectory() throws {
        try FileManager.default.createDirectory(
            at: SegmentLayout.markerLogURL(captureDirectory: captureDirectory), withIntermediateDirectories: true)
    }

    /// The I1 defect, pinned: `markers.jsonl` is written DURING capture by voice taps,
    /// at which point the eligibility gate correctly refuses every push. Before this
    /// fix `namesToPush` named only entry/audio/liveLog, so a fresh capture's marker
    /// stream was pushed by nothing until the next launch's `SyncPlanner.reconcile()` —
    /// on iOS potentially weeks, with the receiving device rendering that transcript
    /// with its speaker attribution missing the whole time.
    func testNamesToPushIncludesThisDevicesMarkerStreamWhenMarkersExist() throws {
        try writeManifest(verified: true)
        // Audio-bearing fixture — see `testNamesToPushIsThreeAnswerHonestAboutTheLiveLog`.
        try writeFinalM4a()
        try writeMarkerLog()

        XCTAssertEqual(
            FinalizeArtifactPush.namesToPush(capturesRoot: capturesRoot, captureID: captureID,
                                             deviceID: "device-under-test"),
            [.entry(captureID: captureID), .audio(captureID: captureID),
             .markerStream(captureID: captureID, deviceID: "device-under-test")],
            "a finalized capture with voice-tap markers must push its own marker stream at finalize")

        try writeLiveLog()
        XCTAssertEqual(
            FinalizeArtifactPush.namesToPush(capturesRoot: capturesRoot, captureID: captureID,
                                             deviceID: "device-under-test"),
            [.entry(captureID: captureID), .audio(captureID: captureID), .liveLog(captureID: captureID),
             .markerStream(captureID: captureID, deviceID: "device-under-test")],
            "the marker stream rides alongside the liveLog, never in place of it")
    }

    /// The absent and the unreadable case, together — the same readability probe the
    /// LiveLog check uses, and the same reason (`SyncTreeScanner.markerStreamArtifact`
    /// reads the bytes to hash them, so a `markers.jsonl` nothing can read must never be
    /// queued for a push that would find nothing to upload).
    ///
    /// Mutation check (run by hand — see the fix report): changing `namesToPush`'s
    /// marker check to `FileManager.default.fileExists(atPath: markerURL.path)` makes
    /// the unreadable half of this test fail.
    func testNamesToPushOmitsAnAbsentOrUnreadableMarkerStream() throws {
        try writeManifest(verified: true)
        // Audio-bearing fixture — see `testNamesToPushIsThreeAnswerHonestAboutTheLiveLog`.
        try writeFinalM4a()

        XCTAssertEqual(
            FinalizeArtifactPush.namesToPush(capturesRoot: capturesRoot, captureID: captureID,
                                             deviceID: "device-under-test"),
            [.entry(captureID: captureID), .audio(captureID: captureID)],
            "no markers.jsonl at all — a capture with no voice taps has no stream to push")

        try writeMarkerLogAsUnreadableDirectory()
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: SegmentLayout.markerLogURL(captureDirectory: captureDirectory).path),
                      "sanity: something really is at that path — this is not just a missing file")

        XCTAssertEqual(
            FinalizeArtifactPush.namesToPush(capturesRoot: capturesRoot, captureID: captureID,
                                             deviceID: "device-under-test"),
            [.entry(captureID: captureID), .audio(captureID: captureID)],
            "an unreadable markers.jsonl must read exactly like an absent one")
    }

    /// And through the real chokepoint, not just the pure predicate: the hook recorder
    /// sees the marker stream fired at finalize.
    func testPushNotifiesTheHookForTheMarkerStreamAtFinalize() async throws {
        try writeManifest(verified: true)
        // Audio-bearing fixture — see `testNamesToPushIsThreeAnswerHonestAboutTheLiveLog`.
        try writeFinalM4a()
        try writeLiveLog()
        try writeMarkerLog()
        let hooks = RecordingSyncHooks()

        await FinalizeArtifactPush.push(capturesRoot: capturesRoot, captureID: captureID,
                                        syncHooks: hooks, deviceID: "device-under-test")

        let names = await hooks.names
        XCTAssertEqual(names, [.entry(captureID: captureID), .audio(captureID: captureID),
                               .liveLog(captureID: captureID),
                               .markerStream(captureID: captureID, deviceID: "device-under-test")])
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

    // MARK: recordToPush — wiring the T6 builders into the real push path

    /// Fixture defect this task exists to fix: Task 6 built the builders and the
    /// finalize-completion `noteLocalChange` hooks; Task 7-9 built ingest/merge/revision
    /// push, but nothing ever wired `.entry`/`.audio`/`.liveLog` into
    /// `SyncRecordExchange.recordToPush` itself — every enqueued Entry-family name
    /// silently dropped at push time (`recordToPush` returned nil, logging "no builder
    /// yet"). These tests exercise the real orchestrator, not just the pure builders
    /// `SyncRecordBuilders`/`FinalizeArtifactPush` above already cover.
    private func exchange() -> SyncRecordExchange {
        let journalStore = JournalStore(containerRoot: containerRoot)
        let covers = JournalCoverStore(containerRoot: containerRoot, journalStore: journalStore)
        return SyncRecordExchange(
            journalStore: journalStore, coverStore: covers,
            bookkeeping: SyncBookkeepingStore(root: AppContainer.syncRoot(containerRoot: containerRoot)),
            deviceID: "device-low", containerRoot: containerRoot)
    }

    private func writeEntryMetadata(_ metadata: EntryMetadata) throws {
        try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
        try EntryMetadataStore.write(metadata, url: SegmentLayout.entryMetadataURL(captureDirectory: captureDirectory))
    }

    @discardableResult
    private func writeFinalM4a(_ bytes: Data = Data("m4a-bytes".utf8)) throws -> URL {
        let url = SegmentLayout.finalRecordingURL(captureDirectory: captureDirectory)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try bytes.write(to: url)
        return url
    }

    /// (a) A finalized capture with all three artifacts present: `recordToPush` builds
    /// real records for all three names, carrying the fields/assets a fresh read of
    /// this capture's own files should produce.
    func testRecordToPushBuildsAllThreeRecordsForAFinalizedCapture() async throws {
        try writeManifest(verified: true)
        try writeEntryMetadata(EntryMetadata(journalID: journalID, multiVoice: true))
        let m4aBytes = Data("real-m4a-bytes".utf8)
        try writeFinalM4a(m4aBytes)
        try writeLiveLog()

        let ex = exchange()

        let entryAnswer = await ex.recordToPush(for: .entry(captureID: captureID), zoneID: zoneID)
        let entryRecord = try XCTUnwrap(entryAnswer)
        XCTAssertEqual(entryRecord.recordType, "Entry")
        XCTAssertEqual(entryRecord["journalID"] as? String, journalID)
        XCTAssertEqual(entryRecord["multiVoice"] as? Bool, true)
        XCTAssertEqual(entryRecord["capturedAt"] as? Date, stamp(0),
                       "capturedAt is the manifest's own createdAt, per entryRecord's contract")
        XCTAssertEqual(entryRecord["deviceID"] as? String, "device-low")

        let audioAnswer = await ex.recordToPush(for: .audio(captureID: captureID), zoneID: zoneID)
        let audioRecord = try XCTUnwrap(audioAnswer)
        XCTAssertEqual(audioRecord.recordType, "AudioAsset")
        let audioAsset = try XCTUnwrap(audioRecord["file"] as? CKAsset)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(audioAsset.fileURL)), m4aBytes)
        XCTAssertEqual(audioRecord["frameCount"] as? Int64, 480_000)
        XCTAssertEqual(audioRecord["sampleRate"] as? Double, 48_000)
        let audioRef = try XCTUnwrap(audioRecord["entryRef"] as? CKRecord.Reference)
        XCTAssertEqual(audioRef.recordID, entryRecordID)

        let liveLogAnswer = await ex.recordToPush(for: .liveLog(captureID: captureID), zoneID: zoneID)
        let liveLogRecord = try XCTUnwrap(liveLogAnswer)
        XCTAssertEqual(liveLogRecord.recordType, "LiveLog")
        let logAsset = try XCTUnwrap(liveLogRecord["file"] as? CKAsset)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(logAsset.fileURL)), Data("{}\n".utf8))
        let logRef = try XCTUnwrap(liveLogRecord["entryRef"] as? CKRecord.Reference)
        XCTAssertEqual(logRef.recordID, entryRecordID)
    }

    /// (b) Eligibility refusal, the fail-safe half of this task: a capture that is not
    /// finalized returns nil for ALL THREE record types, even when every underlying
    /// file happens to already be sitting on disk (a stray or premature enqueue must
    /// never push an in-flight capture).
    ///
    /// Mutation check (run by hand, reported): removing the
    /// `loadFinalizedManifest`/`isFinalized` guard from `entryRecordToPush` (and its
    /// audio/liveLog siblings) makes this test fail — all three calls start returning
    /// real records instead of nil, because nothing else in the method stops them.
    func testRecordToPushRefusesAllThreeForANonFinalizedCaptureEvenWithFilesPresent() async throws {
        try writeManifest(verified: false)
        try writeEntryMetadata(EntryMetadata(journalID: journalID))
        try writeFinalM4a()
        try writeLiveLog()

        let ex = exchange()

        let entryRecord = await ex.recordToPush(for: .entry(captureID: captureID), zoneID: zoneID)
        let audioRecord = await ex.recordToPush(for: .audio(captureID: captureID), zoneID: zoneID)
        let liveLogRecord = await ex.recordToPush(for: .liveLog(captureID: captureID), zoneID: zoneID)

        XCTAssertNil(entryRecord, "a not-yet-finalized capture must never push an Entry record")
        XCTAssertNil(audioRecord, "…nor an AudioAsset record")
        XCTAssertNil(liveLogRecord, "…nor a LiveLog record")
    }

    /// (c) An unreadable `live.jsonl` (Task 6's own directory-at-that-path technique)
    /// refuses `.liveLog` specifically, while `.entry`/`.audio` still push normally —
    /// the same readability predicate `FinalizeArtifactPush.namesToPush` and
    /// `SyncTreeScanner.liveLogArtifact` already share.
    func testRecordToPushRefusesLiveLogAloneWhenUnreadableButStillPushesEntryAndAudio() async throws {
        try writeManifest(verified: true)
        try writeEntryMetadata(EntryMetadata(journalID: journalID))
        try writeFinalM4a()
        try writeLiveLogAsUnreadableDirectory()

        let ex = exchange()

        let entryRecord = await ex.recordToPush(for: .entry(captureID: captureID), zoneID: zoneID)
        let audioRecord = await ex.recordToPush(for: .audio(captureID: captureID), zoneID: zoneID)
        let liveLogRecord = await ex.recordToPush(for: .liveLog(captureID: captureID), zoneID: zoneID)

        XCTAssertNotNil(entryRecord, "entry.json/manifest are untouched by the bad live.jsonl")
        XCTAssertNotNil(audioRecord, "the m4a is untouched by the bad live.jsonl")
        XCTAssertNil(liveLogRecord, "a name that was enqueued before the log went bad must not push garbage")
    }

    /// (d) Digest agreement, the drift tripwire this task's brief names: the pushed
    /// AudioAsset record's `sha256` must equal `SyncTreeScanner`'s OWN digest for the
    /// same fixture — not a value this test recomputes independently, but the real
    /// scanner's real answer, so the two can never silently diverge (which would make
    /// `SyncPlanner.reconcile` re-enqueue this capture on every future launch, per T9's
    /// lesson).
    func testAudioRecordDigestAgreesWithSyncTreeScannersOwnDigestForTheSameFixture() async throws {
        try writeManifest(verified: true)
        try writeEntryMetadata(EntryMetadata(journalID: journalID))
        try writeFinalM4a(Data("agree-on-this-please".utf8))
        try writeLiveLog()

        let ex = exchange()
        let audioAnswer = await ex.recordToPush(for: .audio(captureID: captureID), zoneID: zoneID)
        let audioRecord = try XCTUnwrap(audioAnswer)
        let pushedSHA = try XCTUnwrap(audioRecord["sha256"] as? String)

        let scan = SyncTreeScanner(containerRoot: containerRoot, deviceID: "device-low").scan()
        let scannedAudio = try XCTUnwrap(
            scan.artifacts.first { $0.name == .audio(captureID: captureID) },
            "the scanner must find the same m4a this fixture just wrote")

        XCTAssertEqual(pushedSHA, scannedAudio.sha256,
                       "the push path and the reconciliation scan must agree on this capture's digest, " +
                       "or the planner will re-enqueue it forever")
        XCTAssertEqual(audioRecord["bytes"] as? Int, scannedAudio.bytes)
    }

    /// (e) A trashed-but-not-purged entry still pushes — trash is a synced field, not a
    /// removal (`SyncTreeScanner`'s own doc comment: "A trashed-but-not-purged entry…
    /// IS eligible — trash is a synced field, not a removal"). Eligibility here is
    /// purely `FinalizeArtifactPush.isFinalized` (the manifest's verified-m4a check),
    /// which knows nothing about trash at all — so a trashed entry is not a special
    /// case the push path has to carve out, only one it must not accidentally refuse.
    func testRecordToPushStillPushesATrashedButNotPurgedEntry() async throws {
        try writeManifest(verified: true)
        try writeEntryMetadata(EntryMetadata(journalID: journalID, trashedAt: stamp(30)))
        try writeFinalM4a()
        try writeLiveLog()

        let ex = exchange()

        let entryAnswer = await ex.recordToPush(for: .entry(captureID: captureID), zoneID: zoneID)
        let entryRecord = try XCTUnwrap(entryAnswer)
        XCTAssertEqual(entryRecord["trashedAt"] as? Date, stamp(30))

        let audioRecord = await ex.recordToPush(for: .audio(captureID: captureID), zoneID: zoneID)
        let liveLogRecord = await ex.recordToPush(for: .liveLog(captureID: captureID), zoneID: zoneID)
        XCTAssertNotNil(audioRecord, "trash does not gate the audio push — only finalization does")
        XCTAssertNotNil(liveLogRecord, "trash does not gate the live-log push either")
    }

    // MARK: entryRecordToPush — single-read pin (fix-round review finding)

    /// Source-scan pin for a review finding: `entryRecordToPush` must read `entry.json`
    /// exactly ONCE and derive both the ledger digest and the decoded `EntryMetadata`
    /// from those same bytes — never a second, independent `Data(contentsOf:)` (via
    /// `EntryMetadataStore.read(url:)` or otherwise). A prior version of this method read
    /// the file twice; the ordering "happened" to be self-healing on every fixture tried,
    /// which is exactly why it was a bug and not a guarantee (an edit — or a delete —
    /// landing between the two reads would desync the digest from the record's actual
    /// content, silently, with no test able to observe it without controlling the OS's
    /// file-read scheduling). No seam exists to inject a mutation between two reads that
    /// no longer happen, so this is a structural pin at the source level — the same
    /// technique `CaptureLabelTests`/`PrecisionDatePickerTests` already use for their own
    /// "no second, independent path" guarantees — rather than a runtime race test.
    ///
    /// Comments are stripped first (`strippingComments`, shared helper) so this cannot be
    /// satisfied by prose *about* the single read rather than the code doing it — this
    /// very doc comment mentions `Data(contentsOf:)` and `EntryMetadataStore.read(url:)`
    /// by name, which would otherwise trivially defeat an unstripped scan.
    func testEntryRecordToPushReadsEntryJSONExactlyOnce() throws {
        let body = try entryRecordToPushSource()

        let directReads = body.components(separatedBy: "Data(contentsOf: entryURL)").count - 1
        XCTAssertEqual(directReads, 1,
                       "entry.json must be read exactly once — the ledger digest and the " +
                       "decoded EntryMetadata must come from the SAME bytes")

        XCTAssertFalse(body.contains("EntryMetadataStore.read(url:"),
                       "must decode the already-read entryData via EntryMetadataStore.decode(_:), " +
                       "not re-read the file through EntryMetadataStore.read(url:)")
    }

    /// Isolates `entryRecordToPush`'s body from `Raconte/Sync/SyncIngest.swift`: from its
    /// `private func entryRecordToPush(` signature to the next sibling `private func` at
    /// the same indentation, which is where the method ends. Comments stripped.
    private func entryRecordToPushSource() throws -> String {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // RaconteTests
            .deletingLastPathComponent()          // repo root
            .appendingPathComponent("Raconte/Sync/SyncIngest.swift")
        let raw = try String(contentsOf: sourceURL, encoding: .utf8)
        let stripped = strippingComments(raw)

        guard let start = stripped.range(of: "private func entryRecordToPush(") else {
            XCTFail("entryRecordToPush not found in SyncIngest.swift — check the source scan path")
            return ""
        }
        let afterSignature = stripped[start.upperBound...]
        guard let end = afterSignature.range(of: "\n    private func ") else {
            XCTFail("could not find the end of entryRecordToPush's body")
            return ""
        }
        return String(afterSignature[afterSignature.startIndex..<end.lowerBound])
    }

    /// Without this, `entryRecordToPushSource()` could quietly stop stripping and the
    /// pin above would go back to being satisfiable by a comment mentioning the pattern.
    func testTheStripperActuallyRemovesCommentsFromTheScannedEntrySource() throws {
        let body = try entryRecordToPushSource()
        XCTAssertFalse(body.contains("//"), "the scanned source still contains a `//` comment marker")
    }
}
