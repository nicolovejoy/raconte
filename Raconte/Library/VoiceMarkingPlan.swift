import Foundation

/// The rules that turn a marking gesture — "this paragraph is the other voice", "these
/// words are LN" — into `markers.jsonl` appends (T7 Mark Voices, issue #56, Task 4).
/// Pure: no I/O, no actor, no clock. The caller (`MarkVoicesModel`) executes the
/// returned commands through `MarkerCorrectionWriter`, in order.
///
/// **Why there is no retract and no correct.** Every command here is an APPEND, and
/// `TranscriptAttribution` collapses markers that land at the same attribution cut into
/// one breakpoint whose voice is the LAST one in `(frame, seq)` order — so a new
/// voice-carrying add at an already-marked cut simply overrides it. Re-flipping the same
/// paragraph, or re-marking a range someone already marked, is therefore safe and needs
/// no read-modify-write against the log: locked decision 5 (raw taps are never modified)
/// is kept for free rather than worked around.
enum VoiceMarkingPlan {
    enum Command: Equatable {
        case addOpeningVoice(voice: String)
        case addVoiceBoundary(spanIndex: Int, voice: String)
    }

    /// The single refusal. A gesture whose anchor cannot carry a marker — no placeable
    /// span in the target paragraph, a paragraph with no `spanRange` at all (the
    /// committed/pieces attribution path never populates one), an index outside the
    /// list, or a range endpoint that isn't placeable — is planned as nothing, never as
    /// a boundary placed "somewhere near".
    enum PlanError: Error, Equatable { case notMarkable }

    /// "This paragraph is the other voice." Emits the flip itself plus, unless the
    /// paragraph after it already declares a voice of its own, a RESTORE that re-declares
    /// what governed there before — without it, a boundary add would flip not just the
    /// tapped paragraph but everything after it to the end of the entry.
    static func flipParagraph(at index: Int,
                              paragraphs: [TranscriptAttribution.Paragraph],
                              spans: [TranscriptSpan],
                              hasAnyVoiceMarker: Bool) throws -> [Command] {
        guard paragraphs.indices.contains(index),
              let range = paragraphs[index].spanRange,
              let anchor = firstPlaceable(in: range, spans: spans) else {
            throw PlanError.notMarkable
        }

        let currentVoice = paragraphs[index].voice
        let target = VoiceDisplay.other(currentVoice ?? VoiceDisplay.mainVoice)

        var commands = openerIfNeeded(anchorSpanIndex: anchor, spans: spans,
                                      hasAnyVoiceMarker: hasAnyVoiceMarker)
        commands.append(.addVoiceBoundary(spanIndex: anchor, voice: target))

        // A paragraph whose voice differs from the one before it can only have gotten
        // that voice from a voice marker declaring it at its own start — that declaration
        // is already on disk and already outlives this flip, so a restore would be a
        // duplicate record saying what the log already says.
        if paragraphs.indices.contains(index + 1), paragraphs[index + 1].voice == currentVoice {
            let next = paragraphs[index + 1]

            // The restored voice is the FOLLOWING paragraph's pre-change voice; the index
            // it lands on is the first placeable span from that paragraph forward, which
            // can sit in a LATER paragraph when the following one has nothing placeable to
            // anchor to. `paragraphs[j].spanRange` is read directly at every step rather
            // than derived by arithmetic from a neighbour: a paragraph whose spans all
            // carry empty text is filtered out of this list entirely, so surviving ranges
            // need not be contiguous.
            for j in (index + 1)..<paragraphs.count {
                guard let laterRange = paragraphs[j].spanRange,
                      let restore = firstPlaceable(in: laterRange, spans: spans) else { continue }
                commands.append(.addVoiceBoundary(spanIndex: restore,
                                                  voice: next.voice ?? VoiceDisplay.mainVoice))
                break
            }
        }

        try validate(commands, spans: spans)
        return commands
    }

    /// "These words are LN." `range` is a closed range of span indices whose endpoints
    /// the caller has already restricted to placeable spans (the selection UI can only
    /// offer placeable words); the planner re-checks rather than trusting it, because a
    /// half-executed plan — switch appended, restore refused by the writer — would leave
    /// the entry marked wrong rather than unmarked.
    static func markRange(_ range: ClosedRange<Int>,
                          to voice: String,
                          paragraphs: [TranscriptAttribution.Paragraph],
                          spans: [TranscriptSpan],
                          hasAnyVoiceMarker: Bool) throws -> [Command] {
        guard spans.indices.contains(range.lowerBound), spans.indices.contains(range.upperBound),
              TranscriptAttribution.isPlaceableSpan(spans[range.lowerBound]),
              TranscriptAttribution.isPlaceableSpan(spans[range.upperBound]) else {
            throw PlanError.notMarkable
        }

        var commands = openerIfNeeded(anchorSpanIndex: range.lowerBound, spans: spans,
                                      hasAnyVoiceMarker: hasAnyVoiceMarker)
        commands.append(.addVoiceBoundary(spanIndex: range.lowerBound, voice: voice))

        if let restore = firstPlaceable(in: (range.upperBound + 1)..<spans.count, spans: spans) {
            commands.append(.addVoiceBoundary(spanIndex: restore,
                                              voice: governingVoice(atSpanIndex: restore,
                                                                    paragraphs: paragraphs)
                                                  ?? VoiceDisplay.mainVoice))
        }

        try validate(commands, spans: spans)
        return commands
    }

    // MARK: - Rules shared by both gestures

