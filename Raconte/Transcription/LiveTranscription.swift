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
    private(set) var runs: [ConsolidatedTranscriptRun] = []
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
                    let runs = await session.runs
                    await MainActor.run {
                        self?.runs = runs
                        self?.displayText = TranscriptText.join(runs.map(\.text))
                    }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            await session.consume(stream)
            ticker.cancel()
            let final = await session.committedText
            await MainActor.run {
                self?.displayText = final
                self?.runs = final.isEmpty ? [] : [ConsolidatedTranscriptRun(text: final, range: FrameRange(start: 0, end: 0), isProvisional: false)]
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
    ///
    /// Named `liveRuns`, not `runs`: `runs` is the `[ConsolidatedTranscriptRun]` computed
    /// property below (#118 §5), and the two names collided.
    private var liveRuns: [String: LiveTranscriptionRun] = [:]

    private(set) var activeCaptureID: String?

    /// Ids whose `finish()` is in flight. `liveRuns` used to serve as this guard by
    /// removing up front; it can't any more, because the run must stay in the map across
    /// the await so the panel keeps rendering. See `finish(captureID:)`.
    private var finishing: Set<String> = []

    /// The finished capture's text, held until the next one begins.
    ///
    /// Without it the panel blanks the moment a capture completes, which is the same
    /// "it stopped transcribing early" illusion the ordering fix below removes — just
    /// moved a beat later.
    private(set) var lastCompletedText: String = ""

    var displayText: String {
        if let id = activeCaptureID, let run = liveRuns[id] { return run.displayText }
        return lastCompletedText
    }

    /// The active run's runs; outside a capture, the last completed text as one
    /// committed run (the receipt covers this on the ordinary path — see `displayText`).
    var runs: [ConsolidatedTranscriptRun] {
        if let id = activeCaptureID, let run = liveRuns[id] { return run.runs }
        return lastCompletedText.isEmpty
            ? [] : [ConsolidatedTranscriptRun(text: lastCompletedText, range: FrameRange(start: 0, end: 0), isProvisional: false)]
    }

    var isRunning: Bool {
        activeCaptureID.flatMap { liveRuns[$0]?.isRunning } ?? false
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
        liveRuns[captureID] = run
        activeCaptureID = captureID
        lastCompletedText = ""
        return run.sink
    }

    /// Stand up the session now that the format is known.
    ///
    /// Called from the capture screen when the coordinator reaches `.recording`.
    /// Idempotent — the phase can be observed more than once.
    func activate(captureID: String, inputFormat: AudioFormatDescriptor) {
        guard let run = liveRuns[captureID], let engine = makeEngine() else { return }
        run.activate(inputFormat: inputFormat, engine: engine)
    }

    /// Unhook the view only *after* the run has finished, never before.
    ///
    /// `run.finish()` awaits the pump, and the pump's tail is what publishes the
    /// analyzer's finalized text into `displayText` — the last phrase of a capture is
    /// produced *during* shutdown, not before it. Removing the run and clearing
    /// `activeCaptureID` up front blanked the panel the instant stop began, so those
    /// words reached `live.jsonl` and were never rendered. Read on the 2026-08-02 iPhone
    /// pass as "the transcript stopped a few words early"; nothing was ever lost.
    func finish(captureID: String) async -> TranscriptRef? {
        guard let run = liveRuns[captureID], !finishing.contains(captureID) else { return nil }
        finishing.insert(captureID)
        let ref = await run.finish()
        finishing.remove(captureID)
        lastCompletedText = run.displayText
        liveRuns.removeValue(forKey: captureID)
        // Only if the next capture hasn't already claimed the slot during the await —
        // `finishCurrentCapture()` spawns the successor immediately.
        if activeCaptureID == captureID { activeCaptureID = nil }
        return ref
    }

    func abandon(captureID: String) async {
        guard let run = liveRuns.removeValue(forKey: captureID) else { return }
        if activeCaptureID == captureID { activeCaptureID = nil }
        await run.abandon()
    }
}
