import Foundation
import AVFoundation
import CoreMedia
import Speech

/// Resolves a two-way race exactly once, so the loser can be abandoned rather than
/// awaited. `NSLock` rather than an actor: the whole point is that resolving must not
/// suspend, since one caller is a timer that has to win against a task that may never
/// return.
private final class RaceResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resolve(_ value: Bool) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

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

    /// What `prepare` settled on. Nil until it has. The T3 writer needs `generator` and
    /// `locale` on every record and `TranscriptRef` needs both too; neither is knowable
    /// outside the engine, which is why `prepare` reports them.
    private var setup: TranscriptionSetup?

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

    /// Whether the next buffer of the current run must carry an explicit timestamp.
    ///
    /// Only the *first* buffer of a run does. See `ingest` for why stamping every buffer
    /// is not merely redundant but actively wrong.
    private var runNeedsStamp = false

    private(set) var runCount = 0
    private var skipped: [FrameRange] = []
    /// Set the moment a stop is asked for, so `start()` can bail at either of its
    /// suspension points instead of resuming into `.running` after the capture ended.
    private var stopRequested = false

    /// Where `transcript/live.jsonl` goes. `nil` means "do not persist" — the shape most
    /// unit tests want, and the honest representation of a session with nowhere to write.
    private let captureDirectory: URL?
    private var writer: LiveTranscriptWriter?
    /// One complaint per capture. A failing log must not spam, and must not escalate:
    /// §0's rule is that transcription may fail at any moment without touching capture.
    private var loggingBroken = false

    #if DEBUG
    /// Writes exactly what the analyzer is fed, for diagnosing "it transcribes gibberish".
    /// Enabled with `RACONTE_DUMP_ANALYSIS_AUDIO=1`; off in every normal run.
    private lazy var analysisTap: AnalysisAudioTap? = {
        guard ProcessInfo.processInfo.environment["RACONTE_DUMP_ANALYSIS_AUDIO"] == "1",
              let captureDirectory else { return nil }
        return AnalysisAudioTap(directory: captureDirectory)
    }()
    #endif

    init(engine: any TranscriptionEngine,
         inputFormat: AudioFormatDescriptor,
         captureDirectory: URL? = nil,
         finalizeBound: Duration = .seconds(5)) {
        self.engine = engine
        self.inputFormat = inputFormat
        self.captureDirectory = captureDirectory
        self.finalizeBound = finalizeBound
    }

    // MARK: Introspection

    var committedText: String { consolidator.committedText }
    var displayText: String { consolidator.displayText }
    var committed: [TranscriptResult] { consolidator.committed }
    var provisional: [TranscriptResult] { consolidator.provisional }

    /// The module and resolved locale `prepare` settled on — §3 requires both on every
    /// record and on `TranscriptRef`. Nil before `prepare` succeeds.
    var generator: String? { setup?.generator }
    var locale: String? { setup?.locale }

    /// Records actually written to `live.jsonl`. Feeds `TranscriptRef.committedRecords`,
    /// which is the only thing that can detect a torn tail (§11.3).
    var committedRecords: Int { writer?.recordsWritten ?? 0 }

    /// True once a log file exists on disk. Distinct from `committedRecords > 0` only in
    /// the window where `open()` failed.
    var hasLog: Bool { writer != nil }

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

        let setup: TranscriptionSetup
        do {
            setup = try await engine.prepare(inputFormat: inputFormat)
        } catch let unavailable as TranscriptionUnavailable {
            state = .unavailable(unavailable)
            return
        } catch {
            state = .failed(TranscriptionFailure(error))
            return
        }
        if await bailIfStopRequested() { return }

        guard let analysisAV = setup.analysisFormat.avAudioFormat else {
            state = .unavailable(.noAnalysisFormat)
            return
        }
        self.analysisAV = analysisAV
        self.setup = setup

        do {
            try await engine.start()
        } catch {
            state = .failed(TranscriptionFailure(error))
            return
        }
        if await bailIfStopRequested() { return }

        drainResults()
        state = .running
    }

    /// `start()` suspends twice — `prepare` and `start` — and an actor releases its
    /// isolation across every `await`. A `finish()` arriving in either window used to
    /// set `.done` and return, after which `start()` resumed and set `.running`,
    /// leaving the analyzer live and draining forever after the capture had ended.
    ///
    /// Model asset installation makes that window seconds long on first run, so
    /// "user taps Record then Done quickly" reaches it.
    private func bailIfStopRequested() async -> Bool {
        guard stopRequested else { return false }
        await engine.abandon()
        resultsTask?.cancel()
        resultsTask = nil
        closeWriter()
        state = .done
        return true
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
        guard case .running = state, let inputAV, let analysisAV else {
            // A chunk arriving while this session is not running is a *gap*, not a
            // no-op. Returning silently made `coverageFrames` claim full coverage of a
            // capture the analyzer stopped seeing after 0.7 s — measured on the mini —
            // and that number is the whole basis for offering a re-derive. If the
            // session is dead, the honest answer is that none of this audio was read.
            recordSkip(stamped.frameRange)
            return
        }

        if expectedNextFrame != stamped.startFrame {
            await flushCurrentRun()
            if let expected = expectedNextFrame, stamped.startFrame > expected {
                recordSkip(FrameRange(start: expected, end: stamped.startFrame))
            }
            openRun(from: inputAV, to: analysisAV)
            runNeedsStamp = true
        }
        // `max` because a *backwards* startFrame must not rewind the cursor: doing so
        // made every subsequent contiguous chunk look like a discontinuity, re-priming
        // a converter per chunk for the rest of the capture.
        expectedNextFrame = max(expectedNextFrame ?? 0,
                                stamped.startFrame + Int64(stamped.chunk.frameCount))

        // A chunk the transcriber could not use is a *gap*, not a no-op. Returning
        // silently here made `skippedRanges` claim full coverage while the analyzer
        // saw nothing — and T3 persists that claim as the re-derive hint, so the one
        // signal telling the owner their transcript is incomplete would say the
        // opposite. Worst case is total: `AVAudioConverter(from:to:)` returning nil
        // sends every chunk down this path.
        guard stamped.chunk.sampleRate == inputAV.sampleRate else {
            // Resume pins the canonical format, so this is unreachable unless that
            // pinning regresses. Recording it beats stamping every later timestamp
            // wrong by a constant ratio with no trace.
            recordSkip(stamped.frameRange)
            return
        }
        guard let converter,
              let input = Self.buffer(from: stamped.chunk, format: inputAV),
              let output = Self.convert(input, using: converter, to: analysisAV),
              output.frameLength > 0
        else {
            recordSkip(stamped.frameRange)
            return
        }

        #if DEBUG
        analysisTap?.write(output)
        #endif

        // `AnalyzerInput` is `@unchecked Sendable` and the analyzer holds the buffer
        // past this call, so `output` MUST be freshly allocated. The disk path's
        // house style of reusing a scratch buffer would be a silent data race here
        // with no diagnostic (design §2, "Trap").
        // **Only the first buffer of a run is stamped.** Everything after passes `nil`,
        // which the SDK defines as "immediately after the previous buffer".
        //
        // Stamping every buffer was wrong, and measurably so. The converter emits
        // lumpily — it holds ~235 frames back for several calls and then flushes a burst
        // of about 1.7x the ratio's worth — so an output buffer routinely contains audio
        // belonging to *earlier* input chunks. Labelling it with the current chunk's
        // start frame then declares a span that overlaps the buffer before it, and the
        // SDK is explicit: "The audio buffer must not overlap or precede other audio
        // input, as determined by the `bufferStartTime` value." The analyzer answers with
        // `audioDisordered` on the results stream, which kills the session — measured as
        // every 6th buffer overlapping by 73 ms, first violation at 0.6 s, and a live
        // capture that transcribed 0.685 s of a 6.2 s recording and then went quiet.
        //
        // Contiguity is exactly what `nil` expresses, and within a run the converted
        // stream *is* contiguous. Gaps stay expressible because a discontinuity opens a
        // new run, and that run's first buffer carries a real capture-frame stamp.
        let stamp = runNeedsStamp ? bufferStartTime(at: stamped.startFrame) : nil
        runNeedsStamp = false
        await engine.ingest(AnalyzerInput(buffer: output, bufferStartTime: stamp))
    }

    /// Ordered shutdown (§4). `finishInput()` first is mandatory, not stylistic:
    /// `finalizeAndFinishThroughEndOfInput()` waits for the input sequence to
    /// terminate, so finalizing first hangs until the bound expires — on every single
    /// capture.
    func finish() async {
        stopRequested = true
        guard case .running = state else {
            // Mid-`start()`, never started, or already dead. `bailIfStopRequested`
            // handles the first; the rest are terminal by definition.
            if case .preparing = state { return }
            closeWriter()
            if !state.isTerminal { state = .done }
            return
        }
        state = .finishing

        await flushCurrentRun()
        await engine.finishInput()

        if await finalizedWithinBound() == false {
            // Past the bound the only correct call is `cancelAndFinishNow()`. Losing
            // the tail costs a re-derive, not the words — the audio is already on disk.
            await engine.abandon()
        }

        // Drain before cancelling. `finalizeAndFinish()` exists precisely to flush the
        // analyzer's tail into the results stream; cancelling the drain task the
        // instant it returns threw away the words it had just been asked to produce.
        // Both paths finish the results continuation, so the task ends on its own —
        // the bound is only here so a stuck engine can't hold the session open.
        await drainedWithinBound()
        resultsTask?.cancel()
        resultsTask = nil
        closeWriter()
        if !state.isTerminal { state = .done }
    }

    /// Abort without finalizing. Always safe, at any point.
    func abandon() async {
        stopRequested = true
        await engine.abandon()
        resultsTask?.cancel()
        resultsTask = nil
        closeWriter()
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
    /// Flush the outgoing converter's delay line before dropping it.
    ///
    /// The resampler holds real audio back — measured at ~235 output frames — and the
    /// old `openRun` simply replaced the converter, so those frames reached neither the
    /// analyzer nor `skippedRanges`. That is silent timeline compression at every drop,
    /// suspension and resume: precisely the class of loss §2 exists to prevent, and
    /// invisible because the totals only reconcile within one uninterrupted run.
    private func flushCurrentRun() async {
        guard let converter, let analysisAV, let inputAV, let lastFrame = expectedNextFrame else { return }
        var error: NSError?
        let capacity = AVAudioFrameCount(analysisAV.sampleRate) // 1 s of slack, ample
        guard let tail = AVAudioPCMBuffer(pcmFormat: analysisAV, frameCapacity: capacity) else { return }
        let status = converter.convert(to: tail, error: &error) { _, outStatus in
            outStatus.pointee = .endOfStream
            return nil
        }
        guard status != .error, tail.frameLength > 0 else { return }

        // `nil`, not a computed stamp. The delay line holds the audio that *follows*
        // everything already emitted in this run, so it is contiguous by construction —
        // and the old backdated stamp was itself an overlap, declaring a span that
        // reached back into buffers the analyzer had already accepted.
        await engine.ingest(AnalyzerInput(buffer: tail, bufferStartTime: nil))
    }

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
        for logged in consolidator.apply(result) {
            persist(logged)
        }
    }

    /// Append one committed mutation to `live.jsonl`.
    ///
    /// **Every failure is swallowed.** A full disk, a revoked container, a torn write —
    /// none of them may reach the capture path, which is §0's governing rule. The audio
    /// is already on disk and the transcript is re-derivable from it; taking the
    /// recording down to report a logging fault would invert the whole milestone.
    private func persist(_ result: TranscriptResult) {
        guard !loggingBroken, let setup else { return }
        do {
            let writer = try openWriterIfNeeded()
            try writer?.append(TranscriptRecord(result,
                                                generator: setup.generator,
                                                locale: setup.locale))
        } catch {
            loggingBroken = true
        }
    }

    /// Open on first write, never at construction.
    ///
    /// `open()` creates `transcript/` and `O_CREAT`s the file, and `transcriptPresent` is
    /// deliberately "any file at all" — so a zero-byte log flips
    /// `holdsIrreplaceableArtifacts` and turns `.deleteCaptureDirectory` into the
    /// quarantine no-op. Opening eagerly would therefore make every denied-permission tap
    /// and every sub-0.5 s accidental tap leave a permanently undeletable empty directory
    /// (design §11.6). Deferring to the first record means a capture that never produced a
    /// word never creates the directory at all.
    private func openWriterIfNeeded() throws -> LiveTranscriptWriter? {
        if let writer { return writer }
        guard let captureDirectory else { return nil }
        let writer = LiveTranscriptWriter(captureDirectory: captureDirectory)
        try writer.open()
        self.writer = writer
        return writer
    }

    private func closeWriter() {
        try? writer?.close()
        #if DEBUG
        analysisTap?.close()
        #endif
    }

    private func fail(_ error: Error) {
        guard !state.isTerminal else { return }
        state = .failed(TranscriptionFailure(error))
    }

    // MARK: Bounded finalize

    /// True if finalize completed inside the bound.
    ///
    /// **The loser is abandoned, not awaited.** An earlier version raced the two inside
    /// a `withTaskGroup`, which is wrong in exactly the case the bound exists for: a
    /// task group implicitly awaits *every* child before returning, and `await
    /// task.value` is not interrupted by cancellation. So against a finalize that does
    /// not observe cancellation — which `SpeechAnalyzer`'s ObjC-backed
    /// `finalizeAndFinishThroughEndOfInput()` is exactly the kind of call to be — the
    /// bound was decorative and the wait ran to completion anyway. Measured at 5.2 s
    /// against a 100 ms bound before this rewrite.
    ///
    /// Here the finalize task is unstructured and simply left running when the timer
    /// wins; `abandon()` → `cancelAndFinishNow()` is what actually unsticks it, which
    /// is why the caller issues that unconditionally on the false branch.
    private func finalizedWithinBound() async -> Bool {
        let engine = self.engine
        return await withCheckedContinuation { continuation in
            let race = RaceResolver(continuation)
            Task {
                do { try await engine.finalizeAndFinish(); race.resolve(true) }
                catch { race.resolve(false) }
            }
            Task { [finalizeBound] in
                try? await Task.sleep(for: finalizeBound)
                race.resolve(false)
            }
        }
    }

    /// Wait for the results task to end naturally, bounded the same way.
    private func drainedWithinBound() async {
        guard let resultsTask else { return }
        _ = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let race = RaceResolver(continuation)
            Task {
                await resultsTask.value
                race.resolve(true)
            }
            Task { [finalizeBound] in
                try? await Task.sleep(for: finalizeBound)
                race.resolve(false)
            }
        }
    }

    // MARK: Buffers

    /// A **fresh** buffer per chunk. See the `AnalyzerInput` trap above.
    ///
    /// `frameLength` is set from what was actually copied, not from the chunk's claim.
    /// Setting it first and then under-copying handed `AVAudioPCMBuffer`'s uninitialized
    /// tail to the analyzer as if it were audio.
    private static func buffer(from chunk: PCMChunk, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let available = AVAudioFrameCount(chunk.data.count / MemoryLayout<Float>.size)
        let frames = min(chunk.frameCount, available)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channel = buffer.floatChannelData?[0]
        else { return nil }

        let copied: Bool = chunk.data.withUnsafeBytes { raw in
            // No force-unwrap: a non-empty `Data` can still vend a nil base address,
            // and trapping here would kill the app from the derived path.
            guard let base = raw.bindMemory(to: Float.self).baseAddress else { return false }
            channel.update(from: base, count: Int(frames))
            return true
        }
        guard copied else { return nil }
        buffer.frameLength = frames
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
