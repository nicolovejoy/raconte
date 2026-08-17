import SwiftUI

/// The sidebar of places (nav T5): Capture, one row per journal, All Entries, Trash, and
/// Debug (DEBUG builds only). Replaces the capture screen's library door, the toolbar
/// library button and the Debug sheet — none of those routes depended on capture phase,
/// which is why the owner failed to find the library door twice (it only existed in the
/// idle branch of the setup band) and why the Debug modal trapped the app (a sheet has no
/// way out but its own Done). The sidebar is reachable from every phase and every screen.
struct SidebarView: View {
    let services: AppServices

    var body: some View {
        @Bindable var router = services.router
        List(selection: Binding(get: { router.place },
                                set: { newPlace in
            // DEVIATION FROM THE BRIEF'S STEP 4 SNIPPET, evidence-based (same shape as
            // T4's documented `NavigationStack(path:)` deviation): the brief's literal
            // `set: { router.select($0 ?? .capture) }` forces a nil selection back to
            // `.capture` unconditionally. On iPhone, tapping the collapsed split view's
            // system Back button CLEARS the List's selection to nil to reveal the bare
            // sidebar (so nothing reads as pre-picked while browsing it) — that is the
            // moment this fires. Coalescing nil to `.capture` fights that: it
            // immediately re-selects `.capture`, and since `.capture` is a real place
            // change whenever the prior place was anything else, the split view
            // re-collapses straight past the sidebar into the capture detail — the
            // sidebar is never actually shown. Reproduced directly:
            // `testTheDebugPlaceIsAScreenNotAModal` (Debug → Back → straight to Capture,
            // never landing on the bare sidebar) and `testDeleteNowPermanentlyRemovesEntry`
            // (Trash → Back after a second reveal, same failure) both failed against the
            // literal snippet, both pass with this fix — confirmed by the accessibility
            // hierarchy captured at the moment of failure, which showed `capture.record`
            // on screen where `sidebar.capture` was expected. A `nil` selection is now a
            // no-op: `router.place` — and the detail column behind the momentarily-bare
            // sidebar — stays exactly where it was until a row is actually tapped.
            guard let newPlace else { return }
            router.select(newPlace)
        })) {
            ForEach(rows) { row in
                SidebarRowView(row: row, cover: row.journalID.flatMap { services.library.journalCovers[$0] })
                    .tag(row.place)
                    .accessibilityIdentifier(row.accessibilityIdentifier)
            }
        }
        .navigationTitle("Raconte")
        // NO accessibilityIdentifier on the List itself — the container-flattening trap
        // this repo has hit three times (design §8.4). Putting one here would merge every
        // row into one accessibility element and make none of the `sidebar.*` identifiers
        // above independently queryable.
    }

    private var rows: [PlaceRow] {
        var ranges: [String: String] = [:]
        for journal in services.library.journals {
            if let range = services.library.dateRange(forJournal: journal.id) {
                ranges[journal.id] = range.formatted()
            }
        }
        #if DEBUG
        let includesDebug = true
        #else
        let includesDebug = false
        #endif
        return SidebarModel.rows(journals: services.library.journals,
                                 dateRanges: ranges,
                                 includesDebug: includesDebug)
    }
}

/// One sidebar row: a system icon (Capture, All Entries, Trash, Debug) or a journal cover
/// thumbnail, the title, and an optional subtitle (a journal's derived date range).
///
/// No `live` indicator yet — that is Task 6's `CaptureSidebarRow`, which shows whether a
/// capture is in progress under a different place. This task only routes.
struct SidebarRowView: View {
    let row: PlaceRow
    let cover: Data?

    var body: some View {
        HStack(spacing: 10) {
            if row.journalID != nil {
                JournalCoverThumbnail(data: cover, size: 30)
            } else if let systemImage = row.systemImage {
                Image(systemName: systemImage)
                    .frame(width: 30, height: 30)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                if let subtitle = row.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        // Combined with an explicit label, same reasoning as `capture.libraryDoor`'s old
        // combine (a two-`Text` VStack otherwise reads as two elements): the row's title
        // plus its date range, or just the title when there is none.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.subtitle.map { "\(row.title), \($0)" } ?? row.title)
    }
}
