import SwiftUI

/// The whole undo story (T7 Task 8, ruling Q1) — reached from the detail screen. Thin
/// binding over `RevisionHistoryModel`, per the editor's and marker-correction screen's
/// own precedent: no logic here, only layout.
struct RevisionHistoryView: View {
    @Bindable var model: RevisionHistoryModel

    var body: some View {
        Group {
            switch model.state {
            case .loading:
                ProgressView()
            case .ready:
                List {
                    // Review Important 2: rendered ABOVE whatever content is honestly
                    // renderable — a trashed or degraded entry can still show its
                    // rows (or an honestly empty list), but the reason revert isn't
                    // offered must never be discoverable only via a failed-revert
                    // alert.
                    if let readOnlyMessage = model.readOnlyMessage {
                        Section {
                            Label(readOnlyMessage, systemImage: "lock.fill")
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityIdentifier("revisionHistory.readOnlyMessage")
                    }
                    if model.isForked {
                        Section {
                            Label("This entry has edits that never converged.", systemImage: "arrow.triangle.branch")
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityIdentifier("revisionHistory.forkIndicator")
                    }
                    Section {
                        ForEach(model.rows) { row in
                            rowView(row)
                        }
                    } header: {
                        Text("Revisions")
                    } footer: {
                        Text(footerText)
                    }
                }
            }
        }
        .navigationTitle("Revision history")
        .task { await model.open() }
        .alert("Couldn’t revert", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { shown in if !shown { model.acknowledgeError() } }
        )) {
            Button("OK") { model.acknowledgeError() }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var footerText: String {
        let size = ByteCountFormatter.string(fromByteCount: model.chainByteSize, countStyle: .file)
        let base = "\(model.revisionCount) revision\(model.revisionCount == 1 ? "" : "s"), \(size)."
        guard model.isGrowthElevated else { return base }
        return base + " This entry has been edited a lot — consider whether older revisions are still worth keeping."
    }

    @ViewBuilder
    private func rowView(_ row: RevisionHistoryModel.Row) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(row.source.isHumanLineage ? "Human" : "Machine")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                    if row.isCurrent {
                        Text("Current")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.tint)
                    }
                    if row.isDetached {
                        // §12.8: "machine transcript, not applied" — never suggest this
                        // is what the entry currently shows.
                        Text("Machine transcript, not applied")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(row.firstLine)
                    .lineLimit(2)
                Text(row.createdAt, format: .dateTime)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if row.canRevert {
                Button("Revert") {
                    Task { await model.revert(row) }
                }
                .accessibilityIdentifier("revisionHistory.revert.\(row.id)")
            }
        }
        .accessibilityIdentifier("revisionHistory.row.\(row.id)")
    }
}
