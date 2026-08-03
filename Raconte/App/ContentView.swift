import SwiftUI

/// Top-level navigation (M3 T4). Capture stays the app's home screen — the phone mockup
/// and every existing UI test target it directly — with the library reachable from a
/// toolbar button rather than a tab: the lightest thing that behaves identically on iOS
/// and macOS. A `TabView` would also work but reshapes the whole window around a screen
/// used far less than capture, and macOS tab chrome reads oddly for a two-item app. The
/// recent-recordings list on the capture screen stays exactly as it is: it answers "did
/// the recording I just made finish?" right where the owner already is, a different
/// question from "show me my library", and folding it away would cost every existing UI
/// test's `finished.duration` assertions for no gain.
struct ContentView: View {
    @State private var model = CaptureScreenModel.liveWithTranscription()
    @State private var library = LibraryScreenModel.live()

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
