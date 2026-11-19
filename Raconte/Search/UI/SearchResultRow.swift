import SwiftUI

/// One search result (#194): the date line and journal, then the snippet with its matches
/// highlighted. The date is the library row's own (`formattedLibraryRowDate`), so an entry
/// reads the same here as in its list.
struct SearchResultRow: View {
    let result: SearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(result.item.formattedLibraryRowDate(now: Date()))
                    .font(TypeRole.secondary.font.weight(.semibold))
                    .foregroundStyle(InkTone.ink.color)
                Text(result.item.journal?.name ?? "Unfiled")
                    .font(TypeRole.label.font)
                    .foregroundStyle(InkTone.inkSecondary.color)
            }
            Text(result.snippet.attributed)
                .font(TypeRole.reading.font)
                .foregroundStyle(InkTone.ink.color)
                .lineLimit(3)
        }
        .padding(.vertical, 6)
        // One element, so the row's label carries the snippet's words.
        .accessibilityElement(children: .combine)
    }
}
