import Foundation

/// Appends correction records to `transcript/markers.jsonl` (T7 Task 6). The only
/// writer on this path: raw taps stay immutable (locked decision 5), so every action
/// here is an append, never a rewrite of an existing line.
///
/// Reuses `MarkerLogWriter` unchanged rather than a parallel implementation — the
/// SAME append discipline (torn-tail handling, `seq` resumed from the file's own
/// tail, refuse-to-open-an-unreadable-log) a correction append needs applies
/// identically to a capture-time tap. `open()` + `append()` + `close()` per call
/// (corrections are rare, user-initiated events off the main flow, not a capture-time
/// hot path where reusing one open handle across many writes matters).
///
/// **Correction (review Minor 6):** `open()` DOES create `transcript/markers.jsonl`
/// on disk immediately (`O_CREAT`, even for zero bytes) — it is not, in fact, lazy in
/// the sense of waiting for a successful append. What actually protects a mis-tapped
/// capture here is two things, neither of which is "this creates nothing": (1) the
/// append immediately follows the open within the SAME `appendOne` call, so there is
/// no caller-visible window where an empty file sits unattended; and (2) in every
/// path this writer is actually reached through
/// (`MarkerCorrectionModel`/`MarkerCorrectionView`), a `retract`/`correctVoice`
/// requires an ALREADY-rendered boundary row (which only exists if `markers.jsonl`
/// is already present) and `addBoundary` requires a readable `current` revision
/// (which means `transcript/canonical-N.json` already exists) — so
/// `holdsIrreplaceableArtifacts` is already `true` before any of these three actions
/// can run at all. See the T7 Task 6 report for the full reachability argument.
enum MarkerCorrectionWriter {
    /// Brief case 3: a word whose covering span has no usable bounds (`.none`/
    /// `.unknown` anchor, or a zero-length `.inherited` span — same test as
    /// `TranscriptAttribution.isPlaceableSpan`) is not offerable, full stop. No
    /// boundary is ever placed "nearby" as a fallback.
    enum BoundaryAddError: Error, Equatable {
        case indexOutOfRange
        case noUsableBounds
    }

    /// Case 1: retract a mis-tapped marker by its `seq`. The reader
    /// (`MarkerCorrections.effectiveMarkers`) ignores a retract whose target is
    /// already gone or never existed — this writer does not need to check first, and
    /// deliberately doesn't: checking-then-writing would be a TOCTOU against a second
    /// device or a second correction session doing the same retract.
    static func retract(seq targetSeq: Int, captureDirectory: URL) throws {
        try appendOne(StructureMarker(seq: 0, frame: 0, kind: .correctionRetract, retractsSeq: targetSeq),
                     captureDirectory: captureDirectory)
    }

    /// Case 2: correct the voice AT an existing boundary. `frame` must be the raw
    /// tap's own frame (never a scrubbed or re-derived one) — that is what "an
    /// existing boundary" (brief case 2) means, and it is how
    /// `MarkerCorrections.effectiveMarkers` finds the marker to override.
    static func correctVoice(frame: Int64, voice: String, captureDirectory: URL) throws {
        try appendOne(StructureMarker(seq: 0, frame: frame, kind: .correctionVoice, voice: voice),
                     captureDirectory: captureDirectory)
    }

    /// Case 3: mint a boundary the owner never tapped, anchored to the PICKED WORD's
    /// covering span — never a time he scrubs to. `spanIndex` identifies that
    /// covering span in the same `spans` array `TranscriptAttribution.attribute(
    /// spans:snapped:)` already renders, so a caller building an "add boundary here"
    /// affordance over the rendered transcript can hand back the exact index it
    /// rendered from.
    ///
    /// Returns the frame actually written (span's own `frameStart`) on success. Writes
    /// NOTHING and throws `.noUsableBounds` when the span cannot anchor a boundary —
    /// shares `TranscriptAttribution.isPlaceableSpan` rather than re-deriving the rule,
    /// so "offerable in the UI" and "acceptable to the writer" can never disagree.
    @discardableResult
    static func addBoundary(atSpanIndex spanIndex: Int, spans: [TranscriptSpan],
                            captureDirectory: URL) throws -> Int64 {
        let frame = try placeableFrame(atSpanIndex: spanIndex, spans: spans)
        try appendOne(StructureMarker(seq: 0, frame: frame, kind: .correctionBoundaryAdd),
                     captureDirectory: captureDirectory)
        return frame
    }

    /// Shared by `addBoundary` and `addVoiceBoundary` (Task 1, #56) — the identical
    /// placeable-anchor rule (`TranscriptAttribution.isPlaceableSpan`, the picked span's
    /// own `frameStart`, never the group's), factored out once so a voice-carrying add
    /// can never silently disagree with a plain one about what is offerable.
    private static func placeableFrame(atSpanIndex spanIndex: Int, spans: [TranscriptSpan]) throws -> Int64 {
        guard spans.indices.contains(spanIndex) else { throw BoundaryAddError.indexOutOfRange }
        let target = spans[spanIndex]
        guard TranscriptAttribution.isPlaceableSpan(target), let frame = target.frameStart else {
            throw BoundaryAddError.noUsableBounds
        }
        return frame
    }

    // MARK: - Task 1 (#56): voice-carrying boundary adds

    /// Case 3, voice-carrying variant: identical to `addBoundary` (same picked-span
    /// anchor, same placeable-anchor rejection via `placeableFrame`, shares the exact
    /// rule rather than re-deriving it), but the persisted record also carries `voice`
    /// — so `MarkerCorrections.effectiveMarkers` synthesizes a `.voice` marker instead
    /// of a plain `.paragraph` one at this exact, word-anchored frame.
    @discardableResult
    static func addVoiceBoundary(atSpanIndex spanIndex: Int, spans: [TranscriptSpan],
                                 voice: String, captureDirectory: URL) throws -> Int64 {
        let frame = try placeableFrame(atSpanIndex: spanIndex, spans: spans)
        try appendOne(StructureMarker(seq: 0, frame: frame, kind: .correctionBoundaryAdd, voice: voice),
                     captureDirectory: captureDirectory)
        return frame
    }

    /// The "he tapped a voice before saying anything" case: a voice-carrying boundary
    /// add anchored at frame 0, with no span requirement at all (unlike
    /// `addVoiceBoundary`, there is no picked word to validate against — frame 0 is
    /// always a legal anchor, the same frame `TranscriptAttribution`'s frame-0 opener
    /// convention already gives special meaning to). Writes unconditionally, creating
    /// `markers.jsonl` if it doesn't exist yet — there is no prerequisite readable state
    /// to check first the way `addBoundary`/`addVoiceBoundary` have (a readable
    /// `current` revision supplying `spans`).
    static func addOpeningVoice(voice: String, captureDirectory: URL) throws {
        try appendOne(StructureMarker(seq: 0, frame: 0, kind: .correctionBoundaryAdd, voice: voice),
                     captureDirectory: captureDirectory)
    }

    /// A sentence for the UI (mirrors `TranscriptEditorModel.saveFailureMessage`'s
    /// precedent: rendered text lives in one place, not re-derived per screen).
    static func boundaryAddRejectionMessage() -> String {
        "This word wasn’t given a timed position when it was transcribed or edited, "
            + "so a boundary can’t be placed there."
    }

    private static func appendOne(_ marker: StructureMarker, captureDirectory: URL) throws {
        let writer = MarkerLogWriter(captureDirectory: captureDirectory)
        try writer.open()
        try writer.append(marker)
        try writer.close()
    }
}
