import Foundation
import Observation

/// Merge overlapping/adjacent capture-frame ranges into a minimal covering set.
///
/// Needed because the two ledgers overlap by construction: `BoundedPCMSink.dropped`
/// records what the sink never delivered, and `TranscriptionSession.skippedRanges`
/// records the discontinuity the session then *observes* for that same span, plus
/// chunks it received and could not use. Summing them double-counts, which would make
/// `coverageFrames` understate coverage and offer a re-derive that isn't needed.
///
/// Pure and free-standing so it is testable without a capture.
enum FrameRangeSet {
    static func union(_ ranges: [FrameRange]) -> [FrameRange] {
        let sorted = ranges.filter { $0.frameCount > 0 }.sorted { $0.start < $1.start }
        var merged: [FrameRange] = []
        for range in sorted {
            if var last = merged.last, range.start <= last.end {
                last.end = max(last.end, range.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    static func frameCount(_ ranges: [FrameRange]) -> Int64 {
        union(ranges).reduce(0) { $0 + $1.frameCount }
    }
}

/// One capture's live transcription, from the sink the tee fans into through to the
/// `TranscriptRef` the manifest carries (design §4, wired in T3).
///
/// `@MainActor` because it is UI-facing state and the capture screen observes it; the
/// actual work happens in the `TranscriptionSession` actor it owns, and the log writer
/// lives inside that actor so records never touch the main thread.
@MainActor
@Observable
final class LiveTranscriptionRun {

    let captureID: String
    /// The tee's second branch. Handed straight back to the coordinator's factory.
    let sink: BoundedPCMSink

    /// Created at `activate`, not at init.
    ///
    /// The split is forced by the capture path, not chosen: the tee is assembled inside
    /// `configureAndStart` and needs the sink *then*, but the capture format only reads
    /// back after `recorder.start` returns. The sink needs no format; the session cannot
    /// exist without one. So the sink is born here and the session a moment later.
    private var session: TranscriptionSession?
    private var pump: Task<Void, Never>?

    /// Committed text plus the current hypothesis — the capture screen's ghost text.
    /// Never persisted; `TranscriptionSession` keeps the two separate for exactly that.
    private(set) var displayText: String = ""
    private(set) var isRunning = false

    /// `capacity` in chunks. Generous: overflow costs a converter restart and a recorded
    /// gap, and the tee delivers unconditionally, so a deep buffer is cheaper than a
    /// truthful-but-avoidable hole in the transcript.
    init(captureID: String, captureDirectory: URL, capacity: Int = 256) {
        self.captureID = captureID
        self.captureDirectory = captureDirectory
        self.sink = BoundedPCMSink(capacity: capacity)
    }

    private let captureDirectory: URL

    /// Stand up the session and begin draining, now that the format is known.
    func activate(inputFormat: AudioFormatDescriptor, engine: any TranscriptionEngine) {
        guard session == nil else { return }
        let session = TranscriptionSession(engine: engine,
                                           inputFormat: inputFormat,
                                           captureDirectory: captureDirectory)
        self.session = session
        start(session)
    }

    private func start(_ session: TranscriptionSession) {
        guard pump == nil else { return }
        isRunning = true
        let stream = sink.stream
        pump = Task { [weak self] in
            await session.start()
            // Publishing on a timer rather than per result: the consolidator revises and
            // revokes, so the only correct thing to show is the whole current view, and
            // recomputing it at speaking cadence is cheaper than diffing it.
            let ticker = Task { [weak self] in
                while !Task.isCancelled {
                    let text = await session.displayText
                    await MainActor.run { self?.displayText = text }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            await session.consume(stream)
            ticker.cancel()
            let final = await session.committedText
            await MainActor.run {
                self?.displayText = final
                self?.isRunning = false
            }
        }
    }

    /// End the capture's transcription and report what to record on the manifest.
    ///
    /// Returns `nil` when there is nothing worth recording — no log was ever opened, so
    /// no `transcript/` exists and a ref would claim otherwise.
    func finish() async -> TranscriptRef? {
        // Finishing the sink ends the chunk stream, which is what makes `consume` fall
        // through to the session's ordered shutdown. There is no separate stop signal.
        sink.finish()
        await pump?.value
        pump = nil

        guard let session,
              await session.hasLog,
              let generator = await session.generator,
              let locale = await session.locale
        else { return nil }

        let ingested = sink.ingestedFrames
        let skipped = FrameRangeSet.union(sink.dropped + (await session.skippedRanges))

        return TranscriptRef(
            generator: generator,
            locale: locale,
            coverageFrames: max(0, ingested - FrameRangeSet.frameCount(skipped)),
            skippedRanges: skipped,
            committedRecords: await session.committedRecords,
            completedAt: Date(),
            latestRevision: nil)
    }

    /// Drop everything without finalizing. For the paths where the capture never
    /// started — a denied permission, a failed activate — where awaiting a finalize
    /// would be waiting on an analyzer that never saw audio.
    func abandon() async {
        sink.finish()
        pump?.cancel()
        pump = nil
        await session?.abandon()
        isRunning = false
    }
}

/// Owns the per-capture runs and is the seam the composition root injects.
///
/// Separate from `CaptureScreenModel` because the coordinator's `SecondarySinkFactory`
/// must be built *before* the model exists — the model's init constructs the coordinator
/// — so the factory closure captures this instead of the model.
@MainActor
@Observable
final class LiveTranscriptionCoordinator {

    private let capturesRoot: URL
    private let makeEngine: @MainActor () -> (any TranscriptionEngine)?

    /// Keyed by capture id, not a single slot: `finishCurrentCapture()` spawns the next
    /// coordinator immediately, so capture N+1 can begin while N is still draining.
    private var runs: [String: LiveTranscriptionRun] = [:]

    private(set) var activeCaptureID: String?

    var displayText: String {
        activeCaptureID.flatMap { runs[$0]?.displayText } ?? ""
    }

    var isRunning: Bool {
        activeCaptureID.flatMap { runs[$0]?.isRunning } ?? false
    }

    init(capturesRoot: URL, makeEngine: @escaping @MainActor () -> (any TranscriptionEngine)?) {
        self.capturesRoot = capturesRoot
        self.makeEngine = makeEngine
    }

    /// The `SecondarySinkFactory` body: build the run and hand back its sink.
    ///
    /// Only the sink — the session cannot be built here, because the capture format is
    /// unknown until `recorder.start` returns and the factory deliberately receives only
    /// the id. `activate` finishes the job once the format is readable. The sink is inert
    /// until then: it buffers stamped chunks and nothing consumes them, which is exactly
    /// what `BoundedPCMSink` is built to survive.
    func begin(captureID: String) -> (any PCMSink)? {
        let directory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot,
                                                       captureID: captureID)
        let run = LiveTranscriptionRun(captureID: captureID, captureDirectory: directory)
        runs[captureID] = run
        activeCaptureID = captureID
        return run.sink
    }

    /// Stand up the session now that the format is known.
    ///
    /// Called from the capture screen when the coordinator reaches `.recording`.
    /// Idempotent — the phase can be observed more than once.
    func activate(captureID: String, inputFormat: AudioFormatDescriptor) {
        guard let run = runs[captureID], let engine = makeEngine() else { return }
        run.activate(inputFormat: inputFormat, engine: engine)
    }

    func finish(captureID: String) async -> TranscriptRef? {
        guard let run = runs.removeValue(forKey: captureID) else { return nil }
        if activeCaptureID == captureID { activeCaptureID = nil }
        return await run.finish()
    }

    func abandon(captureID: String) async {
        guard let run = runs.removeValue(forKey: captureID) else { return }
        if activeCaptureID == captureID { activeCaptureID = nil }
        await run.abandon()
    }
}
