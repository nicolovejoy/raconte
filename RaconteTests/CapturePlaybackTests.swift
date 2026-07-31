import XCTest
import AVFoundation
@testable import Raconte

/// T9 playback tests (design §5/§6): pure playable-source selection, duration
/// from sidecars/file-size, and one real encode→decode duration check. No mic,
/// no audible-output assertions.
@MainActor
final class CapturePlaybackTests: XCTestCase {
    private var root: URL!
    private static let sampleRate = 48000
    private static let bytesPerFrame = 4

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CapturePlayback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func format() -> AudioFormatDescriptor {
        AudioFormatDescriptor(sampleRate: Self.sampleRate, channels: 1,
                              commonFormat: .pcmFormatFloat32, interleaved: false, bytesPerFrame: 4)
    }

    private func captureDir(_ id: String) -> URL {
        SegmentLayout.captureDirectory(capturesRoot: root, captureID: id)
    }

    private func snapshot(id: String = "01J0000000000000000000AA",
                          segments: [SegmentFileStat],
                          finalM4APresent: Bool = false,
                          finalM4APartPresent: Bool = false,
                          manifest: Manifest? = nil) -> CaptureSnapshot {
        CaptureSnapshot(captureID: id, directory: captureDir(id),
                        manifest: manifest, segments: segments,
                        finalM4APresent: finalM4APresent,
                        finalM4APartPresent: finalM4APartPresent,
                        format: DirectorySnapshot.normalizingBytesPerFrame(format()))
    }

    private func sidecar(id: String, index: Int, frames: Int, offset: Int) -> SegmentSidecar {
        SegmentSidecar(captureID: id, index: index, format: format(), frameCount: frames,
                       startFrameOffset: offset, startHostTime: 0,
                       wallClockStart: Date(timeIntervalSince1970: 0), sha256Prefix: "00000000",
                       closedReason: .rotation, byteCount: frames * Self.bytesPerFrame)
    }

    // MARK: - source selection (pure)

    func testSelectsFinalizedM4AWhenPresentAndVerified() {
        let id = "01J0000000000000000000AA"
        let manifest = Manifest(captureID: id, createdAt: Date(timeIntervalSince1970: 0),
                                state: .complete, stateSeq: 9,
                                stateUpdatedAt: Date(timeIntervalSince1970: 0), format: format(),
                                final: FinalRef(verifiedAt: Date(timeIntervalSince1970: 1),
                                                durationFrames: 72000))
        // m4a wins even when raw segments are also present.
        let snap = snapshot(id: id,
                            segments: [SegmentFileStat(index: 0, pcmByteSize: 24000 * 4,
                                                       sidecar: sidecar(id: id, index: 0, frames: 24000, offset: 0))],
                            finalM4APresent: true, manifest: manifest)
        let expected = SegmentLayout.finalRecordingURL(captureDirectory: captureDir(id))
        XCTAssertEqual(PlayableSourceSelector.select(snap), .finalizedM4A(expected))
    }

    func testSelectsRawSegmentsWhenNoM4A() {
        let id = "01J0000000000000000000BB"
        let snap = snapshot(id: id, segments: [
            SegmentFileStat(index: 0, pcmByteSize: 24000 * 4, sidecar: sidecar(id: id, index: 0, frames: 24000, offset: 0)),
            SegmentFileStat(index: 1, pcmByteSize: 24000 * 4, sidecar: sidecar(id: id, index: 1, frames: 24000, offset: 24000)),
        ])
        guard case .rawSegments(let segs, let fmt) = PlayableSourceSelector.select(snap) else {
            return XCTFail("expected rawSegments")
        }
        XCTAssertEqual(segs.map(\.index), [0, 1])
        XCTAssertEqual(PlayableSourceSelector.frameTotal(of: segs), 48000)
        XCTAssertEqual(fmt.sampleRate, Self.sampleRate)
        XCTAssertEqual(segs[1].pcmURL,
                       SegmentLayout.pcmURL(segmentsDirectory: SegmentLayout.segmentsDirectory(captureDirectory: captureDir(id)), index: 1))
    }

