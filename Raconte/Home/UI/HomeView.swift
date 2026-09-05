import SwiftUI

/// The launch landing (#108): journals as a bookshelf — face-out covers ranked by
/// capture activity, the rest as quiet serif spines — and one New entry action.
/// Design doc: docs/plans/2026-08-29-home-bookshelf-design.md.
struct HomeView: View {
    let library: LibraryScreenModel
    let capture: CaptureScreenModel
    let onOpenJournal: (String) -> Void
    let onNewEntry: () -> Void

    private var shelf: HomeShelf {
        HomeShelf.make(journals: library.journals,
                       entries: library.allEntries,
                       faceOutLimit: 3)
    }

    var body: some View {
        VStack(spacing: 0) {
            if library.journals.isEmpty {
                recoveryBanners
                emptyInvitation
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        recoveryBanners
                        faceOutRow
                        spineList
                    }
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                }
            }
            newEntryButton
        }
        .background(InkTone.paper.color)
        .navigationTitle("Raconte")
    }

    /// #108: crash-recovery banners, shown here since Home is now the launch root and
    /// recovery must not depend on ever visiting capture. Since #118 §3 this is the
    /// ONLY place they render — `CaptureView` no longer has a recovery-banner region at
    /// all. Reads `capture.visibleRecovered`/`capturesRoot`/`keep`/`delete` straight off
    /// the same `CaptureScreenModel` instance capture uses, so there is one recovery
    /// list, not two. `RecoveryBanner` is styled for the near-black studio (white text,
    /// `.orange` tint) — illegible on paper — so it is wrapped in a dark card here
    /// rather than restyled at the shared-view level (spec ruling). No auto-jump to
    /// capture: the banner is the whole treatment.
    @ViewBuilder
    private var recoveryBanners: some View {
        ForEach(capture.visibleRecovered) { rec in
            RecoveryBanner(recording: rec,
                           capturesRoot: capture.capturesRoot,
                           onKeep: { capture.keep(rec.captureID) },
                           onDelete: { capture.delete(rec.captureID) })
                .padding(12)
                .background(InkTone.studio.color,
                           in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .environment(\.colorScheme, .dark)
                .padding(.horizontal, 24)
        }
    }

    private var faceOutRow: some View {
        HStack(spacing: 14) {
            ForEach(shelf.faceOut) { journal in
                Button {
                    onOpenJournal(journal.id)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        faceOutCover(for: journal)
                        Text(journal.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(InkTone.ink.color)
                            .lineLimit(2)
                        if let last = shelf.lastActivity[journal.id] {
                            Text(last, format: .relative(presentation: .named))
                                .font(.system(size: 11))
                                .foregroundStyle(InkTone.inkSecondary.color)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home.cover.\(journal.id)")
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private func faceOutCover(for journal: Journal) -> some View {
        // Cover art or the placeholder treatment — lifted from `JournalCoverThumbnail`
        // (`Raconte/Library/UI/JournalCoverImage.swift`), which renders nothing when
        // there's no cover data or it fails to decode, rather than a broken silhouette.
        if let data = library.journalCovers[journal.id], let image = JournalCoverThumbnail.decode(data) {
            image
                .resizable()
                .scaledToFill()
                .frame(width: 104, height: 132)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(InkTone.paperInset.color)
                .frame(width: 104, height: 132)
        }
    }

    @ViewBuilder
    private var spineList: some View {
        if !shelf.spines.isEmpty {
            VStack(spacing: 0) {
                ForEach(shelf.spines) { journal in
                    Button {
                        onOpenJournal(journal.id)
                    } label: {
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(InkTone.accent.color.opacity(0.55))
                                .frame(width: 3, height: 20)
                            Text(journal.name)
                                .font(.system(size: 17, design: .serif))
                                .foregroundStyle(InkTone.ink.color)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13))
                                .foregroundStyle(InkTone.inkSecondary.color)
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 52)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home.spine.\(journal.id)")
                    .overlay(alignment: .bottom) {
                        Divider().overlay(InkTone.hairline.color)
                    }
                }
            }
        }
    }

    private var newEntryButton: some View {
        Button(action: onNewEntry) {
            HStack(spacing: 10) {
                Image(systemName: "mic.fill")
                Text("New entry")
                    .font(.system(size: 17, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(InkTone.accent.color, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        .accessibilityIdentifier("home.newEntry")
    }

    private var emptyInvitation: some View {
        VStack(spacing: 14) {
            Text("Speak your first entry.")
                .font(.system(size: 24, design: .serif))
                .foregroundStyle(InkTone.ink.color)
            Text("Your journals will appear here.")
                .font(.system(size: 15))
                .foregroundStyle(InkTone.inkSecondary.color)
        }
        .frame(maxHeight: .infinity)
    }
}
