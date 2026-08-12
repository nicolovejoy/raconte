import Foundation

/// The disk seam the marker-correction screen writes through (T7 Task 6, ruling Q11 —
/// marker correction is its OWN mode, off the detail screen, never inline in the
/// editor). Mirrors `TranscriptEditorStore`'s shape (T7 Task 4): reads are
/// `nonisolated async` off whatever actor the caller is on, writes are plain `async
/// throws` passthroughs to `MarkerCorrectionWriter`.
@MainActor
protocol MarkerCorrectionStore: AnyObject {
    /// `current`'s own spans — the word list this screen offers for boundary-add, and
    /// the exact frame source `MarkerCorrectionWriter.addBoundary` anchors to (brief
    /// case 3: the word's own span, never a scrubbed time). `nil` when there is no
    /// readable current revision — nothing here to correct, same "nothing transcribed
    /// yet" state the editor's `.readOnlyNoTranscript` already names.
    func currentSpans(for captureID: String) async -> [TranscriptSpan]?
    /// The marker log, THREE-answer honest (review Important 5 — the exact #11/§7
    /// collapse the rest of the codebase refuses to make): absent, unreadable, or
    /// present with its raw records. `MarkerCorrectionModel.open()` runs `.markers`
    /// through `MarkerCorrections.effectiveMarkers` itself before rendering
    /// `boundaries` (never the raw list directly — a retract only ever APPENDS a
    /// `.correctionRetract`, it never removes the original tap, so showing the raw
    /// list would make a retracted row immortal) — but an `.unreadable` log must
    /// render its OWN state, with no correction affordances at all, never silently
    /// flattened to "no markers yet".
    func markerLog(for captureID: String) async -> MarkerLogReader.LoadResult
    func retractMarker(seq: Int, captureID: String) async throws
    func correctVoice(frame: Int64, voice: String, captureID: String) async throws
    @discardableResult
    func addBoundary(atSpanIndex: Int, captureID: String) async throws -> Int64
}

/// The marker-correction screen's whole behaviour (T7 Task 6). `MarkerCorrectionView`
/// is a thin binding over this, per the editor's own precedent (`TranscriptEditorModel`
/// / `TranscriptEditorView`) — SwiftUI body rendering is not reachable from
/// `RaconteTests`, so anything with a rule in it lives here.
///
/// No debounce, no draft: every action here (retract / correct a voice / add a
/// boundary) is its own immediate, additive append (locked decision 5) — there is
/// nothing to accumulate and nothing to discard. `open()` re-runs after every
/// successful action so the screen always reflects what is actually on disk, the same
/// "trust the disk, not local state" discipline `TranscriptEditorModel.open()` uses
/// for its own resume path.
@MainActor
@Observable
final class MarkerCorrectionModel {
    /// One existing raw `.voice`/`.paragraph` marker, offered for retraction or (for
    /// `.voice`) a voice correction. `id` is the marker's own `seq` — stable across a
    /// re-`open()` as long as the underlying tap is still on disk (a retract removes
    /// its row entirely, never renumbers the rest).
    struct BoundaryRow: Identifiable, Equatable {
        var id: Int
        var frame: Int64
        var kind: StructureMarker.Kind
        var voice: String?
    }

    /// One word (span) offered as a boundary-add target. `id` is the span's own index
    /// into `current.spans` — exactly what `MarkerCorrectionWriter.addBoundary` wants.
    ///
    /// **Honesty note (review Minor 9):** one row per SPAN, not per literal word.
    /// `TranscriptRevisionStore.spans(fromCommitted:)` mints one span per TIMED RUN
    /// (or, absent runs, one per whole record), and a run/record can hold more than
    /// one word — the writer anchors to that span's own `frameStart` regardless
    /// (brief: "take the frame at the start of the span COVERING the picked word"). In
    /// practice this is one word per span the overwhelming majority of the time
    /// (device transcription runs are short), but a multi-word span offers its span
    /// START for every word inside it, not a per-word frame this codebase does not
    /// have.
    struct WordRow: Identifiable, Equatable {
        var id: Int
        var text: String
        /// Brief case 3: a word whose span has no usable bounds is not offerable. The
        /// row still renders (so the owner can see the word exists) but is disabled,
        /// per `TranscriptAttribution.isPlaceableSpan` — the SAME rule the writer
        /// enforces, so a tap here can never reach a rejection the UI didn't already
        /// predict.
        var isPlaceable: Bool
        /// The span's own start frame, when placeable — `nil` otherwise. Lets
        /// `addBoundary` refuse a duplicate add at an already-effective frame (review
        /// Minor 7) without a second disk read.
        var frameStart: Int64?
    }

