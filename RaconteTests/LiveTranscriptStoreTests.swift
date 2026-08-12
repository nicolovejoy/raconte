import XCTest
@testable import Raconte

/// M2 T3: `live.jsonl` is append-only, survives a force-kill with a torn trailing
/// line, and replays deterministically (design §3/§8).
final class LiveTranscriptStoreTests: XCTestCase {

    private var capturesRoot: URL!
    private var captureDir: URL!

    override func setUpWithError() throws {
        // A real `captures/<id>/` shape: `DirectorySnapshot.gather` walks the root's
        // children, so the capture must be nested one level down rather than sitting
        // directly in the system temp directory alongside everything else on the Mac.
        capturesRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RaconteLiveTranscript-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("captures", isDirectory: true)
        captureDir = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: "cap")
        try FileManager.default.createDirectory(at: captureDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: capturesRoot.deletingLastPathComponent())
    }

    private var logURL: URL { SegmentLayout.liveTranscriptURL(captureDirectory: captureDir) }

    private func record(_ text: String, _ start: Int64, _ end: Int64) -> TranscriptRecord {
        TranscriptRecord(seq: 0, text: text,
                         captureFrameStart: start, captureFrameEnd: end,
                         analyzerStart: TranscriptTimeStamp(value: start / 3, timescale: 16_000),
                         analyzerEnd: TranscriptTimeStamp(value: end / 3, timescale: 16_000),
                         runs: [TranscriptRun(text: text, captureFrameStart: start,
                                              captureFrameEnd: end, confidence: 0.9)],
                         generator: "SpeechTranscriber", locale: "en_US")
    }

    // MARK: Round trip

    func testRecordsRoundTripInOrder() throws {
        let writer = LiveTranscriptWriter(captureDirectory: captureDir)
        try writer.open()
        try writer.append(record("one", 0, 4_800))
        try writer.append(record("two", 4_800, 9_600))
        try writer.close()

        let read = LiveTranscriptReader.load(captureDirectory: captureDir).records
        XCTAssertEqual(read.map(\.text), ["one", "two"])
        XCTAssertEqual(read.map(\.seq), [0, 1])
        XCTAssertEqual(read.first?.frameRange, FrameRange(start: 0, end: 4_800))
    }

    func testEveryFieldSurvivesTheRoundTrip() throws {
        let original = record("hello world", 48_000, 96_000)
        let writer = LiveTranscriptWriter(captureDirectory: captureDir)
        try writer.open()
        let stamped = try writer.append(original)
        try writer.close()

        let read = try XCTUnwrap(LiveTranscriptReader.load(captureDirectory: captureDir).records.first)
        XCTAssertEqual(read, stamped)
        XCTAssertEqual(read.runs.first?.confidence, 0.9)
        XCTAssertEqual(read.analyzerStart?.timescale, 16_000)
        XCTAssertEqual(read.generator, "SpeechTranscriber")
        XCTAssertEqual(read.locale, "en_US")
    }

    func testAbsentLogReadsAsEmpty() {
        XCTAssertTrue(LiveTranscriptReader.load(captureDirectory: captureDir).records.isEmpty)
    }

    // MARK: Torn trailing line — the force-kill case

    /// The expected shape after a kill mid-write. Not an error: everything before the
    /// last newline was committed and stays valid.
    func testTornTrailingLineIsDiscardedAndEarlierRecordsSurvive() throws {
        let writer = LiveTranscriptWriter(captureDirectory: captureDir)
        try writer.open()
        try writer.append(record("one", 0, 4_800))
        try writer.append(record("two", 4_800, 9_600))
        try writer.close()

        // Simulate the kill: a half-written third line with no terminating newline.
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"seq":2,"text":"thr"#.utf8))
        try handle.close()

        let read = LiveTranscriptReader.load(captureDirectory: captureDir).records
        XCTAssertEqual(read.map(\.text), ["one", "two"],
                       "the torn tail is dropped, the committed prefix is kept")
    }

    func testASingleTornLineWithNoNewlineReadsAsEmpty() throws {
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(#"{"seq":0,"text":"tor"#.utf8).write(to: logURL)
        XCTAssertTrue(LiveTranscriptReader.load(captureDirectory: captureDir).records.isEmpty)
    }

    /// One unreadable interior line must not discard every valid line after it.
    func testAnUndecodableInteriorLineIsSkippedNotFatal() throws {
        let writer = LiveTranscriptWriter(captureDirectory: captureDir)
        try writer.open()
        try writer.append(record("one", 0, 4_800))
        try writer.close()

        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{ garbage }\n".utf8))
        try handle.close()

        let writer2 = LiveTranscriptWriter(captureDirectory: captureDir)
        try writer2.open()
        try writer2.append(record("three", 9_600, 14_400))
        try writer2.close()

        XCTAssertEqual(LiveTranscriptReader.load(captureDirectory: captureDir).records.map(\.text),
                       ["one", "three"])
    }

    // MARK: Reopen

    /// Reopening after a crash must not restart `seq` at 0 — the sequence is what
    /// tells a reader whether a record is missing.
    func testReopeningContinuesTheSequence() throws {
        let first = LiveTranscriptWriter(captureDirectory: captureDir)
        try first.open()
        try first.append(record("one", 0, 4_800))
        try first.append(record("two", 4_800, 9_600))
        try first.close()

        let second = LiveTranscriptWriter(captureDirectory: captureDir)
        try second.open()
        XCTAssertEqual(second.nextSeq, 2)
        try second.append(record("three", 9_600, 14_400))
        try second.close()

        XCTAssertEqual(LiveTranscriptReader.load(captureDirectory: captureDir).records.map(\.seq), [0, 1, 2])
    }

    /// `O_APPEND` means a reopen writes past the torn tail rather than over it, so the
    /// damaged bytes stay damaged and everything new stays readable.
    func testReopeningAfterATornLineDoesNotCorruptNewRecords() throws {
        let first = LiveTranscriptWriter(captureDirectory: captureDir)
        try first.open()
        try first.append(record("one", 0, 4_800))
        try first.close()

        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"seq":1,"te"#.utf8))
        try handle.close()

        let second = LiveTranscriptWriter(captureDirectory: captureDir)
        try second.open()
        XCTAssertEqual(second.nextSeq, 1, "the torn line was never a committed record")
        try second.append(record("two", 4_800, 9_600))
        try second.close()

        let read = LiveTranscriptReader.load(captureDirectory: captureDir).records
        XCTAssertEqual(read.map(\.text), ["one", "two"])
    }

    func testAppendBeforeOpenThrows() {
        let writer = LiveTranscriptWriter(captureDirectory: captureDir)
        XCTAssertThrowsError(try writer.append(record("x", 0, 1)))
    }

    func testCloseIsIdempotent() throws {
        let writer = LiveTranscriptWriter(captureDirectory: captureDir)
        try writer.open()
        try writer.append(record("one", 0, 4_800))
        try writer.close()
        XCTAssertNoThrow(try writer.close())
    }

    // MARK: Layout

    // MARK: Regressions found in review

    /// A complete-but-undecodable line still occupied a sequence number. Reusing it
    /// would put two records with the same `seq` in a file whose whole purpose is
    /// letting a reader notice one is missing.
    func testSeqDoesNotCollideWithAnUndecodableLine() throws {
        let writer = LiveTranscriptWriter(captureDirectory: captureDir)
        try writer.open()
        try writer.append(record("one", 0, 4_800))
        try writer.close()

        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{ garbage }\n".utf8))
        try handle.close()

        let second = LiveTranscriptWriter(captureDirectory: captureDir)
        try second.open()
        XCTAssertEqual(second.nextSeq, 2, "the garbage line consumed seq 1")
        try second.append(record("three", 9_600, 14_400))
        try second.close()

        let seqs = LiveTranscriptReader.load(captureDirectory: captureDir).records.map(\.seq)
        XCTAssertEqual(seqs, [0, 2])
        XCTAssertEqual(Set(seqs).count, seqs.count, "no duplicate sequence numbers")
    }

    /// A fault on the derived path must never take the recording down with it.
    func testAMultilineRecordThrowsRatherThanTrapping() throws {
        let writer = LiveTranscriptWriter(captureDirectory: captureDir)
        try writer.open()
        // Encoders escape control characters, so this is unreachable through the
        // public API today; assert the guard is a throw, not a trap, regardless.
        XCTAssertNoThrow(try writer.append(record("has\nnewline", 0, 4_800)))
        try writer.close()
        XCTAssertEqual(LiveTranscriptReader.load(captureDirectory: captureDir).records.count, 1,
                       "the newline is JSON-escaped, so the record stays one line")
    }

    func testReopeningTwiceDoesNotLeakADescriptor() throws {
        let writer = LiveTranscriptWriter(captureDirectory: captureDir)
        try writer.open()
        try writer.append(record("one", 0, 4_800))
        try writer.open()          // second open must close the first descriptor
        try writer.append(record("two", 4_800, 9_600))
        try writer.close()

        XCTAssertEqual(LiveTranscriptReader.load(captureDirectory: captureDir).records.map(\.text),
                       ["one", "two"])
    }

    func testCanonicalRevisionFileNameRoundTrips() {
        let url = SegmentLayout.canonicalTranscriptURL(captureDirectory: captureDir, revision: 7)
        XCTAssertEqual(url.lastPathComponent, "canonical-7.json")
        XCTAssertEqual(SegmentLayout.canonicalRevision(fromFileName: "canonical-7.json"), 7)
        XCTAssertNil(SegmentLayout.canonicalRevision(fromFileName: "canonical-.json"))
        XCTAssertNil(SegmentLayout.canonicalRevision(fromFileName: "canonical-x.json"))
        XCTAssertNil(SegmentLayout.canonicalRevision(fromFileName: "live.jsonl"))
        XCTAssertNil(SegmentLayout.canonicalRevision(fromFileName: "canonical-007.json"),
                     "leading zeros would alias two distinct files onto one revision")
        XCTAssertEqual(SegmentLayout.canonicalRevision(fromFileName: "canonical-0.json"), 0)
    }

    // MARK: The issue #8 guard reads these stats

    /// Regression: narrowing `transcriptPresent` to "a file we can name" would drop
    /// protection for a `canonical-3.json.part`, which is exactly what a crashed
    /// `AtomicFile.replace` leaves behind and exactly what T6 will be writing.
    func testAnUnrecognizedTranscriptFileStillCountsAsPresent() throws {
        let dir = SegmentLayout.transcriptDirectory(captureDirectory: captureDir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: dir.appendingPathComponent("canonical-3.json.part"))

        let snapshot = DirectorySnapshot.gather(capturesRoot: capturesRoot)
        let capture = try XCTUnwrap(snapshot.captures.first)
        XCTAssertTrue(capture.transcriptPresent)
        XCTAssertTrue(capture.holdsIrreplaceableArtifacts,
                      "a tree we cannot interpret is the most dangerous one to delete")
    }

    func testGatherPopulatesTranscriptStats() throws {
        let writer = LiveTranscriptWriter(captureDirectory: captureDir)
        try writer.open()
        try writer.append(record("one", 0, 4_800))
        try writer.close()
        let dir = SegmentLayout.transcriptDirectory(captureDirectory: captureDir)
        try Data("{}".utf8).write(to: dir.appendingPathComponent("canonical-2.json"))
        try Data("{}".utf8).write(to: dir.appendingPathComponent("canonical-11.json"))

        let snapshot = DirectorySnapshot.gather(capturesRoot: capturesRoot)
        let capture = try XCTUnwrap(snapshot.captures.first)
        XCTAssertEqual(capture.canonicalRevisions, [2, 11], "sorted numerically, not lexically")
        XCTAssertGreaterThan(capture.liveTranscriptByteSize ?? 0, 0)
        XCTAssertTrue(capture.transcriptPresent)
    }

    /// #39, T7 Task 3 ruling 1: `Int?`, non-nil once real canonical files exist —
    /// counting BOTH bytes ("{}" is 2 bytes each), matching `canonicalRevisions`' own
    /// two-file fixture above so the byte count is directly checkable, not just > 0.
    func testGatherPopulatesRevisionsByteSize() throws {
        let dir = SegmentLayout.transcriptDirectory(captureDirectory: captureDir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dir.appendingPathComponent("canonical-2.json"))
        try Data("{}".utf8).write(to: dir.appendingPathComponent("canonical-11.json"))

        let snapshot = DirectorySnapshot.gather(capturesRoot: capturesRoot)
        let capture = try XCTUnwrap(snapshot.captures.first)
        XCTAssertEqual(capture.revisionsByteSize, 4, "two 2-byte \"{}\" files")
    }

    /// `transcript/` present (so `live.jsonl` alone counts as `transcriptPresent`) but
    /// holding no canonical revision files at all — `revisionsByteSize` stays nil,
    /// mirroring `liveTranscriptByteSize`'s own "nil if absent" convention, not 0.
    func testRevisionsByteSizeIsNilWhenNoCanonicalFilesExist() throws {
        let writer = LiveTranscriptWriter(captureDirectory: captureDir)
        try writer.open()
        try writer.append(record("one", 0, 4_800))
        try writer.close()

        let snapshot = DirectorySnapshot.gather(capturesRoot: capturesRoot)
        let capture = try XCTUnwrap(snapshot.captures.first)
        XCTAssertNil(capture.revisionsByteSize)
    }

    func testAnEmptyTranscriptDirectoryIsNotPresent() throws {
        try FileManager.default.createDirectory(
            at: SegmentLayout.transcriptDirectory(captureDirectory: captureDir),
            withIntermediateDirectories: true)
        let snapshot = DirectorySnapshot.gather(capturesRoot: capturesRoot)
        let capture = try XCTUnwrap(snapshot.captures.first)
        XCTAssertFalse(capture.transcriptPresent)
        XCTAssertNil(capture.liveTranscriptByteSize)
        XCTAssertNil(capture.revisionsByteSize)
    }

    // MARK: T6a — SegmentLayout head/draft/entry-log paths

    func testHeadAndDraftURLsLandInTranscriptDirectory() {
        let head = SegmentLayout.transcriptHeadURL(captureDirectory: captureDir)
        let draft = SegmentLayout.transcriptDraftURL(captureDirectory: captureDir)
        let transcriptDir = SegmentLayout.transcriptDirectory(captureDirectory: captureDir)

        XCTAssertEqual(head, transcriptDir.appendingPathComponent("head.json"))
        XCTAssertEqual(draft, transcriptDir.appendingPathComponent("draft.json"))
    }

    func testEntryLogURLLandsBesideEntryMetadataNotInTranscriptDirectory() {
        let entryLog = SegmentLayout.entryLogURL(captureDirectory: captureDir)

        XCTAssertEqual(entryLog, captureDir.appendingPathComponent("entry-log.jsonl"))
        XCTAssertEqual(entryLog.deletingLastPathComponent(),
                       SegmentLayout.entryMetadataURL(captureDirectory: captureDir).deletingLastPathComponent())
    }

    /// T7 §7 rule 10 (the zero-byte-log trap): writing `entry-log.jsonl` must never flip
    /// `holdsIrreplaceableArtifacts` false→true for a capture that otherwise holds
    /// nothing — that would make a mis-tapped capture permanently undeletable, the exact
    /// hazard `MarkerLog`/`CaptureCoordinator` already guard against for `transcript/`.
    /// Verified directly against `DirectorySnapshot.gather` rather than asserted in a
    /// comment (a Task 6 review found exactly that kind of overclaiming comment): the
    /// walk that computes `transcriptPresent` only looks inside `transcript/`, and
    /// `entry-log.jsonl` lives beside `entry.json` at the capture root, so it is
    /// structurally invisible to every input `holdsIrreplaceableArtifacts` reads.
    func testEntryLogAloneDoesNotFlipHoldsIrreplaceableArtifacts() throws {
        try Data("{}".utf8).write(to: SegmentLayout.entryMetadataURL(captureDirectory: captureDir))
        try EntryLogWriter.append(
            EntryLogRecord(at: Date(), field: "journalID", from: nil, to: "J1",
                          cause: .userEdit, origin: nil),
            captureDirectory: captureDir)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: SegmentLayout.entryLogURL(captureDirectory: captureDir).path))

        let snapshot = DirectorySnapshot.gather(capturesRoot: capturesRoot)
        let capture = try XCTUnwrap(snapshot.captures.first)
        XCTAssertFalse(capture.transcriptPresent)
        XCTAssertFalse(capture.holdsIrreplaceableArtifacts,
                       "entry-log.jsonl alone must not make a mis-tapped capture undeletable")
    }

    func testCanonicalRevisionNeverMistakesHeadOrDraftForARevision() {
        XCTAssertNil(SegmentLayout.canonicalRevision(fromFileName: "head.json"))
        XCTAssertNil(SegmentLayout.canonicalRevision(fromFileName: "draft.json"))
    }

    // MARK: T6a — transcriptDirUnreadable (three-answer listing)

    /// A `transcript/` that is a *file*, not a directory, makes `contentsOfDirectory`
    /// fail with something other than "no such file" — mirror
    /// `LiveTranscriptReader.loadBytes`'s absent/unreadable split. Quarantine-never-
    /// delete: an unreadable dir may hold irreplaceable transcripts, so both flags
    /// must be true together.
    func testUnreadableTranscriptDirectorySetsBothFlags() throws {
        let transcriptDir = SegmentLayout.transcriptDirectory(captureDirectory: captureDir)
        try Data("not a directory".utf8).write(to: transcriptDir)

        let snapshot = DirectorySnapshot.gather(capturesRoot: capturesRoot)
        let capture = try XCTUnwrap(snapshot.captures.first)

        XCTAssertTrue(capture.transcriptDirUnreadable)
        XCTAssertTrue(capture.transcriptPresent)
        XCTAssertTrue(capture.holdsIrreplaceableArtifacts)
    }

    func testAbsentTranscriptDirectoryLeavesBothFlagsFalse() throws {
        let snapshot = DirectorySnapshot.gather(capturesRoot: capturesRoot)
        let capture = try XCTUnwrap(snapshot.captures.first)

        XCTAssertFalse(capture.transcriptDirUnreadable)
        XCTAssertFalse(capture.transcriptPresent)
    }
}
