import XCTest
import AVFoundation
@testable import Raconte

/// Integration test for the real `AVAssetWriterAudioEncoder` (design §6, VERIFY
/// §4/§5): synthetic sine PCM segments → AAC-LC `.m4a` → decode → assert duration
/// within tolerance and non-silent. No microphone; runs on macOS/simulator.
final class AudioEncoderRoundTripTests: XCTestCase {
    private var root: URL!
    private static let sampleRate = 48000
    private static let bytesPerFrame = 4

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioEncoderRoundTrip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func format() -> AudioFormatDescriptor {
        AudioFormatDescriptor(sampleRate: Self.sampleRate, channels: 1,
                              commonFormat: .pcmFormatFloat32, interleaved: false, bytesPerFrame: 4)
    }

    /// A 440 Hz sine at amplitude 0.5, written as flat little-endian Float32.
    private func writeSineSegment(index: Int, frames: Int, startFrame: Int) throws -> EncodableSegment {
        var samples = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            let t = Double(startFrame + i) / Double(Self.sampleRate)
            samples[i] = Float(sin(2 * Double.pi * 440 * t) * 0.5)
        }
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let url = root.appendingPathComponent("\(index).pcm")
        try data.write(to: url)
        return EncodableSegment(index: index, startFrameOffset: startFrame,
                                frameCount: frames, pcmURL: url)
    }

    // MARK: encode → decode round-trip

    func testSinePCMEncodesToVerifiableM4A() async throws {
        // Three contiguous 0.5s segments = 1.5s / 72000 frames.
        let seg0 = try writeSineSegment(index: 0, frames: 24000, startFrame: 0)
        let seg1 = try writeSineSegment(index: 1, frames: 24000, startFrame: 24000)
        let seg2 = try writeSineSegment(index: 2, frames: 24000, startFrame: 48000)
        let expectedFrames = 72000

        let encoder = AVAssetWriterAudioEncoder()
        let partURL = root.appendingPathComponent("recording.m4a.part")
        let result = try await encoder.encode(segments: [seg0, seg1, seg2],
                                              format: format(), to: partURL)

        XCTAssertEqual(result.encodedFrameCount, expectedFrames)
        XCTAssertTrue(FileManager.default.fileExists(atPath: partURL.path))
        let size = try FileManager.default.attributesOfItem(atPath: partURL.path)[.size] as! Int
        XCTAssertGreaterThan(size, 0)

        let verified = try await encoder.verify(m4aURL: partURL)
        XCTAssertTrue(verified.decodable)
        XCTAssertTrue(verified.nonSilent)

        // AAC priming/padding makes duration inexact; assert within the 0.5s
        // finalizer tolerance and record the observed delta.
        let toleranceFrames = 0.5 * Double(Self.sampleRate)
        let deltaFrames = abs(Double(verified.decodedFrameCount) - Double(expectedFrames))
        XCTAssertLessThan(deltaFrames, toleranceFrames,
                          "decoded \(verified.decodedFrameCount) vs raw \(expectedFrames), " +
                          "delta \(deltaFrames) frames (\(deltaFrames / Double(Self.sampleRate))s)")
    }

    // MARK: end-to-end via FinalizerWorker with the real encoder

    func testWorkerFinalizesRealEncodeEndToEnd() async throws {
        let id = "01J0000000000000000000AA"
        let dir = SegmentLayout.captureDirectory(capturesRoot: root, captureID: id)
        let segs = SegmentLayout.segmentsDirectory(captureDirectory: dir)
        try FileManager.default.createDirectory(at: segs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: SegmentLayout.finalDirectory(captureDirectory: dir), withIntermediateDirectories: true)

        let fmt = format()
        var running = 0
        for i in 0..<2 {
            let frames = 24000
            var samples = [Float](repeating: 0, count: frames)
            for j in 0..<frames {
                let t = Double(running + j) / Double(Self.sampleRate)
                samples[j] = Float(sin(2 * Double.pi * 440 * t) * 0.5)
            }
            let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
            try data.write(to: SegmentLayout.pcmURL(segmentsDirectory: segs, index: i))
            let sidecar = SegmentSidecar(
                captureID: id, index: i, format: fmt, frameCount: frames,
                startFrameOffset: running, startHostTime: 0,
                wallClockStart: Date(timeIntervalSince1970: 0), sha256Prefix: "00000000",
                closedReason: .rotation, byteCount: frames * Self.bytesPerFrame)
            try AtomicFile.replace(at: SegmentLayout.sidecarURL(segmentsDirectory: segs, index: i),
                                   writing: try CaptureCoding.encoder().encode(sidecar))
            running += frames
        }
        let manifestFmt = AudioFormatDescriptor(sampleRate: Self.sampleRate, channels: 1,
                                                commonFormat: .pcmFormatFloat32, interleaved: false)
        let manifest = Manifest(captureID: id, createdAt: Date(timeIntervalSince1970: 0),
                                state: .captured, stateSeq: 5,
                                stateUpdatedAt: Date(timeIntervalSince1970: 0),
                                format: manifestFmt, segmentCount: 2, lastKnownFrameOffset: running)
        try AtomicFile.replace(at: SegmentLayout.manifestURL(captureDirectory: dir),
                               writing: try CaptureCoding.encoder().encode(manifest))

        let worker = FinalizerWorker(capturesRoot: root, encoder: AVAssetWriterAudioEncoder())
        await worker.enqueue(id)
        let outcomes = await worker.drain()

        XCTAssertEqual(outcomes[0].status, .completed)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: SegmentLayout.finalRecordingURL(captureDirectory: dir).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: segs.path), "raw deleted after verify")

        let data = try Data(contentsOf: SegmentLayout.manifestURL(captureDirectory: dir))
        let final = try CaptureCoding.decoder().decode(Manifest.self, from: data)
        XCTAssertEqual(final.state, .complete)
        XCTAssertNotNil(final.final.verifiedAt)
    }
}
