import XCTest
@testable import Raconte

final class SegmentLayoutTests: XCTestCase {

    // MARK: Padding + naming

    func testSixDigitPadding() {
        XCTAssertEqual(SegmentLayout.segmentBaseName(index: 0), "000000")
        XCTAssertEqual(SegmentLayout.segmentBaseName(index: 42), "000042")
        XCTAssertEqual(SegmentLayout.segmentBaseName(index: 999999), "999999")
        XCTAssertEqual(SegmentLayout.pcmFileName(index: 0), "000000.pcm")
        XCTAssertEqual(SegmentLayout.pcmPartFileName(index: 42), "000042.pcm.part")
        XCTAssertEqual(SegmentLayout.sidecarFileName(index: 42), "000042.json")
    }

    func testIndexParsing() {
        XCTAssertEqual(SegmentLayout.segmentIndex(fromFileName: "000042.pcm"), 42)
        XCTAssertEqual(SegmentLayout.segmentIndex(fromFileName: "000042.pcm.part"), 42)
        XCTAssertEqual(SegmentLayout.segmentIndex(fromFileName: "000042.json"), 42)
        XCTAssertEqual(SegmentLayout.segmentIndex(fromFileName: "000000.pcm"), 0)
        XCTAssertNil(SegmentLayout.segmentIndex(fromFileName: "manifest.json"))
        XCTAssertNil(SegmentLayout.segmentIndex(fromFileName: "abc.pcm"))
        XCTAssertNil(SegmentLayout.segmentIndex(fromFileName: ".pcm"))
    }

    // MARK: Ordering — readdir (lexicographic) order == chronological order

    func testLexicographicSortMatchesChronologicalOrder() {
        let indices = [5, 0, 12, 3, 100, 1, 999999, 42]
        let names = indices.map { SegmentLayout.pcmFileName(index: $0) }
        let sortedByString = names.sorted()
        let recoveredOrder = sortedByString.compactMap { SegmentLayout.segmentIndex(fromFileName: $0) }
        XCTAssertEqual(recoveredOrder, indices.sorted())
    }

    func testGapFreeDetection() {
        XCTAssertTrue(SegmentLayout.indicesAreGapFree([0, 1, 2, 3]))
        XCTAssertTrue(SegmentLayout.indicesAreGapFree([2, 0, 1]))   // order-independent
        XCTAssertTrue(SegmentLayout.indicesAreGapFree([0]))
        XCTAssertTrue(SegmentLayout.indicesAreGapFree([]))
        XCTAssertFalse(SegmentLayout.indicesAreGapFree([0, 1, 3]))  // gap at 2
        XCTAssertFalse(SegmentLayout.indicesAreGapFree([1, 2, 3]))  // doesn't start at 0
    }

    // MARK: Cumulative startFrameOffset chain

    func testCumulativeStartFrameOffsets() {
        XCTAssertEqual(SegmentLayout.startFrameOffsets(frameCounts: [100, 200, 300, 50]),
                       [0, 100, 300, 600])
        XCTAssertEqual(SegmentLayout.startFrameOffsets(frameCounts: []), [])
        XCTAssertEqual(SegmentLayout.startFrameOffsets(frameCounts: [960000]), [0])
        // Chain over N equal segments matches the sidecar contract:
        // offset[i] + frameCount == offset[i+1].
        let counts = Array(repeating: 960000, count: 10)
        let offsets = SegmentLayout.startFrameOffsets(frameCounts: counts)
        for i in 0..<(counts.count - 1) {
            XCTAssertEqual(offsets[i] + counts[i], offsets[i + 1])
        }
        XCTAssertEqual(offsets.last! + counts.last!, 9_600_000)
    }

    // MARK: .part truncation math (fileSize not a multiple of bytesPerFrame)

