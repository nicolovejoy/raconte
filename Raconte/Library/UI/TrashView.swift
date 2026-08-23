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

    var body: some View {
        Group {
            if model.trashed.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(model.trashed) { item in
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
                .listStyle(.plain)
                .accessibilityIdentifier("trash.list")
            }
        }
        .navigationTitle("Trash")
        .task { await model.rescan() }
        // Visible-but-disabled when there is nothing to empty — the journal-editor
        // disabled-delete idiom (#80 ruling 2): an absent control cannot be discovered,
        // let alone understood, so the button always exists and only `.disabled` moves.
        .toolbar {
            ToolbarItem {
                Button("Empty Trash", role: .destructive) {
                    showingEmptyTrashConfirmation = true
                }
                .disabled(model.trashed.isEmpty)
                .accessibilityIdentifier("trash.emptyAll")
            }
        }
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

            HStack(spacing: 16) {
                Button("Restore", action: onRestore)
                    .accessibilityIdentifier("trash.row.restore")
                Button("Delete Now", role: .destructive, action: onDeleteNow)
                    .accessibilityIdentifier("trash.row.deleteNow")
            }
            .font(.caption)
            .buttonStyle(.borderless)
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
