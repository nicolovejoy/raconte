import SwiftUI

/// The one coverless/imageless tile the ink & paper redesign uses everywhere a cover or
/// entry thumbnail is absent (Image lifecycle rule: "coverless/imageless states are quiet
/// neutrals — no placeholder icons shouting absence, no broken-image glyphs"). A quiet
/// `paperInset` rounded rectangle with one glyph in `inkSecondary` — never a "photo failed
/// to load" icon.
///
/// Originally private to `JournalPickerSheet`'s row cover; extracted here (#117) so the
/// library header band and entry rows reuse the exact same tile rather than a second
/// implementation drifting from it.
struct NeutralCoverTile: View {
    var size: CGFloat
    /// `nil` = a plain quiet tile — the right shape for an imageless ENTRY thumb
    /// (owner ruling 2026-08-29: a mic glyph there reads as "audio icon", not
    /// "no image", and `book.closed` reads as a paper-towel dispenser at small sizes).
    var glyph: String? = nil
    /// Coverless JOURNAL tiles show a serif monogram instead of a glyph (the design
    /// doc's "mic/monogram tile"). Pass the journal's full name; the tile takes the
    /// first character itself.
    var monogram: String? = nil
    var cornerRadius: CGFloat = 10

    /// First character of the trimmed name, uppercased; nil for a blank name.
    static func monogramText(_ name: String?) -> String? {
        guard let first = name?.trimmingCharacters(in: .whitespacesAndNewlines).first
        else { return nil }
        return String(first).uppercased()
    }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(InkTone.paperInset.color)
            .overlay {
                // Decorative only — `.accessibilityHidden` so neither the SF Symbol's
                // synthesized label (e.g. "microphone") nor a stray letter leaks into a
                // merged `NavigationLink` label a UI test reads (`library.entryLink`'s
                // "Entry photo" check, `CaptureUITests.durationSeconds(in:)`'s technique).
                if let letter = Self.monogramText(monogram) {
                    Text(letter)
                        .font(.system(size: size * 0.42, design: .serif))
                        .foregroundStyle(InkTone.inkSecondary.color)
                        .accessibilityHidden(true)
                } else if let glyph {
                    Image(systemName: glyph)
                        .foregroundStyle(InkTone.inkSecondary.color)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: size, height: size)
    }
}
