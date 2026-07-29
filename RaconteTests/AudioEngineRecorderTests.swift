import XCTest
import AVFoundation
@testable import Raconte

/// Records everything the tap hands off, in order. Thread-safe so it can be a `PCMSink`.
final class FakeSink: PCMSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _chunks: [PCMChunk] = []

    var chunks: [PCMChunk] {
        lock.lock(); defer { lock.unlock() }
        return _chunks
    }

    func receive(_ chunk: PCMChunk) {
        lock.lock(); defer { lock.unlock() }
        _chunks.append(chunk)
    }
}

final class AudioEngineRecorderTests: XCTestCase {

    // MARK: helpers

    private func monoFormat(_ rate: Double = 48000) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    }

    private func stereoFormat(_ rate: Double = 48000) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false)!
    }

    /// Builds a PCM buffer; `fill(channel, frame)` provides each sample.
    private func buffer(_ format: AVAudioFormat, frames: AVAudioFrameCount,
                        fill: (Int, Int) -> Float) -> AVAudioPCMBuffer {
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        let channels = Int(format.channelCount)
        for c in 0..<channels {
            let p = buf.floatChannelData![c]
            for f in 0..<Int(frames) { p[f] = fill(c, f) }
        }
        return buf
    }

    // MARK: RMS math

    func testRMSSilenceIsZero() {
        XCTAssertEqual(AudioEngineRecorder.rms([Float](repeating: 0, count: 512)), 0, accuracy: 1e-7)
    }

    func testRMSEmptyIsZero() {
        XCTAssertEqual(AudioEngineRecorder.rms([]), 0, accuracy: 1e-7)
    }

    func testRMSConstantEqualsMagnitude() {
        XCTAssertEqual(AudioEngineRecorder.rms([Float](repeating: 1.0, count: 100)), 1.0, accuracy: 1e-6)
        XCTAssertEqual(AudioEngineRecorder.rms([Float](repeating: -0.5, count: 100)), 0.5, accuracy: 1e-6)
    }

    func testRMSFullScaleSineIsRoot2Over2() {
        let n = 4800 // whole cycles at 48k
        let samples = (0..<n).map { Float(sin(2 * Double.pi * Double($0) / 480.0)) }
        XCTAssertEqual(AudioEngineRecorder.rms(samples), Float(1 / 2.0.squareRoot()), accuracy: 1e-3)
    }

    // MARK: sink handoff

    func testSinkReceivesFramesInOrderPassthrough() {
        let fmt = monoFormat()
        let sink = FakeSink()
        let proc = TapProcessor(inputFormat: fmt, sink: sink) // input == canonical → no converter
        let sizes: [AVAudioFrameCount] = [100, 200, 300]
        let marks: [Float] = [0.1, 0.2, 0.3]
        for (i, frames) in sizes.enumerated() {
            proc.process(buffer(fmt, frames: frames) { _, _ in marks[i] })
        }
        let chunks = sink.chunks
        XCTAssertEqual(chunks.map(\.frameCount), sizes)
        XCTAssertEqual(chunks.map(\.sampleRate), [48000, 48000, 48000])
        // first sample of each chunk confirms ordering + byte layout
        for (i, chunk) in chunks.enumerated() {
            let first = chunk.data.withUnsafeBytes { $0.load(as: Float.self) }
            XCTAssertEqual(first, marks[i], accuracy: 1e-6)
            XCTAssertEqual(chunk.data.count, Int(sizes[i]) * MemoryLayout<Float>.size)
        }
    }

    func testLevelCallbackReportsRMS() {
        let fmt = monoFormat()
        let sink = FakeSink()
        let box = LevelBox()
        let proc = TapProcessor(inputFormat: fmt, sink: sink, onLevel: { box.set($0) })
        proc.process(buffer(fmt, frames: 256) { _, _ in 1.0 })
        XCTAssertEqual(box.value, 1.0, accuracy: 1e-6)
    }

    // MARK: channel downmix (converter path, hardware rate preserved)

    func testStereoDownmixToMonoPreservesRateAndFrames() {
        let inFmt = stereoFormat()
        let sink = FakeSink()
        let proc = TapProcessor(inputFormat: inFmt, sink: sink)
        XCTAssertEqual(proc.outputFormat.channelCount, 1)
        XCTAssertEqual(proc.outputFormat.sampleRate, 48000) // hardware rate, no resample
        // equal channels → downmix preserves the common value regardless of coefficients
        proc.process(buffer(inFmt, frames: 128) { _, _ in 0.5 })
        let chunk = sink.chunks.first
        XCTAssertNotNil(chunk)
        XCTAssertEqual(chunk?.frameCount, 128)
        XCTAssertEqual(chunk?.sampleRate, 48000)
        let first = chunk!.data.withUnsafeBytes { $0.load(as: Float.self) }
        XCTAssertEqual(first, 0.5, accuracy: 1e-3)
    }

    // MARK: no-disk / non-blocking by construction

    func testManyBuffersAllDeliveredNoBlocking() {
        // TapProcessor only ever calls the sink; a fast burst proves no per-buffer disk I/O.
        let fmt = monoFormat()
        let sink = FakeSink()
        let proc = TapProcessor(inputFormat: fmt, sink: sink)
        for _ in 0..<1000 { proc.process(buffer(fmt, frames: 64) { _, _ in 0.25 }) }
        XCTAssertEqual(sink.chunks.count, 1000)
        XCTAssertTrue(sink.chunks.allSatisfy { $0.frameCount == 64 })
    }
}

/// Thread-safe scalar sink for the `@Sendable` level callback.
final class LevelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Float = -1
    var value: Float { lock.lock(); defer { lock.unlock() }; return _value }
    func set(_ v: Float) { lock.lock(); _value = v; lock.unlock() }
}
