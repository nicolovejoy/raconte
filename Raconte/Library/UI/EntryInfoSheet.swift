import SwiftUI

/// Task 5 (PR 2, ink & paper redesign, issue #55): one `⋯` sheet gathering everything
/// that used to be scattered across the entry detail body — journal, backdate, add
/// image, edit transcript, mark voices, revision history, trash. All seven actions are
/// closures; this view owns no state and makes no write of its own. `EntryDetailView`
/// still owns every destination (editor push, backdate sheet, image picker, trash
/// confirmation) — this sheet only dismisses itself and asks the detail screen to open
/// them, via the `pendingInfoAction` dance documented there.
///
/// Presented from the ScrollView level in `EntryDetailView` — never from inside a
/// `Form`/`List` `Section` (repo memory: a `.sheet` attached to a `Section` silently
/// never presents on iOS 26).
///
/// Task 6 removed the old in-body sections this duplicated (journal/backdate/trash rows,
/// the "Capture Image…"/"Edit transcript…"/"Mark voices…"/"Revision history…" buttons) —
/// this sheet is now their only home.
struct EntryInfoSheet: View {
    let item: EntryListItem
    let onJournal: () -> Void
    let onBackdate: () -> Void
    let onAddImage: () -> Void
    let onEditTranscript: () -> Void
    let onMarkVoices: () -> Void
    let onRevisionHistory: () -> Void
    let onTrash: () -> Void

    /// `"Recorded \(date) · \(duration)"` — pure, no `@State`/`Environment` reads, so a
    /// plain unit test pins the format without a view-inspection harness (same
    /// reasoning as `EntryDetailView.transcriptDisplay` and friends).
    static func headerSubtitle(capturedAt: Date, durationSeconds: Double) -> String {
        let dateText = capturedAt.formatted(date: .abbreviated, time: .shortened)
        let durationText = CaptureCoordinator.formatDuration(durationSeconds)
        return "Recorded \(dateText) · \(durationText)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(20)

            Divider().overlay(InkTone.hairline.color)

            VStack(alignment: .leading, spacing: 0) {
                row(systemImage: "book.closed", label: "Journal",
                    trailingValue: item.journal?.name ?? "Unfiled",
                    identifier: "detail.journalPicker", action: onJournal)
                hairline
                row(systemImage: "calendar", label: "Backdate",
                    trailingValue: backdateTrailingValue,
                    identifier: "detail.backdateButton", action: onBackdate)
                hairline
                row(systemImage: "photo.badge.plus", label: "Add Image…",
                    trailingValue: nil,
                    identifier: "entryDetail.images.captureButton", action: onAddImage)
                hairline
                row(systemImage: "pencil", label: "Edit transcript",
                    trailingValue: nil,
                    identifier: "detail.editButton", action: onEditTranscript)
                hairline
                row(systemImage: "person.wave.2", label: "Mark voices",
                    trailingValue: nil,
                    identifier: "detail.markVoicesButton", action: onMarkVoices)
                hairline
                row(systemImage: "clock.arrow.circlepath", label: "Revision history",
                    trailingValue: nil,
                    identifier: "detail.revisionHistoryButton", action: onRevisionHistory)
            }

            Spacer(minLength: 24)

            trashRow
                .padding(.bottom, 20)
        }
        .padding(.horizontal, 4)
        .background(InkTone.paperInset.color)
        // Repo memory (container-identifier trap): an `.accessibilityIdentifier` on a
        // plain container silently overwrites every descendant's own identifier with
        // this same string — every row button below read back as 'detail.infoSheet'
        // instead of its own id until `.accessibilityElement(children: .contain)` was
        // added here, which tells the system this view is a CONTAINER of its
        // children's own elements rather than a candidate to flatten into one.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail.infoSheet")
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }

    private var backdateTrailingValue: String {
        guard item.isBackdated else { return "Not backdated" }
        return item.formattedEffectiveDate()
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(EntryDetailView.navigationTitleText(for: item))
                .font(.headline)
                .foregroundStyle(InkTone.ink.color)

            Text(Self.headerSubtitle(capturedAt: item.capturedAt, durationSeconds: item.durationSeconds))
                .font(.subheadline)
                .foregroundStyle(InkTone.inkSecondary.color)

            if item.backdateWasDetected {
                Text("Detected from the recording")
                    .font(.caption)
                    .foregroundStyle(InkTone.inkSecondary.color)
                    .accessibilityIdentifier("detail.detectedDate")
            }
        }
    }

    private var hairline: some View {
        Divider().overlay(InkTone.hairline.color).padding(.leading, 20)
    }

    private func row(systemImage: String, label: String, trailingValue: String?,
                     identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .foregroundStyle(InkTone.accent.color)
                    .frame(width: 22)
                Text(label)
                    .foregroundStyle(InkTone.ink.color)
                Spacer()
                if let trailingValue {
                    Text(trailingValue)
                        .foregroundStyle(InkTone.inkSecondary.color)
                }
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(InkTone.inkSecondary.color)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    private var trashRow: some View {
        Button(action: onTrash) {
            HStack(spacing: 12) {
                Image(systemName: "trash")
                    .frame(width: 22)
                Text("Move to Trash")
                Spacer()
            }
            .foregroundStyle(InkTone.record.color)
            .padding(.vertical, 12)
            .padding(.horizontal, 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("detail.trashButton")
    }
}
