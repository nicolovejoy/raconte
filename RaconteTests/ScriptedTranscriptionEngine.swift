import Foundation
import AVFoundation
import CoreMedia
import Speech
@testable import Raconte

/// A `TranscriptionEngine` with no models and no hardware, so consolidation, frame
/// accounting, and shutdown ordering are all reachable on CI (design §8).
///
/// It records its call sequence, which is the point: shutdown ordering is a contract
/// the real SDK enforces by *hanging*, and a hang is a useless test failure. Here a
/// violation is recorded and asserted instead.
final class ScriptedTranscriptionEngine: TranscriptionEngine, @unchecked Sendable {

    enum Call: Equatable {
        case prepare, start, ingest, finishInput, finalizeAndFinish, abandon
    }

    let results: AsyncThrowingStream<TranscriptResult, Error>
    private let continuation: AsyncThrowingStream<TranscriptResult, Error>.Continuation

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _inputs: [AnalyzerInput] = []
    private var _sawFinishInput = false
    private var _finalizeBeforeFinishInput = false

    /// Thrown from `prepare`. Set a `TranscriptionUnavailable` to exercise the
    /// unavailable path, anything else for the failed path.
    var prepareError: Error?
    var startError: Error?
    /// What `prepare` reports as the analyzer's preferred format.
    var analysisFormat = AudioFormatDescriptor(
        sampleRate: 16_000, channels: 1, commonFormat: .pcmFormatFloat32, interleaved: false)
    /// Makes `finalizeAndFinish` outlast the session's bound. Cancellable, so the
    /// session's race can actually reclaim it.
    var finalizeStall: Duration?

    init() {
        (results, continuation) = AsyncThrowingStream<TranscriptResult, Error>.makeStream()
    }

    // MARK: Recorded state

    var calls: [Call] { lock.withLock { _calls } }
    var inputs: [AnalyzerInput] { lock.withLock { _inputs } }
    var bufferStartTimes: [CMTime] { lock.withLock { _inputs.compactMap(\.bufferStartTime) } }
    /// True if `finalizeAndFinish()` was ever reached without a prior `finishInput()`
    /// — the failure mode that costs one bounded wait on every capture.
    var violatedShutdownOrder: Bool { lock.withLock { _finalizeBeforeFinishInput } }

    // MARK: Scripting

    func emit(_ result: TranscriptResult) { continuation.yield(result) }
    func emitFailure(_ error: Error) { continuation.finish(throwing: error) }
    func endResults() { continuation.finish() }

    // MARK: TranscriptionEngine

    func prepare(inputFormat: AudioFormatDescriptor) async throws -> AudioFormatDescriptor {
        lock.withLock { _calls.append(.prepare) }
        if let prepareError { throw prepareError }
        return analysisFormat
    }

    func start() async throws {
        lock.withLock { _calls.append(.start) }
        if let startError { throw startError }
    }

    func ingest(_ input: AnalyzerInput) async {
        lock.withLock {
            _calls.append(.ingest)
            _inputs.append(input)
        }
    }

    func finishInput() async {
        lock.withLock {
            _calls.append(.finishInput)
            _sawFinishInput = true
        }
    }

    func finalizeAndFinish() async throws {
        lock.withLock {
            _calls.append(.finalizeAndFinish)
            if !_sawFinishInput { _finalizeBeforeFinishInput = true }
        }
        if let finalizeStall {
            try await Task.sleep(for: finalizeStall)
        }
        continuation.finish()
    }

    func abandon() async {
        lock.withLock { _calls.append(.abandon) }
        continuation.finish()
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