    func testTruncationMath() {
        let bytesPerFrame = 4  // Float32 mono

        // Exact multiple: nothing to truncate.
        XCTAssertEqual(SegmentLayout.wholeFrameCount(fileSize: 4000, bytesPerFrame: bytesPerFrame), 1000)
        XCTAssertEqual(SegmentLayout.truncatedByteCount(fileSize: 4000, bytesPerFrame: bytesPerFrame), 4000)
        XCTAssertFalse(SegmentLayout.hasTrailingPartialFrame(fileSize: 4000, bytesPerFrame: bytesPerFrame))

        // Trailing partial frame (crash mid-write): drop the last 1 byte.
        XCTAssertEqual(SegmentLayout.wholeFrameCount(fileSize: 4001, bytesPerFrame: bytesPerFrame), 1000)
        XCTAssertEqual(SegmentLayout.truncatedByteCount(fileSize: 4001, bytesPerFrame: bytesPerFrame), 4000)
        XCTAssertTrue(SegmentLayout.hasTrailingPartialFrame(fileSize: 4001, bytesPerFrame: bytesPerFrame))

        // 3 of 4 bytes of one frame written.
        XCTAssertEqual(SegmentLayout.wholeFrameCount(fileSize: 4003, bytesPerFrame: bytesPerFrame), 1000)
        XCTAssertEqual(SegmentLayout.truncatedByteCount(fileSize: 4003, bytesPerFrame: bytesPerFrame), 4000)
        XCTAssertTrue(SegmentLayout.hasTrailingPartialFrame(fileSize: 4003, bytesPerFrame: bytesPerFrame))

        // Empty file.
        XCTAssertEqual(SegmentLayout.wholeFrameCount(fileSize: 0, bytesPerFrame: bytesPerFrame), 0)
        XCTAssertEqual(SegmentLayout.truncatedByteCount(fileSize: 0, bytesPerFrame: bytesPerFrame), 0)
        XCTAssertFalse(SegmentLayout.hasTrailingPartialFrame(fileSize: 0, bytesPerFrame: bytesPerFrame))

        // Non-4 frame size (e.g. Int16 stereo = 4 too; use 6 = Int16*3ch) to prove generality.
        XCTAssertEqual(SegmentLayout.truncatedByteCount(fileSize: 100, bytesPerFrame: 6), 96)
        XCTAssertTrue(SegmentLayout.hasTrailingPartialFrame(fileSize: 100, bytesPerFrame: 6))
    }

    // MARK: URL construction

    func testURLConstruction() {
        let root = URL(fileURLWithPath: "/tmp/Raconte/captures", isDirectory: true)
        let dir = SegmentLayout.captureDirectory(capturesRoot: root, captureID: "01J")
        XCTAssertEqual(dir.lastPathComponent, "01J")
        XCTAssertEqual(SegmentLayout.manifestURL(captureDirectory: dir).lastPathComponent, "manifest.json")
        XCTAssertEqual(SegmentLayout.manifestPartURL(captureDirectory: dir).lastPathComponent, "manifest.json.part")
        let segs = SegmentLayout.segmentsDirectory(captureDirectory: dir)
        XCTAssertEqual(segs.lastPathComponent, "segments")
        XCTAssertEqual(SegmentLayout.pcmURL(segmentsDirectory: segs, index: 42).lastPathComponent, "000042.pcm")
        XCTAssertEqual(SegmentLayout.pcmPartURL(segmentsDirectory: segs, index: 42).lastPathComponent, "000042.pcm.part")
        XCTAssertEqual(SegmentLayout.sidecarURL(segmentsDirectory: segs, index: 42).lastPathComponent, "000042.json")
        XCTAssertEqual(SegmentLayout.finalRecordingURL(captureDirectory: dir).lastPathComponent, "recording.m4a")
        XCTAssertEqual(SegmentLayout.finalRecordingPartURL(captureDirectory: dir).lastPathComponent, "recording.m4a.part")
    }

    // MARK: Codable round-trips

