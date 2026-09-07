import SwiftUI

/// The Trash screen (M3 T5): everything soft-deleted, with the time it has left, Restore,
/// and a per-entry Delete Now.
///
/// Nothing here is alarming and nothing is hidden. The countdown is the whole contract —
/// "recoverable 30 days, then truly gone" is only true if the owner can see how many of
/// the thirty are left — and Restore is the primary action, sitting left of the
/// destructive one.
struct TrashView: View {
    let model: LibraryScreenModel

    /// The capture awaiting "Delete Now" confirmation. An item rather than a flag, so the
    /// dialog can name what it is about to destroy permanently.
    @State private var pendingPermanentDelete: EntryListItem?

    /// A permanent delete that reported failure. Surfaced, never swallowed — the owner
    /// hit exactly this on device with no feedback (the entry quietly stayed).
    @State private var permanentDeleteFailed = false

    /// A restore that reported failure — same swallowed-`try?` family.
    @State private var restoreFailed = false

    /// Boolean-flag confirmation idiom (`JournalEditorView`'s delete-journal dialog):
    /// there is nothing per-item to name here, so a flag is enough — the count comes
    /// straight from `model.trashed` at presentation time.
    @State private var showingEmptyTrashConfirmation = false

    /// A completed Empty Trash whose `failed` count is nonzero. Holds the count so the
    /// alert can say how many, not just that something went wrong — the same
    /// never-read-as-total-success discipline as `permanentDeleteFailed` above, applied
    /// to a batch instead of one entry.
    @State private var emptyTrashFailedCount: Int?

    /// Select mode (#128 Task 4) — its own selection, deliberately separate from the
    /// entry lists' (out of scope to select across the two screens at once). View-held,
    /// same reasoning as `LibraryView.selection`: nothing about it survives the view.
    @State private var selection = BulkSelection()
    /// Bulk Delete Now confirms — that one is not recoverable. Bulk Restore does not:
    /// it only ever puts entries back.
    @State private var confirmingBulkDeleteNow = false
    /// A completed bulk operation with a nonzero `failed` — both counts reported, the
    /// failed ids re-selected (see `finishBulkAction`).
    @State private var bulkFailure: BulkFailureReport?

    /// The unreadable-sidecar entry (#81) awaiting quarantine confirmation. An item
    /// rather than a flag, same reasoning as `pendingPermanentDelete`: the dialog names
    /// what it is about to move.
    @State private var pendingQuarantine: EntryListItem?
    /// A `quarantineUnreadable` call that threw — surfaced, never swallowed, same
    /// `try?`-with-a-flag family as `restoreFailed`/`permanentDeleteFailed` above.
    @State private var quarantineFailed = false

    private struct BulkFailureReport {
        var title: String
        var succeeded: Int
        var failed: Int
    }

    var body: some View {
        // Dialog groups live in helper functions, matching `LibraryView`'s split (one
        // monolithic modifier chain stops type-checking once a second mode joins it).
        withUnreadableDialogs(withBulkDialogs(withSingleEntryDialogs(screenBody)))
            .navigationTitle("Trash")
            .task { await model.rescan() }
            .toolbar { toolbarContent }
    }

