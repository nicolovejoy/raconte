import Foundation

/// The ONE voice-display mapping (T7 Mark Voices, issue #56): replaces
/// `TranscriptAttribution.displayName`/`isItalic`. Owner ruling: labels are per-journal
/// and opt-in — the DEFAULT render has no label at all, voices are told apart only by
/// `isItalic` (the main voice) vs regular (the alternative). Pure, no I/O, sibling in
/// spirit to `TranscriptAttribution` itself.
enum VoiceDisplay {
    /// The voice whose paragraphs render italic — the print/cursive stand-in
    /// (owner decision 2026-08-08, carried over unchanged from
    /// `TranscriptAttribution.isItalic`).
    static let mainVoice = StructureMarker.Voice.bigNico

    /// Flips between the two v1 voices (exactly two voices, string ids — owner decision
    /// 3). The one place this rule is written; anything that needs "the other voice"
    /// (e.g. a marker-correction affordance) should call this rather than re-deriving it.
    static func other(_ voice: String) -> String {
        voice == mainVoice ? StructureMarker.Voice.littleNico : mainVoice
    }

    /// `nil` unless a voice is set AND that journal has configured a non-empty label for
    /// it. Trims defensively (a store-level trim already drops empty-after-trim values
    /// at write time, but this is the read-side ground truth and must not trust that a
    /// stored value is clean).
    static func label(forVoice voice: String?, voiceLabels: [String: String]) -> String? {
        guard let voice, let raw = voiceLabels[voice] else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Whether a voice's paragraphs render in italic. Unchanged rule from
    /// `TranscriptAttribution.isItalic`: the main voice is italic, everything else —
    /// including `nil` (no voice marker in force) — is not.
    static func isItalic(voice: String?) -> Bool {
        voice == mainVoice
    }

    /// VoiceOver never loses the voice distinction just because visual labels are off:
    /// the configured label if there is one, else the voice id itself, uppercased (the
    /// old `TranscriptAttribution.displayName` rule, now the fallback rather than the
    /// only answer).
    static func accessibilityName(forVoice voice: String, voiceLabels: [String: String]) -> String {
        label(forVoice: voice, voiceLabels: voiceLabels) ?? voice.uppercased()
    }
}
