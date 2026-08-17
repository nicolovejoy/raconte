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
