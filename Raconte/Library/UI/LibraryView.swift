import SwiftUI

/// Where a `LibraryView` push lands (also entry detail, since both screens share one
/// `LibraryScreenModel`). Lives here rather than in `ContentView` because the library
/// screen is what mints the value `NavigationLink`s push.
///
/// `.trash` retired (nav T5): Trash is now its own sidebar place (`Place.trash`), reached
/// directly rather than as a push nested under the library screen.
enum LibraryDestination: Hashable {
    case entry(String)
}

/// The library screen (M3 T4, phone mockup; nav T5 dropped the journal filter chips and
/// the Trash link — both are sidebar places now): entries grouped by year of
/// `effectiveDate` descending, one quiet row each. Trashed entries are never shown here.
struct LibraryView: View {
    let model: LibraryScreenModel
    /// From the PLACE that routed here (`ContentView.libraryTitle`) — "All Entries" for
    /// the cross-journal scope, a journal's own name for a scoped one.
    let title: String
    /// The journal itself, when this place is a single journal — `nil` for All Entries,
    /// which is not a journal and shows no header (spec ruling 5).
    let journal: Journal?
    /// Task 6 replaces this with a real push to the journal editor. A no-op default so
    /// this task can ship the header without the editor existing yet — deliberate
    /// staging, not an oversight.
    var onEditJournal: (String) -> Void = { _ in }

    /// Row swipe/context-menu state (owner request, 2026-08-03): the row that asked to
    /// trash or move, if any. Held here rather than per-row `@State` because the
    /// confirmation dialogs are single instances shared across every row, keyed by the
    /// captured id — the same shape `EntryDetailView` uses for its own trash confirm.
    @State private var pendingTrashCaptureID: String?
    @State private var pendingMoveCaptureID: String?

    /// Sidecar writes that reported failure — same swallowed-`try?` family as
    /// `EntryDetailView`/`TrashView`.
    @State private var trashFailed = false
    @State private var moveFailed = false

    var body: some View {
        VStack(spacing: 0) {
            if model.journalsUnreadable { registryBanner }
            // Above `content`, not inside the List's non-empty branch: a freshly
            // created journal has zero entries and would otherwise show `emptyState`
            // with no header at all — an owner-created journal with nothing recorded
            // yet must still be reachable for editing (spec ruling 5 doesn't carve out
            // an exception for an empty one).
            journalHeader
                .padding(.horizontal, 16)
            content
            #if DEBUG
            skippedNote
            sweepNote
            #endif
        }
        .navigationTitle(title)
        .task { await model.rescan() }
        .confirmationDialog("Move this entry to the trash?",
                            isPresented: Binding(
                                get: { pendingTrashCaptureID != nil },
                                set: { if !$0 { pendingTrashCaptureID = nil } }),
                            titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) {
                if let id = pendingTrashCaptureID {
                    Task {
                        if !(await model.trashEntry(id)) { trashFailed = true }
                    }
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
                        Task {
                            if !(await model.moveEntry(id, toJournal: journal.id)) { moveFailed = true }
                        }
                        pendingMoveCaptureID = nil
                    }
                }
            }
            Button("Cancel", role: .cancel) { pendingMoveCaptureID = nil }
        }
        .alert("Couldn’t move this entry to the trash", isPresented: $trashFailed) {
            Button("OK") { trashFailed = false }
        } message: {
            Text("The change didn’t save. Try again.")
        }
        .alert("Couldn’t move this entry", isPresented: $moveFailed) {
            Button("OK") { moveFailed = false }
        } message: {
            Text("The change didn’t save. Try again.")
        }
    }

    /// Every journal except the entry's current one — reassigning to where it already is
    /// isn't a choice. `model.items` (not `allEntries`): the library list is already
    /// scoped to non-trashed entries, which is the only place these rows appear.
    private func journalChoices(for captureID: String) -> [Journal] {
        let currentJournalID = model.items.first { $0.captureID == captureID }?.journalID
        return model.journals.filter { $0.id != currentJournalID }
    }

    /// The scan knew the registry was damaged and nothing said so. Calm and specific:
    /// the entries are all here, only their filing is unreadable.
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
        if let sweep = model.lastSweep, !sweep.skipped.isEmpty || !sweep.pendingRemovalFailures.isEmpty {
            let pending = sweep.pendingRemovalFailures.count
            Text("Trash sweep: \(sweep.deleted.count) erased, \(sweep.skipped.count) skipped."
                + (pending > 0 ? ", \(pending) pending" : ""))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .accessibilityIdentifier("library.sweepNote")
        }
    }

    /// The journal itself, above its entries (spec ruling 5) — `nil` (renders nothing)
    /// for All Entries, which is not a journal.
    @ViewBuilder
    private var journalHeader: some View {
        if let journal {
            JournalHeaderCard(name: journal.name,
                              cover: model.journalCovers[journal.id],
                              dateLine: model.dateLine(forJournal: journal.id),
                              entryCount: model.items.count,
                              onEdit: { onEditJournal(journal.id) })
        }
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
                            // On the LINK, not on the row inside it. A `NavigationLink`
                            // merges its label's children into one accessibility element,
                            // so `LibraryEntryRow`'s own `library.row` identifier is not
                            // independently queryable — the same flattening `capture
                            // .recentRow` exists to work around, and which silently made
                            // every library row unqueryable from a UI test until the
                            // capture screen stopped listing three recents and the tests
                            // had to come here instead.
                            .accessibilityIdentifier("library.entryLink")
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

                // Weekday only at day precision (issue #48) — see
                // `PartialDate.weekdayText`. Abbreviated for the row; full name lives on
                // the detail screen.
                if let weekday = item.weekdayText() {
                    Text(weekday)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("library.row.weekday")
                }

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
