import SwiftUI

/// Top-level navigation (nav T4/T5): a `NavigationSplitView` with the sidebar selection
/// bound to `AppRouter`, capture pre-selected. On iPhone the collapsed split view lands
/// directly on the detail column (capture) at launch — verified by
/// `NavigationUITests.testLaunchLandsDirectlyOnCaptureWithNoTaps`, the load-bearing platform
/// claim the whole redesign rests on.
///
/// The detail `NavigationStack` is bound to `router.detailPath: [LibraryDestination]`
/// (T4 shipped it unbound — see the T4 review comment this replaced — because a typed
/// path has no slot for the now-deleted `RootDestination`; with that type gone the stack
/// is homogeneous and the bind is safe). Binding is what lets `AppRouter.select`'s
/// clear/keep rule drive real pops when the sidebar switches places.
struct ContentView: View {
    let services: AppServices
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    /// Draft text for the root-level New Journal alert below (nav T8, ⌘N) — separate
    /// from `JournalHeaderView`'s own `draftName`, which is that view's private `@State`
    /// and unreachable from a Mac menu command.
    @State private var newJournalName = ""

    var body: some View {
        @Bindable var router = services.router
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(services: services)
        } detail: {
            NavigationStack(path: $router.detailPath) {
                detailRoot
                    .navigationDestination(for: LibraryDestination.self) { destination in
                        switch destination {
                        case .entry(let captureID):
                            // The `else` is not decoration (issue #32): a destination
                            // builder that returns nothing still pushes, so an unresolvable
                            // id used to land the owner on a blank page with no way to tell
                            // what went wrong. `item` is scope-independent now, which leaves
                            // only the honest cases — a capture that is genuinely gone.
                            if let item = services.library.item(captureID) {
                                EntryDetailView(model: services.library, item: item)
                            } else {
                                ContentUnavailableView(
                                    "Entry Unavailable",
                                    systemImage: "questionmark.folder",
                                    description: Text("This entry is no longer in the library. "
                                                      + "It may have been permanently deleted."))
                                .accessibilityIdentifier("entry.unavailable")
                            }
                        }
                    }
            }
        }
        #if os(macOS)
        .frame(minWidth: 720, minHeight: 560)
        #endif
        .onChange(of: services.router.place) { _, place in
            if let scope = PlaceRouting.journalScope(for: place) {
                Task { await services.library.selectJournalScope(scope) }
            }
        }
        // A deleted journal's place must not keep pointing at nothing forever — falls
        // back to `.capture` rather than showing an empty list with no way out. Routed
        // through `router.select`, not a direct `router.place =` assignment (task review,
        // minor 3): a direct assignment bypasses `AppRouter.select`'s clear-the-path
        // contract, so a stale `detailPath` from the deleted journal's place could survive
        // the fallback and push against a place it no longer belongs to.
        .onChange(of: services.library.journals) { _, journals in
            router.select(PlaceRouting.resolve(router.place, journals: journals))
        }
        // ⌘N (nav T8, `RaconteCommands`) must work from any place — All Entries, Trash,
        // a journal, not just Capture — so this alert lives on the outermost view rather
        // than inside `JournalHeaderView`, which only mounts on the capture screen.
        // `JournalHeaderView`'s own New Journal menu item and alert stay: the capture
        // screen's journal picker is capture configuration, not navigation (design §3),
        // and removing it would take the affordance away on iPhone, where there is no
        // menu bar to reach this one.
        .alert("New Journal", isPresented: $router.showingNewJournalPrompt) {
            // `.foregroundStyle(Color.primary)` for the same reason JournalHeaderView's
            // copy has it: an alert draws on the system's own light material, but its
            // content is a builder nested inside a view tree that may set
            // `.foregroundStyle(.white)` — owner smoke 2026-08-15, "white on white,
            // can't read what I type".
            TextField("Journal name", text: $newJournalName)
                .foregroundStyle(Color.primary)
                .accessibilityIdentifier("root.newJournalNameField")
            Button("Create") {
                let name = newJournalName
                newJournalName = ""
                Task { await services.capture.createJournal(name: name) }
            }
            Button("Cancel", role: .cancel) { newJournalName = "" }
        }
    }

    @ViewBuilder private var detailRoot: some View {
        switch services.router.place {
        case .capture:
            CaptureView(model: services.capture)
        case .allEntries, .journal:
            LibraryView(model: services.library, title: libraryTitle)
        case .trash:
            TrashView(model: services.library)
        case .debug:
            #if DEBUG
            DebugMenuView()
            #else
            CaptureView(model: services.capture)
            #endif
        }
    }

    /// The library screen's title comes from the PLACE, not a fixed "Library" string —
    /// "All Entries" for the cross-journal scope, the journal's own name for a scoped one.
    /// No `default:`, same convention as `PlaceRouting`'s own switches: a place this
    /// property doesn't know how to title should fail to build, not silently say "Library".
    private var libraryTitle: String {
        switch services.router.place {
        case .allEntries:
            return "All Entries"
        case .journal(let id):
            return services.library.journals.first(where: { $0.id == id })?.name ?? "Library"
        case .capture, .trash, .debug:
            return "Library"
        }
    }
}

#Preview {
    ContentView(services: AppServices())
}
