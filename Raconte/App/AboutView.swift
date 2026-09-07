import SwiftUI
import UniformTypeIdentifiers

/// #89: the Release-visible diagnostic surface — version+build, CloudKit environment,
/// and read-only sync status. Exists because five sessions paid for TestFlight builds
/// having zero on-device sync visibility (the Debug screen is `#if DEBUG`-gated).
/// Read-only by design EXCEPT the T13 export action, which writes only to a folder the
/// owner explicitly picks via the system document picker — never anywhere else, and
/// never anything under the app's own container.
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

    /// Built in `AppServices` (T13, composition root — same reasoning as `sync` above)
    /// and threaded straight through, never a view-local `@State` default: constructing
    /// an `ArchiveExporter` reads `AppContainer.root()`, which creates a directory on
    /// disk, and that must happen once at app launch, not every time this view's
    /// default state initializer runs.
    let exportRunner: ExportRunner

    /// Detected here rather than plumbed from `SyncCoordinator` so the row still
    /// renders when sync is unavailable — and it is byte-for-byte the same detection
    /// the environment gate uses (`CloudKitEnvironment.detectFromBundle`). Reading
    /// the embedded provisioning profile is file I/O: compute once in `.task`, never
    /// inline in `body` (same idiom as `DebugMenuView.buildInfo`).
    @State private var environment: CloudKitEnvironment?

    @State private var showingExportPicker = false

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
                // A DIFFERENT fact from Version, not a duplicate of it: Version is the
                // marketing/build number pair ("1.0 (12)"), which is identical across
                // every install of one build submission. The build TIME is what tells
                // you whether the app in your hand is the one just built — the question
                // a wireless `devicectl` install and a TestFlight update both leave
                // unanswered (see `BuildInfo`). It lived on the capture screen until
                // #118 §7 moved it here; About is the only Release-visible screen it
                // can live on. Not DEBUG-gated, for the same reason.
                //
                // The value keeps `BuildInfo.stamp` verbatim, sentence prefix and all —
                // it is the string the owner reads off a smoke build and compares
                // against the build he just ran, so it should not be reworded per site.
                LabeledContent("Build", value: BuildInfo.stamp)
                    .accessibilityIdentifier("about.buildStamp")
                LabeledContent("CloudKit", value: environment.map { $0.rawValue.capitalized } ?? "…")
                    .accessibilityIdentifier("about.environment")
            }
            SyncStatusSectionView(sync: sync, idPrefix: "about")

            Section("Archive") {
                Button("Export archive…") { showingExportPicker = true }
                    .accessibilityIdentifier("about.export")
                    .disabled(exportRunner.state == .running)

                if exportRunner.state == .running {
                    HStack {
                        ProgressView()
                        Text("Exporting…")
                            .font(.body)
                    }
                    .accessibilityIdentifier("about.export.progress")
                }

                if let resultText = exportResultText {
                    Text(resultText)
                        .font(.body)
                        .accessibilityIdentifier("about.export.result")
                }
            }
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
        // T13: attached to the LIST — the screen's outer view — never to a `Section`;
        // a `.fileImporter` on a `Section` silently never presents on iOS 26 (standing
        // lesson, `.sheet` has the same failure mode).
        .fileImporter(isPresented: $showingExportPicker,
                     allowedContentTypes: [.folder],
                     allowsMultipleSelection: false) { result in
            switch result {
            case .failure(let error):
                // Fix wave Finding 9: dismissing the picker without choosing a folder
                // is not a failure — route it to `.idle`, not `.failed`, and keep the
                // raw error text for every other (real) failure.
                if (error as? CocoaError)?.code == .userCancelled {
                    exportRunner.cancelled()
                } else {
                    exportRunner.fail(String(describing: error))
                }
            case .success(let urls):
                guard let destination = urls.first else { return }
                Task {
                    guard destination.startAccessingSecurityScopedResource() else {
                        exportRunner.fail("could not access the selected folder")
                        return
                    }
                    defer { destination.stopAccessingSecurityScopedResource() }
                    await exportRunner.run(into: destination)
                }
            }
        }
    }

    /// `about.export.result`'s text, per T13's exact three shapes: verified success,
    /// success with verification problems, and outright failure. The folder name comes
    /// back out of the written package's own URL — `ArchiveExporter.export(into:)`
    /// writes its timestamped package directory directly inside the picked folder, so
    /// the package URL's parent IS the folder the owner chose.
    private var exportResultText: String? {
        switch exportRunner.state {
        case .idle, .running:
            return nil
        case let .finished(report, verification):
            let folderName = report.packageURL.deletingLastPathComponent().lastPathComponent
            if verification.ok {
                return "Exported \(report.counts.entries) entries to \(folderName) — verified"
            } else {
                return "Exported, but verification found \(verification.problems.count) problems"
            }
        case let .failed(reason):
            return "Export failed: \(reason)"
        }
    }
}

#Preview {
    NavigationStack {
        AboutView(sync: nil, exportRunner: ExportRunner(exporter: ArchiveExporter(
            containerRoot: FileManager.default.temporaryDirectory,
            appVersion: "1.0", build: "1")))
    }
}
