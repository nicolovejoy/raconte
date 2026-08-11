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
    /// The RAW marker list, unfolded — everything on disk, taps and correction
    /// records alike. `MarkerCorrectionModel.open()` runs this through
    /// `MarkerCorrections.effectiveMarkers` itself before rendering `boundaries`
    /// (never the raw list directly — a retract only ever APPENDS a
    /// `.correctionRetract`, it never removes the original tap, so showing the raw
    /// list would make a retracted row immortal).
    func rawMarkers(for captureID: String) async -> [StructureMarker]
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
    struct WordRow: Identifiable, Equatable {
        var id: Int
        var text: String
        /// Brief case 3: a word whose span has no usable bounds is not offerable. The
        /// row still renders (so the owner can see the word exists) but is disabled,
        /// per `TranscriptAttribution.isPlaceableSpan` — the SAME rule the writer
        /// enforces, so a tap here can never reach a rejection the UI didn't already
        /// predict.
        var isPlaceable: Bool
    }

    enum State: Equatable {
        case loading
        case ready
        /// No current revision to correct against AND no existing markers either —
        /// there is nothing on this screen to show. Distinct from `.ready` with two
        /// empty lists would be: an entry that DOES have spans but zero markers still
        /// offers the "add a boundary" word list, so that case is `.ready`.
        case nothingToCorrect
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
        let markers = await store.rawMarkers(for: captureID)
        let spans = await store.currentSpans(for: captureID)

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
        // beside in git history).
        let effective = MarkerCorrections.effectiveMarkers(markers)
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
            WordRow(id: index, text: spans[index].text,
                    isPlaceable: TranscriptAttribution.isPlaceableSpan(spans[index]))
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
    func addBoundary(_ row: WordRow) async {
        guard row.isPlaceable else {
            errorMessage = MarkerCorrectionWriter.boundaryAddRejectionMessage()
            return
        }
        do {
            try await store.addBoundary(atSpanIndex: row.id, captureID: captureID)
            await open()
        } catch {
            errorMessage = MarkerCorrectionWriter.boundaryAddRejectionMessage()
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

    nonisolated func rawMarkers(for captureID: String) async -> [StructureMarker] {
        let capturesRoot = self.capturesRoot
        return await Task.detached(priority: .userInitiated) {
            let directory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
            return MarkerLogReader.load(captureDirectory: directory).markers
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
