import Foundation
import AVFoundation
import CoreMedia
import Speech

/// The real `SpeechAnalyzer` behind the `TranscriptionEngine` seam (M2 T4, design §1
/// and §6), running whichever transcription module `TranscriptionModuleSelector` picked
/// — `SpeechTranscriber`, or `DictationTranscriber` as the §6.1 fallback.
///
/// Everything hardware- and model-dependent lives here and in
/// `TranscriptionModuleCandidate.swift`, and nothing else in the app imports `Speech`
/// for behavior. `TranscriptionSession` owns the clock, the converter, and shutdown
/// ordering; this owns the SDK's sharp edges:
///
/// - **The analyzer never converts audio.** Buffers must already be in
///   `bestAvailableAudioFormat`, which returns `nil` while assets are missing — that
///   `nil` is the runtime signal for "not ready", not an error to report.
/// - **`start(inputSequence:)` may be called once.** *"The analyzer can only analyze one
///   input sequence at a time"*, and starting again renders the previous sequence
///   inoperable, so there is no re-`start` path here.
/// - **Finalization is driven by `resultsFinalizationTime`**, mapped onto the capture-frame
///   axis and handed to the consolidator. Waiting for a matching final per range loses
///   every phrase the transcriber gets right the first time (design §11.1).
///
/// An actor because the SDK objects are, but `results` is a `nonisolated let` so the
/// session can attach its drain without awaiting.
actor SpeechAnalyzerEngine: TranscriptionEngine {

    nonisolated let results: AsyncThrowingStream<TranscriptResult, Error>
    private nonisolated let resultsContinuation: AsyncThrowingStream<TranscriptResult, Error>.Continuation

    private let requestedLocale: Locale
    private let candidates: [any TranscriptionModuleCandidate]

    private var analyzer: SpeechAnalyzer?
    /// The candidate selection settled on — the owner of the running module and of the
    /// results drain, because only it knows the module's concrete `Result` type.
    private var selected: (any TranscriptionModuleCandidate)?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var forwardingTask: Task<Void, Never>?

    /// The capture's input rate. Every `CMTime` the analyzer hands back is on the axis we
    /// stamped `bufferStartTime` with, so this is the timescale to convert *from*.
    private var inputRate: Double = 48_000

    init(locale: Locale = .current,
         candidates: [any TranscriptionModuleCandidate] = TranscriptionModuleSelector.defaultCandidates()) {
        self.requestedLocale = locale
        self.candidates = candidates
        (results, resultsContinuation) = AsyncThrowingStream<TranscriptResult, Error>.makeStream()
    }

    // MARK: Prepare

    func prepare(inputFormat: AudioFormatDescriptor) async throws -> TranscriptionSetup {
        // §6/§6.1: `SpeechTranscriber`, else `DictationTranscriber`, else an honest
        // `TranscriptionUnavailable`. The gate is a real analysis format per module —
        // never `AssetInventory.status`, and never one module's format reused for the
        // other. See `TranscriptionModuleSelector`.
        let selection = try await TranscriptionModuleSelector.select(from: candidates,
                                                                    requestedLocale: requestedLocale,
                                                                    inputFormat: inputFormat)

        // The descriptor already round-tripped inside the candidate (§11.7), where the
        // original `AVAudioFormat` still existed to compare against; rebuilding it here
        // therefore yields the analyzer's own format, and it is the same object the
        // session will convert to.
        guard let module = await selection.candidate.speechModule(),
              let analysisAV = selection.analysisFormat.avAudioFormat else {
            throw TranscriptionUnavailable.noAnalysisFormat
        }

        let analyzer = SpeechAnalyzer(
            modules: [module],
            options: SpeechAnalyzer.Options(priority: .userInitiated,
                                            modelRetention: .whileInUse))

        // "To reduce or eliminate delays in analyzing the first audio input." Best-effort:
        // a preheat failure is not a reason to abandon a transcription that may still run.
        try? await analyzer.prepareToAnalyze(in: analysisAV)

        self.selected = selection.candidate
        self.analyzer = analyzer
        self.inputRate = Double(inputFormat.sampleRate)

        return TranscriptionSetup(generator: selection.generator,
                                  locale: selection.locale.identifier,
                                  analysisFormat: selection.analysisFormat)
    }

    // MARK: Run

    func start() async throws {
        guard let analyzer, let selected else {
            throw TranscriptionUnavailable.other("start() before a successful prepare()")
        }
        let (inputs, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation

        // Attach the drain before starting: results can arrive as soon as audio does.
        forwardingTask = await selected.forwardResults(inputRate: inputRate,
                                                       into: resultsContinuation)

        // The push model. `analyzeSequence(_:)` is the pull alternative and does not
        // return until the sequence is consumed, which is the wrong shape for a seam whose
        // caller feeds it chunk by chunk.
        try await analyzer.start(inputSequence: inputs)
    }

    func ingest(_ input: AnalyzerInput) async {
        inputContinuation?.yield(input)
    }

    func finishInput() async {
        inputContinuation?.finish()
        inputContinuation = nil
    }

    func finalizeAndFinish() async throws {
        guard let analyzer else { return }
        // Mandatory ordering, and the SDK is stricter than §4 stated: this waits for the
        // input sequence to terminate, and *"if there is no input sequence, this method
        // waits until there is an input sequence and the sequence terminates"* — so
        // calling it without `finishInput()` first does not merely delay, it never
        // returns. The session's bounded wait is the backstop, not the plan.
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        resultsContinuation.finish()
    }

    func abandon() async {
        inputContinuation?.finish()
        inputContinuation = nil
        // *"You do not need to call this method before releasing this analyzer"* — but it
        // is what actually unsticks a finalize that outran its bound, which is why the
        // session issues it unconditionally on that path.
        await analyzer?.cancelAndFinishNow()
        forwardingTask?.cancel()
        forwardingTask = nil
        resultsContinuation.finish()
    }

    // MARK: Results

    /// Map an SDK result onto the capture-frame axis.
    ///
    /// Everything the analyzer reports is already on the axis we stamped
    /// `bufferStartTime` with, so this is a rescale, not a reinterpretation — which is
    /// exactly what makes a live result and one re-derived from `final/recording.m4a`
    /// directly comparable (§2).
    ///
    /// Generic over `TimedTextResult` so `SpeechTranscriber.Result` and
    /// `DictationTranscriber.Result` — separate types with identical shape — share one
    /// implementation of the frame math rather than two that can drift.
    static func map<R: TimedTextResult>(_ result: R, inputRate: Double) -> TranscriptResult {
        let start = frame(result.range.start, inputRate: inputRate)
        let end = frame(CMTimeRangeGetEnd(result.range), inputRate: inputRate)

        return TranscriptResult(
            text: String(result.text.characters),
            range: FrameRange(start: start, end: max(start, end)),
            isVolatile: !result.isFinal,
            confidence: nil,
            finalizedThroughFrame: frame(result.resultsFinalizationTime, inputRate: inputRate),
            runs: runs(of: result.text, inputRate: inputRate),
            analyzerStart: result.range.start,
            analyzerEnd: CMTimeRangeGetEnd(result.range))
    }

    /// `CMTimeConvertScale` rather than `seconds * rate`.
    ///
    /// The SDK's stated reason for refusing to resample audio is *"to keep `CMTime` values
    /// sample-accurate"*; routing through `Double` throws away exactly that. Invalid times
    /// map to 0 rather than trapping — a garbage timestamp is a derived-path fault.
    static func frame(_ time: CMTime, inputRate: Double) -> Int64 {
        guard time.isValid, !time.isIndefinite else { return 0 }
        let scaled = CMTimeConvertScale(time,
                                        timescale: CMTimeScale(inputRate),
                                        method: .roundHalfAwayFromZero)
        return max(0, scaled.value)
    }

    /// Flatten the `AttributedString` run attributes (§3).
    ///
    /// Frame bounds are optional because the SDK says so: *"the string can include runs
    /// without a time range attribute"*, and timed runs are *"not necessarily
    /// contiguous"*. An untimed run still carries text worth keeping.
    static func runs(of text: AttributedString, inputRate: Double) -> [TranscriptRun] {
        text.runs.map { run in
            let span = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self]
            return TranscriptRun(
                text: String(text[run.range].characters),
                captureFrameStart: span.map { frame($0.start, inputRate: inputRate) },
                captureFrameEnd: span.map { frame(CMTimeRangeGetEnd($0), inputRate: inputRate) },
                confidence: run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self])
        }
    }
}
