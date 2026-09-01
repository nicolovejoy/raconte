import SwiftUI
import UniformTypeIdentifiers

/// Where a `LibraryView` push lands (also entry detail, since both screens share one
/// `LibraryScreenModel`). Lives here rather than in `ContentView` because the library
/// screen is what mints the value `NavigationLink`s push.
///
/// `.trash` retired (nav T5): Trash is now its own sidebar place (`Place.trash`), reached
/// directly rather than as a push nested under the library screen.
enum LibraryDestination: Hashable {
    case entry(String)
    /// The journal editor (Task 6), pushed from `LibraryCoverBand.onEdit`. Journal id.
    case journalEditor(String)
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
    /// Pushes `.journalEditor(id)` onto `router.detailPath` (wired in `ContentView`).
    /// A no-op default keeps `#Preview`/tests that never tap the header working.
    var onEditJournal: (String) -> Void = { _ in }
    /// Pushes `.entry(captureID)` onto `router.detailPath` for a freshly minted blank
    /// entry (image capture plan Task 7, "+ New entry" toolbar action) — same
    /// no-op-default-for-previews shape as `onEditJournal` above.
    var onCreateEntry: (String) -> Void = { _ in }
    /// The floating record button (Task 11, #117): selects this journal as current and
    /// routes to capture. Wired in `ContentView` — for a scoped journal, selects it via
    /// `CaptureScreenModel.selectJournal` first; for All Entries (not a journal), records
    /// into whatever journal is already current. Same no-op-default-for-previews shape as
    /// `onEditJournal`/`onCreateEntry` above.
    var onRecord: () -> Void = {}

    /// Row swipe/context-menu state (owner request, 2026-08-03): the row that asked to
    /// trash or move, if any. Held here rather than per-row `@State` because the
    /// confirmation dialogs are single instances shared across every row, keyed by the
    /// captured id — the same shape `EntryDetailView` uses for its own trash confirm.
    @State private var pendingTrashCaptureID: String?
    @State private var pendingMoveCaptureID: String?

    /// Select mode (#128). On the VIEW, deliberately — the inverse of the
    /// capture-screen lifetime invariant: selection *should* die on navigation away.
    /// Flat set of capture ids, so it spans the year/month grouping for free.
    @State private var selection = BulkSelection()
    /// The two bulk confirmations. Trash confirms because a seven-entry action is not a
    /// one-entry action (#83's single-swipe direction deliberately diverged from);
    /// Move confirms implicitly by being a destination picker.
    @State private var confirmingBulkTrash = false
    @State private var choosingBulkMoveDestination = false
    /// A completed bulk operation with a nonzero `failed` — presented with BOTH counts,
    /// never swallowed. The failed ids are re-selected by then (see `finishBulkAction`).
    @State private var bulkFailure: BulkFailureReport?

    /// What the partial-failure alert needs to say: which action, and both counts.
    private struct BulkFailureReport {
        var title: String
        var succeeded: Int
        var failed: Int
    }

    /// Sidecar writes that reported failure — same swallowed-`try?` family as
    /// `EntryDetailView`/`TrashView`.
    @State private var trashFailed = false
    @State private var moveFailed = false
    /// `BlankEntryMinter` write failure surfaced to the owner — one more instance of the
    /// `trashFailed`/`moveFailed` family (image capture plan Task 7).
    @State private var createEntryFailed = false

    var body: some View {
        // Split into `screenStack` + two dialog-group functions + `toolbarContent`
        // because one monolithic modifier chain stopped type-checking in reasonable
        // time once the select-mode chrome (#128) joined it.
        withBulkDialogs(withSingleEntryDialogs(screenStack))
            .navigationTitle(title)
            .toolbar { toolbarContent }
            .task { await model.rescan() }
    }

