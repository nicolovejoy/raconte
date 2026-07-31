import XCTest
import AVFoundation
import CoreMedia
@testable import Raconte

/// M2 T2: frame accounting, discontinuity handling, and shutdown ordering against a
/// scripted engine (design §8). No models, no hardware, no `SpeechAnalyzer`.
final class TranscriptionSessionTests: XCTestCase {

    private static let captureRate = 48_000.0
    private static let chunkFrames: AVAudioFrameCount = 4_800   // 100 ms at 48 kHz

    private let captureFormat = AudioFormatDescriptor(
        sampleRate: 48_000, channels: 1, commonFormat: .pcmFormatFloat32, interleaved: false)

    private func chunk() -> PCMChunk {
        PCMChunk(data: Data(count: Int(Self.chunkFrames) * MemoryLayout<Float>.size),
                 frameCount: Self.chunkFrames,
                 sampleRate: Self.captureRate)
    }

    private func stamped(at frame: Int64) -> StampedChunk {
        StampedChunk(chunk: chunk(), startFrame: frame)
    }

    private func makeSession(_ engine: ScriptedTranscriptionEngine,
                             bound: Duration = .seconds(5)) -> TranscriptionSession {
        TranscriptionSession(engine: engine, inputFormat: captureFormat, finalizeBound: bound)
    }

    // MARK: Lifecycle

    func testStartReachesRunning() async {
        let engine = ScriptedTranscriptionEngine()
        let session = makeSession(engine)
        await session.start()
        let state = await session.state
        XCTAssertEqual(state, .running)
        XCTAssertEqual(engine.calls, [.prepare, .start])
    }

    func testUnavailableEngineLeavesTheSessionUnavailableNotFailed() async {
        let engine = ScriptedTranscriptionEngine()
        engine.prepareError = TranscriptionUnavailable.noModel
        let session = makeSession(engine)
        await session.start()
        let state = await session.state
        XCTAssertEqual(state, .unavailable(.noModel))
    }

    func testAThrownStartIsAbsorbedAsFailed() async {
        struct Boom: Error {}
        let engine = ScriptedTranscriptionEngine()
        engine.startError = Boom()
        let session = makeSession(engine)
        await session.start()
        let state = await session.state
        guard case .failed = state else { return XCTFail("expected .failed, got \(state)") }
    }

    /// The milestone's governing rule, as a test: once transcription is dead, chunks
    /// keep arriving and nothing throws, crashes, or back-pressures.
    func testIngestAfterFailureIsASilentNoOp() async {
        let engine = ScriptedTranscriptionEngine()
        engine.prepareError = TranscriptionUnavailable.noModel
        let session = makeSession(engine)
        await session.start()

        for i in 0..<5 {
            await session.ingest(stamped(at: Int64(i) * Int64(Self.chunkFrames)))
        }
        XCTAssertFalse(engine.calls.contains(.ingest))
        let state = await session.state
        XCTAssertEqual(state, .unavailable(.noModel))
    }

    // MARK: Frame accounting

    func testContiguousChunksStayInOneConverterRun() async {
        let engine = ScriptedTranscriptionEngine()
        let session = makeSession(engine)
        await session.start()

        for i in 0..<4 {
            await session.ingest(stamped(at: Int64(i) * Int64(Self.chunkFrames)))
        }
        let runs = await session.runCount
        XCTAssertEqual(runs, 1)
        let skipped = await session.skippedRanges
        XCTAssertTrue(skipped.isEmpty)
        XCTAssertEqual(engine.calls.filter { $0 == .ingest }.count, 4)
    }

    /// A gap must open a new run *and* be recorded. An emitted-frame accumulator
    /// would silently compress here, which is the whole reason §2 rejects one.
    func testAGapOpensANewRunAndIsRecorded() async {
        let engine = ScriptedTranscriptionEngine()
        let session = makeSession(engine)
        await session.start()

        await session.ingest(stamped(at: 0))
        // 0..4800 delivered; 4800..96000 dropped by the bounded sink; resume at 96000.
        await session.ingest(stamped(at: 96_000))

        let runs = await session.runCount
        XCTAssertEqual(runs, 2, "a discontinuity must start a fresh converter")
        let skipped = await session.skippedRanges
        XCTAssertEqual(skipped, [FrameRange(start: 4_800, end: 96_000)])
    }

    func testSeparateGapsStaySeparateRanges() async {
        let engine = ScriptedTranscriptionEngine()
        let session = makeSession(engine)
        await session.start()

        await session.ingest(stamped(at: 0))          // 0..4800
        await session.ingest(stamped(at: 9_600))      // gap 4800..9600
        await session.ingest(stamped(at: 14_400))     // contiguous
        await session.ingest(stamped(at: 24_000))     // gap 19200..24000

        let skipped = await session.skippedRanges
        XCTAssertEqual(skipped, [FrameRange(start: 4_800, end: 9_600),
                                 FrameRange(start: 19_200, end: 24_000)])
        let runs = await session.runCount
        XCTAssertEqual(runs, 3)
    }

