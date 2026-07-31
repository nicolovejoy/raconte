import Foundation
import AVFoundation
import CoreMedia
import Speech

/// Why transcription could not run at all — distinct from a mid-run failure, and
/// distinct from "no words yet". Surfaced to the UI as an explanation, never as an
/// error the user must dismiss.
enum TranscriptionUnavailable: Error, Sendable, Equatable {
    /// No installed model for the requested locale, and none obtainable.
    case noModel
    case unsupportedLocale(String)
    /// `bestAvailableAudioFormat` returned nil — the CI case, and the case on a
    /// device whose assets have not been installed.
    case noAnalysisFormat
    case other(String)
}

/// A mid-run failure, flattened to a message.
///
/// The session absorbs every error by design (§4: "every failure is absorbing"), so
/// nothing downstream ever needs the original to branch on — only to display and log.
/// Flattening buys `Equatable`, which the state tests need.
struct TranscriptionFailure: Error, Sendable, Equatable {
    var message: String
    init(_ error: Error) { self.message = String(describing: error) }
    init(message: String) { self.message = message }
}

/// Owns the engine, the converter, and the capture-frame accounting for one capture
/// (design §4). Deliberately **not** a `CaptureMachine` phase: transcription is
/// derived, it may fail at any moment, and it never sends an event into the capture
/// state machine. Every terminal state here is absorbing — the audio path does not
/// learn that this failed, because nothing it would do differs.
actor TranscriptionSession {

    enum State: Sendable, Equatable {
        case idle
        case preparing
        case running
        case finishing
        case done
        case failed(TranscriptionFailure)
        case unavailable(TranscriptionUnavailable)

        var isTerminal: Bool {
            switch self {
            case .done, .failed, .unavailable: return true
            case .idle, .preparing, .running, .finishing: return false
            }
        }
    }

    private let engine: any TranscriptionEngine
    private let inputFormat: AudioFormatDescriptor
    private let finalizeBound: Duration

    private var inputAV: AVAudioFormat?
    private var analysisAV: AVAudioFormat?

    private(set) var state: State = .idle

    private var consolidator = TranscriptConsolidator()
    private var resultsTask: Task<Void, Never>?

    // MARK: Capture-frame accounting (design §2, "The clock")

    /// Where the next chunk must start for the stream to be contiguous. `nil` before
    /// the first chunk. Compared against `StampedChunk.startFrame`, which
    /// `BoundedPCMSink` advances even for chunks it drops — that is what makes a gap
    /// *expressible* here rather than silently compressed.
    private var expectedNextFrame: Int64?


    /// Fresh per run. A converter carries resampler state across calls, so reusing one
    /// across a discontinuity would smear the boundary and, worse, keep the old run's
    /// priming — the timestamps after the gap would be wrong by a constant.
    private var converter: AVAudioConverter?

    /// The current converter's constant leading latency, on the input axis. Measured
    /// from `primeInfo` rather than assumed zero (design §10.6).
    private(set) var primingOffset: CMTime = .zero

    private(set) var runCount = 0
    private var skipped: [FrameRange] = []

    init(engine: any TranscriptionEngine,
         inputFormat: AudioFormatDescriptor,
         finalizeBound: Duration = .seconds(5)) {
        self.engine = engine
        self.inputFormat = inputFormat
        self.finalizeBound = finalizeBound
    }

    // MARK: Introspection

    var committedText: String { consolidator.committedText }
    var displayText: String { consolidator.displayText }
    var committed: [TranscriptResult] { consolidator.committed }
    var provisional: [TranscriptResult] { consolidator.provisional }

    /// Capture-frame ranges that never reached the analyzer — `BoundedPCMSink` drops
    /// and suspensions. T3 persists these as `TranscriptRef.skippedRanges`; they are
    /// what tells a later re-derive which spans the live pass never saw.
    var skippedRanges: [FrameRange] { skipped }

    // MARK: Lifecycle

    /// Resolve the analysis format, stand the engine up, and start draining results.
    /// Never throws: unavailability and failure are states, not exceptions (§4).
    func start() async {
        guard case .idle = state else { return }
        state = .preparing

        guard let inputAV = inputFormat.avAudioFormat else {
            state = .unavailable(.other("uninterpretable capture format"))
            return
        }
        self.inputAV = inputAV

        let analysis: AudioFormatDescriptor
        do {
            analysis = try await engine.prepare(inputFormat: inputFormat)
        } catch let unavailable as TranscriptionUnavailable {
            state = .unavailable(unavailable)
            return
        } catch {
            state = .failed(TranscriptionFailure(error))
            return
        }

        guard let analysisAV = analysis.avAudioFormat else {
            state = .unavailable(.noAnalysisFormat)
            return
        }
        self.analysisAV = analysisAV

        do {
            try await engine.start()
        } catch {
            state = .failed(TranscriptionFailure(error))
            return
        }

        drainResults()
        state = .running
    }

    /// Consume a `BoundedPCMSink` stream to completion, then shut down. The stream
    /// ending is the capture ending; there is no separate stop signal.
    func consume(_ chunks: AsyncStream<StampedChunk>) async {
        for await stamped in chunks {
            await ingest(stamped)
        }
        await finish()
    }

    /// Convert one stamped chunk and hand it to the analyzer.
    ///
    /// Silently no-ops unless running — a chunk arriving after a failure is not an
    /// error, it is the audio path continuing to work correctly while the derived
    /// consumer is dead. That asymmetry is the milestone's governing rule.
    func ingest(_ stamped: StampedChunk) async {
        guard case .running = state, let inputAV, let analysisAV else { return }

        if expectedNextFrame != stamped.startFrame {
            if let expected = expectedNextFrame, stamped.startFrame > expected {
                recordSkip(FrameRange(start: expected, end: stamped.startFrame))
            }
            openRun(from: inputAV, to: analysisAV)
        }
        expectedNextFrame = stamped.startFrame + Int64(stamped.chunk.frameCount)

        guard let converter,
              let input = Self.buffer(from: stamped.chunk, format: inputAV),
              let output = Self.convert(input, using: converter, to: analysisAV)
        else { return }

        // `AnalyzerInput` is `@unchecked Sendable` and the analyzer holds the buffer
        // past this call, so `output` MUST be freshly allocated. The disk path's
        // house style of reusing a scratch buffer would be a silent data race here
        // with no diagnostic (design §2, "Trap").
        await engine.ingest(AnalyzerInput(buffer: output,
                                          bufferStartTime: bufferStartTime(at: stamped.startFrame)))
    }

    /// Ordered shutdown (§4). `finishInput()` first is mandatory, not stylistic:
    /// `finalizeAndFinishThroughEndOfInput()` waits for the input sequence to
    /// terminate, so finalizing first hangs until the bound expires — on every single
    /// capture.
    func finish() async {
        guard case .running = state else {
            // Nothing was ever started, or we already died. Still terminal.
            if !state.isTerminal { state = .done }
            return
        }
        state = .finishing

        await engine.finishInput()

        if await finalizedWithinBound() == false {
            // Past the bound the only correct call is `cancelAndFinishNow()`. Losing
            // the tail costs a re-derive, not the words — the audio is already on disk.
            await engine.abandon()
        }

        resultsTask?.cancel()
        resultsTask = nil
        if !state.isTerminal { state = .done }
    }

    /// Abort without finalizing. Always safe, at any point.
    func abandon() async {
        await engine.abandon()
        resultsTask?.cancel()
        resultsTask = nil
        if !state.isTerminal { state = .done }
    }

    // MARK: Runs and the clock

    /// Open a fresh converter run at a true capture-frame offset.
    ///
    /// Called on every discontinuity — an overflow drop, a suspension, a resume — and
    /// once at the first chunk. The alternative rev 1 proposed, an accumulator over
    /// emitted frames, is contiguous by construction and therefore cannot express a
    /// gap: every timestamp after a drop would be early by exactly the omitted
    /// duration, compressing the transcript against the audio.
    private func openRun(from input: AVAudioFormat, to analysis: AVAudioFormat) {
        let converter = AVAudioConverter(from: input, to: analysis)
        // Measured (design §10.6): with the default `.normal` priming, 6 × 4800 input
        // frames yield 9594 output frames instead of 9600 — six frames swallowed per
        // run by the resampler's priming. `.none` converts exactly. Nothing here wants
        // priming: the analyzer is fed a stream whose alignment we assert, not a
        // rendered signal whose transient we care about.
        converter?.primeMethod = .none
        self.converter = converter
        runCount += 1
        primingOffset = converter.map {
            CMTime(value: Int64($0.primeInfo.leadingFrames), timescale: CMTimeScale(input.sampleRate))
        } ?? .zero
    }

    /// The chunk's own capture-frame offset, straight off the axis — **not** an
    /// accumulator over frames the converter emitted.
    ///
    /// Deliberate deviation from design §2 step 3, which specifies
    /// `runStartCaptureFrame + emittedInRun`. Measured here (see
    /// `testConverterLagsByAConstantNumberOfOutputFrames`): converting 4800 frames at
    /// 48 kHz yields 1360 frames at 16 kHz, not 1600 — the resampler retains ~15 ms in
    /// its delay line, and `primeInfo.leadingFrames` reports 0, so the priming
    /// subtraction §2 relies on cannot see it. An emitted-frame accumulator therefore
    /// drifts against the true axis and, because each run re-primes, the drift *resets*
    /// at every discontinuity — putting a ~15 ms step in the timeline at exactly the
    /// boundaries §2 exists to make honest.
    ///
    /// Stamping from `StampedChunk.startFrame` has none of that: it is the authoritative
    /// capture-frame position, exact at every run start, monotonic by construction, and
    /// it makes the milestone's central claim literally rather than approximately true —
    /// transcript time *is* capture-frame time *is* position in `final/recording.m4a`.
    /// The residual is the converter's group delay, bounded by the ~15 ms measured
    /// above, constant, and identical on a re-derive through the same path.
    /// `primingOffset` is recorded but **not** subtracted: `primeMethod = .none` means
    /// no priming is applied, so there is nothing to correct for. It is kept as a
    /// measured quantity that `testConverterConvertsExactlyWithPrimingDisabled` pins,
    /// so an SDK change that reintroduces priming trips a test rather than quietly
    /// shifting every timestamp.
    private func bufferStartTime(at captureFrame: Int64) -> CMTime {
        let inputRate = inputAV?.sampleRate ?? 48_000
        return CMTime(value: captureFrame, timescale: CMTimeScale(inputRate))
    }

    private func recordSkip(_ range: FrameRange) {
        if let last = skipped.last, last.isContiguous(with: range) {
            skipped[skipped.count - 1].end = range.end
        } else {
            skipped.append(range)
        }
    }

    // MARK: Results

    private func drainResults() {
        let results = engine.results
        resultsTask = Task { [weak self] in
            do {
                for try await result in results {
                    await self?.apply(result)
                }
            } catch {
                await self?.fail(error)
            }
        }
    }

    private func apply(_ result: TranscriptResult) {
        consolidator.apply(result)
    }

    private func fail(_ error: Error) {
        guard !state.isTerminal else { return }
        state = .failed(TranscriptionFailure(error))
    }

    // MARK: Bounded finalize

    /// True if finalize completed inside the bound.
    ///
    /// The loser is cancelled rather than awaited — a task group would otherwise wait
    /// for the hung child on scope exit and the bound would be decorative. Cancelling
    /// only helps if finalize observes cancellation; when it does not, `abandon()` →
    /// `cancelAndFinishNow()` is what actually unsticks the analyzer, which is why the
    /// caller issues it unconditionally on the false branch.
    private func finalizedWithinBound() async -> Bool {
        let engine = self.engine
        let work = Task { () -> Bool in
            do { try await engine.finalizeAndFinish(); return true } catch { return false }
        }
        return await withTaskGroup(of: Bool?.self) { group in
            group.addTask {
                await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            }
            group.addTask { [finalizeBound] in
                try? await Task.sleep(for: finalizeBound)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? false
        }
    }

    // MARK: Buffers

    /// A **fresh** buffer per chunk. See the `AnalyzerInput` trap above.
    private static func buffer(from chunk: PCMChunk, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard chunk.frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk.frameCount),
              let channel = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = chunk.frameCount
        let wanted = Int(chunk.frameCount)
        chunk.data.withUnsafeBytes { raw in
            let source = raw.bindMemory(to: Float.self)
            channel.update(from: source.baseAddress!, count: min(wanted, source.count))
        }
        return buffer
    }

    private static func convert(_ input: AVAudioPCMBuffer,
                                using converter: AVAudioConverter,
                                to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / input.format.sampleRate
        // Generous, and deliberately not ratio-tight. The converter delivers output
        // lumpily — it holds ~235 frames back for several calls, then flushes a burst
        // measured at 1.7× the ratio's worth. A ratio-sized buffer silently clips that
        // burst, which *would* be real audio loss.
        let capacity = AVAudioFrameCount(Double(input.frameLength) * max(ratio, 1) * 2) + 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return input
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}
