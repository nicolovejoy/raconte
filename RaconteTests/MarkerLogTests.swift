import XCTest
@testable import Raconte

/// T6 §14 step 2: `transcript/markers.jsonl` is append-only, survives a force-kill with a
/// torn trailing line, and never renumbers over a log it could not read (design §4/§8).
///
/// Deliberately a structural mirror of `LiveTranscriptStoreTests` — the T3 bugs these
/// cases pin (the `O_APPEND` fuse, the pretty-printed encoder, the unreadable-log
/// renumbering) were all real, and the marker log inherits the same file discipline.
final class MarkerLogTests: XCTestCase {

    private var capturesRoot: URL!
    private var captureDir: URL!

    override func setUpWithError() throws {
        // A real `captures/<id>/` shape: `DirectorySnapshot.gather` walks the root's
        // children, so the capture must be nested one level down rather than sitting
        // directly in the system temp directory alongside everything else on the Mac.
        capturesRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RaconteMarkerLog-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("captures", isDirectory: true)
        captureDir = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: "cap")
        try FileManager.default.createDirectory(at: captureDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: capturesRoot.deletingLastPathComponent())
    }

    private var logURL: URL { SegmentLayout.markerLogURL(captureDirectory: captureDir) }

    private func marker(_ kind: StructureMarker.Kind,
                        _ frame: Int64,
                        voice: String? = nil) -> StructureMarker {
        StructureMarker(seq: 0, frame: frame, kind: kind, voice: voice)
    }

    // MARK: Round trip

    /// Design §4's exact example: a frame-0 `bn` opener, a paragraph, a switch to `ln`.
    func testAppendedMarkersRoundTrip() throws {
        let writer = MarkerLogWriter(captureDirectory: captureDir)
        try writer.open()
        try writer.append(marker(.voice, 0, voice: StructureMarker.Voice.bigNico))
        try writer.append(marker(.paragraph, 812_544))
        try writer.append(marker(.voice, 1_104_128, voice: StructureMarker.Voice.littleNico))
        try writer.close()

        let read = MarkerLogReader.load(captureDirectory: captureDir).markers
        XCTAssertEqual(read.map(\.seq), [0, 1, 2])
        XCTAssertEqual(read.map(\.frame), [0, 812_544, 1_104_128])
        XCTAssertEqual(read.map(\.kind), [.voice, .paragraph, .voice])
        XCTAssertEqual(read.map(\.voice), ["bn", nil, "ln"])
    }

    func testParagraphLineOmitsTheVoiceKey() throws {
        let writer = MarkerLogWriter(captureDirectory: captureDir)
        try writer.open()
        try writer.append(marker(.paragraph, 812_544))
        try writer.close()

        let bytes = try XCTUnwrap(String(data: try Data(contentsOf: logURL), encoding: .utf8))
        XCTAssertFalse(bytes.contains("voice"),
                       "a paragraph line carries no voice key at all — design §4")
        XCTAssertTrue(bytes.contains("\"kind\":\"paragraph\""))
    }

    func testAbsentLogReadsAsEmpty() {
        XCTAssertTrue(MarkerLogReader.load(captureDirectory: captureDir).markers.isEmpty)
    }

    // MARK: Torn trailing line — the force-kill case

    func testTornTrailingLineIsDiscardedAndEarlierMarkersSurvive() throws {
        let writer = MarkerLogWriter(captureDirectory: captureDir)
        try writer.open()
        try writer.append(marker(.voice, 0, voice: "bn"))
        try writer.append(marker(.paragraph, 4_800))
        try writer.close()

        // Simulate the kill: a half-written third line with no terminating newline.
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"seq":2,"frame":96"#.utf8))
        try handle.close()

        let read = MarkerLogReader.load(captureDirectory: captureDir).markers
        XCTAssertEqual(read.map(\.frame), [0, 4_800],
                       "the torn tail is dropped, the committed prefix is kept")
    }

    func testASingleTornLineWithNoNewlineReadsAsEmpty() throws {
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(#"{"seq":0,"frame":1"#.utf8).write(to: logURL)
        XCTAssertTrue(MarkerLogReader.load(captureDirectory: captureDir).markers.isEmpty)
    }

    /// The exact T3 `O_APPEND` bug: without terminating the inherited torn tail, the
    /// first new record lands directly onto it and one undecodable line swallows both.
    func testReopeningAfterATornLineDoesNotCorruptNewMarkers() throws {
        let first = MarkerLogWriter(captureDirectory: captureDir)
        try first.open()
        try first.append(marker(.voice, 0, voice: "bn"))
        try first.close()

        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"seq":1,"fra"#.utf8))
        try handle.close()

        let second = MarkerLogWriter(captureDirectory: captureDir)
        try second.open()
        XCTAssertEqual(second.nextSeq, 1, "the torn line was never a committed record")
        try second.append(marker(.paragraph, 4_800))
        try second.close()

        let read = MarkerLogReader.load(captureDirectory: captureDir).markers
        XCTAssertEqual(read.map(\.frame), [0, 4_800])
        XCTAssertEqual(read.map(\.kind), [.voice, .paragraph])
    }

    /// A complete-but-undecodable line still occupied a sequence number.
    func testSeqDoesNotCollideWithAnUndecodableLine() throws {
        let writer = MarkerLogWriter(captureDirectory: captureDir)
        try writer.open()
        try writer.append(marker(.voice, 0, voice: "bn"))
        try writer.close()

        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{ garbage }\n".utf8))
        try handle.close()

        let second = MarkerLogWriter(captureDirectory: captureDir)
        try second.open()
        XCTAssertEqual(second.nextSeq, 2, "the garbage line consumed seq 1")
        try second.append(marker(.paragraph, 4_800))
        try second.close()

        let seqs = MarkerLogReader.load(captureDirectory: captureDir).markers.map(\.seq)
        XCTAssertEqual(seqs, [0, 2])
        XCTAssertEqual(Set(seqs).count, seqs.count, "no duplicate sequence numbers")
    }

    // MARK: Absent vs unreadable vs present

    /// Refusing to open is the fix for the #11 writer bug: an unreadable log read as
    /// empty restarts `seq` at 0 and appends records colliding with what is already there.
    func testOpenOnAnUnreadableLogThrowsRatherThanRenumbering() throws {
        let first = MarkerLogWriter(captureDirectory: captureDir)
        try first.open()
        try first.append(marker(.voice, 0, voice: "bn"))
        try first.close()

        try FileManager.default.setAttributes([.posixPermissions: 0o000],
                                              ofItemAtPath: logURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                       ofItemAtPath: logURL.path) }
        try XCTSkipIf(FileManager.default.isReadableFile(atPath: logURL.path),
                      "running as root — permissions cannot be made to bite")

        let second = MarkerLogWriter(captureDirectory: captureDir)
        XCTAssertThrowsError(try second.open()) { error in
            guard case MarkerLogError.unreadableExistingLog = error else {
                return XCTFail("expected unreadableExistingLog, got \(error)")
            }
        }
    }

    func testAbsentVsUnreadableVsPresentAreThreeAnswers() throws {
        XCTAssertEqual(MarkerLogReader.load(captureDirectory: captureDir).source, .absent)

        let writer = MarkerLogWriter(captureDirectory: captureDir)
        try writer.open()
        try writer.append(marker(.paragraph, 4_800))
        try writer.close()

        let present = MarkerLogReader.load(captureDirectory: captureDir)
        guard case .present = present.source else {
            return XCTFail("expected .present, got \(present.source)")
        }
        XCTAssertFalse(present.isUnreadable)
        XCTAssertEqual(present.markers.count, 1)

        try FileManager.default.setAttributes([.posixPermissions: 0o000],
                                              ofItemAtPath: logURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                       ofItemAtPath: logURL.path) }
        try XCTSkipIf(FileManager.default.isReadableFile(atPath: logURL.path),
                      "running as root — permissions cannot be made to bite")

        let unreadable = MarkerLogReader.load(captureDirectory: captureDir)
        XCTAssertTrue(unreadable.isUnreadable)
        XCTAssertNotEqual(unreadable.source, .absent,
                          "an unreadable log is not an absent one — issue #11")
        XCTAssertTrue(unreadable.markers.isEmpty,
                      "no fabricated answer from a failed read (design §7)")
    }

    // MARK: Writer discipline

    func testAppendBeforeOpenThrows() {
        let writer = MarkerLogWriter(captureDirectory: captureDir)
        XCTAssertThrowsError(try writer.append(marker(.paragraph, 0)))
    }

    func testCloseIsIdempotent() throws {
        let writer = MarkerLogWriter(captureDirectory: captureDir)
        try writer.open()
        try writer.append(marker(.paragraph, 0))
        try writer.close()
        XCTAssertNoThrow(try writer.close())
    }

    /// JSON encoders escape control characters, so `multilineRecord` is unreachable
    /// through the public API — assert the guard is a throw, not a trap, and that the
    /// line stays one line. The guard still earns its keep: it is what catches an
    /// accidental pretty-printing encoder.
    func testAMultilineVoiceStringIsEscapedNotTorn() throws {
        let writer = MarkerLogWriter(captureDirectory: captureDir)
        try writer.open()
        XCTAssertNoThrow(try writer.append(marker(.voice, 0, voice: "has\nnewline")))
        try writer.close()

        let read = MarkerLogReader.load(captureDirectory: captureDir)
        XCTAssertEqual(read.markers.count, 1,
                       "the newline is JSON-escaped, so the marker stays one line")
        XCTAssertEqual(read.markers.first?.voice, "has\nnewline")
    }

    /// Constructing a writer must touch nothing: a zero-byte log in `transcript/` flips
    /// `holdsIrreplaceableArtifacts`, which would make a mis-tapped capture permanently
    /// undeletable. (The call-site laziness — no `open()` until the first mark — is
    /// step 3's test; this pins the file layer.)
    func testLazyDirectoryCreation() throws {
        let transcriptDir = SegmentLayout.transcriptDirectory(captureDirectory: captureDir)
        let writer = MarkerLogWriter(captureDirectory: captureDir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: transcriptDir.path),
                       "constructing the writer creates nothing on disk")

        try writer.open()
        XCTAssertTrue(FileManager.default.fileExists(atPath: transcriptDir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: logURL.path))
        try writer.close()
    }

    // MARK: Decoding

    /// A kind written by a newer build must survive a read-rewrite cycle on this one.
    /// Reachable the moment M4 syncs.
    func testUnknownKindRoundTripsIntact() throws {
        let line = #"{"frame":10,"kind":"chapter","seq":0}"#
        let decoded = try CaptureCoding.decoder().decode(StructureMarker.self,
                                                         from: Data(line.utf8))
        XCTAssertEqual(decoded.kind, .unknown("chapter"))
        XCTAssertEqual(decoded.frame, 10)

        let reencoded = try CaptureCoding.lineEncoder().encode(decoded)
        let text = try XCTUnwrap(String(data: reencoded, encoding: .utf8))
        XCTAssertTrue(text.contains("\"kind\":\"chapter\""),
                      "the unknown kind is preserved verbatim, not dropped or coerced")
    }

    /// Leniency stops at the identity fields — garbage still fails rather than decoding
    /// into a plausible-looking marker at frame 0.
    func testMissingIdentityFieldThrows() {
        let noFrame = #"{"seq":0,"kind":"paragraph"}"#
        let noKind = #"{"seq":0,"frame":10}"#
        let noSeq = #"{"frame":10,"kind":"paragraph"}"#
        for line in [noFrame, noKind, noSeq] {
            XCTAssertThrowsError(try CaptureCoding.decoder().decode(StructureMarker.self,
                                                                     from: Data(line.utf8)),
                                 "expected \(line) to fail decoding")
        }

        // And the parser counts them as complete lines it could not read, so `nextSeq`
        // still steps past them.
        let data = Data(([noFrame, noKind, noSeq].joined(separator: "\n") + "\n").utf8)
        let parsed = MarkerLogReader.parse(data)
        XCTAssertTrue(parsed.markers.isEmpty)
        XCTAssertEqual(parsed.completeLines, 3)
    }

    func testVoiceMarkerWithoutVoiceStringStillDecodes() throws {
        let missing = #"{"seq":0,"frame":10,"kind":"voice"}"#
        let decoded = try CaptureCoding.decoder().decode(StructureMarker.self,
                                                          from: Data(missing.utf8))
        XCTAssertEqual(decoded.kind, .voice)
        XCTAssertNil(decoded.voice)

        // Garbage in an additive field degrades to nil rather than throwing away the
        // whole marker — the frame is the part that matters.
        let garbage = #"{"seq":1,"frame":20,"kind":"voice","voice":7}"#
        let lenient = try CaptureCoding.decoder().decode(StructureMarker.self,
                                                          from: Data(garbage.utf8))
        XCTAssertEqual(lenient.frame, 20)
        XCTAssertNil(lenient.voice)
    }
}
