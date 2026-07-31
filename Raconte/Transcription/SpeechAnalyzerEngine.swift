import Foundation
import AVFoundation
import CoreMedia
import Speech

/// The real `SpeechAnalyzer`/`SpeechTranscriber` behind the `TranscriptionEngine` seam
/// (M2 T4, design §1 and §6).
///
/// Everything hardware- and model-dependent lives here, and nothing else in the app
/// imports `Speech` for behavior. `TranscriptionSession` owns the clock, the converter,
/// and shutdown ordering; this owns the SDK's sharp edges:
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

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var forwardingTask: Task<Void, Never>?

    /// The capture's input rate. Every `CMTime` the analyzer hands back is on the axis we
    /// stamped `bufferStartTime` with, so this is the timescale to convert *from*.
    private var inputRate: Double = 48_000

    init(locale: Locale = .current) {
        self.requestedLocale = locale
        (results, resultsContinuation) = AsyncThrowingStream<TranscriptResult, Error>.makeStream()
    }

    // MARK: Prepare

    func prepare(inputFormat: AudioFormatDescriptor) async throws -> TranscriptionSetup {
        guard SpeechTranscriber.isAvailable else {
            // §6.1: the fallback to `DictationTranscriber` is not wired yet. Reporting
            // `noModel` is honest and the app still records perfectly, which is the
            // milestone's governing rule.
            throw TranscriptionUnavailable.noModel
        }
        guard let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw TranscriptionUnavailable.unsupportedLocale(requestedLocale.identifier)
        }

        // Deliberately not a `Preset`. No shipped preset enables `.transcriptionConfidence`
        // (verified against the preset table in the SDK's own `.swiftdoc`), and
        // `timeIndexedProgressiveTranscription` couples `.volatileResults` with
        // `.fastResults`, which trades accuracy for latency. §10.5 A/Bs that separately.
        let transcriber = SpeechTranscriber(
            locale: resolved,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence])

        // §6: `nil` here is the assets-not-ready signal, and it is the *authoritative*
        // one. Measured on the mini 2026-07-31: nine `en_*` locales installed and a real
        // format returned, while `AssetInventory.status` reported `.supported` rather
        // than `.installed` and `reservedLocales` was empty — status evidently reflects
        // this app's reservation, not whether the model bytes exist. Gating installation
        // on status would fire an `assetInstallationRequest` on a machine that already
        // has everything. So: ask for the format first, and only chase assets when there
        // genuinely is no format to be had.
        var analysisFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber],
            considering: inputFormat.avAudioFormat)

        if analysisFormat == nil {
            try await installAssets(for: transcriber)
            analysisFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [transcriber],
                considering: inputFormat.avAudioFormat)
        }

        guard let analysisAV = analysisFormat else {
            throw TranscriptionUnavailable.noAnalysisFormat
        }

        // The round-trip assertion §11.7 calls for.
        //
        // `AudioFormatDescriptor` is the seam's value-type stand-in for the non-`Sendable`
        // `AVAudioFormat`, and rebuilding from it goes through
        // `AVAudioFormat(commonFormat:sampleRate:channels:interleaved:)` — a *standard*
        // format with a default channel layout, and `.otherFormat` collapses to Float32.
        // If the analyzer ever asks for something that does not survive that, the session
        // would convert to a format the analyzer did not request and the SDK would reject
        // the buffers at ingest, surfacing as an opaque mid-run failure. Failing here
        // instead costs the live pass and keeps re-derivation available.
        let descriptor = AudioFormatDescriptor(from: analysisAV)
        guard let roundTripped = descriptor.avAudioFormat, roundTripped.isEqual(analysisAV) else {
            throw TranscriptionUnavailable.noAnalysisFormat
        }

        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(priority: .userInitiated,
                                            modelRetention: .whileInUse))

        // "To reduce or eliminate delays in analyzing the first audio input." Best-effort:
        // a preheat failure is not a reason to abandon a transcription that may still run.
        try? await analyzer.prepareToAnalyze(in: analysisAV)

        self.transcriber = transcriber
        self.analyzer = analyzer
        self.inputRate = Double(inputFormat.sampleRate)

        return TranscriptionSetup(generator: "SpeechTranscriber",
                                  locale: resolved.identifier,
                                  analysisFormat: descriptor)
    }

    /// Install models. Called **only** when there is no analysis format to be had —
    /// see the gate in `prepare`.
    ///
    /// Nothing about installation state is cached: assets are shared system-wide and the
    /// system *"may unsubscribe your app from assets that haven't been used in a while"*,
    /// so this is re-decided at every capture start (§6.4).
    private func installAssets(for transcriber: SpeechTranscriber) async throws {
        // Advisory only. `.unsupported` means no asset can ever support this locale, so
        // requesting one is pointless; anything above it is worth trying.
        guard await AssetInventory.status(forModules: [transcriber]) > .unsupported else {
            throw TranscriptionUnavailable.noModel
        }
        do {
            // Returns nil when nothing further is needed. Auto-reserves the locale, and
            // throws if that would exceed `maximumReservedLocales` — which varies by
            // device, so it is never hardcoded.
            guard let request = try await AssetInventory.assetInstallationRequest(
                supporting: [transcriber]) else { return }
            try await request.downloadAndInstall()
        } catch {
            throw TranscriptionUnavailable.other("model install failed: \(error)")
        }
    }

    // MARK: Run

    func start() async throws {
        guard let analyzer, let transcriber else {
            throw TranscriptionUnavailable.other("start() before a successful prepare()")
        }
        let (inputs, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation

        // Attach the drain before starting: results can arrive as soon as audio does.
        forwardResults(from: transcriber)

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

    private func forwardResults(from transcriber: SpeechTranscriber) {
        let rate = inputRate
        let continuation = resultsContinuation
        forwardingTask = Task {
            do {
                for try await result in transcriber.results {
                    continuation.yield(Self.map(result, inputRate: rate))
                }
                continuation.finish()
            } catch {
                // *"If there is an error in the overall analysis, all modules will throw
                // the error from their individual result sequence"* — so this is the one
                // and only error path for analysis failures.
                continuation.finish(throwing: error)
            }
        }
    }

    /// Map an SDK result onto the capture-frame axis.
    ///
    /// Everything the analyzer reports is already on the axis we stamped
    /// `bufferStartTime` with, so this is a rescale, not a reinterpretation — which is
    /// exactly what makes a live result and one re-derived from `final/recording.m4a`
    /// directly comparable (§2).
    static func map(_ result: SpeechTranscriber.Result, inputRate: Double) -> TranscriptResult {
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
