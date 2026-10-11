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

    /// Opens (creating if needed) `search/index.sqlite` under `containerRoot`. Does file
    /// work, so callers keep it off the main actor.
    init(containerRoot: URL) {
        do {
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
