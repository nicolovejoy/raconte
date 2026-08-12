import Foundation

/// The disk seam the "Mark voices" screen writes through (T7 Mark Voices, issue #56,
/// Task 5). Mirrors `MarkerCorrectionStore`'s shape: the read is a pure passthrough to
/// `EntryTranscript.voiceMarkingLayout`, writes are plain `async throws` passthroughs to
/// `MarkerCorrectionWriter`'s Task 1 voice-carrying methods.
@MainActor
protocol VoiceMarkingStore: AnyObject {
    func voiceMarkingLayout(for captureID: String) async -> EntryTranscript.VoiceMarkingLayout
    @discardableResult
    func addVoiceBoundary(atSpanIndex: Int, voice: String, captureID: String) async throws -> Int64
    func addOpeningVoice(voice: String, captureID: String) async throws
}

/// The mark-voices screen's whole behaviour (T7 Mark Voices, issue #56, Task 5). Owner
/// ruling: an explicit mode — tap a paragraph to flip its voice, drag a range of words
/// to mark a range — WYSIWYG, Done exits. `VoiceMarkingView` is a thin binding over
/// this, per `MarkerCorrectionModel`/`MarkerCorrectionView`'s own precedent.
///
/// `VoiceMarkingPlan` (Task 4) is the pure planner: it turns a gesture into an ordered
/// list of `Command`s. This model's whole job is executing that plan through the store,
/// IN ORDER, and re-deriving `rows` from what actually landed on disk afterward — never
/// from what the model assumed the plan would do. Two things this discipline exists
/// for, both carried forward from Task 4's review:
///
/// 1. **Plan execution is not atomic.** A write failure partway through a multi-command
///    plan (e.g. the flip's switch boundary lands but the restore write throws) leaves
///    the entry genuinely flipped-to-end-of-entry on disk. `open()` after ANY failure —
///    first command or last — is what keeps `rows` honest about that, rather than
///    silently presenting either the pre-gesture state or the fully-applied one.
/// 2. **`VoiceMarkingPlan.validate()` can refuse with `.notMarkable`** (frame-ambiguity:
///    splice fragments sharing identical frames — see the plan's own doc comment). This
///    is a reachable UI state, not a programmer error, and is surfaced with the same
///    rejection copy `MarkerCorrectionWriter.boundaryAddRejectionMessage()` already uses
///    for "this word has no timed position" — refusing a boundary-add for frame-
///    ambiguity is the same kind of "can't place a marker here" story to the owner.
@MainActor
@Observable
final class VoiceMarkingModel {
    /// One word (span), offered as a flip/mark-range target. `id` is the span's own
    /// GLOBAL index into the layout's `spans` array — not a per-paragraph-local index —
    /// so a range gesture spanning tokens from what the UI renders as one contiguous
    /// strip can hand `markRange` the exact indices `VoiceMarkingPlan` expects.
    struct Token: Identifiable, Equatable {
        var id: Int
        var text: String
        /// Same rule `MarkerCorrectionWriter`/`VoiceMarkingPlan` enforce
        /// (`TranscriptAttribution.isPlaceableSpan`) — a tap here can never reach a
        /// plan refusal the UI didn't already predict.
        var isPlaceable: Bool
    }

    /// One paragraph as marking mode renders it. `id` is the paragraph's own index in
    /// THIS load — stable for the duration of one `rows` snapshot, re-derived (and
    /// potentially renumbered) on every `open()`.
    struct ParagraphRow: Identifiable, Equatable {
        var id: Int
        var voice: String?
        var tokens: [Token]
        var hasApproximateBoundary: Bool
    }

    enum State: Equatable {
        case loading
        case ready
        /// No readable canonical revision to mark onto (`.unavailable`), or a `.ready`
        /// layout whose spans produced no paragraphs at all — nothing here to mark.
        case nothingToMark
        /// `markers.jsonl` exists and could not be read. Never flattened into
        /// `.nothingToMark` — same #11/§7 distinction the rest of the codebase makes
        /// for this file: marking directly over an unreadable log risks colliding
        /// `seq` values with taps that are still really there on disk.
        case unreadable(String)
    }

    private(set) var state: State = .loading
    private(set) var rows: [ParagraphRow] = []
    private(set) var errorMessage: String?

    let captureID: String
    private let store: any VoiceMarkingStore

    /// The layout's own spans/paragraphs/`hasAnyVoiceMarker`, kept from the last
    /// successful `.ready` load — `VoiceMarkingPlan.flipParagraph`/`markRange` need all
    /// three to plan a gesture, and re-reading them from `rows` alone would lose
    /// `hasAnyVoiceMarker` and the exact `TranscriptSpan` values the plan anchors to.
    private var spans: [TranscriptSpan] = []
    private var paragraphs: [TranscriptAttribution.Paragraph] = []
    private var hasAnyVoiceMarker = false

    /// Guards `flipParagraph`/`markRange` against a second gesture entering while the
    /// first is still suspended on a store `await` (Task 5 review, finding 3):
    /// MainActor re-entrancy means a second tap between the first gesture's plan and
    /// its `open()` reload would plan against the SAME pre-gesture `paragraphs`
    /// snapshot the first gesture is busy invalidating, and later-seq-wins on an
    /// append-only log means the interleaved write can land as a silent no-op (a
    /// paragraph that reads as unflipped, no error shown) rather than a visible
    /// conflict. The model never trusts the UI to have disabled its own affordances
    /// during the write — same "never trust the caller already enforced it" rule as
    /// every other guard in this file.
    private var isWriting = false

