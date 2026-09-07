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
    /// T13: `AboutView`'s "Export archive…" action. Built here, once, at app-composition
    /// time — never as a view's own `@State` default, which would run
    /// `AppContainer.root()`'s directory-creating file I/O every time that view value
    /// gets constructed. `AppVersion`/`BuildInfo` are the same two bundle-reading types
    /// the About rows already read, so this is the only place that pairs
    /// `CFBundleShortVersionString`/`CFBundleVersion` for the export manifest.
    let exportRunner: ExportRunner

    init() {
        let library = LibraryScreenModel.live()
        self.library = library
        self.capture = CaptureScreenModel.liveWithTranscription(library: library)
        self.router = AppRouter()
        // Built from the library's own stores, never its own copies — see
        // `SyncCoordinator.live(library:)`.
        self.sync = SyncCoordinator.live(library: library)
        self.exportRunner = ExportRunner(exporter: ArchiveExporter(
            containerRoot: AppContainer.root(),
            appVersion: AppVersion.shortVersion(),
            build: AppVersion.displayString(short: nil, build: BuildInfo.buildNumber)))
        // M4 T6: the finalize-completion choke point (`CaptureScreenModel
        // .finishCurrentCapture` → `FinalizeArtifactPush.push`) needs a `SyncHooks` of
        // its own — it fires `.audio`/`.liveLog` too, which are not
        // `EntryMetadataStore`'s concern to notify about. Wired here, after `sync`
        // exists, for the same construction-order reason `SyncCoordinator.live`
        // attaches the library's stores after building the coordinator.
        if let sync { capture.attach(syncHooks: sync) }
        // #82: `deleteJournal`'s on-demand resolution of a worthless zero-frame blocker
        // must never resolve out from under a capture that is actively recording — this
        // is the only way it can tell. Weak: `capture` already holds `library` strongly
        // (see that property's own doc comment), so a strong capture here would be
        // library -> closure -> capture -> library, a retain cycle.
        library.attachActiveCaptureProbe { [weak capture = self.capture] in capture?.coordinator.activeCaptureID }
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
    /// M4 T12 (design §3, "fetch on launch, foreground, and silent push"): the
    /// foreground half. Launch's own fetch is `ContentView`'s `.task { sync?.launch() }`
    /// — this covers the scene coming back to `.active` afterward (backgrounded then
    /// resumed). Not unit-testable (no UI-test harness reaches `Scene` composition on
    /// this project); `SyncCoordinator.foregrounded()` itself is exercised directly.
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(services: services)
        }
        #if os(macOS)
        .commands { RaconteCommands(services: services) }
        #endif
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task { await services.sync?.foregrounded() }
        }
    }
}
