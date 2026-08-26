import SwiftUI

/// #89: the Release-visible diagnostic surface — version+build, CloudKit environment,
/// and read-only sync status. Exists because five sessions paid for TestFlight builds
/// having zero on-device sync visibility (the Debug screen is `#if DEBUG`-gated).
/// Read-only by design: no actions beyond Refresh, no settings.
struct AboutView: View {
    /// Nil in every build `SyncCoordinator.live()` refuses (XCTest host, UI-test
    /// harness, preview, nocloud-signed) — the Sync section degrades to an
    /// explanatory row rather than hiding, same contract as the Debug screen.
    let sync: SyncCoordinator?

    /// Detected here rather than plumbed from `SyncCoordinator` so the row still
    /// renders when sync is unavailable — and it is byte-for-byte the same detection
    /// the environment gate uses (`CloudKitEnvironment.detectFromBundle`). Reading
    /// the embedded provisioning profile is file I/O: compute once in `.task`, never
    /// inline in `body` (same idiom as `DebugMenuView.buildInfo`).
    @State private var environment: CloudKitEnvironment?

    var body: some View {
        List {
            Section("App") {
                LabeledContent("Version", value: AppVersion.current())
                    .accessibilityIdentifier("about.version")
                LabeledContent("CloudKit", value: environment.map { $0.rawValue.capitalized } ?? "…")
                    .accessibilityIdentifier("about.environment")
            }
            SyncStatusSectionView(sync: sync, idPrefix: "about")
        }
        .navigationTitle("About")
        .accessibilityIdentifier("about.list")
        .task {
            if environment == nil {
                environment = await Task.detached(priority: .utility) {
                    CloudKitEnvironment.detectFromBundle()
                }.value
            }
        }
    }
}

#Preview {
    NavigationStack { AboutView(sync: nil) }
}
