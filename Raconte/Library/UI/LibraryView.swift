import SwiftUI

/// Where a `LibraryView` push lands (also entry detail, since both screens share one
/// `LibraryScreenModel`). Lives here rather than in `ContentView` because the library
/// screen is what mints the value `NavigationLink`s push.
enum LibraryDestination: Hashable {
    case entry(String)
}

/// The library screen (M3 T4, phone mockup): journal filter chips, entries grouped by
/// year of `effectiveDate` descending, one quiet row each. Trashed entries are never
/// shown here — T5 owns the Trash screen.
struct LibraryView: View {
    let model: LibraryScreenModel

    var body: some View {
        VStack(spacing: 0) {
            journalChips
            content
        }
        .navigationTitle("Library")
        .onAppear { Task { await model.rescan() } }
    }

    private var journalChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "All", isSelected: model.journalScope == .all) {
                    Task { await model.selectJournalScope(.all) }
                }
                ForEach(model.journals) { journal in
                    chip(title: journal.name,
                         isSelected: model.journalScope == .journal(journal.id)) {
                        Task { await model.selectJournalScope(.journal(journal.id)) }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .accessibilityIdentifier("library.journalChips")
    }

    @ViewBuilder
    private func chip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(isSelected ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.12),
                           in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("library.journalChip")
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    @ViewBuilder
    private var content: some View {
        if model.items.isEmpty {
            emptyState
        } else {
            List {
                ForEach(model.yearGroups) { group in
                    Section(String(group.year)) {
                        ForEach(group.items) { item in
                            NavigationLink(value: LibraryDestination.entry(item.captureID)) {
                                LibraryEntryRow(item: item)
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .accessibilityIdentifier("library.list")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No recordings yet")
                .font(.headline)
            Text("Entries you record will show up here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("library.empty")
    }
}

/// One library row: effective date, a serif snippet, duration, journal name, and two
/// quiet markers — backdated and degraded. Neither marker is alarming; both carry an
/// accessibility label naming exactly what they mean rather than raising an icon that
/// reads as an error.
struct LibraryEntryRow: View {
    let item: EntryListItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(dateText)
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("library.row.date")

                if item.isBackdated {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Backdated. Recorded \(recordedDateText).")
                        .accessibilityIdentifier("library.row.backdatedMarker")
                }

                if !item.degradations.isEmpty {
                    Image(systemName: "questionmark.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(item.degradations.accessibilityReasons.joined(separator: ", "))
                        .accessibilityIdentifier("library.row.degradedMarker")
                }

                Spacer()

                Text(durationText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("library.row.duration")
            }

            if let snippet = item.snippet, !snippet.isEmpty {
                Text(snippet)
                    .font(.system(.body, design: .serif))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .accessibilityIdentifier("library.row.snippet")
            }

            if let journalName = item.journal?.name {
                Text(journalName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("library.row.journal")
            }
        }
        .padding(.vertical, 6)
        .accessibilityIdentifier("library.row")
    }

    private var dateText: String { item.effectiveDate.formatted(date: .abbreviated, time: .omitted) }
    private var recordedDateText: String { item.capturedAt.formatted(date: .abbreviated, time: .shortened) }
    private var durationText: String { CaptureCoordinator.formatDuration(item.durationSeconds) }
}

/// Calm, specific reasons for the degraded marker's accessibility label — never "error"
/// or "corrupt", per the M3 T4 brief: a degradation is a reason to look, not to alarm.
extension EntryDegradation {
    var accessibilityReasons: [String] {
        var reasons: [String] = []
        if contains(.manifestAbsent) || contains(.manifestCorrupt) {
            reasons.append("recording details incomplete")
        }
        if contains(.metadataUnreadable) { reasons.append("entry settings unreadable") }
        if contains(.journalUnresolved) { reasons.append("journal not found") }
        if contains(.transcriptUnreadable) { reasons.append("transcript unreadable") }
        if contains(.transcriptTruncated) { reasons.append("transcript may be incomplete") }
        return reasons
    }
}
