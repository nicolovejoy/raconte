import SwiftUI

/// Top-level navigation (nav T4): a `NavigationSplitView` with the sidebar selection bound
/// to `AppRouter`, capture pre-selected. On iPhone the collapsed split view lands directly
/// on the detail column (capture) at launch — verified by
/// `NavigationUITests.testLaunchLandsDirectlyOnCaptureWithNoTaps`, the load-bearing platform
/// claim the whole redesign rests on.
///
/// Old routes (`capture.libraryButton`, `capture.libraryDoor`, `RootDestination.library`,
/// `library.trashLink`) are deliberately kept working through this task so every
/// pre-existing UI test passes unmodified. `RootDestination` retires in Task 5.
struct ContentView: View {
    let services: AppServices
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    var body: some View {
        @Bindable var router = services.router
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // Task 4 stub: one row. Task 5 replaces this with SidebarView.
            List(selection: Binding(get: { router.place },
                                    set: { router.select($0 ?? .capture) })) {
                Text("Capture").tag(Place.capture)
                    .accessibilityIdentifier("sidebar.capture")
            }
            .navigationTitle("Raconte")
        } detail: {
            // DEVIATION FROM THE BRIEF'S STEP 3 SNIPPET, evidence-based (Step 5 spirit —
            // a second load-bearing platform claim, found while satisfying the first):
            // `NavigationStack(path: $router.detailPath)` — the brief's literal code, where
            // `detailPath: [LibraryDestination]` — silently breaks EVERY
            // `NavigationLink(value: RootDestination.library)` push (both
            // `capture.libraryButton` and `capture.libraryDoor`), even the very first one,
            // on a freshly launched app.
            //
            // This is a deterministic contract, not an SDK flake: a typed `path:` binding
            // has storage only for the type it was declared with, so a push of a DIFFERENT
            // type (`RootDestination`, which is not `LibraryDestination`) has no slot to
            // land in and is inert. `LibraryDestination`-typed pushes through that same
            // binding are fully verified working — confirmed both in this task's own A/B
            // (with the binding, `library.trashLink` never appears after a
            // `RootDestination.library` push, 2/2 cold-simulator runs, reliable identifier
            // — not the flaky `app.staticTexts["Library"]` locator, which gave a false pass
            // by matching `capture.libraryDoor`'s own on-screen "Library" label; removing
            // only the `path:` binding fixes the RootDestination push, 1/1) and
            // independently by the task review, which found `TranscriptEditorUITests`
            // passing 2/2 through a bound `[LibraryDestination]` path in the very same run
            // where the `RootDestination` push failed. So: bound path + same-typed pushes
            // = verified working; only the heterogeneous `RootDestination` push is
            // impossible, by design of typed paths, not by platform unreliability.
            //
            // Nothing in Task 4 depends on `router.detailPath` driving the real stack —
            // `goBack()`/`canGoBack`/`detailPath` are not called from any view yet (the
            // sidebar stub has one row, so `select()` is never exercised against a second
            // place). Implicit (unbound) `NavigationStack` is exactly what the pre-T4
            // `ContentView` used, so this preserves proven-working behaviour rather than
            // introducing new risk. Task 5 should be able to bind `path: $router.detailPath`
            // with full confidence the moment `detailPath` needs to drive real pops
            // (SidebarView's place-switching): once `RootDestination` retires that task,
            // only `LibraryDestination` remains on the stack, and that combination is
            // already proven to work above.
            NavigationStack {
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
                        case .trash:
                            TrashView(model: services.library)
                        }
                    }
                    // Retired in Task 5; kept here so every existing UI test stays green.
                    .navigationDestination(for: RootDestination.self) { _ in
                        LibraryView(model: services.library)
                    }
            }
        }
        #if os(macOS)
        .frame(minWidth: 720, minHeight: 560)
        #endif
    }

    @ViewBuilder private var detailRoot: some View {
        switch services.router.place {
        case .capture:            captureDetail
        case .allEntries, .journal, .trash, .debug:  captureDetail // Task 5
        }
    }

    /// `CaptureView` plus its toolbar — kept exactly as `ContentView.swift` had it before
    /// the split-view swap (R4 ruling): `capture.libraryButton` must keep pushing
    /// `RootDestination.library` inside the detail `NavigationStack`, or every UI test
    /// that opens the library through the toolbar breaks.
    private var captureDetail: some View {
        CaptureView(model: services.capture)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink(value: RootDestination.library) {
                        Image(systemName: "books.vertical")
                    }
                    .accessibilityIdentifier("capture.libraryButton")
                }
            }
    }
}

/// Destinations reachable from the capture screen's toolbar. Separate from
/// `LibraryDestination` (which the library screen itself pushes) so a capture-screen push
/// can never accidentally satisfy the library screen's `navigationDestination`, or the
/// reverse.
enum RootDestination: Hashable {
    case library
}

#Preview {
    ContentView(services: AppServices())
}
