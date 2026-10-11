import Foundation
import Observation
import os

/// What the search screen needs from the index: one query.
protocol SearchQuerying: Sendable {
    func search(_ query: SearchQuery) async throws -> [SearchHit]
}

extension SearchIndex: SearchQuerying {}

/// One row of search results: a live entry and where the words were found in it.
struct SearchResult: Identifiable, Sendable, Equatable {
    var id: String { item.captureID }
    var item: EntryListItem
    var snippet: SearchSnippet
}

/// Turns the search field's text into results (#194).
///
/// The index knows a captureID and a body, nothing else. Journal, date and trash are
/// decided here, by joining its hits against `LibraryScreenModel.allEntries`.
///
/// Three states of the index, because it is opened off the main actor after launch:
/// not connected yet (no index, no reason — a query finds nothing and nothing is wrong),
/// ready, and unavailable (`unavailableReason`). `connect` moves it out of the first.
@MainActor @Observable
final class SearchScreenModel {
    /// The search field. Any change supersedes the query in flight. One that leaves no
    /// word to search for clears the results at once; one that leaves some runs the query
    /// after the debounce.
    var text = "" {
        didSet { textChanged(from: oldValue) }
    }
    /// Changing either filter does not query by itself: the caller follows with `refresh()`.
    var journalScope: JournalScope = .all
    var dateFilter: SearchDateFilter = .anyTime
    private(set) var results: [SearchResult] = []
    /// False when `text` holds no word to search for.
    private(set) var hasQuery = false
    /// Why there is no index, when it could not be opened. Nil while it is on its way.
    private(set) var unavailableReason: String?

    private var searching: (any SearchQuerying)?
    private let library: LibraryScreenModel
    private let currentJournal: CurrentJournal
    private let debounce: Duration
    private var debounceTask: Task<Void, Never>?
    /// Bumped by every query and every change of `text`, and checked before results are
    /// assigned: an answer that arrives after either is dropped. Same pattern as
    /// `LibraryScreenModel.scanGeneration`.
    private var queryGeneration = 0
    private var scopeSeeded = false

    private static let log = Logger(subsystem: "org.pianohouseproject.raconte", category: "search")

    /// `searching` and `unavailableReason` are both nil where the index has not been
    /// opened yet; `connect` supplies them. Constructing the model reads no file and runs
    /// no query.
    init(searching: (any SearchQuerying)?, unavailableReason: String?,
         library: LibraryScreenModel, currentJournal: CurrentJournal,
         debounce: Duration = .milliseconds(150)) {
        self.searching = searching
        self.unavailableReason = unavailableReason
        self.library = library
        self.currentJournal = currentJournal
        self.debounce = debounce
        armIndexObservation()
    }

    /// The index has been opened, or has failed to open. Text typed before this is
    /// searched now.
    func connect(searching: (any SearchQuerying)?, unavailableReason: String?) {
        self.searching = searching
        self.unavailableReason = unavailableReason
        guard hasQuery else { return }
        Task { [weak self] in await self?.refresh() }
    }

    /// Starts the screen in the journal captures are being filed into. First appearance
    /// only: after that the scope is the owner's.
    func appeared() {
        guard !scopeSeeded else { return }
        scopeSeeded = true
        if let journal = currentJournal.resolve(in: JournalRegistry(journals: library.journals)) {
            journalScope = .journal(journal.id)
        }
    }

    /// Runs the query for the current text and filters now, with no debounce. Publishes
    /// only if nothing superseded it while the index was answering.
    func refresh() async {
        queryGeneration &+= 1
        let generation = queryGeneration
        guard hasQuery, let searching else {
            results = []
            return
        }
        var hits: [SearchHit] = []
        do {
            hits = try await searching.search(SearchQuery(text: text))
        } catch {
            // The type only. An FTS5 syntax error's description quotes the query text.
            Self.log.notice("search: query failed (\(String(describing: type(of: error)), privacy: .public))")
        }
        guard generation == queryGeneration else { return }
        results = Self.filterAndSort(hits: hits, entries: library.allEntries, scope: journalScope,
                                     date: dateFilter, calendar: .gregorianCurrent, now: Date())
    }

    /// Pure. A hit with no row in `entries` is dropped, which is what keeps the trash out
    /// when `entries` is `allEntries`. Newest first by effective date, then captureID
    /// descending — the library's order (`EntryListItem.sortedByEffectiveDate`).
    static func filterAndSort(hits: [SearchHit], entries: [EntryListItem], scope: JournalScope,
                              date: SearchDateFilter, calendar: Calendar, now: Date) -> [SearchResult] {
        let byID = Dictionary(entries.map { ($0.captureID, $0) }, uniquingKeysWith: { first, _ in first })
        // The journal half of the library's own filter, so a dangling journal id matches
        // here exactly as it does there. Trash is the join's business, not this filter's.
        let filter = EntryListFilter(journal: scope, trash: .all)
        var dated: [(result: SearchResult, date: Date)] = []
        for hit in hits {
            guard let item = byID[hit.captureID], filter.matches(item) else { continue }
            let effective = item.metadata.effectiveDate(capturedAt: item.capturedAt, calendar: calendar)
            guard date.contains(effective, calendar: calendar, now: now) else { continue }
            dated.append((SearchResult(item: item, snippet: hit.snippet), effective))
        }
        return dated
            .sorted { $0.date == $1.date ? $0.result.id > $1.result.id : $0.date > $1.date }
            .map(\.result)
    }

    // MARK: internals

    private func textChanged(from old: String) {
        guard text != old else { return }
        queryGeneration &+= 1
        debounceTask?.cancel()
        debounceTask = nil
        // `terms`, not `pattern`: building a pattern costs a round trip through an
        // in-memory database, and the index builds the one it needs.
        hasQuery = !SearchQuery(text: text).terms.isEmpty
        guard hasQuery else {
            results = []
            return
        }
        debounceTask = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    /// A reconcile pass that changed the index re-runs the visible query: text typed
    /// while the archive was still being indexed would otherwise keep its first answer
    /// until the next keystroke. Observed here, not from a view's `.onChange`, so it holds
    /// whatever is mounted (the mechanism `CaptureScreenModel` uses for its own state).
    ///
    /// `onChange` fires once per arm and before the new value is visible, so the work hops
    /// to the next main-actor turn, re-arms first, and reads current state.
    private func armIndexObservation() {
        withObservationTracking {
            _ = library.searchIndexRevision
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.armIndexObservation()
                if self.hasQuery { await self.refresh() }
            }
        }
    }
}