    enum State: Equatable {
        case loading
        case ready
        /// No current revision to correct against AND no existing markers either —
        /// there is nothing on this screen to show. Distinct from `.ready` with two
        /// empty lists would be: an entry that DOES have spans but zero markers still
        /// offers the "add a boundary" word list, so that case is `.ready`.
        case nothingToCorrect
        /// `markers.jsonl` exists and could not be read (review Important 5). Never
        /// collapsed into `.nothingToCorrect` — that would tell the owner there is
        /// nothing here when the truth is "something is here and we failed to read
        /// it," the exact #11/§7 distinction the rest of the codebase already makes
        /// for this same file. No correction affordances are offered: acting against
        /// an unreadable log risks colliding `seq` values, the same reason
        /// `MarkerLogWriter.open()` refuses to open one at all.
        case unreadable(String)
    }

    private(set) var state: State = .loading
    private(set) var boundaries: [BoundaryRow] = []
    private(set) var words: [WordRow] = []
    private(set) var errorMessage: String?

    let captureID: String
    private let store: any MarkerCorrectionStore

    init(captureID: String, store: any MarkerCorrectionStore) {
        self.captureID = captureID
        self.store = store
    }

    /// Reads markers and spans fresh from disk every time — called on first appear
    /// and again after every successful write, so the screen is always a projection
    /// of what is actually on disk, never of what the model THINKS it just wrote.
    func open() async {
        state = .loading
        // Sequential, not `async let`: `store` is a non-Sendable existential (the same
        // shape `TranscriptEditorStore` uses), and Swift 6 strict concurrency refuses
        // to capture it into a concurrent child task even though the protocol itself
        // is `@MainActor`-isolated.
        let markerLog = await store.markerLog(for: captureID)
        let spans = await store.currentSpans(for: captureID)

        // Review Important 5: an unreadable log is its OWN state, checked before
        // anything else — never flattened into "no markers yet" (`.nothingToCorrect`)
        // or silently treated as an empty list. No correction affordances follow.
        if case .unreadable(let reason) = markerLog.source {
            boundaries = []
            words = []
            state = .unreadable(reason)
            return
        }

        let markers = markerLog.markers

        // MUST be the EFFECTIVE list, not the raw one: raw taps are immutable (locked
        // decision 5), so a retract never removes anything from `markers` — it only
        // ever appends a `.correctionRetract` record. Folding here is what makes a
        // retracted row actually disappear and a voice-corrected row show the
        // CORRECTED voice, not the original raw one. `MarkerCorrections
        // .effectiveMarkers` already drops correction records themselves (they are
        // never `.voice`/`.paragraph`), so the extra `.filter` below is redundant
        // defense, not the mechanism — kept because "boundaries never contains a
        // correction record" is worth stating twice given how directly it bit this
        // exact model during development (see the fixed regression this comment sits
        // beside in git history). `isExact` is irrelevant here — that flag only
        // matters to the snap step (`EntryTranscript.snappedMarkers`); this screen
        // just reads `.marker`.
        let effective = MarkerCorrections.effectiveMarkers(markers).map(\.marker)
        boundaries = effective
            .filter { $0.kind == .voice || $0.kind == .paragraph }
            .sorted { $0.frame < $1.frame }
            .map { BoundaryRow(id: $0.seq, frame: $0.frame, kind: $0.kind, voice: $0.voice) }

        guard let spans else {
            words = []
            state = boundaries.isEmpty ? .nothingToCorrect : .ready
            return
        }
        words = spans.indices.map { index in
            let placeable = TranscriptAttribution.isPlaceableSpan(spans[index])
            return WordRow(id: index, text: spans[index].text, isPlaceable: placeable,
                           frameStart: placeable ? spans[index].frameStart : nil)
        }
        state = .ready
    }

    func retract(_ row: BoundaryRow) async {
        do {
            try await store.retractMarker(seq: row.id, captureID: captureID)
            await open()
        } catch {
            errorMessage = "That couldn’t be saved. Try again."
        }
    }

    /// A no-op for a `.paragraph` row — the view never offers this action there, this
    /// is the model-level guard against a stale/racing call reaching it anyway.
    func correctVoice(_ row: BoundaryRow, to voice: String) async {
        guard row.kind == .voice else { return }
        do {
            try await store.correctVoice(frame: row.frame, voice: voice, captureID: captureID)
            await open()
        } catch {
            errorMessage = "That couldn’t be saved. Try again."
        }
    }