    func testSelectsNoneWhenEmpty() {
        XCTAssertEqual(PlayableSourceSelector.select(snapshot(segments: [])), PlayableSource.none)
    }

    func testM4APartOnlyIsNotPlayable_FallsBackToRaw() {
        let id = "01J0000000000000000000CC"
        // Only a `.m4a.part` (finalM4APresent == false): must not be chosen.
        let snap = snapshot(id: id,
                            segments: [SegmentFileStat(index: 0, pcmByteSize: 24000 * 4,
                                                       sidecar: sidecar(id: id, index: 0, frames: 24000, offset: 0))],
                            finalM4APresent: false, finalM4APartPresent: true)
        guard case .rawSegments = PlayableSourceSelector.select(snap) else {
            return XCTFail("expected rawSegments, not the .part")
        }
    }

    func testSelectsNoneWhenSegmentsHaveZeroFrames() {
        let snap = snapshot(segments: [SegmentFileStat(index: 0, pcmByteSize: 0)])
        XCTAssertEqual(PlayableSourceSelector.select(snap), PlayableSource.none)
    }

    // MARK: - duration (pure, no decode)

    func testDurationFromSidecars() {
        let id = "01J0000000000000000000DD"
        let snap = snapshot(id: id, segments: [
            SegmentFileStat(index: 0, pcmByteSize: 999, sidecar: sidecar(id: id, index: 0, frames: 24000, offset: 0)),
            SegmentFileStat(index: 1, pcmByteSize: 999, sidecar: sidecar(id: id, index: 1, frames: 48000, offset: 24000)),
        ])
        // Sidecar frameCount wins over the (deliberately wrong) file size.
        XCTAssertEqual(PlayableSourceSelector.rawDurationSeconds(snap), 72000.0 / 48000.0, accuracy: 1e-9)
    }

    func testDurationFromFileSizeWhenSidecarMissing() {
        let snap = snapshot(segments: [
            SegmentFileStat(index: 0, pcmByteSize: 24000 * 4, sidecar: nil),
            SegmentFileStat(index: 1, pcmByteSize: 12000 * 4, sidecar: nil),
        ])
        XCTAssertEqual(PlayableSourceSelector.rawDurationSeconds(snap), 36000.0 / 48000.0, accuracy: 1e-9)
    }

    // MARK: - real encode → CapturePlayback reports decoded m4a duration

    func testCapturePlaybackReportsDecodedM4ADuration() async throws {
        let id = "01J0000000000000000000EE"
        let dir = captureDir(id)
        try FileManager.default.createDirectory(
            at: SegmentLayout.finalDirectory(captureDirectory: dir), withIntermediateDirectories: true)

        // Three contiguous 0.5s sine segments -> 1.5s / 72000 frames.
        let segs = (0..<3).map { i in makeSineSegment(index: i, frames: 24000, startFrame: i * 24000) }
        let expectedSeconds = 72000.0 / Double(Self.sampleRate)

        let encoder = AVAssetWriterAudioEncoder()
        let m4aURL = SegmentLayout.finalRecordingURL(captureDirectory: dir)
        _ = try await encoder.encode(segments: segs, format: format(), to: m4aURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: m4aURL.path))

