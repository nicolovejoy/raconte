import Foundation

/// Drives one "Export archive…" OR "Verify archive…" run for `AboutView` (T13, #154):
/// export-then-verify a freshly written package, or verify an existing one alone,
/// publishing progress through one small state enum so the view stays dumb — it
/// renders `state`, it never orchestrates the picker's async I/O itself.
///
/// The actual work (`ArchiveExporter.export` + `ArchiveVerifier.verify`) runs on a
/// detached utility task, off the main actor — an archive can be gigabytes of audio, and
/// nothing here may block the UI thread. Only the published `state` hops back to
/// `@MainActor`.
///
/// Security-scoped access to the picked folder is this type's caller's concern, not
/// this type's: `AboutView`'s `.fileImporter` callback starts it and stops it (via
/// `defer`) around the call to `run(into:)` or `verify(package:)`, so the scope's
/// lifetime is visible in one place rather than split across two.
@MainActor @Observable
final class ExportRunner {
    enum State: Equatable {
        case idle
        /// Fix wave Finding 2: `verifying` tells the label which of the two flows is
        /// running — `false` for an export (which itself ends by verifying what it just
        /// wrote), `true` for a standalone `verify(package:)`. Carried in the runner's
        /// own state rather than left to view-local `@State` so a still-running verify
        /// reads correctly even after `AboutView` is navigated away from and back.
        case running(verifying: Bool)
        case finished(ArchiveExporter.Report, ArchiveVerifier.Report)
        /// #154: a verify-only run over a package the owner picked — nothing was
        /// written. `packageName` is the picked folder's last path component.
        case verified(packageName: String, ArchiveVerifier.Report)
        case failed(String)
    }

    private(set) var state: State = .idle
    private let exporter: ArchiveExporter

    /// Fix wave Finding 2: `true` for either running case, regardless of which flow —
    /// the one place both "disable the buttons" call sites need to ask.
    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    init(exporter: ArchiveExporter) {
        self.exporter = exporter
    }

    /// `destination` is the folder the owner picked via `.fileImporter` — the exporter
    /// creates its own timestamped package directory inside it, so this never writes
    /// directly into a folder the owner did not choose. `scope` (#157) is what the
    /// confirmation sheet resolved; `.all` is the pre-#157 behaviour.
    func run(into destination: URL, scope: ExportScope = .all) async {
        state = .running(verifying: false)
        let exporter = self.exporter
        do {
            let (report, verification) = try await Task.detached(priority: .utility) {
                let report = try await exporter.export(into: destination, scope: scope)
                let verification = ArchiveVerifier.verify(packageURL: report.packageURL)
                return (report, verification)
            }.value
            state = .finished(report, verification)
        } catch {
            state = .failed(String(describing: error))
        }
    }

    /// #157: what the confirmation sheet renders. One walk of the container, off the main
    /// actor (a large archive is thousands of directory reads). Not a "run": `state` is left
    /// alone on success so a stale result row from a previous export stays visible behind
    /// the sheet. On failure — realistically only a missing container root — publishes
    /// `.failed` and returns nil so the caller shows nothing.
    func inventory() async -> ExportInventory? {
        let containerRoot = exporter.containerRoot
        do {
            return try await Task.detached(priority: .utility) {
                try ExportInventory.read(containerRoot: containerRoot)
            }.value
        } catch {
            state = .failed(String(describing: error))
            return nil
        }
    }

    /// #154: verify an EXISTING package without exporting. Same detached utility task
    /// as `run(into:)` — a package can be gigabytes and every byte is re-hashed.
    /// `ArchiveVerifier.verify` never throws: a folder that is not a package comes back
    /// as a report whose first problem is `.manifestUnreadable`, which is the honest
    /// answer for "I picked the wrong folder".
    func verify(package: URL) async {
        state = .running(verifying: true)
        let report = await Task.detached(priority: .utility) {
            ArchiveVerifier.verify(packageURL: package)
        }.value
        state = .verified(packageName: package.lastPathComponent, report)
    }

    /// Lets the caller report a failure that happened before `run(into:)` could even
    /// start — e.g. `startAccessingSecurityScopedResource()` returning false.
    func fail(_ reason: String) {
        state = .failed(reason)
    }

    /// Fix wave Finding 9: the owner dismissing the folder picker without choosing
    /// anything is not a failure — `.fileImporter` reports it as a `.failure(
    /// CocoaError.userCancelled)`, and `AboutView` routes that specific case here
    /// instead of `fail(_:)` so the screen goes back to quiet `.idle` rather than
    /// showing an alarming "Failed: …" row for a no-op.
    func cancelled() {
        state = .idle
    }
}
