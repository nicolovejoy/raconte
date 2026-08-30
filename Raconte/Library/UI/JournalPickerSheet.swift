import SwiftUI

/// Task 9 (#18): the one designed journal switcher, replacing the capture screen's
/// `Menu` (Task 10) and the entry detail's temporary `confirmationDialog` (Task 10).
/// Rows are `Button`s, never a `Menu` — #69: a macOS `Menu` label discards a resizable
/// `Image`'s frame, which is exactly what a cover thumbnail needs.
///
/// Owns no state and makes no write of its own — same shape as `EntryInfoSheet`:
/// `onSelect`/`onNewJournal` are handed in by the caller, which already knows the
/// right code path (`CaptureScreenModel.selectJournal`/`createJournal` on capture,
/// `LibraryScreenModel.moveEntry` + the journal-creation flow on detail).
struct JournalPickerSheet: View {
    let journals: [Journal]
    let covers: [String: Data]
    let currentJournalID: String?
    /// `nil` when the caller has no cheap per-journal count source — the subtitle
    /// then falls back to `dateLine` alone (see `rowSubtitle`).
    let dateLine: (String) -> String?
    let entryCount: (String) -> Int?
    let onSelect: (String) -> Void
    let onNewJournal: () -> Void

    @Environment(\.dismiss) private var dismiss

    /// `("Jun – Aug 2026", 41)` → `"Jun – Aug 2026 · 41 entries"`; either half absent
    /// drops its half (and the separator); both absent → `""`. Singular "1 entry".
    static func rowSubtitle(dateLine: String?, entryCount: Int?) -> String {
        let countText = entryCount.map { $0 == 1 ? "1 entry" : "\($0) entries" }
        switch (dateLine, countText) {
        case let (line?, count?): return "\(line) · \(count)"
        case let (line?, nil): return line
        case let (nil, count?): return count
        case (nil, nil): return ""
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(journals) { journal in
                    row(for: journal)
                }
                Divider()
                newJournalRow
            }
            .listStyle(.plain)
            .navigationTitle("Choose Journal")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        .accessibilityIdentifier("journalPicker.sheet")
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
        #if os(macOS)
        // An unsized macOS sheet collapses to its intrinsic height — a clipped card
        // showing barely one row (owner smoke, 2026-08-29). Give it a real reading size.
        .frame(minWidth: 400, minHeight: 460)
        #endif
    }

    private func row(for journal: Journal) -> some View {
        let isCurrent = journal.id == currentJournalID
        return Button {
            dismiss()
            onSelect(journal.id)
        } label: {
            HStack(spacing: 12) {
                cover(for: journal)
                VStack(alignment: .leading, spacing: 2) {
                    Text(journal.name)
                        .fontWeight(isCurrent ? .semibold : .regular)
                        .foregroundStyle(InkTone.ink.color)
                    let subtitle = Self.rowSubtitle(dateLine: dateLine(journal.id),
                                                     entryCount: entryCount(journal.id))
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(InkTone.inkSecondary.color)
                    }
                }
                Spacer(minLength: 0)
                if isCurrent {
                    Image(systemName: "checkmark")
                        .foregroundStyle(InkTone.accent.color)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("journalPicker.row.\(journal.id)")
    }

    @ViewBuilder
    private func cover(for journal: Journal) -> some View {
        AsyncCaptureImage(id: journal.id, load: {
            covers[journal.id]
        }, loaded: { image in
            image
                .resizable()
                .scaledToFill()
        }, placeholder: {
            // Coverless is the ordinary case, not a broken/error state — the shared
            // neutral tile (#117), never a "photo failed to load" icon.
            NeutralCoverTile(size: 52)
        })
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var newJournalRow: some View {
        Button {
            dismiss()
            onNewJournal()
        } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(InkTone.accent.color, style: StrokeStyle(lineWidth: 1, dash: [4]))
                    .frame(width: 52, height: 52)
                    .overlay {
                        Image(systemName: "plus")
                            .foregroundStyle(InkTone.accent.color)
                    }
                Text("New Journal…")
                    .foregroundStyle(InkTone.accent.color)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("journalPicker.new")
    }
}
