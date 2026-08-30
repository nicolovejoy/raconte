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
                Raconte is a private audio journaling app. It syncs across your devices \
                through your own iCloud account, so no one else can read what you record.
                """)
                .accessibilityIdentifier("about.whatItIs")
            }

            Section("How it works") {
                Text("""
                I built this to bring my old paper journals into one place. I have kept \
                them for decades. For each one I wanted three things held together: the \
                audio of me reading it aloud, a transcript of those words, and a photo of \
                the original page.

                So entries are filed into journals. An entry can be backdated to when it \
                was really written, and you can attach pictures to it.

                The audio is the record that matters, and it is always preserved. The \
                transcript is written from it.
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