        let playback = CapturePlayback(capturesRoot: root, captureID: id)
        guard case .finalizedM4A = playback.source else {
            return XCTFail("expected finalizedM4A source")
        }
        XCTAssertTrue(playback.hasAudio)
        // AAC priming/padding makes duration inexact — same 0.5s tolerance as finalize.
        XCTAssertEqual(playback.duration, expectedSeconds, accuracy: 0.5)
    }

    func testCapturePlaybackNoneWhenNothingOnDisk() {
        let playback = CapturePlayback(capturesRoot: root, captureID: "01J0000000000000000000FF")
        XCTAssertFalse(playback.hasAudio)
        XCTAssertEqual(playback.duration, 0)
    }

    // MARK: - seeking / scrubbing (issue #6)

    func testSeekOnM4AMovesBothTheModelAndThePlayer() async throws {
        let id = "01J0000000000000000000GG"
        let playback = try await encodedPlayback(id: id)

        playback.seek(to: 1.0)
        XCTAssertEqual(playback.currentTime, 1.0, accuracy: 1e-9)
        // Never played, so the position must come from the seek, not the ticker.
        XCTAssertFalse(playback.isPlaying)
    }

    func testSeekClampsToDecodedDuration() async throws {
        let id = "01J0000000000000000000HH"
        let playback = try await encodedPlayback(id: id)

        playback.seek(to: -5)
        XCTAssertEqual(playback.currentTime, 0, accuracy: 1e-9)
        playback.seek(to: 999)
        XCTAssertEqual(playback.currentTime, playback.duration, accuracy: 1e-9)
    }

    /// The drag must suspend the ticker (via `pause()`), and releasing at the end
    /// must not restart playback.
    func testScrubbingSuspendsAndSeeks() async throws {
        let id = "01J0000000000000000000II"
        let playback = try await encodedPlayback(id: id)

        playback.beginScrubbing()
        XCTAssertTrue(playback.isScrubbing)
        XCTAssertFalse(playback.isPlaying)

        playback.endScrubbing(at: 0.5)
        XCTAssertFalse(playback.isScrubbing)
        XCTAssertEqual(playback.currentTime, 0.5, accuracy: 1e-9)
        // Wasn't playing when the drag began, so it must not start now.
        XCTAssertFalse(playback.isPlaying)
    }

    func testScrubbingToTheEndDoesNotResume() async throws {
        let id = "01J0000000000000000000JJ"
        let playback = try await encodedPlayback(id: id)

        playback.beginScrubbing()
        playback.endScrubbing(at: playback.duration)
        XCTAssertEqual(playback.currentTime, playback.duration, accuracy: 1e-9)
        XCTAssertFalse(playback.isPlaying)
    }

    func testSeekOnRawSegments() {
        let segs = (0..<3).map { makeSineSegment(index: $0, frames: 24000, startFrame: $0 * 24000) }
        let playback = CapturePlayback(source: .rawSegments(segs, format: format()))
        XCTAssertEqual(playback.duration, 1.5, accuracy: 1e-9)

        playback.seek(to: 1.0)
        XCTAssertEqual(playback.currentTime, 1.0, accuracy: 1e-9)

        playback.seek(to: 99)
        XCTAssertEqual(playback.currentTime, playback.duration, accuracy: 1e-9)
    }

    func testSeekOnNoneSourceIsHarmless() {
        let playback = CapturePlayback(source: .none)
        playback.seek(to: 5)
        XCTAssertEqual(playback.currentTime, 0)
    }

    // MARK: - helpers

    /// Encode three 0.5s sine segments into `final/recording.m4a` and open a
    /// `CapturePlayback` over the resulting capture directory.
    private func encodedPlayback(id: String) async throws -> CapturePlayback {
        let dir = captureDir(id)
        try FileManager.default.createDirectory(
            at: SegmentLayout.finalDirectory(captureDirectory: dir), withIntermediateDirectories: true)
        let segs = (0..<3).map { i in makeSineSegment(index: i, frames: 24000, startFrame: i * 24000) }
        _ = try await AVAssetWriterAudioEncoder()
            .encode(segments: segs, format: format(),
                    to: SegmentLayout.finalRecordingURL(captureDirectory: dir))
        let playback = CapturePlayback(capturesRoot: root, captureID: id)
        guard case .finalizedM4A = playback.source else {
            throw XCTSkip("expected a finalized m4a source")
        }
        return playback
    }

    /// A 440 Hz sine at amplitude 0.5, flat little-endian Float32, under the
    /// capture's `segments/` dir so the disk gatherer finds it if needed.
    private func makeSineSegment(index: Int, frames: Int, startFrame: Int) -> EncodableSegment {
        var samples = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            let t = Double(startFrame + i) / Double(Self.sampleRate)
            samples[i] = Float(sin(2 * Double.pi * 440 * t) * 0.5)
        }
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let url = root.appendingPathComponent("sine-\(index).pcm")
        try? data.write(to: url)
        return EncodableSegment(index: index, startFrameOffset: startFrame, frameCount: frames, pcmURL: url)
    }
}
