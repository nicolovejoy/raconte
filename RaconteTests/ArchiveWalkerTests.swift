import XCTest
@testable import Raconte

/// T10: what the archive export copies. `ArchiveWalker.list` mirrors the SHAPE of
/// `SyncTreeScanner`'s walk (`Raconte/Sync/SyncTreeScanner.swift:77-130`) but
/// deliberately without its exclusions — an unfinalized capture, a foreign device's
/// marker stream, and an unreadable sidecar are all listed (with a warning where one
/// applies), never silently dropped the way sync eligibility drops them.
///
/// Fixture helpers copied from `SyncTreeScannerTests` (do not import across test files),
/// plus a few new ones for images, entry-log, and the deliberately-excluded junk
/// (`segments/`, `transcript/head.json`, `images/thumbnails/`).
///
/// Every capture/journal/device id here is a real 26-char Crockford ULID (`ULID.make()`),
/// never a hand-typed placeholder — `ULID.isWellFormed` gates the whole walk.
final class ArchiveWalkerTests: XCTestCase {

    private var containerRoot: URL!
    private var capturesRoot: URL { AppContainer.capturesRoot(containerRoot: containerRoot) }
    private let format = AudioFormatDescriptor(
        sampleRate: 48_000, channels: 1, commonFormat: .pcmFormatFloat32,
        interleaved: false, bytesPerFrame: 4)

