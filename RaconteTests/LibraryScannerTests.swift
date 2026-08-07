import XCTest
@testable import Raconte

/// M3 T2, disk half: the scan over `captures/` — what it lists, what it degrades, what
/// it skips, and where the journals registry does *not* live.
final class LibraryScannerTests: XCTestCase {

    private var containerRoot: URL!
    private var capturesRoot: URL { AppContainer.capturesRoot(containerRoot: containerRoot) }

    /// Real ULIDs: the scan reads its date fallback out of the id, so a placeholder
    /// string would exercise a path the app never takes.
    private let idA = "01AAAAAAAAAAAAAAAAAAAAAAAA"     // 2016-ish prefix
    private let idB = "01BBBBBBBBBBBBBBBBBBBBBBBB"

    override func setUpWithError() throws {
        containerRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RaconteLibrary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: capturesRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: containerRoot)
    }

    // MARK: Fixtures

    private let format = AudioFormatDescriptor(
        sampleRate: 48_000, channels: 1, commonFormat: .pcmFormatFloat32,
        interleaved: false, bytesPerFrame: 4)

    private func captureDir(_ id: String) -> URL {
        SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: id)
    }

    private func scanner() -> LibraryScanner {
        LibraryScanner(capturesRoot: capturesRoot, containerRoot: containerRoot)
    }

    /// The single-row case, which most of these tests are. Hoisted out of the assertion
    /// because an `await` inside an `XCTAssert` autoclosure does not compile.
    private func firstItem(filter: EntryListFilter = .default) async throws -> EntryListItem {
        let result = await scanner().scan(filter: filter)
        return try XCTUnwrap(result.items.first)
    }

    /// One finalized segment of `frames` frames of silence.
    private func writeSegment(_ id: String, frames: Int = 48_000) throws {
        let segs = SegmentLayout.segmentsDirectory(captureDirectory: captureDir(id))
        try FileManager.default.createDirectory(at: segs, withIntermediateDirectories: true)
        try Data(count: frames * 4).write(to: SegmentLayout.pcmURL(segmentsDirectory: segs, index: 0))
    }

    private func manifest(_ id: String,
                          createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
                          state: CaptureState = .captured,
                          durationFrames: Int? = nil,
                          transcript: TranscriptRef? = nil) -> Manifest {
        var m = Manifest(captureID: id, createdAt: createdAt, state: state,
                         stateSeq: 1, stateUpdatedAt: createdAt, format: format)
        m.final = FinalRef(path: "final/recording.m4a",
                           verifiedAt: durationFrames == nil ? nil : createdAt,
                           durationFrames: durationFrames)
        m.transcript = transcript
        return m
    }

    private func write(_ manifest: Manifest, id: String) throws {
        try FileManager.default.createDirectory(at: captureDir(id), withIntermediateDirectories: true)
        try CaptureCoding.encoder().encode(manifest)
            .write(to: SegmentLayout.manifestURL(captureDirectory: captureDir(id)))
    }

    private func writeRawManifest(_ json: String, id: String) throws {
        try FileManager.default.createDirectory(at: captureDir(id), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: SegmentLayout.manifestURL(captureDirectory: captureDir(id)))
    }

    private func writeMetadata(_ metadata: EntryMetadata, id: String) throws {
        try EntryMetadataStore.write(metadata,
                                     url: SegmentLayout.entryMetadataURL(captureDirectory: captureDir(id)))
    }

    private func writeRawMetadata(_ json: String, id: String) throws -> URL {
        let url = SegmentLayout.entryMetadataURL(captureDirectory: captureDir(id))
        try FileManager.default.createDirectory(at: captureDir(id), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
        return url
    }

    private func writeFinalM4A(_ id: String) throws {
        let dir = SegmentLayout.finalDirectory(captureDirectory: captureDir(id))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: 4_096)
            .write(to: SegmentLayout.finalRecordingURL(captureDirectory: captureDir(id)))
    }

    @discardableResult
    private func writeTranscript(_ id: String, _ results: [(String, Int64, Int64)]) throws -> URL {
        let writer = LiveTranscriptWriter(captureDirectory: captureDir(id))
        try writer.open()
        for (text, start, end) in results {
            try writer.append(TranscriptRecord(seq: 0, text: text,
                                               captureFrameStart: start, captureFrameEnd: end,
                                               generator: "SpeechTranscriber", locale: "en_US"))
        }
        try writer.close()
        return SegmentLayout.liveTranscriptURL(captureDirectory: captureDir(id))
    }

    private func writeJournals(_ journals: [Journal]) throws {
        try JournalStore.encode(JournalRegistry(journals: journals))
            .write(to: AppContainer.journalsURL(containerRoot: containerRoot))
    }

    // MARK: Enumeration

    func testEmptyTreeScansToAnEmptyLibrary() async throws {
        let result = await scanner().scan()
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertTrue(result.skipped.isEmpty)
        XCTAssertFalse(result.journalsUnreadable)
    }

    func testMissingCapturesRootIsNotAFailure() async throws {
        try FileManager.default.removeItem(at: capturesRoot)
        let result = await scanner().scan()
        XCTAssertTrue(result.items.isEmpty)
    }

    /// The registry is a sibling of `captures/`, not a child, so the walk never sees it.
    /// Pinned by T1 at the path level; pinned here at the behavioural level — a
    /// `journals.json` inside `captures/` would show up as a row (or a skip) named
    /// "journals.json".
    func testJournalsRegistryIsNotEnumeratedAsACapture() async throws {
        try writeJournals([Journal(id: "J1", name: "1987", createdAt: Date(timeIntervalSince1970: 0))])
        try writeSegment(idA)
        try write(manifest(idA), id: idA)

        let result = await scanner().scan()
        XCTAssertEqual(result.items.map(\.captureID), [idA])
        XCTAssertTrue(result.skipped.isEmpty)
        XCTAssertFalse(AppContainer.journalsURL(containerRoot: containerRoot).path
            .hasPrefix(capturesRoot.path))
    }

    /// A loose file dropped into `captures/` is not a directory and is ignored outright
    /// by the gather — it is not even worth a skip record.
    func testNonDirectoryChildOfCapturesIsIgnored() async throws {
        try Data("junk".utf8).write(to: capturesRoot.appendingPathComponent("stray.txt"))
        try writeSegment(idA)
        let result = await scanner().scan()
        XCTAssertEqual(result.items.map(\.captureID), [idA])
        XCTAssertTrue(result.skipped.isEmpty)
    }

    /// A directory with no audio, no `.m4a` and no transcript is the mis-tap recovery
    /// deletes. It is skipped *with a reason*, never silently.
    func testEmptyCaptureDirectoryIsSkippedWithAReason() async throws {
        try FileManager.default.createDirectory(at: captureDir(idA), withIntermediateDirectories: true)
        let result = await scanner().scan()
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertEqual(result.skipped, [SkippedCapture(captureID: idA, reason: .noDurableContent)])
    }

    /// The inverse, and the reason the skip test above is narrow: a transcript with no
    /// audio left is still something on disk and still gets a row.
    func testTranscriptOnlyDirectoryIsListedNotSkipped() async throws {
        try writeTranscript(idA, [("orphaned words", 0, 4_800)])
        let result = await scanner().scan()
        XCTAssertEqual(result.items.map(\.captureID), [idA])
        XCTAssertEqual(result.items.first?.snippet, "orphaned words")
    }

    // MARK: Degraded manifests

    func testMissingManifestStillProducesARowDatedFromTheULID() async throws {
        try writeSegment(idA, frames: 96_000)
        let result = await scanner().scan()
        let item = try XCTUnwrap(result.items.first)
        XCTAssertTrue(item.degradations.contains(.manifestAbsent))
        XCTAssertFalse(item.degradations.contains(.manifestCorrupt))
        XCTAssertEqual(item.capturedAt, ULID.timestamp(from: idA))
        XCTAssertEqual(item.durationSeconds, 2, accuracy: 0.0001)
    }

    /// Recovery treats a corrupt manifest as "unknown state, trust the files". So does
    /// the library: the entry is the thing the owner needs to find, and hiding it because
    /// its metadata is damaged is exactly issue #8's mistake in a read path.
    func testCorruptManifestDegradesTheRowRatherThanDroppingIt() async throws {
        try writeSegment(idA)
        try writeRawManifest("{ not json at all", id: idA)
        let result = await scanner().scan()
        let item = try XCTUnwrap(result.items.first)
        XCTAssertEqual(item.captureID, idA)
        XCTAssertTrue(item.degradations.contains(.manifestCorrupt))
        XCTAssertEqual(item.capturedAt, ULID.timestamp(from: idA), "falls back to the id's own clock")
        XCTAssertEqual(item.durationSeconds, 1, accuracy: 0.0001)
    }

    func testIntactManifestSuppliesCapturedAt() async throws {
        let created = Date(timeIntervalSince1970: 1_600_000_000.5)
        try writeSegment(idA)
        try write(manifest(idA, createdAt: created), id: idA)
        let item = try await firstItem()
        XCTAssertEqual(item.capturedAt, created)
        XCTAssertTrue(item.degradations.isEmpty)
    }

    // MARK: Duration

    /// After finalize the segments are gone, so the manifest's frame count is the only
    /// duration left. No audio file is opened either way.
    func testFinalizedCaptureTakesItsDurationFromTheManifest() async throws {
        try writeFinalM4A(idA)
        try write(manifest(idA, durationFrames: 240_000), id: idA)
        let item = try await firstItem()
        XCTAssertEqual(item.durationSeconds, 5, accuracy: 0.0001)
    }

    func testRawSegmentsSumTheirFrameCounts() async throws {
        let segs = SegmentLayout.segmentsDirectory(captureDirectory: captureDir(idA))
        try FileManager.default.createDirectory(at: segs, withIntermediateDirectories: true)
        try Data(count: 48_000 * 4).write(to: SegmentLayout.pcmURL(segmentsDirectory: segs, index: 0))
        try Data(count: 24_000 * 4).write(to: SegmentLayout.pcmURL(segmentsDirectory: segs, index: 1))
        try write(manifest(idA), id: idA)
        let item = try await firstItem()
        XCTAssertEqual(item.durationSeconds, 1.5, accuracy: 0.0001)
    }

    // MARK: entry.json

    func testSidecarSuppliesJournalBackdateAndTrashState() async throws {
        let backdate = PartialDate(year: 1986, month: 11, day: 6)
        try writeSegment(idA)
        try write(manifest(idA), id: idA)
        try writeMetadata(EntryMetadata(journalID: "J1", originalDate: backdate), id: idA)
        try writeJournals([Journal(id: "J1", name: "1987 Journal",
                                   createdAt: Date(timeIntervalSince1970: 0))])

        let item = try await firstItem()
        XCTAssertEqual(item.journalID, "J1")
        XCTAssertEqual(item.journal?.name, "1987 Journal")
        XCTAssertEqual(item.originalDate, backdate)
        XCTAssertEqual(item.effectiveDate, backdate.anchorDate(calendar: .gregorianCurrent))
        XCTAssertFalse(item.isTrashed)
        XCTAssertTrue(item.degradations.isEmpty)
    }

    func testAbsentSidecarIsDefaultsAndNotADegradation() async throws {
        try writeSegment(idA)
        try write(manifest(idA), id: idA)
        let item = try await firstItem()
        XCTAssertNil(item.journalID)
        XCTAssertNil(item.originalDate)
        XCTAssertFalse(item.isTrashed)
        XCTAssertTrue(item.degradations.isEmpty)
    }

    /// A damaged sidecar shows defaults *and says so*. Nothing in this path writes them
    /// back — T5's trash sweep must be able to tell "not trashed" from "we don't know".
    func testUnreadableSidecarDegradesAndStaysVisible() async throws {
        try writeSegment(idA)
        try write(manifest(idA), id: idA)
        _ = try writeRawMetadata(#"{"journalID":5}"#, id: idA)

        let result = await scanner().scan()
        let item = try XCTUnwrap(result.items.first)
        XCTAssertTrue(item.degradations.contains(.metadataUnreadable))
        XCTAssertNil(item.journalID)
        XCTAssertFalse(item.isTrashed, "unknown trash state reads as visible")
    }

    // MARK: issue #25 — a trashed capture is trash, whatever else the directory holds

    /// RED (#25 step 3). A directory holding only `entry.json` with `trashedAt` set —
    /// the mirror-image outcome of the #25 walk, where the tombstone survived a
    /// half-destroyed delete and the audio did not. Today this is skipped as
    /// `noDurableContent` and is invisible in both the library *and* the Trash view.
    func testTrashedCaptureWithNothingDurableIsStillListed() async throws {
        try writeMetadata(EntryMetadata(trashedAt: Date(timeIntervalSince1970: 99)), id: idA)

        let all = await scanner().scan(filter: EntryListFilter(trash: .all))
        XCTAssertEqual(all.items.map(\.captureID), [idA])
        XCTAssertTrue(all.skipped.isEmpty)

        let trashed = await scanner().scan(filter: EntryListFilter(trash: .trashedOnly))
        XCTAssertEqual(trashed.items.map(\.captureID), [idA])
    }

    /// GUARD (#25 step 3). Same fixture as above, through the default (excludeTrashed)
    /// scope. **Mutation:** emit the row unconditionally without the trash filter
    /// applying (e.g. `result.items = items` instead of `filter.apply(to: items)`) ->
    /// must fail. Pins that the rule changes trash membership only, never live
    /// visibility.
    func testTrashedCaptureWithNothingDurableIsNeverInTheLiveList() async throws {
        try writeMetadata(EntryMetadata(trashedAt: Date(timeIntervalSince1970: 99)), id: idA)

        let live = await scanner().scan(filter: EntryListFilter(trash: .excludeTrashed))
        XCTAssertTrue(live.items.isEmpty)
    }

    /// GUARD (#25 step 3). A directory with an undecodable `entry.json` and nothing else
    /// durable: still skipped, still `noDurableContent`. **Mutation:** treat an
    /// unreadable sidecar as trashed in the metadata-read catch block -> must fail. This
    /// is owner answer 5's "never fabricate an answer from a failed read."
    func testUnreadableSidecarWithNothingDurableIsStillSkipped() async throws {
        _ = try writeRawMetadata(#"{"journalID":5}"#, id: idA)

        let result = await scanner().scan(filter: EntryListFilter(trash: .all))
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertEqual(result.skipped, [SkippedCapture(captureID: idA, reason: .noDurableContent)])
    }

    func testTrashedEntryIsHiddenByDefaultAndFoundByTheTrashScope() async throws {
        try writeSegment(idA)
        try write(manifest(idA), id: idA)
        try writeMetadata(EntryMetadata(trashedAt: Date(timeIntervalSince1970: 99)), id: idA)

        let live = await scanner().scan()
        XCTAssertTrue(live.items.isEmpty)
        let trashed = await scanner().scan(filter: EntryListFilter(trash: .trashedOnly))
        XCTAssertEqual(trashed.items.map(\.captureID), [idA])
        XCTAssertTrue(try XCTUnwrap(trashed.items.first).isTrashed)
    }

    // MARK: Journal resolution

    func testDanglingJournalIDResolvesToNilAndIsFlagged() async throws {
        try writeSegment(idA)
        try write(manifest(idA), id: idA)
        try writeMetadata(EntryMetadata(journalID: "GONE"), id: idA)
        try writeJournals([Journal(id: "J1", name: "1987", createdAt: Date(timeIntervalSince1970: 0))])

        let result = await scanner().scan()
        let item = try XCTUnwrap(result.items.first)
        XCTAssertEqual(item.journalID, "GONE", "the raw reference survives so the damage is visible")
        XCTAssertNil(item.journal)
        XCTAssertTrue(item.hasDanglingJournal)
        XCTAssertTrue(item.degradations.contains(.journalUnresolved))
        XCTAssertFalse(result.journalsUnreadable, "the registry was fine; the reference was not")
    }

    /// A registry we merely failed to parse must not read as "you have no journals" —
    /// that is issue #11's rule, and here it would present every filed entry as dangling
    /// with no way to tell why.
    func testUnreadableRegistryIsReportedAtTheScanLevel() async throws {
        try Data("{ not json".utf8)
            .write(to: AppContainer.journalsURL(containerRoot: containerRoot))
        try writeSegment(idA)
        try write(manifest(idA), id: idA)
        try writeMetadata(EntryMetadata(journalID: "J1"), id: idA)

        let result = await scanner().scan()
        XCTAssertTrue(result.journalsUnreadable)
        let item = try XCTUnwrap(result.items.first)
        XCTAssertNil(item.journal)
        XCTAssertEqual(item.journalID, "J1")
        XCTAssertTrue(item.degradations.contains(.journalUnresolved))
    }

    func testAbsentRegistryIsNotUnreadable() async throws {
        try writeSegment(idA)
        let result = await scanner().scan()
        XCTAssertFalse(result.journalsUnreadable)
    }

    // MARK: Transcript

    func testAbsentTranscriptIsAbsent() async throws {
        try writeSegment(idA)
        let item = try await firstItem()
        XCTAssertEqual(item.transcript, .absent)
        XCTAssertNil(item.snippet)
        XCTAssertFalse(item.hasTranscriptText)
    }

    func testSnippetComesFromTheLog() async throws {
        try writeSegment(idA)
        try writeTranscript(idA, [("Hello there", 0, 4_800), ("world", 4_800, 9_600)])
        let item = try await firstItem()
        XCTAssertEqual(item.transcript, .present)
        XCTAssertEqual(item.snippet, "Hello there world")
        XCTAssertTrue(item.hasTranscriptText)
    }

    /// The snippet is the *consolidated* text, not the raw records (issue #10). Read
    /// raw, the revised phrase would appear twice and the revoked one would appear at
    /// all — both visible right there in the library's first line.
    func testSnippetConsolidatesRevisionsAndDeletions() async throws {
        try writeSegment(idA)
        try writeTranscript(idA, [
            ("wrecked a nice beach", 0, 9_600),      // superseded by the correction below
            ("recognize speech", 0, 9_600),
            ("and then some", 9_600, 14_400),
            ("", 9_600, 14_400),                     // an empty final revokes its span
        ])
        let item = try await firstItem()
        XCTAssertEqual(item.snippet, "recognize speech")
    }

    /// A readable log holding nothing is `.present` with no text — distinct from absent,
    /// and distinct from unreadable.
    func testEmptyLogIsPresentWithoutText() async throws {
        try writeSegment(idA)
        try writeTranscript(idA, [])
        let item = try await firstItem()
        XCTAssertEqual(item.transcript, .present)
        XCTAssertNil(item.snippet)
    }

    /// Three answers, not two. "Unreadable" must never render as "no transcript" — the
    /// UI would offer to re-derive over a log that is sitting right there.
    func testUnreadableLogIsNotAbsent() async throws {
        try writeSegment(idA)
        let url = try writeTranscript(idA, [("secret", 0, 4_800)])
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                       ofItemAtPath: url.path) }
        guard !FileManager.default.isReadableFile(atPath: url.path) else {
            throw XCTSkip("running with privileges that ignore file permissions")
        }

        let item = try await firstItem()
        XCTAssertEqual(item.transcript, .unreadable)
        XCTAssertNil(item.snippet)
        XCTAssertTrue(item.degradations.contains(.transcriptUnreadable))
    }

    /// `TranscriptRef.committedRecords` is written only on a clean close, so a log with
    /// fewer lines than it claims lost its tail to a kill.
    func testShortLogAgainstTheManifestRefIsFlaggedTruncated() async throws {
        try writeSegment(idA)
        try writeTranscript(idA, [("one", 0, 4_800)])
        let ref = TranscriptRef(generator: "SpeechTranscriber", locale: "en_US",
                                committedRecords: 3, completedAt: Date(timeIntervalSince1970: 5))
        try write(manifest(idA, transcript: ref), id: idA)

        let item = try await firstItem()
        XCTAssertTrue(item.degradations.contains(.transcriptTruncated))
        XCTAssertEqual(item.snippet, "one", "the surviving text is still real")
    }

    func testCompleteLogIsNotFlaggedTruncated() async throws {
        try writeSegment(idA)
        try writeTranscript(idA, [("one", 0, 4_800)])
        let ref = TranscriptRef(generator: "SpeechTranscriber", locale: "en_US",
                                committedRecords: 1, completedAt: Date(timeIntervalSince1970: 5))
        try write(manifest(idA, transcript: ref), id: idA)
        let item = try await firstItem()
        XCTAssertFalse(item.degradations.contains(.transcriptTruncated))
    }

    // MARK: End to end

    func testBackdatedEntrySortsUnderItsOriginalDate() async throws {
        try writeSegment(idA)
        try write(manifest(idA, createdAt: Date(timeIntervalSince1970: 1_000)), id: idA)
        try writeSegment(idB)
        try write(manifest(idB, createdAt: Date(timeIntervalSince1970: 2_000)), id: idB)
        // B was recorded later but is a reading of a 1987 notebook.
        // A date safely before the epoch — noon-anchoring a same-day `PartialDate` could
        // otherwise land after `idB`'s capture instant (2000s) depending on the local
        // timezone's offset from UTC.
        try writeMetadata(EntryMetadata(originalDate: PartialDate(year: 1969, month: 1, day: 1)), id: idB)

        let result = await scanner().scan()
        XCTAssertEqual(result.items.map(\.captureID), [idA, idB])
    }

    func testJournalFilterAppliesAcrossTheScan() async throws {
        try writeJournals([Journal(id: "J1", name: "1987", createdAt: Date(timeIntervalSince1970: 0))])
        for id in [idA, idB] {
            try writeSegment(id)
            try write(manifest(id), id: id)
        }
        try writeMetadata(EntryMetadata(journalID: "J1"), id: idA)

        let filed = await scanner().scan(filter: EntryListFilter(journal: .journal("J1")))
        XCTAssertEqual(filed.items.map(\.captureID), [idA])
        let unfiled = await scanner().scan(filter: EntryListFilter(journal: .unfiled))
        XCTAssertEqual(unfiled.items.map(\.captureID), [idB])
    }

    /// The scan derives the container root from the captures root, so a caller holding
    /// only `capturesRoot` (everything in M1/M2 does) still finds the registry.
    func testContainerRootIsInferredFromTheCapturesRoot() async throws {
        try writeJournals([Journal(id: "J1", name: "1987", createdAt: Date(timeIntervalSince1970: 0))])
        try writeSegment(idA)
        try writeMetadata(EntryMetadata(journalID: "J1"), id: idA)

        let inferred = LibraryScanner(capturesRoot: capturesRoot)
        let result = await inferred.scan()
        let item = try XCTUnwrap(result.items.first)
        XCTAssertEqual(item.journal?.name, "1987")
    }
}
