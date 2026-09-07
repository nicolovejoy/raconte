import XCTest
import CryptoKit
@testable import Raconte

/// M4 T3: the eligibility scan over `captures/` + `journals.json`. Eligibility (Locked
/// decisions): a capture syncs only when its manifest reads cleanly AND reports a
/// verified final m4a, and sits directly under `captures/` (never `trash-pending/`).
/// Trashed-but-present entries ARE eligible.
///
/// Every capture/journal/device id here is a real 26-char Crockford ULID
/// (`ULID.make()`), never a hand-typed placeholder — `SyncRecordName.init?(rawValue:)`
/// validates every id component with `ULID.isWellFormed`, so a placeholder the wrong
/// length or containing an excluded letter (I/L/O/U) would make build and parse sides
/// silently never meet.
final class SyncTreeScannerTests: XCTestCase {

    private var containerRoot: URL!
    private var capturesRoot: URL { AppContainer.capturesRoot(containerRoot: containerRoot) }
    private let deviceID = ULID.make()
    private let format = AudioFormatDescriptor(
        sampleRate: 48_000, channels: 1, commonFormat: .pcmFormatFloat32,
        interleaved: false, bytesPerFrame: 4)

    override func setUpWithError() throws {
        containerRoot = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("RaconteSyncScanner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: capturesRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: containerRoot)
    }

    private func scanner() -> SyncTreeScanner {
        SyncTreeScanner(containerRoot: containerRoot, deviceID: deviceID)
    }

    // MARK: Fixture helpers

    private func captureDir(_ id: String) -> URL {
        SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: id)
    }

    @discardableResult
    private func writeManifest(_ id: String, verifiedAt: Date?,
                               createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) throws -> Data {
        try FileManager.default.createDirectory(at: captureDir(id), withIntermediateDirectories: true)
        var m = Manifest(captureID: id, createdAt: createdAt, state: verifiedAt == nil ? .captured : .complete,
                         stateSeq: 1, stateUpdatedAt: createdAt, format: format)
        m.final = FinalRef(path: "final/recording.m4a", verifiedAt: verifiedAt, durationFrames: 48_000)
        let data = try CaptureCoding.encoder().encode(m)
        try data.write(to: SegmentLayout.manifestURL(captureDirectory: captureDir(id)))
        return data
    }

    private func writeRawManifest(_ bytes: String, id: String) throws {
        try FileManager.default.createDirectory(at: captureDir(id), withIntermediateDirectories: true)
        try Data(bytes.utf8).write(to: SegmentLayout.manifestURL(captureDirectory: captureDir(id)))
    }

    @discardableResult
    private func writeEntryMetadata(_ metadata: EntryMetadata, id: String) throws -> Data {
        try FileManager.default.createDirectory(at: captureDir(id), withIntermediateDirectories: true)
        let data = try EntryMetadataStore.encode(metadata)
        try data.write(to: SegmentLayout.entryMetadataURL(captureDirectory: captureDir(id)))
        return data
    }