    private var screenStack: some View {
        VStack(spacing: 0) {
            if model.journalsUnreadable { registryBanner }
            // Above `content`, not inside the List's non-empty branch: a freshly
            // created journal has zero entries and would otherwise show `emptyState`
            // with no header at all — an owner-created journal with nothing recorded
            // yet must still be reachable for editing (spec ruling 5 doesn't carve out
            // an exception for an empty one). Full-bleed (no horizontal padding): the
            // cover band spans edge to edge per spec.
            journalHeader
            content
            #if DEBUG
            skippedNote
            sweepNote
            #endif
        }
        .background(InkTone.paper.color)
        .overlay(alignment: .bottomTrailing) {
            // Hidden in select mode: the selection bar owns the bottom edge, and a
            // record button floating over "n selected · Move… · Trash" would sit on
            // top of the very controls the mode exists for.
            if !selection.isActive { floatingRecordButton }
        }
        .safeAreaInset(edge: .bottom) {
            if selection.isActive { selectionBar }
        }
    }

    /// The toolbar, extracted (with the two dialog modifier groups below) because one
    /// monolithic `body` expression stopped type-checking in reasonable time once the
    /// select-mode chrome joined it.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if selection.isActive {
            ToolbarItem {
                Button("Done") {
                    // Leaving the mode clears the selection — nothing about it
                    // survives the mode, let alone the view.
                    selection = BulkSelection()
                }
                .accessibilityIdentifier("library.selectDone")
            }
        } else {
            ToolbarItem {
                Button("Select") { selection.isActive = true }
                    .disabled(model.items.isEmpty)
                    .accessibilityIdentifier("library.select")
            }
            ToolbarItem {
                Button {
                    Task {
                        if let captureID = await model.createBlankEntry(journalID: journal?.id) {
                            onCreateEntry(captureID)
                        } else {
                            createEntryFailed = true
                        }
                    }
                } label: {
                    Label("New Entry", systemImage: "plus")
                }
                .accessibilityIdentifier("library.newEntry")
            }
        }
    }

    /// The pre-#128 per-row dialogs and alerts, moved out of `body` verbatim (see the
    /// type-checking note there). Still attached above the screen's whole stack, per
    /// the repo rule that a dialog on a nested child can silently never present.
    private func withSingleEntryDialogs(_ base: some View) -> some View {
        base
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
        .alert("Couldn’t create a new entry", isPresented: $createEntryFailed) {
            Button("OK") { createEntryFailed = false }
        } message: {
            Text("The change didn’t save. Try again.")
        }
    }

    /// #128 bulk confirmations and the partial-failure alert — same outer-view
    /// attachment rule as `withSingleEntryDialogs`. The count in each title is the
    /// whole point: it is what makes a mis-selection visible before it lands.
    private func withBulkDialogs(_ base: some View) -> some View {
        base
        .confirmationDialog("Move \(entryCountText(selection.count)) to the Trash?",
                            isPresented: $confirmingBulkTrash,
                            titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) {
                confirmingBulkTrash = false
                let ids = selection.sortedIDs
                Task {
                    finishBulkAction(await model.bulkTrash(ids),
                                     failureTitle: "Some entries couldn’t be moved to the trash")
                }
            }
            .accessibilityIdentifier("library.confirmBulkTrash")
            Button("Cancel", role: .cancel) { confirmingBulkTrash = false }
        } message: {
            Text("You can restore them from the Trash for \(TrashPolicy.retentionDays) days.")
        }
        .confirmationDialog("Move \(entryCountText(selection.count)) to journal",
                            isPresented: $choosingBulkMoveDestination,
                            titleVisibility: .visible) {
            ForEach(bulkJournalChoices()) { journal in
                Button(journal.name) {
                    choosingBulkMoveDestination = false
                    let ids = selection.sortedIDs
                    Task {
                        finishBulkAction(await model.bulkMove(ids, toJournal: journal.id),
                                         failureTitle: "Some entries couldn’t be moved")
                    }
                }
            }
            Button("Cancel", role: .cancel) { choosingBulkMoveDestination = false }
        }
        .alert(bulkFailure?.title ?? "", isPresented: Binding(
            get: { bulkFailure != nil },
            set: { if !$0 { bulkFailure = nil } })
        ) {
            Button("OK") { bulkFailure = nil }
        } message: {
            let succeeded = bulkFailure?.succeeded ?? 0
            let failed = bulkFailure?.failed ?? 0
            Text("\(succeeded) succeeded, \(failed) failed. "
                 + "The entries that failed are still selected — try again.")
        }
    }

    // MARK: - Select mode (#128)

    private func entryCountText(_ count: Int) -> String {
        count == 1 ? "1 entry" : "\(count) entries"
    }

    /// The shared epilogue of both bulk operations: full success leaves select mode;
    /// partial failure stays in it with EXACTLY the failed ids re-selected — so the
    /// owner can retry or investigate precisely those — and reports both counts.
    /// A bulk operation must never read as plain success when some entries did not move.
    private func finishBulkAction(_ result: LibraryScreenModel.BulkResult, failureTitle: String) {
        if result.failed.isEmpty {
            selection = BulkSelection()
        } else {
            selection.clear()
            selection.selectAll(result.failed)
            bulkFailure = BulkFailureReport(title: failureTitle,
                                            succeeded: result.succeeded,
                                            failed: result.failed.count)
        }
    }

    /// `journalChoices(for:)` generalized to the selection: a journal is excluded only
    /// when EVERY selected entry is already in it (for a single-journal-scoped list that
    /// is exactly the scoped journal, matching the single-row rule); a mixed selection
    /// keeps every journal, since the move is a real change for at least one entry.
    private func bulkJournalChoices() -> [Journal] {
        let selectedJournalIDs = Set(model.items
            .filter { selection.isSelected($0.captureID) }
            .map(\.journalID))
        return model.journals.filter { journal in
            !(selectedJournalIDs.count == 1 && selectedJournalIDs.first == journal.id)
        }
    }

    /// The bottom action bar, present only in select mode. Explicit point sizes, not
    /// text-style names — `.callout` is 16 pt on iOS but 12 pt on macOS, and this bar
    /// renders on both platforms from this one file.
    private var selectionBar: some View {
        HStack(spacing: 16) {
            Button("Select All") { selection.selectAll(model.items.map(\.captureID)) }
                .accessibilityIdentifier("library.selectAll")
            Spacer()
            Text("\(selection.count) selected")
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(InkTone.inkSecondary.color)
                .accessibilityIdentifier("library.selectionCount")
            Spacer()
            Button("Move…") { choosingBulkMoveDestination = true }
                .disabled(selection.isEmpty)
                .accessibilityIdentifier("library.bulkMove")
            Button("Trash", role: .destructive) { confirmingBulkTrash = true }
                .disabled(selection.isEmpty)
                .accessibilityIdentifier("library.bulkTrash")
        }
        .font(.system(size: 15))
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(InkTone.paperInset.color)
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
    /// for All Entries, which is not a journal. `LibraryCoverBand` (below) replaces the
    /// old `JournalHeaderCard` row (#117 — the dropped half of PR 3).
    @ViewBuilder
    private var journalHeader: some View {
        if let journal {
            LibraryCoverBand(name: journal.name,
                             cover: model.journalCovers[journal.id],
                             subtitle: JournalPickerSheet.rowSubtitle(
                                 dateLine: model.dateLine(forJournal: journal.id),
                                 entryCount: model.items.count),
                             onEdit: { onEditJournal(journal.id) })
        }
    }

    /// 60 pt, bottom-trailing, `InkTone.record.color` — starts capture into this journal
    /// (Task 11). Shown for both a scoped journal and All Entries (spec: "for the All
    /// Entries scope it records into the current journal unchanged" — the button itself
    /// doesn't disappear, only what `onRecord` does behind it differs, and that decision
    /// is made by the caller, not this view).
    private var floatingRecordButton: some View {
        Button(action: onRecord) {
            Image(systemName: "mic.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 60, height: 60)
                .background(InkTone.record.color, in: Circle())
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
        }
        .buttonStyle(.plain)
        .padding(20)
        .accessibilityIdentifier("library.record")
        .accessibilityLabel("Record")
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
                        // Month sub-headers within the year section (Task 11 spec) — a
                        // second `ForEach` nested in the same `Section`'s content, not a
                        // nested `Section`: SwiftUI's `List` does not support nesting a
                        // `Section` inside another `Section`'s content.
                        ForEach(EntryListItem.monthGroups(of: group.items)) { monthGroup in
                            // A `.year`-precision backdate's group has no month name
                            // (final-review finding 1) — no header row for it; the
                            // year `Section` header above already covers those rows.
                            if let month = monthGroup.month {
                                Text(month)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(InkTone.inkSecondary.color)
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(InkTone.paper.color)
                                    .accessibilityIdentifier("library.monthHeader")
                            }

                            ForEach(monthGroup.items) { item in
                                if selection.isActive {
                                    // Select mode (#128): the row toggles instead of
                                    // navigating; swipe actions and the context menu
                                    // are suppressed by living only on the other
                                    // branch. The whole row is the toggle target — a
                                    // deliberate dodge of the known trap where a tap
                                    // on a control inside a List row hits the merged
                                    // label frame and silently does nothing.
                                    selectableRow(item)
                                } else {
                                    navigableRow(item)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(InkTone.paper.color)
            .accessibilityIdentifier("library.list")
            // Final-review finding 3: the floating record button (60 pt + 20 pt
            // padding) overlays the list, and a `List` can't scroll past its own
            // content — without this the last row's trailing side sits permanently
            // under the button. Clearance, not decoration.
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 84) }
        }
    }

    private func selectableRow(_ item: EntryListItem) -> some View {
        Button {
            selection.toggle(item.captureID)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selection.isSelected(item.captureID)
                        ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selection.isSelected(item.captureID)
                        ? InkTone.accent.color : InkTone.inkSecondary.color)
                LibraryEntryRow(model: model, item: item, showsJournalName: journal == nil)
            }
        }
        .buttonStyle(.plain)
        // On the Button, the row's leaf control in this mode — same flattening
        // reasoning as `library.entryLink` on the NavigationLink below. The merged
        // element's VALUE carries the selection state so a UI test can assert which
        // rows are selected without depending on the checkmark glyph.
        .accessibilityIdentifier("library.selectRow")
        .accessibilityValue(selection.isSelected(item.captureID) ? "selected" : "not selected")
        .listRowBackground(InkTone.paper.color)
    }

    private func navigableRow(_ item: EntryListItem) -> some View {
        NavigationLink(value: LibraryDestination.entry(item.captureID)) {
            LibraryEntryRow(model: model, item: item,
                            showsJournalName: journal == nil)
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
        .listRowBackground(InkTone.paper.color)
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
    /// Only needed for the leading thumbnail's model-mediated read
    /// (`thumbnailData(captureID:imageID:)`) — image capture plan Task 7. Every other
    /// field on this row comes from `item` alone, same as before that task.
    let model: LibraryScreenModel
    let item: EntryListItem
    /// `false` when this list is scoped to one journal — the journal is already named by
    /// `LibraryCoverBand` above, so repeating it on every row is noise (Task 11 spec:
    /// "drop the per-row journal-name caption when the list is scoped to a journal").
    /// `true` for All Entries, where the caption is the only place a row says which
    /// journal it belongs to.
    var showsJournalName: Bool = true

    /// image capture plan Task 9: row-level drag-and-drop target, design doc's "the
    /// entry list row" alongside the detail screen's own `.onDrop`
    /// (`EntryDetailView.handleImageProviders`). Cosmetic highlight only.
    @State private var imageDropTargeted = false
    /// Same failure surface as `EntryDetailView.imageAddFailed` — a dropped item that
    /// wasn't a usable image, or a write that failed — shown here because the row has
    /// no other place to report it (unlike the detail screen, a library row has no
    /// sheet to reopen).
    @State private var imageAddFailed = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            thumbnail

            rowContent
        }
        .padding(.vertical, 6)
        .accessibilityIdentifier("library.row")
        // image capture plan Task 9. Left cross-platform (not `#if os(macOS)`-gated) —
        // same reasoning as `EntryDetailView`'s own `.onDrop`: SwiftUI's `.onDrop`
        // compiles and is documented to work on iPadOS with no extra code in the common
        // case, and there is no iPad simulator in this environment to confirm it live,
        // so this is written once for both platforms rather than force-gated and then
        // untested either way.
        .onDrop(of: [.image], isTargeted: $imageDropTargeted, perform: handleImageProviders)
        .background {
            if imageDropTargeted {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        .alert("Couldn’t Use That Photo", isPresented: $imageAddFailed) {
            Button("OK", role: .cancel) {}
        }
    }

    /// Row-level counterpart to `EntryDetailView.handleImageProviders` — same
    /// `ImageDropSource.extract` data-extraction step, then the SAME
    /// `LibraryScreenModel.addImage` the detail screen's picker sheet and drop/paste all
    /// terminate at. No backdate-suggestion prompt here (Task 8's `EntryDetailView
    /// .suggestedBackdate` sheet): a library row has no sheet host of its own to present
    /// one into — that affordance stays scoped to the detail screen, where the owner is
    /// already looking at the entry the image just landed on.
    private func handleImageProviders(_ providers: [NSItemProvider]) -> Bool {
        guard providers.contains(where: { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }) else {
            return false
        }
        let captureID = item.captureID
        Task {
            guard let (data, type) = await ImageDropSource.extract(from: providers) else {
                imageAddFailed = true
                return
            }
            if !(await model.addImage(captureID, data: data, sourceUTType: type.identifier)) {
                imageAddFailed = true
            }
        }
        return true
    }

    /// 56 pt (Task 11 spec) — the entry's own first image when it has one, else the
    /// shared `NeutralCoverTile` (#117), never the old broken-image `photo` glyph.
    /// **Never the journal cover** (Image lifecycle rule: "Entry-row thumbs use the
    /// entry's own first image, never the cover").
    @ViewBuilder
    private var thumbnail: some View {
        if let leadingThumbnail = item.leadingThumbnail {
            AsyncCaptureImage(id: leadingThumbnail.id, load: {
                await model.thumbnailData(captureID: item.captureID, imageID: leadingThumbnail.id)
            }, loaded: { image in
                image
                    .resizable()
                    .scaledToFill()
            }, placeholder: {
                NeutralCoverTile(size: 56, glyph: nil, cornerRadius: 8)
            })
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityIdentifier("library.row.thumbnail")
            // A `NavigationLink`'s label flattens every child into ONE accessibility
            // element (this row's own doc comment, and `library.row.duration`'s —
            // see `CaptureUITests.recentRows`), so `library.row.thumbnail` is not
            // independently queryable from a UI test; only the merged element's
            // LABEL is. This label is the thing a thumbnail-presence UI test can
            // actually assert on, same technique `CaptureUITests.durationSeconds
            // (in:)` uses for the duration text.
            .accessibilityLabel("Entry photo")
        } else {
            NeutralCoverTile(size: 56, glyph: nil, cornerRadius: 8)
        }
    }

    private var rowContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Date + weekday · duration, one line (Task 11 spec).
            HStack(spacing: 6) {
                Text(dateText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(InkTone.ink.color)
                    .accessibilityIdentifier("library.row.date")

                // Weekday only at day precision (issue #48) — see
                // `PartialDate.weekdayText`. Abbreviated for the row; full name lives on
                // the detail screen.
                if let weekday = item.weekdayText() {
                    Text(weekday)
                        .font(.caption)
                        .foregroundStyle(InkTone.inkSecondary.color)
                        .accessibilityIdentifier("library.row.weekday")
                }

                if item.isBackdated {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.caption2)
                        .foregroundStyle(InkTone.inkSecondary.color)
                        .accessibilityLabel("Backdated. Recorded \(recordedDateText).")
                        .accessibilityIdentifier("library.row.backdatedMarker")
                }

                if !item.degradations.isEmpty {
                    Image(systemName: "questionmark.circle")
                        .font(.caption2)
                        .foregroundStyle(InkTone.inkSecondary.color)
                        .accessibilityLabel(item.degradations.accessibilityReasons.joined(separator: ", "))
                        .accessibilityIdentifier("library.row.degradedMarker")
                }

                Spacer()

                Text(durationText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(InkTone.inkSecondary.color)
                    .accessibilityIdentifier("library.row.duration")
            }

            if let snippet = item.snippet, !snippet.isEmpty {
                Text(snippet)
                    .font(.system(.body, design: .serif))
                    .foregroundStyle(InkTone.ink.color)
                    .lineLimit(2)
                    .accessibilityIdentifier("library.row.snippet")
            }

            // Dropped when scoped to one journal — the journal is already named by
            // `LibraryCoverBand` above (Task 11 spec).
            if showsJournalName, let journalName = item.journal?.name {
                Text(journalName)
                    .font(.caption2)
                    .foregroundStyle(InkTone.inkSecondary.color)
                    .accessibilityIdentifier("library.row.journal")
            }
        }
    }

    /// #125: an entry recorded this week also shows the time to the minute, so several
    /// readings in one day are told apart at a glance. Backdated rows are unaffected —
    /// see `EntryListItem.showsCaptureTime(now:calendar:)` for both rules.
    private var dateText: String { item.formattedLibraryRowDate(now: Date()) }
    private var recordedDateText: String { item.capturedAt.formatted(date: .abbreviated, time: .shortened) }
    private var durationText: String { CaptureCoordinator.formatDuration(item.durationSeconds) }
}

