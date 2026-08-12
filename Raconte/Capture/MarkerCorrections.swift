import Foundation

/// Resolves correction records (T7 Task 6) into the effective `.voice`/`.paragraph`
/// marker list that `MarkerSnapping`/`TranscriptAttribution` already know how to
/// render. Pure: no I/O, no clock — a value fold over whatever
/// `MarkerLogReader.load` returned.
///
/// Locked decision 5 (verbatim law): raw taps are NEVER modified. Corrections are
/// additive records appended to `markers.jsonl`; this fold is what turns "append-only
/// log of raw taps + corrections" into "the list attribution should actually use" at
/// READ time — it never writes anything back to disk, and the caller
/// (`EntryTranscript.snappedMarkers`) discards its output on every read rather than
/// caching it, so a mis-fold can never persist.
///
/// The three correction kinds (brief cases 1-3), independent of file order — order in
/// `markers.jsonl` is APPEND order, not resolution order, so this fold gathers every
/// correction record first and then applies all of them at once, rather than walking
/// the raw list once and mutating as it goes:
/// - `.correctionRetract` removes the base marker whose `seq` equals `retractsSeq`. A
///   retract whose target is absent (already retracted, or never existed) is IGNORED,
///   not an error (brief 6.3) — it simply has no match to remove.
/// - `.correctionVoice` overrides the `voice` of the base `.voice` marker at the SAME
///   raw `frame` — "correct a voice at an EXISTING boundary" (brief case 2). No
///   matching `.voice` marker at that frame, no effect — same "ignored" spirit as a
///   retract with no target. **Precedence (Task 1 fix, review Important 1): later
///   record wins, by `seq`** — the override applies to a `.voice` marker only when
///   the correction's own `seq` is greater than that marker's. Before Task 1 taught a
///   `.correctionBoundaryAdd` to synthesize `.voice` (see below), only a raw tap ever
///   had `kind == .voice`, and a correction is always written after the tap it
///   corrects, so frame-only matching and seq-precedence happened to agree. Once a
///   synthesized `.voice` marker can share a frame with a `.correctionVoice` — frame 0
///   is a certainty, since `MarkerCorrectionWriter.addOpeningVoice` always writes it —
///   the two can appear in either order, and only seq decides which one is newer. If
///   more than one `.correctionVoice` targets the same frame, the highest-seq one is
///   the candidate (today's practical last-wins, made explicit).
/// - `.correctionBoundaryAdd` synthesizes a brand-new effective marker at its own
///   `frame` (computed by `MarkerCorrectionWriter` from a picked word's span start,
///   never a scrubbed time) — a boundary the owner never tapped at capture time. Kind
///   depends on whether the record carries a voice (Task 1, #56): non-nil `voice`
///   synthesizes `.voice` (a boundary AND a voice assignment in one record); nil
///   synthesizes plain `.paragraph`, as every boundary-add did before Task 1.
enum MarkerCorrections {
    /// One entry in the effective list. `isExact` distinguishes a boundary-add's
    /// synthesized marker (review Critical 1) from every other effective marker: the
    /// synthesized frame is a SPAN's own bound, computed once by
    /// `MarkerCorrectionWriter` directly from that span — exact by construction, never
    /// a raw tap subject to the latency `MarkerSnapping` exists to correct. A raw tap
    /// (including one whose VOICE was corrected — the FRAME is still the original raw
    /// tap's own) is `isExact == false` and must still be snapped exactly as before
    /// Task 6. The caller (`EntryTranscript.snappedMarkers`) is what actually skips
    /// snapping for `isExact` markers; this type only classifies.
    struct EffectiveMarker: Equatable {
        var marker: StructureMarker
        var isExact: Bool
    }

