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
                        case .journalEditor(let journalID):
                            JournalEditorView(model: services.library, journalID: journalID)
                        }
                    }
            }
        }
        // Sync boots once, alongside the UI, and is never awaited by anything the owner
        // is waiting on. A `.task` on the root rather than `CaptureScreenModel.bootstrap`
        // on purpose: bootstrap is the recovery path a capture depends on, and sync must
        // not be able to delay it.
        .task { await services.sync?.launch() }
        #if os(macOS)
        .frame(minWidth: 720, minHeight: 560)
        #endif
        .onChange(of: services.router.place) { _, place in
            if let scope = PlaceRouting.journalScope(for: place) {
                Task { await services.library.selectJournalScope(scope) }
            }
            // Sidebar `+` (nav T9): the deferred half of `pendingEditorPush` — see its
            // doc comment on `AppRouter` for the full story. This fires once `place` has
            // already changed to the new journal, but the append STILL can't happen
            // inline here: `.onChange`'s closure runs as part of the SAME SwiftUI update
            // transaction that just swapped `detailRoot`'s content (the switch over
            // `place` below), and empirically a `NavigationStack` whose root content and
            // `path` both change within one transaction discards the path — verified with
            // `os_log` tracing showing `detailPath` correctly holding the push in memory
            // right after being set, yet the editor never rendered. An unstructured
            // `Task { @MainActor in … }` schedules the append as a genuinely separate
            // MainActor turn, after this transaction has committed and the new root has
            // actually rendered; a bare synchronous append or a same-transaction `Task`
            // step (tried: plain `.onChange` body) both reproduced the loss.
            if case .journal(let id) = place, router.pendingEditorPush == id {
                router.pendingEditorPush = nil
                let pushedRouter = services.router
                // Deliberately NOT inline (see the paragraph above): this Task defers
                // the append past the CURRENT SwiftUI update transaction — the one that
                // just swapped `detailRoot`'s content to the new root — onto the next
                // MainActor turn, which is what lets the push survive. It is a
                // deterministic one-turn defer, not a sleep-based race, but it is still
                // a race against whatever ELSE is queued on that same turn (e.g. another
                // `Task` from this same `.onChange`, or a `library.journals` mutation
                // landing at the same moment). Do not "simplify" this back into an
                // inline `pushedRouter.detailPath.append(...)` or a same-transaction
                // step — both were tried and both silently dropped the push (verified
                // with `os_log` tracing before this shape was settled on).
                Task { @MainActor in
                    pushedRouter.detailPath.append(.journalEditor(id))
                }
            }
        }
        // A deleted journal's place must not keep pointing at nothing forever — falls
        // back to `.capture` rather than showing an empty list with no way out. Routed
        // through `router.select`, not a direct `router.place =` assignment (task review,
        // minor 3): a direct assignment bypasses `AppRouter.select`'s clear-the-path
        // contract, so a stale `detailPath` from the deleted journal's place could survive
        // the fallback and push against a place it no longer belongs to.
        //
        // Guarded to fire only when `resolve` actually disagrees with the current place
        // (nav T9): `library.journals` changes on EVERY rescan — creating a journal
        // (sidebar `+`), renaming one, setting a cover — and `router.select` unconditionally
        // clears `detailPath` (`PlaceRouting.detailPath` always returns `[]`). Before this
        // guard, the sidebar `+`'s create-then-push-editor sequence lost its own push the
        // instant `createJournal`'s rescan landed here: this handler re-selected the SAME
        // place a moment later and wiped the just-appended `.journalEditor` destination.
        // Reproduced empirically (a UI test landed on the journal's library screen instead
        // of its editor) before being traced to this unconditional call.
        .onChange(of: services.library.journals) { _, journals in
            let resolved = PlaceRouting.resolve(router.place, journals: journals)
            if resolved != router.place {
                router.select(resolved)
            }
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
                Task {
                    // Sidebar `+` (nav T9): push the new journal's editor once it exists.
                    // `createJournal` awaits `library.rescan()` before returning, so the
                    // journal is already in `services.library.journals` by the time this
                    // continuation resumes — `router.select` and the JournalEditorView
                    // lookup it drives cannot observe a not-yet-registered journal.
                    //
                    // The push itself is queued, not inline (`AppRouter.pendingEditorPush`
                    // doc comment has the full story): a `NavigationStack` whose ROOT
                    // content changes in the SAME synchronous update as a non-empty `path`
                    // discards the path, so `select` immediately followed by
                    // `detailPath.append` in one breath silently drops the push — confirmed
                    // empirically with `os_log` traces before this queue replaced it.
                    // `select` still runs first, since `pendingEditorPush` is consumed by
                    // `.onChange(of: place)`, which only fires once `place` has actually
                    // changed.
                    guard let created = await services.capture.createJournal(name: name) else { return }
                    services.router.pendingEditorPush = created.id
                    services.router.select(.journal(created.id))
                }
            }
            Button("Cancel", role: .cancel) { newJournalName = "" }
        }
    }

    @ViewBuilder private var detailRoot: some View {
        switch services.router.place {
        case .capture:
            CaptureView(model: services.capture)
        case .allEntries:
            LibraryView(model: services.library, title: "All Entries", journal: nil)
        case .journal(let id):
            LibraryView(model: services.library,
                        title: libraryTitle,
                        journal: services.library.journals.first { $0.id == id },
                        onEditJournal: { services.router.detailPath.append(.journalEditor($0)) })
        case .trash:
            TrashView(model: services.library)
        case .debug:
            #if DEBUG
            DebugMenuView(sync: services.sync)
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
