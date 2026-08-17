import SwiftUI

/// Everything the app-wide navigation redesign (T1-T9) routes off: one `LibraryScreenModel`,
/// one `CaptureScreenModel` built over it, one `AppRouter`. Built here — rather than as
/// `ContentView`-private `@State` — because macOS `Commands` (Task 8) live on the `Scene`,
/// outside any view, and cannot reach a view-private property.
@MainActor @Observable
final class AppServices {
    let library: LibraryScreenModel
    let capture: CaptureScreenModel
    let router: AppRouter

    init() {
        let library = LibraryScreenModel.live()
        self.library = library
        self.capture = CaptureScreenModel.liveWithTranscription(library: library)
        self.router = AppRouter()
        // Invariant 3 (design §8): one `LibraryScreenModel` app-wide. `CaptureScreenModel`
        // resolves its own `library` internally (accepting an already-built instance or
        // minting one), so an assert here — not a unit test, which would have to stand up
        // the live composition root to check it, worse than the bug it guards — is the
        // same style as `CaptureScreenModel.swift:173`/`:214`.
        assert(capture.library === library,
               "AppServices must thread ONE LibraryScreenModel into CaptureScreenModel")
    }
}

@main
struct RaconteApp: App {
    @State private var services = AppServices()

    var body: some Scene {
        WindowGroup {
            ContentView(services: services)
        }
    }
}
