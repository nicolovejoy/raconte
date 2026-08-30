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
    var glyph: String = "book.closed"
    var cornerRadius: CGFloat = 10

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(InkTone.paperInset.color)
            .overlay {
                // Decorative only — `.accessibilityHidden` so the SF Symbol's own
                // synthesized label (e.g. "microphone") never leaks into a merged
                // `NavigationLink` label a UI test reads (`library.entryLink`'s "Entry
                // photo" check, `CaptureUITests.durationSeconds(in:)`'s technique).
                Image(systemName: glyph)
                    .foregroundStyle(InkTone.inkSecondary.color)
                    .accessibilityHidden(true)
            }
            .frame(width: size, height: size)
    }
}
