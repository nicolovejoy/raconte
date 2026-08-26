import SwiftUI

/// The read-only sync status rows, shared verbatim between the Debug screen (where
/// they lived since M4 T12) and the About page (#89) — one rendering, no drift.
///
/// `idPrefix` keeps each host's accessibility namespace: "debug" preserves the
/// pre-existing `debug.sync.refresh`; "about" yields `about.sync.*`.
///
/// The initial fetch rides a `.task` on the Loading row, NOT on the `Section`: this
/// repo has already been bitten by a modifier on a `Form`/`List` `Section` silently
/// doing nothing (`.sheet`, 2026-08 — mechanism unconfirmed), so no Section-level
/// modifiers here on principle. The Loading row exists exactly until the first
/// status arrives, so its `.task` fires exactly once per appearance of this section.
struct SyncStatusSectionView: View {
    let sync: SyncCoordinator?
    let idPrefix: String

    /// M4 T12 semantics unchanged: fetched on appear and on demand (Refresh) —
    /// this can genuinely change while the screen is open.
    @State private var syncStatus: SyncStatus?

    var body: some View {
        Section("Sync") {
            if let sync {
                if let syncStatus {
                    LabeledContent("Account", value: syncStatus.accountState)
                    LabeledContent("Last push",
                                  value: syncStatus.lastPushAt.map(Self.timestamp(_:)) ?? "never")
                    LabeledContent("Last fetch",
                                  value: syncStatus.lastFetchAt.map(Self.timestamp(_:)) ?? "never")
                    LabeledContent("Pending saves", value: "\(syncStatus.pendingSaveCount)")
                    LabeledContent("Pending deletes", value: "\(syncStatus.pendingDeleteCount)")
                    LabeledContent("Last error", value: syncStatus.lastError ?? "none")
                } else {
                    Text("Loading…")
                        .task { syncStatus = await sync.status() }
                }
                Button("Refresh") { Task { syncStatus = await sync.status() } }
                    .accessibilityIdentifier("\(idPrefix).sync.refresh")
            } else {
                Text("Sync unavailable in this build")
                    .accessibilityIdentifier("\(idPrefix).sync.unavailable")
            }
        }
    }

    /// Device-local time, deliberately NOT the Pacific-display convention: "when did
    /// THIS device last push/fetch" is a device-local question (design doc records
    /// the deviation). Same formatter the Debug screen has used since M4 T12.
    private static func timestamp(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }
}
