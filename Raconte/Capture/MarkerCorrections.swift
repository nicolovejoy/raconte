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
///   retract with no target.
/// - `.correctionBoundaryAdd` synthesizes a brand-new effective `.paragraph` marker at
///   its own `frame` (computed by `MarkerCorrectionWriter` from a picked word's span
///   start, never a scrubbed time) — a boundary the owner never tapped at capture time.
enum MarkerCorrections {
    static func effectiveMarkers(_ raw: [StructureMarker]) -> [StructureMarker] {
        var retractedSeqs: Set<Int> = []
        var voiceCorrectionsByFrame: [Int64: String] = [:]
        var additions: [StructureMarker] = []

        for marker in raw {
            switch marker.kind {
            case .correctionRetract:
                if let target = marker.retractsSeq { retractedSeqs.insert(target) }
            case .correctionVoice:
                if let voice = marker.voice { voiceCorrectionsByFrame[marker.frame] = voice }
            case .correctionBoundaryAdd:
                additions.append(StructureMarker(seq: marker.seq, frame: marker.frame, kind: .paragraph))
            case .voice, .paragraph, .unknown:
                break
            }
        }

        var effective = raw.filter { $0.kind == .voice || $0.kind == .paragraph }
        effective.removeAll { retractedSeqs.contains($0.seq) }
        effective = effective.map { marker in
            guard marker.kind == .voice, let corrected = voiceCorrectionsByFrame[marker.frame] else {
                return marker
            }
            var updated = marker
            updated.voice = corrected
            return updated
        }
        effective.append(contentsOf: additions)
        return effective
    }
}
