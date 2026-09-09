import SwiftUI
import UniformTypeIdentifiers

/// #89: the Release-visible diagnostic surface — version+build, CloudKit environment,
/// and read-only sync status. Exists because five sessions paid for TestFlight builds
/// having zero on-device sync visibility (the Debug screen is `#if DEBUG`-gated).
/// Read-only by design EXCEPT the T13 export action, which writes only to a folder the
/// owner explicitly picks AND confirms (#157) — never anywhere else, and never anything
/// under the app's own container.
///
/// The "What this is"/"How it works" introduction added 2026-08-29 for a first-time
/// reader was removed 2026-09-08 at the owner's request: the app has one user, and the
/// diagnostics are what About is for.
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

    /// #154: one `.fileImporter` serves both Archive buttons. The MODE is set by whichever
    /// button opens the picker and never cleared, so the completion closure can read it
    /// after the picker has dismissed; only the flag flips.
    private enum ArchivePickerMode { case export, verify }
    @State private var archivePickerMode: ArchivePickerMode = .export
    @State private var showingArchivePicker = false

    /// #157: the export the owner has picked a folder for but not yet confirmed. Set only
    /// after the inventory has been read; the `.sheet(item:)` below presents while non-nil.
    /// `requiresSecurityScope` is false only for the UI-test harness destination (the app's
    /// own temp dir), which `startAccessingSecurityScopedResource()` would refuse.
    private struct PendingExport: Identifiable {
        let id = UUID()
        var destination: URL
        var inventory: ExportInventory
        var requiresSecurityScope: Bool
    }
    @State private var pendingExport: PendingExport?

    var body: some View {
        List {
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
                Button("Export archive…") {
                    #if DEBUG
                    // #157 UI test path: the system picker cannot be driven from XCUITest.
                    if ProcessInfo.processInfo.environment["RACONTE_UITEST_EXPORT_DESTINATION"] == "tmp" {
                        Task { await stageExport(to: FileManager.default.temporaryDirectory, requiresSecurityScope: false) }
                        return
                    }
                    #endif
                    archivePickerMode = .export
                    showingArchivePicker = true
                }
                .accessibilityIdentifier("about.export")
                .disabled(exportRunner.isRunning)

                // #154: the same verifier the export runs, over a package picked from
                // anywhere — a years-old copy on a USB stick, or the M4 gate's fresh
                // export from a reinstalled Mac.
                Button("Verify archive…") {
                    archivePickerMode = .verify
                    showingArchivePicker = true
                }
                .accessibilityIdentifier("about.verify")
                .disabled(exportRunner.isRunning)

                // Fix wave Finding 2: the label reads the RUNNER's own state, not
                // view-local `archivePickerMode` — navigating away from About mid-verify
                // and back must still show "Verifying…", not whatever the picker mode
                // happened to be left at.
                if case let .running(verifying) = exportRunner.state {
                    HStack {
                        ProgressView()
                        Text(verifying ? "Verifying…" : "Exporting…")
                            .font(TypeRole.body.font)
                    }
                    .accessibilityIdentifier("about.export.progress")
                }
                if let resultText = exportResultText {
                    Text(resultText)
                        .font(TypeRole.body.font)
                        .accessibilityIdentifier("about.export.result")
                }
            }
        }
        .font(TypeRole.body.font)
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
        .fileImporter(isPresented: $showingArchivePicker,
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
                guard let url = urls.first else { return }
                let mode = archivePickerMode
                Task {
                    switch mode {
                    case .export:
                        // #157: nothing is written yet — read the inventory and confirm.
                        await stageExport(to: url, requiresSecurityScope: true)
                    case .verify:
                        guard url.startAccessingSecurityScopedResource() else {
                            exportRunner.fail("could not access the selected package")
                            return
                        }
                        defer { url.stopAccessingSecurityScopedResource() }
                        await exportRunner.verify(package: url)
                    }
                }
            }
        }
        // #157: attached to the LIST for the same reason `.fileImporter` is.
        .sheet(item: $pendingExport) { pending in
            ExportConfirmationSheet(
                destinationName: pending.destination.lastPathComponent,
                inventory: pending.inventory,
                onCancel: { pendingExport = nil },
                onExport: { scope in
                    pendingExport = nil
                    Task { await performExport(pending, scope: scope) }
                })
        }
    }

    /// `about.export.result`'s text, per its four shapes: verified export success,
    /// export success with verification problems, a standalone verify run (#154,
    /// itself clean or with problems), and outright failure. The folder name comes
    /// back out of the written package's own URL — `ArchiveExporter.export(into:)`
    /// writes its timestamped package directory directly inside the picked folder, so
    /// the package URL's parent IS the folder the owner chose.
    private var exportResultText: String? {
        switch exportRunner.state {
        case .idle, .running:
            return nil // .running matches regardless of `verifying:` payload
        case let .finished(report, verification):
            let folderName = report.packageURL.deletingLastPathComponent().lastPathComponent
            if verification.ok {
                return "Exported \(report.counts.entries) entries to \(folderName) — verified"
            } else {
                return "Exported, but verification found \(verification.problems.count) problems"
            }
        case let .verified(packageName, verification):
            if verification.ok {
                return "Verified \(packageName): \(verification.checkedFiles) files, no problems"
            } else {
                let count = verification.problems.count
                let noun = count == 1 ? "problem" : "problems"
                let first = verification.problems[0].summary
                return "Verification of \(packageName) found \(count) \(noun) — first: \(first)"
            }
        case let .failed(reason):
            return "Failed: \(reason)"
        }
    }

    /// #157 step 1 of 2: read what WOULD be exported and present the sheet. Reads the
    /// container (not the destination), so no security scope is needed here.
    private func stageExport(to destination: URL, requiresSecurityScope: Bool) async {
        guard let inventory = await exportRunner.inventory() else { return } // runner published .failed
        pendingExport = PendingExport(destination: destination, inventory: inventory,
                                      requiresSecurityScope: requiresSecurityScope)
    }

    /// #157 step 2 of 2: the owner confirmed. Security scope is opened HERE, around the
    /// write, exactly as the pre-#157 callback did — the picked URL keeps its scope until
    /// accessed, so deferring the start past the sheet is fine.
    private func performExport(_ pending: PendingExport, scope: ExportScope) async {
        let url = pending.destination
        if pending.requiresSecurityScope {
            guard url.startAccessingSecurityScopedResource() else {
                exportRunner.fail("could not access the selected folder")
                return
            }
        }
        defer { if pending.requiresSecurityScope { url.stopAccessingSecurityScopedResource() } }
        await exportRunner.run(into: url, scope: scope)
    }
}

#Preview {
    NavigationStack {
        AboutView(sync: nil, exportRunner: ExportRunner(exporter: ArchiveExporter(
            containerRoot: FileManager.default.temporaryDirectory,
            appVersion: "1.0", build: "1")))
    }
}