    /// A `.correctionVoice` candidate for one frame: its own `seq` (so the fold can
    /// tell whether it outranks the `.voice` marker it targets) alongside the voice it
    /// carries. When two `.correctionVoice` records target the same frame, the
    /// higher-seq one replaces the lower — see the type doc's precedence note.
    private struct VoiceCorrection {
        var seq: Int
        var voice: String
    }

    static func effectiveMarkers(_ raw: [StructureMarker]) -> [EffectiveMarker] {
        var retractedSeqs: Set<Int> = []
        var voiceCorrectionsByFrame: [Int64: VoiceCorrection] = [:]
        var additions: [StructureMarker] = []

        for marker in raw {
            switch marker.kind {
            case .correctionRetract:
                if let target = marker.retractsSeq { retractedSeqs.insert(target) }
            case .correctionVoice:
                if let voice = marker.voice {
                    let candidate = VoiceCorrection(seq: marker.seq, voice: voice)
                    if let existing = voiceCorrectionsByFrame[marker.frame], existing.seq > candidate.seq {
                        // A lower-seq correction arriving after a higher-seq one in
                        // file order (append order != seq order in a hand-built raw
                        // list) must not clobber the genuinely newer candidate.
                    } else {
                        voiceCorrectionsByFrame[marker.frame] = candidate
                    }
                }
            case .correctionBoundaryAdd:
                // `seq` is deliberately the CORRECTION record's own — not a fresh
                // one — so a later `.correctionRetract` can target this exact
                // synthesized marker the same way it targets any raw tap (review
                // Important 3).
                //
                // Task 1 (#56): a boundary-add that carries a voice synthesizes a
                // `.voice` marker instead of `.paragraph` — the record is now doing
                // double duty as both a paragraph break AND a voice assignment at a
                // word-anchored, exact frame. A nil voice keeps today's behavior
                // (plain `.paragraph`) byte-for-byte — the compat pin in
                // `MarkerCorrectionsTests.testVoicelessBoundaryAddStillSynthesizesAParagraphMarker`.
                if let voice = marker.voice {
                    additions.append(StructureMarker(seq: marker.seq, frame: marker.frame, kind: .voice, voice: voice))
                } else {
                    additions.append(StructureMarker(seq: marker.seq, frame: marker.frame, kind: .paragraph))
                }
            case .voice, .paragraph, .unknown:
                break
            }
        }
        let additionSeqs = Set(additions.map(\.seq))

        // Additions are appended BEFORE the retract removal (review Important 3, fix
        // for a real bug): file order (append order) is not resolution order — this
        // type's own doc comment already said so, but the retract step didn't honor
        // it. Appending additions AFTER `removeAll` meant a retract could never
        // cancel a boundary-add: the addition wasn't in the list yet when the removal
        // ran, so it survived forever, and each retry appended another permanent
        // no-op `.correctionRetract` record. Order between the two steps below is now
        // "add everything, then remove what's retracted" — genuinely order-
        // independent with respect to append order, matching the doc comment's claim.
        var effective = raw.filter { $0.kind == .voice || $0.kind == .paragraph }
        effective.append(contentsOf: additions)
        effective.removeAll { retractedSeqs.contains($0.seq) }
        // Precedence: later record wins, by seq (review Important 1) — a correction
        // only overrides a `.voice` marker whose own `seq` it actually postdates.
        // Without this, a stale `.correctionVoice` at frame 0 would silently beat a
        // NEWER voice-carrying add (`addOpeningVoice` always writes frame 0), which
        // was unreachable before Task 1 (only a raw tap ever had kind == .voice, and a
        // correction is always appended after the tap it targets) but is now a
        // designed-in collision.
        effective = effective.map { marker in
            guard marker.kind == .voice,
                  let correction = voiceCorrectionsByFrame[marker.frame],
                  correction.seq > marker.seq
            else {
                return marker
            }
            var updated = marker
            updated.voice = correction.voice
            return updated
        }
        return effective.map { EffectiveMarker(marker: $0, isExact: additionSeqs.contains($0.seq)) }
    }
}