    /// Only a run's **first** buffer carries a timestamp; the rest are `nil`, meaning
    /// "immediately after the previous buffer".
    ///
    /// Stamping every buffer looks more precise and is wrong: the converter emits
    /// lumpily, so an output buffer routinely carries audio from earlier input chunks,
    /// and labelling it with the current chunk's start frame declares a span overlapping
    /// the buffer before it. The SDK rejects that with `audioDisordered`, on the results
    /// stream, which kills the session — a live capture transcribed 0.685 s of 6.2 s
    /// before this changed.
    func testOnlyRunStartsAreStampedAndTheyUseTheCaptureAxis() async {
        let engine = ScriptedTranscriptionEngine()
        let session = makeSession(engine)
        await session.start()

        await session.ingest(stamped(at: 0))
        await session.ingest(stamped(at: 4_800))      // contiguous — no stamp
        await session.ingest(stamped(at: 96_000))     // after a gap — new run, stamped

        let times = engine.bufferStartTimes.map { CMTimeGetSeconds($0) }
        XCTAssertEqual(times.count, 2, "one stamp per run, not one per buffer")
        XCTAssertEqual(times[0], 0.0, accuracy: 0.0001)
        XCTAssertEqual(times[1], 2.0, accuracy: 0.0001,
                       "the post-gap stamp jumps to the true capture offset, which is "
                       + "what keeps the gap expressible")

        // The delay-line flush still happens at the discontinuity — it just rides the
        // contiguous path rather than being backdated into audio already accepted.
        XCTAssertEqual(engine.inputs.count, 4)
        XCTAssertEqual(engine.inputs.compactMap(\.bufferStartTime).count, 2)
    }

    func testMonotonicTimestampsAcrossGaps() async {
        let engine = ScriptedTranscriptionEngine()
        let session = makeSession(engine)
        await session.start()

        for frame in [Int64(0), 4_800, 48_000, 52_800, 240_000] {
            await session.ingest(stamped(at: frame))
        }
        let times = engine.bufferStartTimes.map { CMTimeGetSeconds($0) }
        XCTAssertEqual(times, times.sorted(), "SpeechAnalyzer rejects disordered input")
    }

    // MARK: Shutdown ordering

    func testFinishInputPrecedesFinalize() async {
        let engine = ScriptedTranscriptionEngine()
        let session = makeSession(engine)
        await session.start()
        await session.ingest(stamped(at: 0))
        await session.finish()

        XCTAssertFalse(engine.violatedShutdownOrder,
                       "finalizeAndFinishThroughEndOfInput waits for the input sequence; "
                       + "finalizing first costs a bounded wait on every capture")
        let calls = engine.calls
        guard let finishIndex = calls.firstIndex(of: .finishInput),
              let finalizeIndex = calls.firstIndex(of: .finalizeAndFinish) else {
            return XCTFail("expected both finishInput and finalizeAndFinish in \(calls)")
        }
        XCTAssertLessThan(finishIndex, finalizeIndex)
        let state = await session.state
        XCTAssertEqual(state, .done)
    }

    func testAStalledFinalizeFallsThroughToAbandonWithinTheBound() async {
        let engine = ScriptedTranscriptionEngine()
        engine.finalizeStall = .seconds(30)   // uncancellable — see the fake's note
        let session = makeSession(engine, bound: .milliseconds(100))
        await session.start()
        await session.ingest(stamped(at: 0))

        let began = ContinuousClock.now
        await session.finish()
        let elapsed = ContinuousClock.now - began

        XCTAssertTrue(engine.calls.contains(.abandon),
                      "past the bound the only correct call is cancelAndFinishNow()")
        XCTAssertLessThan(elapsed, .seconds(2),
                          "the bound must hold against a finalize that ignores "
                          + "cancellation — a task group would have waited the full 30s")
        let state = await session.state
        XCTAssertEqual(state, .done)
    }

    func testFinishWithoutStartIsHarmless() async {
        let engine = ScriptedTranscriptionEngine()
        let session = makeSession(engine)
        await session.finish()
        let state = await session.state
        XCTAssertEqual(state, .done)
        XCTAssertTrue(engine.calls.isEmpty)
    }

    // MARK: Results

    func testResultsReachTheConsolidator() async throws {
        let engine = ScriptedTranscriptionEngine()
        let session = makeSession(engine)
        await session.start()

        engine.emit(TranscriptResult(text: "hello", range: FrameRange(start: 0, end: 4_800),
                                     isVolatile: false, confidence: 0.9))
        engine.emit(TranscriptResult(text: "wrld", range: FrameRange(start: 4_800, end: 9_600),
                                     isVolatile: true, confidence: nil))

        try await pollUntil { await session.displayText == "hello wrld" }
        let committed = await session.committedText
        XCTAssertEqual(committed, "hello", "the volatile tail must not be committed")
    }

    func testAFailedResultStreamIsAbsorbed() async throws {
        struct Boom: Error {}
        let engine = ScriptedTranscriptionEngine()
        let session = makeSession(engine)
        await session.start()

        engine.emit(TranscriptResult(text: "kept", range: FrameRange(start: 0, end: 100),
                                     isVolatile: false, confidence: nil))
        engine.emitFailure(Boom())

        try await pollUntil {
            if case .failed = await session.state { return true }
            return false
        }
        let committed = await session.committedText
        XCTAssertEqual(committed, "kept", "words already committed survive the failure")
    }

    /// The results stream is async, so a deterministic test needs a bounded poll
    /// rather than a fixed sleep.
    private func pollUntil(timeout: Duration = .seconds(2),
                           _ condition: @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("condition not met within \(timeout)")
    }
}
