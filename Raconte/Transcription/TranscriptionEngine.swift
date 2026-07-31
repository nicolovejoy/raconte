import Foundation
import AVFoundation
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
    func prepare(inputFormat: AudioFormatDescriptor) async throws -> AudioFormatDescriptor
    func start() async throws
    func ingest(_ input: AnalyzerInput) async
    /// Terminate the input sequence. Mandatory before `finalizeAndFinish()`.
    func finishInput() async
    func finalizeAndFinish() async throws
    /// Give up without finalizing (→ `cancelAndFinishNow()`). Always safe.
    func abandon() async

    var results: AsyncThrowingStream<TranscriptResult, Error> { get }
}
