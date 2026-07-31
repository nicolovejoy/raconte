import Foundation
import AVFoundation
import CoreMedia
import Speech

/// One transcription result on the capture-frame axis (M2 design §4).
///
/// `range` is in capture frames, not wall clock and not analyzer time, so a live
/// result and one re-derived from `final/recording.m4a` are directly comparable —
/// that comparability is the whole point of the axis choice (design §2).
///
/// `isVolatile` results are provisional: they are revised, superseded, or revoked
/// (by a later empty-text result over the same range) and must never be promoted
/// to final by anything but `resultsFinalizationTime` moving past them.
struct TranscriptResult: Sendable, Equatable {
    var text: String
    var range: FrameRange
    var isVolatile: Bool
    /// Present only when the transcriber attributed one; `nil` is not "zero".
    var confidence: Double?

    /// How far the transcriber has settled, **on the capture-frame axis** — the SDK's
    /// `SpeechModuleResult.resultsFinalizationTime` mapped onto the same axis as
    /// `range`, by the engine, for the same reason `range` is.
    ///
    /// Load-bearing, not informational. Apple documents that a module *is not required*
    /// to reissue a final result for a range it finalizes through when the volatile
    /// hypothesis was unchanged:
    ///
    /// > A module is not required to provide new, final results for audio ranges that it
    /// > finalizes through if the previously-volatile result was unchanged by
    /// > finalization.
    ///
    /// So waiting for `isVolatile == false` to arrive over a span loses every phrase the
    /// transcriber got right the first time: it is finalized by this marker advancing,
    /// never reissued, and then swept out of the volatile overlay by the next overlapping
    /// result. The live screen looks correct throughout while the persisted transcript
    /// silently drops phrases. `TranscriptConsolidator` promotes off this instead.
    ///
    /// `nil` means the engine did not report one — no promotion is implied, only absence
    /// of new information.
    var finalizedThroughFrame: Int64?

    /// The flattened `AttributedString` run attributes, already mapped onto the
    /// capture-frame axis by the engine — the only layer that knows the analyzer
    /// timebase, exactly as it already is for `range`. Empty when the transcriber
    /// attributed none.
    var runs: [TranscriptRun] = []

    /// Revision-local analyzer time, straight off `SpeechTranscriber.Result.range`, kept
    /// so `live.jsonl` can record it (design §3). **Never comparable across revisions.**
    ///
    /// `CMTime` is `Sendable` under `-strict-concurrency=complete` (verified by
    /// compiling a `requireSendable(CMTime.self)` probe), so unlike `AVAudioFormat` it
    /// crosses this seam directly and needs no value-type stand-in.
    ///
    /// Optional rather than `.invalid`: `CMTime`'s `==` routes through `CMTimeCompare`,
    /// which is not meaningful for invalid times, and `Equatable` here is load-bearing
    /// for `TranscriptConsolidator`'s tests.
    var analyzerStart: CMTime?
    var analyzerEnd: CMTime?
}

/// What `prepare` settled on.
///
/// Grouped rather than three separate protocol requirements because all three are one
/// decision made *inside* `prepare` — the module fallback, the locale resolution, and
/// the analyzer's preferred format. As properties they would simply be unpopulated
/// before it, which is a shape that invites reading them too early.
struct TranscriptionSetup: Sendable, Equatable {
    /// `"SpeechTranscriber"` or `"DictationTranscriber"` — the module actually used.
    /// A fallback decision only the engine makes, and §3 requires it per record.
    var generator: String

    /// The **resolved** locale, not the requested one. `supportedLocale(equivalentTo:)`
    /// can return a near-equivalent that is not `==` the request — a different region
    /// with the same language, which is how you get "colour" for "color" (design §6.2).
    var locale: String

    var analysisFormat: AudioFormatDescriptor
}

/// `SpeechAnalyzer`/`SpeechTranscriber` behind a seam so consolidation, frame
/// accounting, and shutdown ordering are testable against a scripted fake with no
/// models and no hardware (design §11).
///
/// Shutdown ordering is part of the contract, not a suggestion:
/// `finishInput()` must precede `finalizeAndFinish()`. The underlying
/// `finalizeAndFinishThroughEndOfInput()` *waits for the input sequence to
/// terminate*, and finishing the chunk stream does not by itself finish the
/// session — calling finalize first hangs until the bounded wait expires, on every
/// capture. `abandon()` is the only correct call after that bound.
protocol TranscriptionEngine: Sendable {
    /// Resolve the analyzer's preferred format and stand up the modules.
    ///
    /// Deviates from design §4's `prepare(format: AVAudioFormat)` in two ways, both
    /// forced. `AVAudioFormat` is a non-`Sendable` class, so it cannot cross into a
    /// `Sendable` protocol under strict concurrency — `AudioFormatDescriptor` is the
    /// codebase's existing value-type stand-in (`SegmentSidecar.swift:6`), with
    /// conversions both ways already written. And the *return* is new: the converter
    /// lives in `TranscriptionSession`, so the session must learn the analysis format
    /// from somewhere, and `bestAvailableAudioFormat` is behind this seam by
    /// construction. Throwing `TranscriptionUnavailable` covers its `nil` case.
    ///
    /// Returns `TranscriptionSetup` rather than a bare format because `generator` and
    /// `locale` are resolved here too and are otherwise unreachable — §3 requires both
    /// on every record, and nothing outside the engine can know either.
    func prepare(inputFormat: AudioFormatDescriptor) async throws -> TranscriptionSetup
    func start() async throws
    func ingest(_ input: AnalyzerInput) async
    /// Terminate the input sequence. Mandatory before `finalizeAndFinish()`.
    func finishInput() async
    func finalizeAndFinish() async throws
    /// Give up without finalizing (→ `cancelAndFinishNow()`). Always safe.
    func abandon() async

    var results: AsyncThrowingStream<TranscriptResult, Error> { get }
}
