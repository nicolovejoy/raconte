import SwiftUI

/// The journal itself, above its entries (spec ruling 5). Before this, selecting a journal
/// showed only a list with the journal's name as a navigation title — the journal had no
/// presence on its own screen, and its cover had nowhere to be seen at a size that lets
/// you recognise the photograph.
///
/// The whole card is the edit affordance. Cover, name and date line are one button, not a
/// row with an Edit button beside it.
struct JournalHeaderCard: View {
    let name: String
    let cover: Data?
    let dateLine: String?
    let entryCount: Int
    let onEdit: () -> Void

    var body: some View {
        Button(action: onEdit) {
            HStack(spacing: 14) {
                // A Button label, NOT a Menu label. #69: a macOS Menu label discards a
                // resizable Image's frame; a Button label honours it (harness variant D).
                JournalCoverThumbnail(data: cover, size: 72)

                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(.title3.weight(.semibold))
                    if let dateLine {
                        Text(dateLine)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Text(entryCount == 1 ? "1 entry" : "\(entryCount) entries")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(dateLine.map { "\(name), \($0)" } ?? name)
        .accessibilityHint("Edit this journal")
        .accessibilityIdentifier("journal.header")
    }
}