    /// A path that EXISTS at `entry.json`'s location but cannot be read as `Data` — a
    /// directory sitting where a file should be, same trick `SyncBookkeepingTests`
    /// uses for its "unreadable, not absent" case. Real corruption (bit rot, a
    /// permissions error) fails `Data(contentsOf:)` the same way; garbage-but-readable
    /// bytes would NOT reproduce this, since `Data(contentsOf:)` only cares whether the
    /// bytes could be read, not whether they're valid JSON.
    private func writeEntryMetadataAsUnreadableDirectory(id: String) throws {
        let url = SegmentLayout.entryMetadataURL(captureDirectory: captureDir(id))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    @discardableResult
    private func writeFinalM4A(_ id: String, bytes: Data = Data(repeating: 0xAB, count: 128)) throws -> Data {
        let dir = SegmentLayout.finalDirectory(captureDirectory: captureDir(id))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try bytes.write(to: SegmentLayout.finalRecordingURL(captureDirectory: captureDir(id)))
        return bytes
    }

    private func transcriptDir(_ id: String) -> URL {
        SegmentLayout.transcriptDirectory(captureDirectory: captureDir(id))
    }

    @discardableResult
    private func writeLiveLog(_ id: String, bytes: Data = Data("live-log-bytes".utf8)) throws -> Data {
        try FileManager.default.createDirectory(at: transcriptDir(id), withIntermediateDirectories: true)
        try bytes.write(to: SegmentLayout.liveTranscriptURL(captureDirectory: captureDir(id)))
        return bytes
    }

    @discardableResult
    private func writeOwnMarkers(_ id: String, bytes: Data = Data("own-marker-bytes".utf8)) throws -> Data {
        try FileManager.default.createDirectory(at: transcriptDir(id), withIntermediateDirectories: true)
        try bytes.write(to: SegmentLayout.markerLogURL(captureDirectory: captureDir(id)))
        return bytes
    }

    /// A foreign device's already-ingested marker stream — the shape a later task
    /// (T10) materializes. Must be structurally invisible to this scanner.
    private func writeForeignMarkers(_ id: String, foreignDeviceID: String,
                                     bytes: Data = Data("foreign-marker-bytes".utf8)) throws {
        try FileManager.default.createDirectory(at: transcriptDir(id), withIntermediateDirectories: true)
        let url = transcriptDir(id).appendingPathComponent("markers-\(foreignDeviceID).jsonl")
        try bytes.write(to: url)
    }

    private func revisionFixture(id: String, text: String = "hello") -> TranscriptRevision {
        TranscriptRevision(id: id, source: .machineLive, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                           spans: [TranscriptSpan(text: text, anchor: .none)])
    }

    @discardableResult
    private func writeCanonicalRevision(_ captureID: String, revisionNumber: Int,
                                        _ revision: TranscriptRevision) throws -> Data {
        try FileManager.default.createDirectory(at: transcriptDir(captureID), withIntermediateDirectories: true)
        let data = try CaptureCoding.encoder().encode(revision)
        try data.write(to: SegmentLayout.canonicalTranscriptURL(captureDirectory: captureDir(captureID),
                                                                 revision: revisionNumber))
        return data
    }

    private func writeRawCanonical(_ captureID: String, revisionNumber: Int, bytes: String) throws {
        try FileManager.default.createDirectory(at: transcriptDir(captureID), withIntermediateDirectories: true)
        try Data(bytes.utf8).write(to: SegmentLayout.canonicalTranscriptURL(captureDirectory: captureDir(captureID),
                                                                            revision: revisionNumber))
    }

    private func writeJournals(_ journals: [Journal]) throws {
        try JournalStore.encode(JournalRegistry(journals: journals))
            .write(to: AppContainer.journalsURL(containerRoot: containerRoot))
    }

    private func writeCover(journalID: String, bytes: Data) throws {
        let url = AppContainer.journalCoverURL(containerRoot: containerRoot, journalID: journalID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func artifact(_ result: SyncScanResult, named name: SyncRecordName) -> SyncArtifactState? {
        result.artifacts.first { $0.name == name }
    }

    // MARK: (a)/(b)/(c)/(d)/(e) eligibility fixture, cardinality >= 2 eligible

    private let idFinalizedOne = ULID.make()
    private let idFinalizedTwo = ULID.make()
    private let idInFlight = ULID.make()
    private let idTrashedPresent = ULID.make()
    private let idTrashPending = ULID.make()
    private let idBadManifest = ULID.make()

    private func buildEligibilityFixture() throws {
        // (a) finalized, eligible.
        try writeManifest(idFinalizedOne, verifiedAt: Date(timeIntervalSince1970: 1_700_000_001))
        try writeFinalM4A(idFinalizedOne)

        // A second finalized capture, distinct content — cardinality >= 2 so an
        // ordering/overwrite bug surfaces.
        try writeManifest(idFinalizedTwo, verifiedAt: Date(timeIntervalSince1970: 1_700_000_002))
        try writeFinalM4A(idFinalizedTwo, bytes: Data(repeating: 0xCD, count: 256))

        // (b) in-flight: manifest present, no final.verifiedAt.
        try writeManifest(idInFlight, verifiedAt: nil)

        // (c) trashed but present: eligible manifest + entry.json.trashedAt set, still
        // directly under captures/.
        try writeManifest(idTrashedPresent, verifiedAt: Date(timeIntervalSince1970: 1_700_000_003))
        try writeFinalM4A(idTrashedPresent)
        var trashed = EntryMetadata()
        trashed.trashedAt = Date(timeIntervalSince1970: 1_700_000_004)
        try writeEntryMetadata(trashed, id: idTrashedPresent)

        // (d) inside trash-pending/, never under captures/ — the scanner must never
        // even look here.
        let stagedDir = AppContainer.trashPendingURL(containerRoot: containerRoot, name: idTrashPending)
        try FileManager.default.createDirectory(at: stagedDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stagedDir.appendingPathComponent("final", isDirectory: true),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0xEE, count: 32).write(
            to: stagedDir.appendingPathComponent("final/recording.m4a"))

        // (e) unreadable manifest.
        try writeRawManifest("not valid json at all", id: idBadManifest)
    }

    func testEligibleCapturesProduceEntryAndAudioArtifacts() throws {
        try buildEligibilityFixture()
        let result = scanner().scan()

        XCTAssertNotNil(artifact(result, named: .entry(captureID: idFinalizedOne)))
        XCTAssertNotNil(artifact(result, named: .audio(captureID: idFinalizedOne)))
        XCTAssertNotNil(artifact(result, named: .entry(captureID: idFinalizedTwo)))
        XCTAssertNotNil(artifact(result, named: .audio(captureID: idFinalizedTwo)))
    }

    func testInFlightCaptureWithNoVerifiedAtIsExcludedAndNotReportedAsSkipped() throws {
        try buildEligibilityFixture()
        let result = scanner().scan()

        XCTAssertNil(artifact(result, named: .entry(captureID: idInFlight)))
        XCTAssertNil(artifact(result, named: .audio(captureID: idInFlight)))
        XCTAssertFalse(result.skipped.contains(idInFlight),
                       "an in-flight capture is ordinarily not-yet-eligible, not a diagnostic failure")
    }

    func testTrashedButPresentCaptureIsIncluded() throws {
        try buildEligibilityFixture()
        let result = scanner().scan()

        XCTAssertNotNil(artifact(result, named: .entry(captureID: idTrashedPresent)),
                        "trash is a synced field, not a removal — the entry stays eligible")
        XCTAssertNotNil(artifact(result, named: .audio(captureID: idTrashedPresent)))
    }

    func testCaptureInsideTrashPendingIsInvisibleToTheScan() throws {
        try buildEligibilityFixture()
        let result = scanner().scan()

        XCTAssertNil(artifact(result, named: .entry(captureID: idTrashPending)))
        XCTAssertFalse(result.skipped.contains(idTrashPending))
    }

    /// #81: `quarantine/` is a sibling of `captures/`, exactly like `trash-pending/`, so
    /// the scanner must never even look there — sync deletes are explicit, never inferred
    /// from a scan, and a repair holding pen is not a deletion.
    func testAQuarantinedCaptureIsInvisibleToTheScan() throws {
        let id = ULID.make()
        try writeManifest(id, verifiedAt: Date(timeIntervalSince1970: 1_700_000_005))
        try writeFinalM4A(id)

        let remover = StagedRemover(capturesRoot: capturesRoot, containerRoot: containerRoot)
        _ = try remover.quarantine(captureID: id)

        let result = scanner().scan()

        XCTAssertNil(artifact(result, named: .entry(captureID: id)))
        XCTAssertNil(artifact(result, named: .audio(captureID: id)))
        XCTAssertFalse(result.skipped.contains(id))
    }

    /// IMPORTANT 3 (review): the manifest-unreadable skip must be the bare captureID —
    /// meaning "the whole capture is excluded" — and nothing else in this suite may
    /// reuse that exact string for a narrower, single-artifact failure. Checked here by
    /// asserting the EXACT skip set for this capture is just the one bare entry, not
    /// also path-qualified forms a less careful implementation might additionally emit.
    func testUnreadableManifestIsExcludedAndReportedInSkippedAsBareCaptureID() throws {
        try buildEligibilityFixture()
        let result = scanner().scan()

        XCTAssertNil(artifact(result, named: .entry(captureID: idBadManifest)))
        XCTAssertNil(artifact(result, named: .audio(captureID: idBadManifest)))
        let related = result.skipped.filter { $0 == idBadManifest || $0.hasPrefix("\(idBadManifest)/") }
        XCTAssertEqual(related, [idBadManifest],
                       "manifest-unreadable is capture-level: exactly the bare id, no path-qualified duplicate")
    }

    /// IMPORTANT 4 (review): a capture directory that exists but has no manifest.json
    /// AT ALL yet (created microseconds before the first manifest write) must be
    /// excluded silently — same "absent is not a failure" shape as an absent
    /// entry.json or an absent journals.json, distinct from a manifest that exists and
    /// fails to read/decode.
    func testCaptureDirectoryWithNoManifestYetIsExcludedSilently() throws {
        let id = ULID.make()
        try FileManager.default.createDirectory(at: captureDir(id), withIntermediateDirectories: true)
        // No manifest.json written — the directory exists (e.g. `mkdir` landed, the
        // manifest write hasn't yet), nothing else does.

        let result = scanner().scan()
        XCTAssertNil(artifact(result, named: .entry(captureID: id)))
        XCTAssertFalse(result.skipped.contains(id),
                       "a not-yet-written manifest is ordinary, not a diagnostic failure")
    }

    /// IMPORTANT 2 (review): a `captures/` child whose name isn't a well-formed ULID
    /// can never be represented as a parseable `SyncRecordName` — it must be reported,
    /// not silently turned into an unparseable name.
    func testStrayNonULIDDirectoryUnderCapturesIsSkippedNotScanned() throws {
        let strayName = "not-a-ulid-at-all"
        let strayDir = capturesRoot.appendingPathComponent(strayName, isDirectory: true)
        try FileManager.default.createDirectory(at: strayDir, withIntermediateDirectories: true)
        // Give it manifest-shaped content so a bug that skipped ULID validation would
        // otherwise happily scan it as eligible.
        var m = Manifest(captureID: strayName, createdAt: Date(timeIntervalSince1970: 1_700_000_030),
                         state: .complete, stateSeq: 1,
                         stateUpdatedAt: Date(timeIntervalSince1970: 1_700_000_030), format: format)
        m.final = FinalRef(path: "final/recording.m4a", verifiedAt: Date(timeIntervalSince1970: 1_700_000_030),
                           durationFrames: 48_000)
        try CaptureCoding.encoder().encode(m).write(to: strayDir.appendingPathComponent("manifest.json"))

        let result = scanner().scan()
        XCTAssertTrue(result.skipped.contains(strayName))
        XCTAssertTrue(result.artifacts.isEmpty)
    }

    // MARK: CRITICAL 1 (review) — unreadable entry.json must never digest as absent

    func testUnreadableEntryMetadataProducesNoEntryArtifactAndIsSkipped() throws {
        let id = ULID.make()
        try writeManifest(id, verifiedAt: Date(timeIntervalSince1970: 1_700_000_040))
        try writeFinalM4A(id)
        try writeEntryMetadataAsUnreadableDirectory(id: id)

        let result = scanner().scan()

        XCTAssertNil(artifact(result, named: .entry(captureID: id)),
                     "a read failure must never digest the same as a genuinely absent sidecar")
        XCTAssertTrue(result.skipped.contains("\(id)/\(SegmentLayout.entryMetadataFileName)"))
        // Independent artifacts still scan — only the Entry artifact is affected.
        XCTAssertNotNil(artifact(result, named: .audio(captureID: id)),
                        "an unreadable entry.json must not take the rest of the capture's scan down with it")
    }

    func testUnreadableEntryMetadataDigestIsNotByteIdenticalToAnAbsentOne() throws {
        // The concrete failure mode the Critical finding names: before the fix, a
        // corrupt entry.json produced an Entry artifact byte-identical to a
        // no-metadata capture, so it would silently sync as if nothing were wrong.
        let unreadableID = ULID.make()
        try writeManifest(unreadableID, verifiedAt: Date(timeIntervalSince1970: 1_700_000_041))
        try writeFinalM4A(unreadableID)
        try writeEntryMetadataAsUnreadableDirectory(id: unreadableID)

        let absentID = ULID.make()
        try writeManifest(absentID, verifiedAt: Date(timeIntervalSince1970: 1_700_000_041))
        try writeFinalM4A(absentID)
        // No entry.json at all for this one.

        let result = scanner().scan()
        XCTAssertNil(artifact(result, named: .entry(captureID: unreadableID)))
        XCTAssertNotNil(artifact(result, named: .entry(captureID: absentID)),
                        "the genuinely-absent sidecar still produces a normal Entry artifact")
    }

    // MARK: Entry digest

    func testEntryDigestIsSha256OfEntryJSONBytesConcatenatedWithManifestBytes() throws {
        let id = ULID.make()
        let manifestData = try writeManifest(id, verifiedAt: Date(timeIntervalSince1970: 1_700_000_010))
        try writeFinalM4A(id)
        var metadata = EntryMetadata()
        metadata.multiVoice = true
        let entryData = try writeEntryMetadata(metadata, id: id)

        let result = scanner().scan()
        let entry = try XCTUnwrap(artifact(result, named: .entry(captureID: id)))

        let expectedSource = entryData + manifestData
        XCTAssertEqual(entry.sha256, sha256(expectedSource))
        XCTAssertEqual(entry.bytes, expectedSource.count)
    }

    func testEntryDigestWithNoEntryJSONIsJustManifestBytes() throws {
        let id = ULID.make()
        let manifestData = try writeManifest(id, verifiedAt: Date(timeIntervalSince1970: 1_700_000_011))
        try writeFinalM4A(id)
        // No entry.json written at all — the common case.

        let result = scanner().scan()
        let entry = try XCTUnwrap(artifact(result, named: .entry(captureID: id)))

        XCTAssertEqual(entry.sha256, sha256(manifestData))
        XCTAssertEqual(entry.bytes, manifestData.count)
    }

    // MARK: Audio digest

    func testAudioDigestIsSha256OfTheM4AFileBytes() throws {
        let id = ULID.make()
        try writeManifest(id, verifiedAt: Date(timeIntervalSince1970: 1_700_000_012))
        let bytes = try writeFinalM4A(id, bytes: Data(repeating: 0x11, count: 64))

        let result = scanner().scan()
        let audio = try XCTUnwrap(artifact(result, named: .audio(captureID: id)))

        XCTAssertEqual(audio.sha256, sha256(bytes))
        XCTAssertEqual(audio.bytes, bytes.count)
    }

    func testAudioMissingDespiteVerifiedAtIsSkippedWithPathQualifiedForm() throws {
        // IMPORTANT 3: distinct skip shape from the manifest-unreadable case — this
        // capture otherwise scans fine (Entry still produced), only Audio is missing.
        let id = ULID.make()
        try writeManifest(id, verifiedAt: Date(timeIntervalSince1970: 1_700_000_042))
        // No final/recording.m4a written at all, despite verifiedAt being set.

        let result = scanner().scan()
        XCTAssertNil(artifact(result, named: .audio(captureID: id)))
        XCTAssertNotNil(artifact(result, named: .entry(captureID: id)))
        XCTAssertTrue(result.skipped.contains("\(id)/final/\(SegmentLayout.finalRecordingName)"))
        XCTAssertFalse(result.skipped.contains(id),
                       "must not also emit the bare-id form that means the whole capture is excluded")
    }

    // MARK: LiveLog

    func testLiveLogArtifactPresentWhenLiveJSONLExists() throws {
        let id = ULID.make()
        try writeManifest(id, verifiedAt: Date(timeIntervalSince1970: 1_700_000_013))
        try writeFinalM4A(id)
        let bytes = try writeLiveLog(id, bytes: Data("committed transcript lines".utf8))

        let result = scanner().scan()
        let liveLog = try XCTUnwrap(artifact(result, named: .liveLog(captureID: id)))

        XCTAssertEqual(liveLog.sha256, sha256(bytes))
        XCTAssertEqual(liveLog.bytes, bytes.count)
    }

    func testNoLiveLogArtifactWhenTranscriptionNeverRan() throws {
        let id = ULID.make()
        try writeManifest(id, verifiedAt: Date(timeIntervalSince1970: 1_700_000_014))
        try writeFinalM4A(id)
        // No transcript/ at all — a degraded capture. Entry + Audio still push;
        // LiveLog simply has no record, never a zero-byte stand-in.

        let result = scanner().scan()
        XCTAssertNil(artifact(result, named: .liveLog(captureID: id)))
        XCTAssertNotNil(artifact(result, named: .entry(captureID: id)))
        XCTAssertNotNil(artifact(result, named: .audio(captureID: id)))
    }

    // MARK: MarkerStream — own only, never foreign

    func testMarkerStreamArtifactUsesOwnMarkersFileAndOwnDeviceID() throws {
        let id = ULID.make()
        try writeManifest(id, verifiedAt: Date(timeIntervalSince1970: 1_700_000_015))
        try writeFinalM4A(id)
        let ownBytes = try writeOwnMarkers(id, bytes: Data("own-taps".utf8))

        let result = scanner().scan()
        let marker = try XCTUnwrap(artifact(result, named: .markerStream(captureID: id, deviceID: deviceID)))

        XCTAssertEqual(marker.sha256, sha256(ownBytes))
        XCTAssertEqual(marker.bytes, ownBytes.count)
    }

    func testForeignMarkerStreamFileIsNeverScannedForUpload() throws {
        let id = ULID.make()
        let foreignDeviceID = ULID.make()
        try writeManifest(id, verifiedAt: Date(timeIntervalSince1970: 1_700_000_016))
        try writeFinalM4A(id)
        let ownBytes = try writeOwnMarkers(id, bytes: Data("own-taps-only".utf8))
        try writeForeignMarkers(id, foreignDeviceID: foreignDeviceID, bytes: Data("someone-elses-taps".utf8))

        let result = scanner().scan()
        let markerArtifacts = result.artifacts.filter {
            if case .markerStream = $0.name { return true }
            return false
        }

        XCTAssertEqual(markerArtifacts.count, 1, "exactly the own-device stream, nothing from the foreign file")
        XCTAssertEqual(markerArtifacts.first?.sha256, sha256(ownBytes))
        XCTAssertNil(artifact(result, named: .markerStream(captureID: id, deviceID: foreignDeviceID)))
    }

    func testNoMarkerStreamArtifactWhenNoMarkersWereEverTapped() throws {
        let id = ULID.make()
        try writeManifest(id, verifiedAt: Date(timeIntervalSince1970: 1_700_000_017))
        try writeFinalM4A(id)

        let result = scanner().scan()
        XCTAssertTrue(result.artifacts.filter {
            if case .markerStream = $0.name { return true }
            return false
        }.isEmpty)
    }

    // MARK: Revisions — keyed by id, not file number

    func testRevisionArtifactKeyedByItsOwnIdNotItsFileNumber() throws {
        let id = ULID.make()
        try writeManifest(id, verifiedAt: Date(timeIntervalSince1970: 1_700_000_018))
        try writeFinalM4A(id)
        let revisionID = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
        let data = try writeCanonicalRevision(id, revisionNumber: 7, revisionFixture(id: revisionID))

        let result = scanner().scan()
        let revision = try XCTUnwrap(artifact(result, named: .revision(id: revisionID)))

        XCTAssertEqual(revision.sha256, sha256(data))
        XCTAssertEqual(revision.bytes, data.count)
    }

    func testTwoRevisionsBothScannedCardinalityCheck() throws {
        let id = ULID.make()
        try writeManifest(id, verifiedAt: Date(timeIntervalSince1970: 1_700_000_019))
        try writeFinalM4A(id)
        let firstID = ULID.make()
        let secondID = ULID.make()
        try writeCanonicalRevision(id, revisionNumber: 0, revisionFixture(id: firstID, text: "first"))
        try writeCanonicalRevision(id, revisionNumber: 1, revisionFixture(id: secondID, text: "second"))

        let result = scanner().scan()
        XCTAssertNotNil(artifact(result, named: .revision(id: firstID)))
        XCTAssertNotNil(artifact(result, named: .revision(id: secondID)))
    }

    func testUnreadableRevisionFileIsSkippedButOthersStillScanned() throws {
        let id = ULID.make()
        try writeManifest(id, verifiedAt: Date(timeIntervalSince1970: 1_700_000_020))
        try writeFinalM4A(id)
        let goodID = ULID.make()
        try writeCanonicalRevision(id, revisionNumber: 0, revisionFixture(id: goodID))
        try writeRawCanonical(id, revisionNumber: 1, bytes: "not a revision at all")

        let result = scanner().scan()
        XCTAssertNotNil(artifact(result, named: .revision(id: goodID)))
        XCTAssertTrue(result.skipped.contains("\(id)/canonical-1.json"))
    }

    // MARK: Journals

    func testJournalArtifactDigestWithNoCoverIsJustTheEncodedJournal() throws {
        let journal = Journal(id: ULID.make(), name: "1987 Journal",
                              createdAt: Date(timeIntervalSince1970: 1_700_000_021))
        try writeJournals([journal])

        let result = scanner().scan()
        let artifactState = try XCTUnwrap(artifact(result, named: .journal(id: journal.id)))
        let expected = try CaptureCoding.lineEncoder().encode(journal)

        XCTAssertEqual(artifactState.sha256, sha256(expected))
        XCTAssertEqual(artifactState.bytes, expected.count)
    }

    func testJournalArtifactDigestChangesWhenCoverChanges() throws {
        let journal = Journal(id: ULID.make(), name: "Trip to France",
                              createdAt: Date(timeIntervalSince1970: 1_700_000_022))
        try writeJournals([journal])
        try writeCover(journalID: journal.id, bytes: Data(repeating: 0x01, count: 8))
        let firstDigest = try XCTUnwrap(artifact(scanner().scan(), named: .journal(id: journal.id))).sha256

        try writeCover(journalID: journal.id, bytes: Data(repeating: 0x02, count: 8))
        let secondDigest = try XCTUnwrap(artifact(scanner().scan(), named: .journal(id: journal.id))).sha256

        XCTAssertNotEqual(firstDigest, secondDigest, "a cover change alone must re-enqueue the journal")
    }

    func testJournalArtifactDigestMatchesTheSuffixedCoverDigestFormula() throws {
        let journal = Journal(id: ULID.make(), name: "Formula Check",
                              createdAt: Date(timeIntervalSince1970: 1_700_000_023))
        try writeJournals([journal])
        let coverBytes = Data(repeating: 0x42, count: 16)
        try writeCover(journalID: journal.id, bytes: coverBytes)

        let result = scanner().scan()
        let artifactState = try XCTUnwrap(artifact(result, named: .journal(id: journal.id)))

        var expected = try CaptureCoding.lineEncoder().encode(journal)
        expected.append(Data("\n".utf8))
        expected.append(Data(sha256(coverBytes).utf8))
        XCTAssertEqual(artifactState.sha256, sha256(expected))
        XCTAssertEqual(artifactState.bytes, expected.count)
    }

    func testMultipleJournalsAllScanned() throws {
        let journalA = Journal(id: ULID.make(), name: "A",
                               createdAt: Date(timeIntervalSince1970: 1_700_000_024))
        let journalB = Journal(id: ULID.make(), name: "B",
                               createdAt: Date(timeIntervalSince1970: 1_700_000_025))
        try writeJournals([journalA, journalB])

        let result = scanner().scan()
        XCTAssertNotNil(artifact(result, named: .journal(id: journalA.id)))
        XCTAssertNotNil(artifact(result, named: .journal(id: journalB.id)))
    }

    func testNoJournalsFileMeansNoJournalArtifactsAndNothingSkipped() {
        let result = scanner().scan()
        XCTAssertTrue(result.artifacts.filter {
            if case .journal = $0.name { return true }
            return false
        }.isEmpty)
        XCTAssertTrue(result.skipped.isEmpty)
    }

    func testUnreadableJournalsFileIsReportedInSkipped() throws {
        let url = AppContainer.journalsURL(containerRoot: containerRoot)
        try Data("not valid json".utf8).write(to: url)

        let result = scanner().scan()
        XCTAssertTrue(result.skipped.contains(AppContainer.journalsFileName))
        XCTAssertTrue(result.artifacts.filter {
            if case .journal = $0.name { return true }
            return false
        }.isEmpty)
    }

    // MARK: IMPORTANT 2 (review) — build and parse sides must actually meet

    /// Every name this scanner ever mints must survive its own `rawValue` → parse
    /// round trip. Runs across the richest fixture in this file (every artifact kind
    /// at once) so a mismatch in any single case would be caught.
    func testEveryScannedArtifactNameRoundTripsThroughSyncRecordName() throws {
        try buildEligibilityFixture()

        let id = ULID.make()
        try writeManifest(id, verifiedAt: Date(timeIntervalSince1970: 1_700_000_050))
        try writeFinalM4A(id)
        try writeLiveLog(id)
        try writeOwnMarkers(id)
        try writeCanonicalRevision(id, revisionNumber: 0, revisionFixture(id: ULID.make()))
        try writeJournals([Journal(id: ULID.make(), name: "Round Trip",
                                   createdAt: Date(timeIntervalSince1970: 1_700_000_051))])

        let result = scanner().scan()
        XCTAssertFalse(result.artifacts.isEmpty)
        for scanned in result.artifacts {
            XCTAssertEqual(SyncRecordName(rawValue: scanned.name.rawValue), scanned.name,
                           "\(scanned.name.rawValue) failed to round-trip")
        }
    }

    // MARK: sha256Hex formula, testable without a real tree

    func testSha256HexMatchesCryptoKitDirectly() {
        let data = Data("hello sync".utf8)
        XCTAssertEqual(SyncTreeScanner.sha256Hex(data),
                       SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    func testSha256HexOfEmptyDataIsTheKnownEmptyDigest() {
        // Well-known constant: sha256("") — a fixed external check on the formula.
        XCTAssertEqual(SyncTreeScanner.sha256Hex(Data()),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }
}
