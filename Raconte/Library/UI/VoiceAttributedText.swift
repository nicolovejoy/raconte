import SwiftUI

/// How a voice-attributed paragraph is set as text, in one place.
///
/// Extracted from `EntryDetailView.attributedParagraph` (2026-08-15) when the capture
/// screen's post-stop receipt became a second renderer of the same thing. The owner's ask
/// was that the voice marks "manifest" — and two implementations of what a voice mark
/// looks like drift, which on this screen would mean the receipt and the entry you open
/// from it disagreeing about who said what.
///
/// The label rules themselves are NOT here: `VoiceDisplay` owns whether a voice has a
/// label at all (per-journal, opt-in, default none — owner ruling, issue #56) and whether
/// it renders italic. This is only the typesetting.
enum VoiceAttributedText {

    /// `Text` concatenation, deliberately, rather than an `AttributedString`: each
    /// segment's own explicit modifiers (weight, colour, italic) survive whatever
    /// `.font(...)` the call site applies to the whole paragraph, which is the mechanism
    /// the voice prefix relies on to stay semibold-secondary inside serif body prose.
    static func paragraph(_ paragraph: TranscriptAttribution.Paragraph,
                          voiceLabels: [String: String]) -> Text {
        let body = Text(paragraph.text)
        let combined: Text
        if let label = VoiceDisplay.label(forVoice: paragraph.voice, voiceLabels: voiceLabels) {
            let prefix = Text("\(label): ")
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            combined = prefix + body
        } else {
            combined = body
        }
        return VoiceDisplay.isItalic(voice: paragraph.voice) ? combined.italic() : combined
    }
}
