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
    /// Nil in every build that must not talk to CloudKit — see `SyncCoordinator.live()`,
    /// which refuses under XCTest (this app is the unit suite's test host) and under the
    /// UI-test harness. Nothing on screen depends on it: sync is a background concern
    /// that never blocks or delays capture (M4 design §8).
    let sync: SyncCoordinator?

    init() {
        let library = LibraryScreenModel.live()
        self.library = library
        self.capture = CaptureScreenModel.liveWithTranscription(library: library)
        self.router = AppRouter()
        // Built from the library's own stores, never its own copies — see
        // `SyncCoordinator.live(library:)`.
        self.sync = SyncCoordinator.live(library: library)
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
        #if os(macOS)
        .commands { RaconteCommands(services: services) }
        #endif
    }
}
