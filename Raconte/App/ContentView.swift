import SwiftUI

/// Top-level navigation (M3 T4). Capture is the home screen; the library is a toolbar
/// push, not a tab, so the shape is identical on iOS and macOS.
///
/// ONE `LibraryScreenModel` for the whole app (M3 T4.5), built here and threaded into
/// `CaptureScreenModel`: the capture screen's recent section and the pushed `LibraryView`
/// must read through the same scan and the same stores, never two parallel data paths.
struct ContentView: View {
    @State private var library: LibraryScreenModel
    @State private var model: CaptureScreenModel
    /// Nil in every build that must not talk to CloudKit — see `SyncCoordinator.live()`,
    /// which refuses under XCTest (this app is the unit suite's test host) and under the
    /// UI-test harness. Nothing on screen depends on it: sync is a background concern
    /// that never blocks or delays capture (M4 design §8).
    @State private var sync: SyncCoordinator?

    init() {
        let library = LibraryScreenModel.live()
        _library = State(initialValue: library)
        _model = State(initialValue: CaptureScreenModel.liveWithTranscription(library: library))
        // Built from the library's own stores, never its own copies — see
        // `SyncCoordinator.live(library:)`.
        _sync = State(initialValue: SyncCoordinator.live(library: library))
    }

    var body: some View {
        NavigationStack {
            CaptureView(model: model)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        NavigationLink(value: RootDestination.library) {
                            Image(systemName: "books.vertical")
                        }
                        .accessibilityIdentifier("capture.libraryButton")
                    }
                }
                .navigationDestination(for: RootDestination.self) { destination in
                    switch destination {
                    case .library:
                        LibraryView(model: library)
                    }
                }
                .navigationDestination(for: LibraryDestination.self) { destination in
                    switch destination {
                    case .entry(let captureID):
                        // The `else` is not decoration (issue #32): a destination builder
                        // that returns nothing still pushes, so an unresolvable id used to
                        // land the owner on a blank page with no way to tell what went
                        // wrong. `item` is scope-independent now, which leaves only the
                        // honest cases — a capture that is genuinely gone.
                        if let item = library.item(captureID) {
                            EntryDetailView(model: library, item: item)
                        } else {
                            ContentUnavailableView(
                                "Entry Unavailable",
                                systemImage: "questionmark.folder",
                                description: Text("This entry is no longer in the library. "
                                                  + "It may have been permanently deleted."))
                            .accessibilityIdentifier("entry.unavailable")
                        }
                    case .trash:
                        TrashView(model: library)
                    }
                }
        }
        // Sync boots once, alongside the UI, and is never awaited by anything the owner
        // is waiting on. A `.task` on the root rather than `CaptureScreenModel.bootstrap`
        // on purpose: bootstrap is the recovery path a capture depends on, and sync must
        // not be able to delay it.
        .task { await sync?.launch() }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 560)
        #endif
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
    ContentView()
}