    /// Mints a Date on a millisecond boundary so ISO8601-fractional round-trips
    /// are exact (parse-once is a fixed point of string<->date).
    private func fixedPointDate(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: iso)!
    }

    func testSidecarCodableRoundTrip() throws {
        let sidecar = SegmentSidecar(
            captureID: "01J000000000000000000000",
            index: 42,
            format: AudioFormatDescriptor(sampleRate: 48000, channels: 1,
                                          commonFormat: .pcmFormatFloat32,
                                          interleaved: false, bytesPerFrame: 4),
            frameCount: 960000,
            startFrameOffset: 40_320_000,
            startHostTime: 1490283.402,
            wallClockStart: fixedPointDate("2026-07-29T15:00:00.123Z"),
            sha256Prefix: "1a2b3c4d",
            closedReason: .rotation,
            byteCount: 3_840_000)

        let data = try CaptureCoding.encoder().encode(sidecar)
        let decoded = try CaptureCoding.decoder().decode(SegmentSidecar.self, from: data)
        XCTAssertEqual(decoded, sidecar)

        // bytesPerFrame present in the sidecar's format block.
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"bytesPerFrame\""))
    }

    func testManifestCodableRoundTripAndSchemaVersion() throws {
        let manifest = Manifest(
            captureID: "01J000000000000000000000",
            createdAt: fixedPointDate("2026-07-29T15:00:00.000Z"),
            state: .recording,
            stateSeq: 7,
            stateUpdatedAt: fixedPointDate("2026-07-29T15:03:22.100Z"),
            format: AudioFormatDescriptor(sampleRate: 48000, channels: 1,
                                          commonFormat: .pcmFormatFloat32,
                                          interleaved: false),
            segmentCount: 43,
            lastKnownFrameOffset: 41_280_000,
            interruptions: [
                InterruptionLogEntry(kind: "call",
                                     beganAt: fixedPointDate("2026-07-29T15:01:00.000Z"),
                                     endedAt: fixedPointDate("2026-07-29T15:01:30.000Z"),
                                     resumed: true)
            ])

        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.schemaVersion, Manifest.currentSchemaVersion)

        let data = try CaptureCoding.encoder().encode(manifest)
        let decoded = try CaptureCoding.decoder().decode(Manifest.self, from: data)
        XCTAssertEqual(decoded, manifest)
        XCTAssertEqual(decoded.schemaVersion, 1)

        let json = String(decoding: data, as: UTF8.self)
        // Manifest format block omits bytesPerFrame (nil -> absent).
        XCTAssertFalse(json.contains("\"bytesPerFrame\""))
        // FinalRef nil fields serialize as explicit null per §1.
        XCTAssertTrue(json.contains("\"verifiedAt\" : null"))
        XCTAssertTrue(json.contains("\"durationFrames\" : null"))
    }

    /// In-progress interruption entries (endedAt/resumed nil) serialize as explicit
    /// `null`, matching FinalRef's shape (finding #5); completed entries carry values.
    func testInterruptionLogEntryEmitsExplicitNullWhileInProgress() throws {
        let inProgress = InterruptionLogEntry(
            kind: "call",
            beganAt: fixedPointDate("2026-07-29T15:01:00.000Z"),
            endedAt: nil, resumed: nil)

        let data = try CaptureCoding.encoder().encode(inProgress)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"endedAt\" : null"))
        XCTAssertTrue(json.contains("\"resumed\" : null"))
        // Round-trips back to the same value (nil stays nil).
        XCTAssertEqual(try CaptureCoding.decoder().decode(InterruptionLogEntry.self, from: data), inProgress)

        // Completed entry still carries concrete values, same key set.
        let completed = InterruptionLogEntry(
            kind: "call",
            beganAt: fixedPointDate("2026-07-29T15:01:00.000Z"),
            endedAt: fixedPointDate("2026-07-29T15:01:30.000Z"), resumed: true)
        let completedJSON = String(decoding: try CaptureCoding.encoder().encode(completed), as: UTF8.self)
        XCTAssertFalse(completedJSON.contains("\"endedAt\" : null"))
        XCTAssertTrue(completedJSON.contains("\"resumed\" : true"))
    }

    /// Operational fields (§2 rows 10/17/18/19) are optional: absent when nil,
    /// present + round-tripping when set.
    func testManifestOperationalFieldsRoundTripAndOmission() throws {
        var m = Manifest(
            captureID: "01J000000000000000000000",
            createdAt: fixedPointDate("2026-07-29T15:00:00.000Z"),
            state: .captured, stateSeq: 9,
            stateUpdatedAt: fixedPointDate("2026-07-29T15:05:00.000Z"),
            format: AudioFormatDescriptor(sampleRate: 48000, channels: 1,
                                          commonFormat: .pcmFormatFloat32, interleaved: false))

        let bare = try CaptureCoding.encoder().encode(m)
        let bareJSON = String(decoding: bare, as: UTF8.self)
        for key in ["needsAttention", "lastError", "retryCount", "finalizeAttempts"] {
            XCTAssertFalse(bareJSON.contains("\"\(key)\""), "\(key) omitted when nil")
        }
        XCTAssertEqual(try CaptureCoding.decoder().decode(Manifest.self, from: bare), m)

        m.needsAttention = true
        m.lastError = "diskFull"
        m.retryCount = 2
        m.finalizeAttempts = 3
        let full = try CaptureCoding.encoder().encode(m)
        XCTAssertEqual(try CaptureCoding.decoder().decode(Manifest.self, from: full), m)
        let fullJSON = String(decoding: full, as: UTF8.self)
        XCTAssertTrue(fullJSON.contains("\"needsAttention\" : true"))
        XCTAssertTrue(fullJSON.contains("\"lastError\" : \"diskFull\""))
        XCTAssertTrue(fullJSON.contains("\"retryCount\" : 2"))
        XCTAssertTrue(fullJSON.contains("\"finalizeAttempts\" : 3"))
    }

    func testManifestDefaultFinalRef() {
        let m = Manifest(captureID: "x", createdAt: Date(), state: .preparing,
                         stateSeq: 0, stateUpdatedAt: Date(),
                         format: AudioFormatDescriptor(sampleRate: 48000, channels: 1,
                                                       commonFormat: .pcmFormatFloat32,
                                                       interleaved: false))
        XCTAssertEqual(m.final.path, "final/recording.m4a")
        XCTAssertNil(m.final.verifiedAt)
        XCTAssertNil(m.final.durationFrames)
        XCTAssertEqual(m.segmentCount, 0)
        XCTAssertTrue(m.interruptions.isEmpty)
    }
}