/// The journal's cover header band (Task 11, #117 — the dropped half of PR 3). Replaces
/// `JournalHeaderCard`. The whole band is the edit affordance, same "no separate Edit
/// button" rule `JournalHeaderCard` shipped with: cover, title and subtitle are one
/// button, and tapping anywhere on the band — including the "Add Cover" pill in the
/// coverless state — routes to the journal editor.
struct LibraryCoverBand: View {
    let name: String
    let cover: Data?
    /// `JournalPickerSheet.rowSubtitle`'s "range · N entries" string, already formatted —
    /// reused rather than re-deriving the same "date line · count" join here.
    let subtitle: String
    let onEdit: () -> Void

    static let height: CGFloat = 190

    var body: some View {
        Button(action: onEdit) {
            ZStack(alignment: .bottomLeading) {
                if let cover, let image = JournalCoverThumbnail.decode(cover) {
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: Self.height)
                        .clipped()
                    // Bottom scrim so white title/subtitle text stays legible over any
                    // photograph, regardless of its own tones. Final-review finding 2:
                    // a flat 0→0.7 ramp from `.center` left only ~0.15–0.35 alpha where
                    // the 26-pt title actually sits, under the 3.0 large-text contrast
                    // floor over a pale photo. Explicit stops rising faster and higher
                    // (0.55 at the midpoint, 0.9 at the bottom) keep the top of the band
                    // clear while giving the text itself real ink behind it.
                    LinearGradient(stops: [
                        .init(color: .black.opacity(0), location: 0.0),
                        .init(color: .black.opacity(0.55), location: 0.6),
                        .init(color: .black.opacity(0.9), location: 1.0),
                    ], startPoint: .top, endPoint: .bottom)
                        .frame(height: Self.height)
                    coverTitleBlock
                } else {
                    InkTone.paperInset.color
                        .frame(height: Self.height)
                    coverlessTitleBlock
                }
            }
        }
        .buttonStyle(.plain)
        .frame(height: Self.height)
        .clipped()
        .accessibilityIdentifier("journal.header")
        .accessibilityLabel(subtitle.isEmpty ? name : "\(name), \(subtitle)")
        .accessibilityHint("Edit this journal")
    }

    /// Cover-present state: white serif title over the scrim, no separate affordance —
    /// the whole photograph is already the button.
    private var coverTitleBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name)
                .font(.system(size: 26, weight: .semibold, design: .serif))
                .foregroundStyle(.white)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .padding(20)
    }

    /// Coverless state: ink title on quiet paper, plus the explicit "Add Cover" pill the
    /// spec calls for. The pill is decorative, not a second `Button` — the whole band is
    /// already one, and a nested control here would fire two actions on one tap.
    private var coverlessTitleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(name)
                .font(.system(size: 26, weight: .semibold, design: .serif))
                .foregroundStyle(InkTone.ink.color)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(InkTone.inkSecondary.color)
            }
            Text("Add Cover")
                .font(.caption.weight(.semibold))
                .foregroundStyle(InkTone.accent.color)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(InkTone.paper.color, in: Capsule())
        }
        .padding(20)
    }
}