    private var screenBody: some View {
        Group {
            // The unreadable-entries section (#81) must render whenever there is
            // something in it, whether or not `trashed` is — an archive can have a
            // corrupt sidecar and an otherwise-empty trash at the same time, and the
            // owner needs a way out of that state without a developer. So the plain
            // centered `trash.empty` placeholder only wins when BOTH are empty; any
            // other combination goes through the `List` below.
            if model.trashed.isEmpty && model.unreadableEntries.isEmpty {
                emptyState
            } else {
                List {
                    unreadableSection
                    if model.trashed.isEmpty {
                        Section {
                            Text("Trash is empty")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(model.trashed) { item in
                            if selection.isActive {
                                selectableRow(item)
                            } else {
                                TrashEntryRow(item: item,
                                              onRestore: {
                                                  Task {
                                                      if !(await model.restoreEntry(item.captureID)) {
                                                          restoreFailed = true
                                                      }
                                                  }
                                              },
                                              onDeleteNow: { pendingPermanentDelete = item })
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .accessibilityIdentifier("trash.list")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if selection.isActive { selectionBar }
        }
    }

    // MARK: - Unreadable entries (#81 Task 6)

    @ViewBuilder
    private var unreadableSection: some View {
        if !model.unreadableEntries.isEmpty {
            // The identifier goes on the HEADER text alone, never on the `Section`
            // itself: a `Section`-level `.accessibilityIdentifier` cascades to every
            // descendant (header, each row, footer) and silently overwrites their own
            // — measured, not assumed, the same container-identifier trap
            // `TrashEntryRow`'s comment and `unreadableRow` below both call out. The
            // section's presence is what `trash.unreadable.section` names, so the
            // header carrying it is enough.
            Section {
                ForEach(model.unreadableEntries) { item in
                    unreadableRow(item)
                }
            } header: {
                Text("Unreadable entries")
                    .accessibilityIdentifier("trash.unreadable.section")
            } footer: {
                Text("These entries’ settings files could not be read. Quarantine moves "
                     + "the whole entry, audio included, out of the library into the "
                     + "app’s quarantine folder. Nothing is deleted.")
            }
        }
    }

    /// One row's own identifier goes on the row's CONTAINER with
    /// `.accessibilityElement(children: .contain)` — an identifier there otherwise
    /// overwrites its children's (repo memory: `TrashEntryRow`'s own comment above,
    /// and the container-identifier trap generally), which would make the
    /// `trash.unreadable.quarantine` button inside unreachable. `.contain` restores
    /// the children but empties the container's own accessibility label, so the label
    /// is set explicitly rather than left to auto-compute from the children's text.
    private func unreadableRow(_ item: EntryListItem) -> some View {
        let dateText = item.capturedAt.formatted(date: .abbreviated, time: .omitted)
        return HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(dateText)
                    .font(.system(size: 16, weight: .semibold))
                Text("Entry settings unreadable")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Quarantine") {
                pendingQuarantine = item
            }
            .font(.system(size: 16))
            .buttonStyle(.borderless)
            .accessibilityIdentifier("trash.unreadable.quarantine")
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("trash.unreadable.row")
        .accessibilityLabel("\(dateText) — entry settings unreadable")
    }

    /// Attached to the screen's outer view (matching `withSingleEntryDialogs`'/
    /// `withBulkDialogs`' own note): a `.confirmationDialog` on a `Section` silently
    /// never presents on iOS 26.
    private func withUnreadableDialogs(_ base: some View) -> some View {
        base
        .confirmationDialog(
            "Quarantine this entry?",
            isPresented: Binding(get: { pendingQuarantine != nil },
                                 set: { if !$0 { pendingQuarantine = nil } }),
            presenting: pendingQuarantine
        ) { item in
            Button("Quarantine") {
                let captureID = item.captureID
                pendingQuarantine = nil
                Task {
                    do {
                        try await model.quarantineUnreadable(captureID: captureID)
                    } catch {
                        quarantineFailed = true
                    }
                }
            }
            .accessibilityIdentifier("trash.unreadable.confirm")
            Button("Cancel", role: .cancel) { pendingQuarantine = nil }
        } message: { _ in
            Text("The whole entry, audio included, moves out of the library into the "
                 + "app’s quarantine folder. Nothing is deleted.")
        }
        .alert("Couldn’t quarantine this entry", isPresented: $quarantineFailed) {
            Button("OK") { quarantineFailed = false }
        } message: {
            Text("Try again, or restart the app.")
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if selection.isActive {
            ToolbarItem {
                Button("Done") { selection = BulkSelection() }
                    .accessibilityIdentifier("trash.selectDone")
            }
        } else {
            ToolbarItem {
                Button("Select") { selection.isActive = true }
                    .disabled(model.trashed.isEmpty)
                    .accessibilityIdentifier("trash.select")
            }
        }
        // Visible-but-disabled when there is nothing to empty — the journal-editor
        // disabled-delete idiom (#80 ruling 2): an absent control cannot be discovered,
        // let alone understood, so the button always exists and only `.disabled` moves.
        // Untouched by select mode (#128: "leave the whole-trash Empty Trash alone").
        ToolbarItem {
            Button("Empty Trash", role: .destructive) {
                showingEmptyTrashConfirmation = true
            }
            .disabled(model.trashed.isEmpty)
            .accessibilityIdentifier("trash.emptyAll")
        }
    }

    // MARK: - Select mode (#128 Task 4)

    private func selectableRow(_ item: EntryListItem) -> some View {
        Button {
            selection.toggle(item.captureID)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selection.isSelected(item.captureID)
                        ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selection.isSelected(item.captureID)
                        ? InkTone.accent.color : InkTone.inkSecondary.color)
                // Per-row Restore/Delete Now are hidden in this mode — the bottom bar
                // owns both actions, and a live button inside the toggle target would
                // fire alongside the toggle.
                TrashEntryRow(item: item, showsActions: false,
                              onRestore: {}, onDeleteNow: {})
            }
        }
        .buttonStyle(.plain)
        // On the Button, the row's leaf control in this mode (`LibraryView
        // .selectableRow`'s flattening reasoning); the merged element's VALUE carries
        // the selection state for UI tests.
        .accessibilityIdentifier("trash.selectRow")
        .accessibilityValue(selection.isSelected(item.captureID) ? "selected" : "not selected")
    }

    private func entryCountText(_ count: Int) -> String {
        count == 1 ? "1 entry" : "\(count) entries"
    }

    /// Same epilogue as `LibraryView.finishBulkAction`: full success leaves select
    /// mode; partial failure stays in it with exactly the failed ids re-selected and
    /// both counts reported. Never plain success while something did not move.
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

    /// Explicit point sizes, not text-style names — this bar renders on macOS too,
    /// where `.callout` drops to 12 pt (`LibraryView.selectionBar`'s rule).
    private var selectionBar: some View {
        HStack(spacing: 16) {
            Text("\(selection.count) selected")
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("trash.selectionCount")
            Spacer()
            Button("Restore") {
                let ids = selection.sortedIDs
                Task {
                    finishBulkAction(await model.bulkRestore(ids),
                                     failureTitle: "Some entries couldn’t be restored")
                }
            }
            .disabled(selection.isEmpty)
            .accessibilityIdentifier("trash.bulkRestore")
            Button("Delete Now", role: .destructive) { confirmingBulkDeleteNow = true }
                .disabled(selection.isEmpty)
                .accessibilityIdentifier("trash.bulkDeleteNow")
        }
        .font(.system(size: 15))
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(InkTone.paperInset.color)
    }

    /// #128's bulk Delete Now confirmation (naming the count — not recoverable) and
    /// the partial-failure alert.
    private func withBulkDialogs(_ base: some View) -> some View {
        base
        .confirmationDialog("Permanently delete \(entryCountText(selection.count))?",
                            isPresented: $confirmingBulkDeleteNow,
                            titleVisibility: .visible) {
            Button("Delete Permanently", role: .destructive) {
                confirmingBulkDeleteNow = false
                let ids = selection.sortedIDs
                Task {
                    finishBulkAction(await model.bulkDeletePermanently(ids),
                                     failureTitle: "Some entries couldn’t be deleted")
                }
            }
            .accessibilityIdentifier("trash.confirmBulkDeleteNow")
            Button("Cancel", role: .cancel) { confirmingBulkDeleteNow = false }
        } message: {
            Text("The audio and its transcript are erased. This can’t be undone.")
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

    /// The pre-#128 dialogs and alerts, moved out of `body` verbatim.
    private func withSingleEntryDialogs(_ base: some View) -> some View {
        base
        // Attached to the screen's outer view, never a `Section` or other child — a
        // `.confirmationDialog` on a `Section` silently never presents on iOS 26
        // (`JournalEditorView`'s delete-journal dialog carries the same note; #68's
        // class of bug).
        .confirmationDialog(
            model.trashed.count == 1
                ? "Permanently delete 1 entry?"
                : "Permanently delete \(model.trashed.count) entries?",
            isPresented: $showingEmptyTrashConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) {
                showingEmptyTrashConfirmation = false
                Task {
                    let result = await model.emptyTrash()
                    if result.failed > 0 { emptyTrashFailedCount = result.failed }
                }
            }
            .accessibilityIdentifier("trash.confirmEmptyAll")
            Button("Cancel", role: .cancel) { showingEmptyTrashConfirmation = false }
        } message: {
            Text("The audio and its transcript are erased. This can’t be undone.")
        }
        // A partial failure must never read as total success (owner's own hit on the
        // single-entry path — see `permanentDeleteFailed` above). Bound to a count, not
        // a bare flag, so the alert can say how many rather than just that something
        // went wrong.
        .alert(
            emptyTrashFailedCount == 1
                ? "1 entry couldn’t be deleted"
                : "\(emptyTrashFailedCount ?? 0) entries couldn’t be deleted",
            isPresented: Binding(get: { emptyTrashFailedCount != nil },
                                 set: { if !$0 { emptyTrashFailedCount = nil } })
        ) {
            Button("OK") { emptyTrashFailedCount = nil }
        } message: {
            Text("Try again, or restart the app.")
        }
        .confirmationDialog(
            "Delete this recording permanently?",
            isPresented: Binding(get: { pendingPermanentDelete != nil },
                                 set: { if !$0 { pendingPermanentDelete = nil } }),
            presenting: pendingPermanentDelete
        ) { item in
            Button("Delete Permanently", role: .destructive) {
                pendingPermanentDelete = nil
                Task {
                    if !(await model.deleteEntryPermanently(item.captureID)) {
                        permanentDeleteFailed = true
                    }
                }
            }
            .accessibilityIdentifier("trash.confirmDeleteNow")
            Button("Cancel", role: .cancel) { pendingPermanentDelete = nil }
        } message: { _ in
            Text("The audio and its transcript are erased. This can’t be undone.")
        }
        .alert("Couldn’t delete this recording", isPresented: $permanentDeleteFailed) {
            Button("OK") { permanentDeleteFailed = false }
        } message: {
            Text("The files couldn’t be removed. Try again, or restart the app.")
        }
        .alert("Couldn’t restore this entry", isPresented: $restoreFailed) {
            Button("OK") { restoreFailed = false }
        } message: {
            Text("The change didn’t save. Try again.")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("Trash is empty")
                .font(.headline)
            Text("Deleted entries stay here for \(TrashPolicy.retentionDays) days "
                 + "before they’re erased.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("trash.empty")
    }
}

/// One trashed entry: what it was, when it was deleted, how long it has left, and the
/// two ways out.
struct TrashEntryRow: View {
    let item: EntryListItem
    /// `false` in select mode (#128): the bottom bar owns Restore/Delete Now there,
    /// and a live button inside the row-as-toggle-target would fire alongside the
    /// toggle. Default `true` keeps every pre-#128 call site unchanged.
    var showsActions: Bool = true
    let onRestore: () -> Void
    let onDeleteNow: () -> Void

    /// Read once per render rather than per label, so the two lines can never disagree
    /// about which day it is.
    private let now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(item.effectiveDate.formatted(date: .abbreviated, time: .omitted))
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("trash.row.date")
                Spacer()
                Text(CaptureCoordinator.formatDuration(item.durationSeconds))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if let snippet = item.snippet, !snippet.isEmpty {
                Text(snippet)
                    .font(.system(.body, design: .serif))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Text(remainingText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("trash.row.remaining")

            if showsActions {
                HStack(spacing: 16) {
                    Button("Restore", action: onRestore)
                        .accessibilityIdentifier("trash.row.restore")
                    Button("Delete Now", role: .destructive, action: onDeleteNow)
                        .accessibilityIdentifier("trash.row.deleteNow")
                }
                .font(.caption)
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 6)
        // No row-level identifier, deliberately: SwiftUI propagates a container's
        // `accessibilityIdentifier` down to every descendant, which overwrites the
        // children's own — measured, not assumed (the first cut of the UI test found
        // five elements all called `trash.row`). Rows are counted by
        // `trash.row.remaining` instead, which every row has exactly one of.
    }

    /// `trashedAt` is nil only for an item that left the trash between the scan and this
    /// render — a restore landing mid-frame. The row says the honest thing rather than
    /// inventing a countdown.
    private var remainingText: String {
        guard let trashedAt = item.trashedAt else { return "No longer in the trash." }
        let days = TrashPolicy.daysRemaining(trashedAt: trashedAt, now: now)
        let deleted = trashedAt.formatted(date: .abbreviated, time: .omitted)
        switch days {
        case 0: return "Deleted \(deleted) · erased today"
        case 1: return "Deleted \(deleted) · 1 day left"
        default: return "Deleted \(deleted) · \(days) days left"
        }
    }
}