    init(captureID: String, store: any VoiceMarkingStore) {
        self.captureID = captureID
        self.store = store
    }

    /// Reads the layout fresh from disk every time — called on first appear and again
    /// after every gesture (successful or not, per the class doc's constraint 1), so
    /// the screen is always a projection of what is actually on disk.
    func open() async {
        state = .loading
        let layout = await store.voiceMarkingLayout(for: captureID)

        switch layout {
        case .unavailable:
            spans = []
            paragraphs = []
            hasAnyVoiceMarker = false
            rows = []
            state = .nothingToMark
        case .markersUnreadable(let reason):
            spans = []
            paragraphs = []
            hasAnyVoiceMarker = false
            rows = []
            state = .unreadable(reason)
        case .ready(let loadedSpans, let loadedParagraphs, let loadedHasAnyVoiceMarker):
            spans = loadedSpans
            paragraphs = loadedParagraphs
            hasAnyVoiceMarker = loadedHasAnyVoiceMarker
            rows = Self.buildRows(paragraphs: loadedParagraphs, spans: loadedSpans)
            state = loadedParagraphs.isEmpty ? .nothingToMark : .ready
        }
    }

    /// "This paragraph is the other voice." Plans, then executes the commands through
    /// the store IN ORDER — never reordered, never parallelized: `VoiceMarkingPlan`'s
    /// restore command depends on the switch command having already landed (frame-order
    /// on an append-only log is APPEND order, and later-seq-wins is what makes the
    /// restore actually win over the switch for the paragraphs after it).
    func flipParagraph(_ rowID: Int) async {
        guard !isWriting, paragraphs.indices.contains(rowID) else { return }
        isWriting = true
        defer { isWriting = false }
        do {
            let commands = try VoiceMarkingPlan.flipParagraph(at: rowID, paragraphs: paragraphs,
                                                               spans: spans,
                                                               hasAnyVoiceMarker: hasAnyVoiceMarker)
            try await execute(commands)
        } catch VoiceMarkingPlan.PlanError.notMarkable {
            errorMessage = MarkerCorrectionWriter.boundaryAddRejectionMessage()
            await open()
            return
        } catch {
            errorMessage = "That couldn’t be saved. Try again."
            await open()
            return
        }
        await open()
    }

    /// "These words are the other voice." `first`/`last` are global span indices (the
    /// same `Token.id` space `rows` renders) — the UI restricts its drag gesture to
    /// placeable tokens, but `VoiceMarkingPlan.markRange` re-checks rather than trusting
    /// that restriction, same "never trust the caller already enforced it" rule as
    /// `MarkerCorrectionModel.addBoundary`.
    func markRange(first: Int, last: Int, to voice: String) async {
        guard !isWriting, first <= last else { return }
        isWriting = true
        defer { isWriting = false }
        do {
            let commands = try VoiceMarkingPlan.markRange(first...last, to: voice,
                                                           paragraphs: paragraphs, spans: spans,
                                                           hasAnyVoiceMarker: hasAnyVoiceMarker)
            try await execute(commands)
        } catch VoiceMarkingPlan.PlanError.notMarkable {
            errorMessage = MarkerCorrectionWriter.boundaryAddRejectionMessage()
            await open()
            return
        } catch {
            errorMessage = "That couldn’t be saved. Try again."
            await open()
            return
        }
        await open()
    }

    /// The voice the confirmation button offers for a range starting at `tokenID`: the
    /// OTHER of whichever voice currently governs that position. Calls
    /// `VoiceMarkingPlan.governingVoice` directly (Task 5 review: this used to be a
    /// byte-identical private copy of that lookup — the plan uses it to pick the
    /// RESTORE voice, this offers it as the confirmation choice, and a second copy
    /// could silently drift) rather than re-deriving the gap-case rule here.
    func alternativeVoice(forRangeStartingAt tokenID: Int) -> String {
        let governing = VoiceMarkingPlan.governingVoice(atSpanIndex: tokenID, paragraphs: paragraphs)
        return VoiceDisplay.other(governing ?? VoiceDisplay.mainVoice)
    }

    func acknowledgeError() { errorMessage = nil }

    // MARK: - Execution

    /// Runs a plan's commands through the store in order, stopping at the first
    /// failure. Never catches here — `flipParagraph`/`markRange` own the error-message
    /// mapping and the mandatory `open()` reload, so a partial failure's exact stopping
    /// point is never smoothed over by a shared catch site.
    private func execute(_ commands: [VoiceMarkingPlan.Command]) async throws {
        for command in commands {
            switch command {
            case .addOpeningVoice(let voice):
                try await store.addOpeningVoice(voice: voice, captureID: captureID)
            case .addVoiceBoundary(let spanIndex, let voice):
                try await store.addVoiceBoundary(atSpanIndex: spanIndex, voice: voice, captureID: captureID)
            }
        }
    }

    // MARK: - Row building

    private static func buildRows(paragraphs: [TranscriptAttribution.Paragraph],
                                  spans: [TranscriptSpan]) -> [ParagraphRow] {
        paragraphs.enumerated().map { index, paragraph in
            let tokens: [Token]
            if let range = paragraph.spanRange {
                tokens = range.map { spanIndex in
                    Token(id: spanIndex, text: spans[spanIndex].text,
                          isPlaceable: TranscriptAttribution.isPlaceableSpan(spans[spanIndex]))
                }
            } else {
                tokens = []
            }
            return ParagraphRow(id: index, voice: paragraph.voice, tokens: tokens,
                                hasApproximateBoundary: paragraph.hasApproximateBoundary)
        }
    }
}
