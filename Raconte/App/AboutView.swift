import SwiftUI

/// #89: the Release-visible diagnostic surface — version+build, CloudKit environment,
/// and read-only sync status. Exists because five sessions paid for TestFlight builds
/// having zero on-device sync visibility (the Debug screen is `#if DEBUG`-gated).
/// Read-only by design: no actions beyond Refresh, no settings.
///
/// Owner request 2026-08-29: also the only always-visible, Release-built place a
/// first-time person (Lori, and whoever comes after) can be told what the app is and
/// how to use it — so it now carries a short "What this is"/"How it works" explanation
/// above the diagnostics.
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
            Section("What this is") {
                Text("""
                Raconte is a private journal you speak into. Press record, say what you \
                want to remember, and it is kept — the recording first, the words second.

                Everything stays on your own devices and your own iCloud. There is no \
                account and no server.
                """)
                .accessibilityIdentifier("about.whatItIs")
            }

            Section("How it works") {
                Text("""
                1. Pick a journal. A journal is just a book to file this reading in.

                2. Tap the red button and talk. The timer and the moving bar mean it is \
                listening.

                3. Tap Stop when you are done. The recording is safe on disk before \
                anything else happens to it.

                4. The words are written out for you afterwards. If one comes out wrong, \
                the recording is still the real thing — you can always listen again.

                5. Started one by accident? Tap Discard. It goes to Trash, where it can be \
                restored for thirty days.
                """)
                .accessibilityIdentifier("about.howItWorks")
            }

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
