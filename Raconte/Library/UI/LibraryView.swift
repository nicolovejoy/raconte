import SwiftUI

/// Where a `LibraryView` push lands (also entry detail, since both screens share one
/// `LibraryScreenModel`). Lives here rather than in `ContentView` because the library
/// screen is what mints the value `NavigationLink`s push.
enum LibraryDestination: Hashable {
    case entry(String)
    /// The Trash screen (M3 T5). Pushed from the library's toolbar.
    case trash
}

/// The library screen (M3 T4, phone mockup): journal filter chips, entries grouped by
/// year of `effectiveDate` descending, one quiet row each. Trashed entries are never
/// shown here — T5 owns the Trash screen.
struct LibraryView: View {
    let model: LibraryScreenModel

    /// Row swipe/context-menu state (owner request, 2026-08-03): the row that asked to
    /// trash or move, if any. Held here rather than per-row `@State` because the
    /// confirmation dialogs are single instances shared across every row, keyed by the
    /// captured id — the same shape `EntryDetailView` uses for its own trash confirm.
    @State private var pendingTrashCaptureID: String?
    @State private var pendingMoveCaptureID: String?

    var body: some View {
        VStack(spacing: 0) {
            if model.journalsUnreadable { registryBanner }
            journalChips
            content
            #if DEBUG
            skippedNote
            sweepNote
            #endif
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { trashLink }
        }
        .task { await model.rescan() }
        .confirmationDialog("Move this entry to the trash?",
                            isPresented: Binding(
                                get: { pendingTrashCaptureID != nil },
                                set: { if !$0 { pendingTrashCaptureID = nil } }),
                            titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) {
                if let id = pendingTrashCaptureID {
                    Task { await model.trashEntry(id) }
                }
                pendingTrashCaptureID = nil
            }
            .accessibilityIdentifier("library.row.confirmTrash")
            Button("Cancel", role: .cancel) { pendingTrashCaptureID = nil }
        } message: {
            Text("You can restore it from the Trash for \(TrashPolicy.retentionDays) days.")
        }
        .confirmationDialog("Move to journal",
                            isPresented: Binding(
                                get: { pendingMoveCaptureID != nil },
                                set: { if !$0 { pendingMoveCaptureID = nil } })) {
            if let id = pendingMoveCaptureID {
                ForEach(journalChoices(for: id)) { journal in
                    Button(journal.name) {
                        Task { await model.moveEntry(id, toJournal: journal.id) }
                        pendingMoveCaptureID = nil
                    }
                }
            }
            Button("Cancel", role: .cancel) { pendingMoveCaptureID = nil }
        }
    }

    /// Every journal except the entry's current one — reassigning to where it already is
    /// isn't a choice. `model.items` (not `allEntries`): the library list is already
    /// scoped to non-trashed entries, which is the only place these rows appear.
    private func journalChoices(for captureID: String) -> [Journal] {
        let currentJournalID = model.items.first { $0.captureID == captureID }?.journalID
        return model.journals.filter { $0.id != currentJournalID }
    }

    /// Quiet by design: a text button, always present so the trash is never a place you
    /// have to already know about, carrying its count only when there is one. Trash is
    /// somewhere you go looking for something, not something the app should keep
    /// pointing at.
    private var trashLink: some View {
        NavigationLink(value: LibraryDestination.trash) {
            Text(model.trashed.isEmpty ? "Trash" : "Trash (\(model.trashed.count))")
                .font(.caption)
        }
        .accessibilityIdentifier("library.trashLink")
    }

    /// The scan knew the registry was damaged and nothing said so. Calm and specific:
    /// the entries are all here, only their filing is unreadable, and the chips below
    /// are empty for a reason rather than because there are no journals.
    private var registryBanner: some View {
        Text("Your journals couldn’t be read, so entries aren’t showing which one they’re in.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .accessibilityIdentifier("library.journalsUnreadable")
    }

    /// DEBUG only — see `LibraryScreenModel.skipped` for why this is not shipping chrome.
    @ViewBuilder
    private var skippedNote: some View {
        if !model.skipped.isEmpty {
            Text("\(model.skipped.count) capture directory(s) skipped — nothing durable in them.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .accessibilityIdentifier("library.skippedNote")
        }
    }

    /// DEBUG only, and only for skips — see `LibraryScreenModel.lastSweep`. A permanent
    /// deletion the owner asked for thirty days ago needs no notice; a directory the
    /// sweep *keeps* declining to remove is one that will sit in the trash forever.
    @ViewBuilder
    private var sweepNote: some View {
        if let sweep = model.lastSweep, !sweep.skipped.isEmpty {
            Text("Trash sweep: \(sweep.deleted.count) erased, \(sweep.skipped.count) skipped.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .accessibilityIdentifier("library.sweepNote")
        }
    }

    private var journalChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "All", isSelected: model.journalScope == .all) {
                    Task { await model.selectJournalScope(.all) }
                }
                ForEach(model.journals) { journal in
                    chip(title: journal.name,
                         subtitle: model.dateRange(forJournal: journal.id)?.formatted(),
                         cover: model.journalCovers[journal.id],
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

    /// `subtitle` is the journal's derived date range (issue #14 part 2) — `nil` for an
    /// empty journal, which shows just the name rather than a blank second line.
    /// `cover` (issue #14 part 3) renders a small leading thumbnail; `nil` shows nothing,
    /// not a placeholder — a chip without a cover looks exactly like it did before covers
    /// existed.
    @ViewBuilder
    private func chip(title: String, subtitle: String? = nil, cover: Data? = nil, isSelected: Bool,
                       action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                JournalCoverThumbnail(data: cover, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.caption.weight(isSelected ? .semibold : .regular))
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.12),
                       in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("library.journalChip")
        .accessibilityLabel(subtitle.map { "\(title), \($0)" } ?? title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    @ViewBuilder
    private var content: some View {
        if model.items.isEmpty {
            // "No recordings yet" is a claim about the disk, and a running scan has not
            // made it yet. Gated on `isLoading` so a slow first scan doesn't tell the
            // owner his library is empty and then contradict itself.
            if model.isLoading { scanningState } else { emptyState }
        } else {
            List {
                ForEach(model.yearGroups) { group in
                    Section(String(group.year)) {
                        ForEach(group.items) { item in
                            NavigationLink(value: LibraryDestination.entry(item.captureID)) {
                                LibraryEntryRow(item: item)
                            }
                            // Trailing swipe (trash first, so a full swipe trashes —
                            // platform convention) plus a Mac-convention right-click
                            // context menu with the same two handlers, reusing
                            // `LibraryScreenModel.trashEntry`/`moveEntry` exactly as the
                            // detail screen does — no second delete or move path.
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    pendingTrashCaptureID = item.captureID
                                } label: {
                                    Label("Trash", systemImage: "trash")
                                }
                                .accessibilityIdentifier("library.row.trashSwipe")

                                Button {
                                    pendingMoveCaptureID = item.captureID
                                } label: {
                                    Label("Move", systemImage: "folder")
                                }
                                .tint(.blue)
                                .accessibilityIdentifier("library.row.moveSwipe")
                            }
                            .contextMenu {
                                Button {
                                    pendingMoveCaptureID = item.captureID
                                } label: {
                                    Label("Move to Journal…", systemImage: "folder")
                                }
                                Button(role: .destructive) {
                                    pendingTrashCaptureID = item.captureID
                                } label: {
                                    Label("Move to Trash", systemImage: "trash")
                                }
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

    private var scanningState: some View {
        ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("library.scanning")
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

    private var dateText: String { item.formattedEffectiveDate() }
    private var recordedDateText: String { item.capturedAt.formatted(date: .abbreviated, time: .shortened) }
    private var durationText: String { CaptureCoordinator.formatDuration(item.durationSeconds) }
}
