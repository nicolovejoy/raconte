import SwiftUI

/// The sidebar of places (nav T5): Capture, one row per journal, All Entries, Trash, and
/// Debug (DEBUG builds only). Replaces the capture screen's library door, the toolbar
/// library button and the Debug sheet — none of those routes depended on capture phase,
/// which is why the owner failed to find the library door twice (it only existed in the
/// idle branch of the setup band) and why the Debug modal trapped the app (a sheet has no
/// way out but its own Done). The sidebar is reachable from every phase and every screen.
struct SidebarView: View {
    let services: AppServices

    // DEVIATION FROM THE BRIEF'S STEP 4 SNIPPET, evidence-based (same shape as T4's
    // documented `NavigationStack(path:)` deviation) — SECOND round, superseding the
    // first fix.
    //
    // Round 1 made the binding's setter ignore `nil` (a no-op on deselection) instead of
    // coalescing it to `.capture`. That fixed the reveal bug but created a worse one,
    // caught by task review: the List's OWN internal selection is cleared to nil by the
    // system on collapse-back (to show the bare sidebar with nothing pre-picked), but a
    // `Binding(get: { router.place }, ...)` getter keeps reporting the OLD place — so
    // re-tapping the row you just left writes the SAME value the getter already claims
    // is selected. SwiftUI drops a same-value `List` selection write as a no-op: no
    // change fires, nothing navigates. Reproduced: back out to the bare sidebar, tap the
    // place you just came from — nothing happens. For Capture this strands the user
    // (no OTHER route back to it once you've left).
    //
    // Fix: track the List's own selection as real `@State`, separate from `router.place`.
    // The getter/setter pair now tells the truth about what the LIST believes is
    // selected (so nil-then-same-value writes are honoured as real transitions), while
    // `router.place` — which drives the detail column — is kept in sync in both
    // directions: tapping a row pushes `router.select(new)`; the router changing from
    // elsewhere (e.g. `PlaceRouting.resolve` retargeting a deleted journal) pulls
    // `selection` back into agreement via `.onChange(of: router.place)`.
    @State private var selection: Place? = PlaceRouting.launchPlace

    var body: some View {
        @Bindable var router = services.router
        List(selection: Binding(get: { selection },
                                set: { newPlace in
            selection = newPlace
            guard let newPlace else { return }
            router.select(newPlace)
        })) {
            ForEach(rows) { row in
                SidebarRowView(row: row,
                               cover: row.journalID.flatMap { services.library.journalCovers[$0] },
                               live: row.place == .capture ? captureLiveRow : nil)
                    .tag(row.place)
                    .accessibilityIdentifier(row.accessibilityIdentifier)
            }
        }
        .navigationTitle("Raconte")
        // NO accessibilityIdentifier on the List itself — by convention (design §8.4),
        // matching the flattening hazard already established for `Button`/`NavigationLink`
        // in this repo (Task-6 backdate row, the control bar, `NavigationLink` rows: an
        // identifier on the wrapping container merges its children into one accessibility
        // element). Measured, not assumed, for THIS container type specifically: Task 5's
        // mutation check 3 put `.accessibilityIdentifier("sidebar.list")` on this exact
        // `List` and re-ran the full `NavigationUITests` class plus two other
        // `openPlace`-driven tests — none broke. On this iOS 26 simulator, a `List`'s own
        // identifier does NOT flatten its rows the way `Button`/`NavigationLink` do; the
        // convention is kept anyway (no reason to add an identifier nothing here needs),
        // but the absence is a choice, not evidence of a hazard reproduced for `List`.
        .onChange(of: router.place) { _, place in
            selection = place
        }
    }

    /// Design §5's visibility guarantee: "the coordinator already lives in
    /// `CaptureScreenModel`, owned at the app root; unmounting the capture view must not
    /// touch it. The sidebar's live indicator is the visibility guarantee." Read fresh
    /// on every body evaluation, which — since `elapsed` is an `@Observable` published
    /// property read directly here — re-evaluates the sidebar once per timer tick while a
    /// capture is live. Accepted cost: the sidebar is a handful of rows, and the only
    /// alternative (a coarser "something is recording" flag with no running time) throws
    /// away the reason a live indicator exists in the first place.
    private var captureLiveRow: CaptureSidebarRow {
        CaptureSidebarRow.make(phase: services.capture.coordinator.phase,
                               elapsed: services.capture.coordinator.elapsed)
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
/// `live` is non-nil only for the Capture row (nav T6, design §5) — the sidebar's own
/// visibility guarantee for a recording that's running under a DIFFERENT place. Every
/// other row passes `nil`.
struct SidebarRowView: View {
    let row: PlaceRow
    let cover: Data?
    let live: CaptureSidebarRow?

    @ViewBuilder private var titleGroup: some View {
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
    }

    var body: some View {
        if let live, live.isLive, let elapsedText = live.elapsedText {
            // The live-Capture-row shape ONLY: two independently addressable accessibility
            // children (the title group, and the live badge), so `sidebar.capture.live`
            // has its own queryable identifier distinct from the row's own. `.combine` on
            // titleGroup + `.accessibilityElement(children: .contain)` on the outer HStack
            // is required for that split — found empirically (`app.debugDescription` dump
            // against a failing UI test): WITHOUT `.contain`, the ForEach's own
            // `.accessibilityIdentifier(row.accessibilityIdentifier)` (Task 5, applied one
            // level up) doesn't just merge children — it OVERWRITES every descendant
            // accessibility element's identifier with its own string, while leaving their
            // labels alone. Both `titleGroup` and the live badge reported identifier
            // "sidebar.capture" (only their labels — "Capture" vs "Recording, 0:04" —
            // stayed distinct) before `.contain` was added. A new variant of the
            // container-flattening trap already known for `Button`/`NavigationLink`
            // (`NavigationLinkIdentifierGoesOnTheLink` in memory): there it merges
            // children into one element; here it silently overwrote their identifiers
            // instead.
            //
            // Deliberately NOT the shape for any other row/state (see the `else` branch):
            // `.contain` also broke `openSidebarRow`'s compound `label BEGINSWITH … AND
            // identifier BEGINSWITH 'sidebar.journal.'` query (`NavigationUITests
            // .testSelectingAJournalPlaceScopesTheEntryList`, caught by the full-suite
            // run, reproduced solo too — a real regression, not a batch flake) — because
            // under `.contain` the row's own identifier and its label no longer land on
            // the SAME element. That query only exists for journal rows, which never
            // carry a live badge, so scoping this shape to "only while the badge renders"
            // fixes the regression while keeping the fix.
            HStack(spacing: 10) {
                titleGroup
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(row.subtitle.map { "\(row.title), \($0)" } ?? row.title)

                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                    Text(elapsedText)
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("sidebar.capture.live")
                .accessibilityLabel("Recording, \(elapsedText)")
            }
            .accessibilityElement(children: .contain)
            .padding(.vertical, 2)
        } else {
            // Every other row, and the Capture row whenever it isn't live: BYTE-IDENTICAL
            // to Task 5's original shape — one `.combine` element directly on the row,
            // carrying both the label and (via the ForEach one level up) the row's own
            // identifier together. This is what `openPlace`/`openSidebarRow` depend on.
            titleGroup
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(row.subtitle.map { "\(row.title), \($0)" } ?? row.title)
        }
    }
}