    /// A plan is expressed in SPAN INDICES but lands on disk as FRAMES —
    /// `MarkerCorrectionWriter.addVoiceBoundary` writes `spans[k].frameStart` — and
    /// distinct placeable spans are NOT guaranteed distinct frames. `TranscriptSplice`
    /// degrades a touched span into fragments that each carry the PARENT SPAN'S FULL
    /// bounds (`TranscriptSplice.swift`, the `.inherited` fragment branch), so whenever an
    /// intact join separator survives between two fragments of one parent span, two or
    /// more CONSECUTIVE placeable spans share an identical `[frameStart, frameEnd)`. The
    /// read side already documents and pins that shape —
    /// `TranscriptAttribution.placeableCutPosition` and
    /// `TranscriptAttributionTests.testTwoPlaceableSpansSharingBoundsCutAfterTheFirstFragmentAndFlagItApproximate`
    /// — and it is an ORDINARY post-edit shape, not an exotic one.
    ///
    /// On it, a boundary aimed at the second fragment is written at a frame the FIRST
    /// fragment also carries, and `placeableCutPosition` resolves that frame to the
    /// earliest span carrying it. Two silent wrongs follow, both reachable (review
    /// Important 1): a `markRange` starting at fragment two voices fragment one, which the
    /// owner never selected; and a `flipParagraph` whose switch and restore both resolve
    /// to that single cut self-cancels — the restore is appended later, so it wins, and
    /// the gesture does nothing while every write reports success.
    ///
    /// Controller ruling (2026-08-12): REFUSE. Relocating a boundary to a different span
    /// would mark text the owner didn't choose, which is worse than an honest refusal on a
    /// rare shape. Validation runs over the WHOLE plan before any of it is returned, so a
    /// refused gesture writes nothing at all — half of a plan in an append-only log could
    /// never be taken back.
    ///
    /// Rule 2 (distinct frames within one plan) is, for every span array today, implied by
    /// rule 1: boundaries are emitted in increasing index order, so an equal frame later in
    /// the plan always has an earlier placeable span carrying it. It is kept as its own
    /// guard because ascending frame order is an ASSUMPTION about span arrays, not an
    /// invariant anything enforces — `TranscriptAttribution.fullSpanIndex`'s own doc
    /// comment says so — and a self-cancelling plan is the one failure mode with no
    /// visible symptom.
    private static func validate(_ commands: [Command], spans: [TranscriptSpan]) throws {
        var plannedFrames: Set<Int64> = []
        for command in commands {
            guard case .addVoiceBoundary(let index, _) = command else { continue }
            guard spans.indices.contains(index),
                  TranscriptAttribution.isPlaceableSpan(spans[index]),
                  let frame = spans[index].frameStart else {
                throw PlanError.notMarkable
            }
            // 1. The cut this frame produces lands on the EARLIEST placeable span carrying
            //    it. If that isn't the span the gesture named, the boundary would mark
            //    text nobody selected.
            let earliest = spans.indices.first {
                TranscriptAttribution.isPlaceableSpan(spans[$0]) && spans[$0].frameStart == frame
            }
            guard earliest == index else { throw PlanError.notMarkable }
            // 2. Two boundaries of one plan at one frame collapse into a single breakpoint.
            guard plannedFrames.insert(frame).inserted else { throw PlanError.notMarkable }
        }
    }

    /// The opener exists so that marking something in the MIDDLE of an entry that has no
    /// voice markers at all doesn't leave everything before it voiceless: a frame-0
    /// `addOpeningVoice` declares the main voice for the run of text ahead of the anchor.
    ///
    /// It is deliberately NOT emitted when the anchor is itself the first placeable span
    /// of the whole transcript: `addOpeningVoice` writes frame 0, which resolves to the
    /// same attribution cut as that span's own start, so the two records would collide at
    /// one breakpoint and the anchor (written later, higher `seq`) would win anyway. The
    /// opener would be a permanent, no-op line in an append-only log.
    private static func openerIfNeeded(anchorSpanIndex: Int, spans: [TranscriptSpan],
                                       hasAnyVoiceMarker: Bool) -> [Command] {
        guard !hasAnyVoiceMarker,
              let first = firstPlaceable(in: spans.indices, spans: spans),
              anchorSpanIndex != first else { return [] }
        return [.addOpeningVoice(voice: VoiceDisplay.mainVoice)]
    }

    /// Lowest index in `range` whose span can actually anchor a marker — the identical
    /// predicate `MarkerCorrectionWriter` applies at write time
    /// (`TranscriptAttribution.isPlaceableSpan`), so a plan can never contain a command
    /// the writer will refuse.
    private static func firstPlaceable(in range: some Sequence<Int>,
                                       spans: [TranscriptSpan]) -> Int? {
        range.first { spans.indices.contains($0) && TranscriptAttribution.isPlaceableSpan(spans[$0]) }
    }

    /// The voice in force at a span index before this plan is applied: the voice of the
    /// paragraph it belongs to. Read as "the last paragraph that starts at or before it"
    /// rather than "the paragraph whose range contains it" for the gap case — an
    /// all-empty-text paragraph is filtered out of the list, so a span index can fall in
    /// no surviving range at all, and the voice governing it is still the one that was in
    /// force when that gap began.
    private static func governingVoice(atSpanIndex index: Int,
                                       paragraphs: [TranscriptAttribution.Paragraph]) -> String? {
        var voice: String?
        for paragraph in paragraphs {
            guard let range = paragraph.spanRange, range.lowerBound <= index else { continue }
            voice = paragraph.voice
        }
        return voice
    }
}
