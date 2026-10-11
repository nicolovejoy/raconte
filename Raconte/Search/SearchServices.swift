import Foundation
import os

/// What the library model needs from the indexer: one reconcile pass over the archive.
protocol SearchReconciling: Sendable {
    func reconcile(_ entries: [SearchIndexer.Entry]) async -> SearchIndexer.Report
}

extension SearchIndexer: SearchReconciling {}

/// The index and its indexer, built once at launch. A failure to open the index is not an
/// error the app surfaces at launch: `index` is nil and `unavailableReason` says why, and
/// search simply reports itself unavailable.
final class SearchServices: Sendable {
    let index: SearchIndex?
    let indexer: SearchIndexer?
    let unavailableReason: String?

    private static let log = Logger(subsystem: "org.pianohouseproject.raconte", category: "search")

    /// Whether this launch builds a search index at all. Off when the app is the unit suite's
    /// test host (`XCTestConfigurationFilePath` in the environment): that host is the real
    /// app over the owner's real container, and a test run has no business opening or
    /// maintaining an index there. On under the UI-test harness, a separate process over a
    /// throwaway container, so UI tests exercise the real wiring.
    ///
    /// Pure, so the policy is unit-tested; `AppServices` passes the process environment. Not
    /// `SyncCoordinator.isHostedByTestRunner`: that one also refuses under
    /// `RACONTE_UITEST_ID`, where search must stay on.
    static func isEnabled(environment: [String: String]) -> Bool {
        environment["XCTestConfigurationFilePath"] == nil
    }

    /// Opens (creating if needed) `search/index.sqlite` under `containerRoot`. Does file
    /// work, so callers keep it off the main actor.
    ///
    /// The index is a second plaintext copy of every transcript, so `search/` is kept out of
    /// backups. The flag goes on that directory BY NAME and on nothing else: it covers
    /// everything beneath the directory that carries it.
    init(containerRoot: URL) {
        do {
            var searchRoot = AppContainer.searchRoot(containerRoot: containerRoot)
            try FileManager.default.createDirectory(at: searchRoot, withIntermediateDirectories: true)
            // A backup hint must never block opening the index.
            do {
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try searchRoot.setResourceValues(values)
            } catch {
                Self.log.notice("search index: could not exclude from backup: \(error.localizedDescription, privacy: .public)")
            }
            let index = try SearchIndex(databaseURL: AppContainer.searchIndexURL(containerRoot: containerRoot))
            self.index = index
            self.indexer = SearchIndexer(index: index)
            self.unavailableReason = nil
        } catch {
            self.index = nil
            self.indexer = nil
            self.unavailableReason = error.localizedDescription
            Self.log.notice("search index unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }
}