    /// The view disables a non-placeable row, but this is checked again here — the
    /// same "never trust that the UI already enforced it" reasoning as `writeDraft`'s
    /// own guards, and it is what lets `RaconteTests` pin the rejection without a
    /// SwiftUI harness.
    ///
    /// Review Important 5: the catch below used to map EVERY thrown error to the
    /// "word not offerable" message, including a genuine I/O failure
    /// (`MarkerLogError.unreadableExistingLog` and friends) that has nothing to do
    /// with placeability — a real write failure was mis-explained as a placeability
    /// rejection. Only `.noUsableBounds` gets that specific message now; anything
    /// else gets the same generic failure message `retract`/`correctVoice` use.
    ///
    /// Review Minor 7: a duplicate add at a frame that's ALREADY an effective boundary
    /// (e.g. tapping the same word twice, or a word whose frame an earlier add or a
    /// raw tap already covers) is refused here — cheap, since `boundaries` is already
    /// in memory from the last `open()` — rather than appending another
    /// `.correctionBoundaryAdd` record that changes nothing but grows the log forever.
    func addBoundary(_ row: WordRow) async {
        guard row.isPlaceable, let frame = row.frameStart else {
            errorMessage = MarkerCorrectionWriter.boundaryAddRejectionMessage()
            return
        }
        guard !boundaries.contains(where: { $0.frame == frame }) else {
            errorMessage = "There’s already a boundary at this word."
            return
        }
        do {
            try await store.addBoundary(atSpanIndex: row.id, captureID: captureID)
            await open()
        } catch MarkerCorrectionWriter.BoundaryAddError.noUsableBounds {
            errorMessage = MarkerCorrectionWriter.boundaryAddRejectionMessage()
        } catch {
            errorMessage = "That couldn’t be saved. Try again."
        }
    }

    func acknowledgeError() { errorMessage = nil }
}

/// The correction screen writes through this model, never straight to
/// `MarkerCorrectionWriter`/`MarkerLogReader` — same one-store-instance-per-file
/// reasoning as `TranscriptEditorStore`'s conformance below it.
extension LibraryScreenModel: MarkerCorrectionStore {
    nonisolated func currentSpans(for captureID: String) async -> [TranscriptSpan]? {
        let capturesRoot = self.capturesRoot
        return await Task.detached(priority: .userInitiated) {
            let directory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
            guard let chain = TranscriptRevisionStore.loadChain(captureDirectory: directory),
                  let current = TranscriptChain.current(TranscriptChain.ordered(chain.revisions))
            else { return nil }
            return current.spans
        }.value
    }

    nonisolated func markerLog(for captureID: String) async -> MarkerLogReader.LoadResult {
        let capturesRoot = self.capturesRoot
        return await Task.detached(priority: .userInitiated) {
            let directory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
            return MarkerLogReader.load(captureDirectory: directory)
        }.value
    }

    func retractMarker(seq: Int, captureID: String) async throws {
        let capturesRoot = self.capturesRoot
        try await Task.detached(priority: .userInitiated) {
            let directory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
            try MarkerCorrectionWriter.retract(seq: seq, captureDirectory: directory)
        }.value
    }

    func correctVoice(frame: Int64, voice: String, captureID: String) async throws {
        let capturesRoot = self.capturesRoot
        try await Task.detached(priority: .userInitiated) {
            let directory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
            try MarkerCorrectionWriter.correctVoice(frame: frame, voice: voice, captureDirectory: directory)
        }.value
    }

    /// Re-reads `currentSpans` rather than trusting a caller-supplied array: the
    /// screen's own `words` list could be one action stale (another correction
    /// session, or the editor, changed the chain since this screen last opened), and
    /// writing against a stale span array could anchor to the wrong frame silently.
    @discardableResult
    func addBoundary(atSpanIndex: Int, captureID: String) async throws -> Int64 {
        guard let spans = await currentSpans(for: captureID) else {
            throw MarkerCorrectionWriter.BoundaryAddError.noUsableBounds
        }
        let capturesRoot = self.capturesRoot
        return try await Task.detached(priority: .userInitiated) {
            let directory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
            return try MarkerCorrectionWriter.addBoundary(atSpanIndex: atSpanIndex, spans: spans,
                                                           captureDirectory: directory)
        }.value
    }
}