    override func setUpWithError() throws {
        containerRoot = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("RaconteArchiveWalker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: capturesRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: containerRoot)
    }

    // MARK: Fixture helpers (shape copied from SyncTreeScannerTests)

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

    @discardableResult
    private func writeEntryMetadata(_ metadata: EntryMetadata, id: String) throws -> Data {
        try FileManager.default.createDirectory(at: captureDir(id), withIntermediateDirectories: true)
        let data = try EntryMetadataStore.encode(metadata)
        try data.write(to: SegmentLayout.entryMetadataURL(captureDirectory: captureDir(id)))
        return data
    }

    /// A well-formed FILE (readable as `Data`) whose content is not valid `EntryMetadata`
    /// JSON — "garbage entry.json" in the task brief. Distinct from an unreadable path
    /// (a directory sitting where a file should be): this still copies byte-for-byte,
    /// it just fails to decode, which is exactly what should produce a warning.
    private func writeGarbageEntryMetadata(id: String) throws {
        try FileManager.default.createDirectory(at: captureDir(id), withIntermediateDirectories: true)
        try Data("not valid entry metadata json".utf8)
            .write(to: SegmentLayout.entryMetadataURL(captureDirectory: captureDir(id)))
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

    @discardableResult
    private func writeForeignMarkers(_ id: String, foreignDeviceID: String,
                                     bytes: Data = Data("foreign-marker-bytes".utf8)) throws -> Data {
        try FileManager.default.createDirectory(at: transcriptDir(id), withIntermediateDirectories: true)
        try bytes.write(to: SegmentLayout.foreignMarkerLogURL(captureDirectory: captureDir(id),
                                                              deviceID: foreignDeviceID))
        return bytes
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

    private func writeDraft(_ captureID: String, bytes: Data = Data("draft-bytes".utf8)) throws {
        try FileManager.default.createDirectory(at: transcriptDir(captureID), withIntermediateDirectories: true)
        try bytes.write(to: SegmentLayout.transcriptDraftURL(captureDirectory: captureDir(captureID)))
    }

    private func writeHeadJSON(_ captureID: String, bytes: Data = Data("head-cache-bytes".utf8)) throws {
        try FileManager.default.createDirectory(at: transcriptDir(captureID), withIntermediateDirectories: true)
        try bytes.write(to: SegmentLayout.transcriptHeadURL(captureDirectory: captureDir(captureID)))
    }

    private func writeSegmentJunk(_ captureID: String) throws {
        let dir = SegmentLayout.segmentsDirectory(captureDirectory: captureDir(captureID))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0x01, count: 16).write(to: SegmentLayout.pcmURL(segmentsDirectory: dir, index: 0))
    }

    private func writeEntryLog(_ captureID: String, bytes: Data = Data("entry-log-bytes".utf8)) throws {
        try FileManager.default.createDirectory(at: captureDir(captureID), withIntermediateDirectories: true)
        try bytes.write(to: SegmentLayout.entryLogURL(captureDirectory: captureDir(captureID)))
    }

    /// Writes `images/<imageID>.jpg` + `images/<imageID>.json`, and (when requested)
    /// `images/thumbnails/<imageID>.jpg` — the exact names `SegmentLayout` declares.
    private func writeImage(_ captureID: String, imageID: String, includeThumbnail: Bool) throws {
        let dir = captureDir(captureID)
        try FileManager.default.createDirectory(at: SegmentLayout.imagesDirectory(captureDirectory: dir),
                                                 withIntermediateDirectories: true)
        try Data("image-original-bytes".utf8)
            .write(to: SegmentLayout.imageOriginalURL(captureDirectory: dir, imageID: imageID, ext: "jpg"))
        try Data("{}".utf8)
            .write(to: SegmentLayout.imageSidecarURL(captureDirectory: dir, imageID: imageID))
        if includeThumbnail {
            try FileManager.default.createDirectory(
                at: SegmentLayout.imageThumbnailsDirectory(captureDirectory: dir),
                withIntermediateDirectories: true)
            try Data("thumbnail-bytes".utf8)
                .write(to: SegmentLayout.imageThumbnailURL(captureDirectory: dir, imageID: imageID))
        }
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

    // MARK: The full fixture — one capture with everything, one with neither audio nor
    // a readable sidecar, one journal with a cover.

    private struct Fixture {
        var idAudio: String
        var idNoAudio: String
        var imageID: String
        var foreignDeviceID: String
        var journal: Journal
    }

    @discardableResult
    private func buildFullFixture() throws -> Fixture {
        let idAudio = ULID.make()
        let idNoAudio = ULID.make()
        let imageID = ULID.make()
        let foreignDeviceID = ULID.make()

        // Capture with audio: manifest, final audio, two revisions, own + foreign
        // markers, live log, entry-log, one image (+ thumbnail), and deliberately-
        // excluded junk (segments/, transcript/head.json).
        try writeManifest(idAudio, verifiedAt: Date(timeIntervalSince1970: 1_700_000_001))
        try writeFinalM4A(idAudio)
        try writeCanonicalRevision(idAudio, revisionNumber: 0, revisionFixture(id: ULID.make(), text: "first"))
        try writeCanonicalRevision(idAudio, revisionNumber: 1, revisionFixture(id: ULID.make(), text: "second"))
        try writeOwnMarkers(idAudio)
        try writeForeignMarkers(idAudio, foreignDeviceID: foreignDeviceID)
        try writeLiveLog(idAudio)
        try writeEntryLog(idAudio)
        try writeImage(idAudio, imageID: imageID, includeThumbnail: true)
        try writeSegmentJunk(idAudio)
        try writeHeadJSON(idAudio)

        // Capture with no final audio and a garbage entry.json.
        try writeManifest(idNoAudio, verifiedAt: nil)
        try writeGarbageEntryMetadata(id: idNoAudio)

        let journal = Journal(id: ULID.make(), name: "1987 Journal",
                              createdAt: Date(timeIntervalSince1970: 1_700_000_002))
        try writeJournals([journal])
        try writeCover(journalID: journal.id, bytes: Data(repeating: 0x42, count: 8))

        return Fixture(idAudio: idAudio, idNoAudio: idNoAudio, imageID: imageID,
                       foreignDeviceID: foreignDeviceID, journal: journal)
    }

    // MARK: Step 1 — the exact expected file list, captureIDs, journalIDs

    func testFullFixtureListsExpectedFilesCaptureIDsAndJournalIDs() throws {
        let fixture = try buildFullFixture()
        let result = try ArchiveWalker.list(containerRoot: containerRoot)

        let audioBlock = [
            "entries/\(fixture.idAudio)/audio.m4a",
            "entries/\(fixture.idAudio)/capture.json",
            "entries/\(fixture.idAudio)/entry-log.jsonl",
            "entries/\(fixture.idAudio)/images/\(fixture.imageID).jpg",
            "entries/\(fixture.idAudio)/images/\(fixture.imageID).json",
            "entries/\(fixture.idAudio)/live.jsonl",
            "entries/\(fixture.idAudio)/markers/markers-\(fixture.foreignDeviceID).jsonl",
            "entries/\(fixture.idAudio)/markers/markers.jsonl",
            "entries/\(fixture.idAudio)/revisions/canonical-0.json",
            "entries/\(fixture.idAudio)/revisions/canonical-1.json",
        ]
        let noAudioBlock = [
            "entries/\(fixture.idNoAudio)/capture.json",
            "entries/\(fixture.idNoAudio)/entry.json",
        ]
        // Both ids are 26-char ULIDs of equal length, so whichever sorts first owns its
        // ENTIRE "entries/<id>/…" block — no interleaving between the two captures'
        // files is possible. Resolved at runtime since the ids are minted, not literal.
        let entriesBlock = fixture.idAudio < fixture.idNoAudio ? audioBlock + noAudioBlock : noAudioBlock + audioBlock
        let expected = entriesBlock + [
            "journals.json",
            "journals/\(fixture.journal.id)/cover.jpg",
        ]

        XCTAssertEqual(result.files.map(\.relativePath), expected)
        XCTAssertEqual(result.captureIDs, [fixture.idAudio, fixture.idNoAudio].sorted())
        XCTAssertEqual(result.journalIDs, [fixture.journal.id])
    }

    // MARK: Warnings on the second capture

    func testWarningsForNoFinalAudioAndUnreadableSidecar() throws {
        let fixture = try buildFullFixture()
        let result = try ArchiveWalker.list(containerRoot: containerRoot)

        XCTAssertTrue(result.warnings.contains("entries/\(fixture.idNoAudio): no final audio"))
        XCTAssertTrue(result.warnings.contains("entries/\(fixture.idNoAudio): sidecar unreadable"))
        // The capture WITH audio and a valid (absent) sidecar gets neither warning.
        XCTAssertFalse(result.warnings.contains("entries/\(fixture.idAudio): no final audio"))
        XCTAssertFalse(result.warnings.contains("entries/\(fixture.idAudio): sidecar unreadable"))
    }

    // MARK: segments/, head.json, thumbnails are never listed

    func testExcludesSegmentsHeadJsonAndImageThumbnails() throws {
        let fixture = try buildFullFixture()
        let result = try ArchiveWalker.list(containerRoot: containerRoot)
        let paths = result.files.map(\.relativePath)

        XCTAssertFalse(paths.contains { $0.contains("segments/") })
        XCTAssertFalse(paths.contains { $0.hasSuffix("head.json") })
        XCTAssertFalse(paths.contains { $0.contains("thumbnails/") })
    }

    // MARK: A stray non-ULID directory under captures/

    func testStrayNonWellFormedULIDDirectoryProducesWarningAndNoFiles() throws {
        let strayName = "not-a-ulid-at-all"
        let strayDir = capturesRoot.appendingPathComponent(strayName, isDirectory: true)
        try FileManager.default.createDirectory(at: strayDir, withIntermediateDirectories: true)
        // Manifest-shaped content, so a bug that skipped the ULID check would otherwise
        // happily scan it as a real capture.
        var m = Manifest(captureID: strayName, createdAt: Date(timeIntervalSince1970: 1_700_000_030),
                         state: .complete, stateSeq: 1,
                         stateUpdatedAt: Date(timeIntervalSince1970: 1_700_000_030), format: format)
        m.final = FinalRef(path: "final/recording.m4a", verifiedAt: Date(timeIntervalSince1970: 1_700_000_030),
                           durationFrames: 48_000)
        try CaptureCoding.encoder().encode(m).write(to: strayDir.appendingPathComponent("manifest.json"))

        let result = try ArchiveWalker.list(containerRoot: containerRoot)

        XCTAssertTrue(result.warnings.contains { $0.contains(strayName) })
        XCTAssertTrue(result.files.isEmpty)
        XCTAssertTrue(result.captureIDs.isEmpty)
    }

    // MARK: draft.json is included under revisions/ when present

    func testDraftJSONIsIncludedUnderRevisions() throws {
        let id = ULID.make()
        try writeManifest(id, verifiedAt: Date(timeIntervalSince1970: 1_700_000_040))
        try writeFinalM4A(id)
        try writeDraft(id)

        let result = try ArchiveWalker.list(containerRoot: containerRoot)

        XCTAssertTrue(result.files.contains { $0.relativePath == "entries/\(id)/revisions/draft.json" })
    }

    // MARK: Journals — cover is optional per journal

    func testJournalWithoutCoverListsTheJournalButNoCoverFile() throws {
        let journal = Journal(id: ULID.make(), name: "No Cover Yet",
                              createdAt: Date(timeIntervalSince1970: 1_700_000_050))
        try writeJournals([journal])
        // No cover written.

        let result = try ArchiveWalker.list(containerRoot: containerRoot)

        XCTAssertEqual(result.journalIDs, [journal.id])
        XCTAssertFalse(result.files.contains { $0.relativePath.hasSuffix("cover.jpg") })
        XCTAssertEqual(result.files.map(\.relativePath), ["journals.json"])
    }

    // MARK: No journals.json at all

    func testNoJournalsFileProducesEmptyJournalListAndNoWarning() throws {
        let result = try ArchiveWalker.list(containerRoot: containerRoot)

        XCTAssertTrue(result.journalIDs.isEmpty)
        XCTAssertTrue(result.files.isEmpty)
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertTrue(result.captureIDs.isEmpty)
    }
}
