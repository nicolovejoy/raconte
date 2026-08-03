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

    init() {
        let library = LibraryScreenModel.live()
        _library = State(initialValue: library)
        _model = State(initialValue: CaptureScreenModel.liveWithTranscription(library: library))
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
                        if let item = library.item(captureID) {
                            EntryDetailView(model: library, item: item)
                        }
                    }
                }
        }
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
