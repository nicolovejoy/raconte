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
/// So a filter change, or the library changing under the list (a trash, a restore, a
/// move, a backdate), never asks the index: the hits already on hand are joined again, and
/// the list follows the library with no query. The index is asked when the text changes,
/// when a reconcile pass changed the index, and when the index first connects.
///
/// Three states of the index, because it is opened off the main actor after launch:
/// not connected yet (no index, no reason — a query finds nothing and nothing is wrong),
/// ready, and unavailable (`unavailableReason`, with or without an index). `connect`
/// moves it out of the first.
@MainActor @Observable
final class SearchScreenModel {
    /// The search field. Any change supersedes the query in flight. One that leaves no
    /// word to search for clears the results at once; one that leaves some runs the query
    /// after the debounce.
    var text = "" {
        didSet { textChanged(from: oldValue) }
    }
    /// Changing either filter re-joins the hits on hand, in the setter. No query, and
    /// nothing for the caller to follow up with. Setting the scope also spends the scope
    /// seed: a scope the owner picks is never replaced by the default one.
    var journalScope: JournalScope = .all {
        didSet {
            scopeSeed = .spent
            rejoin()
        }
    }
    var dateFilter: SearchDateFilter = .anyTime {
        didSet { rejoin() }
    }
    private(set) var results: [SearchResult] = []
    /// False when `text` holds no word to search for.
    private(set) var hasQuery = false
    /// True once the index has answered the text now in the field and `results` is that
    /// answer, joined. False from a change of text until its answer lands, after a query
    /// that failed, and while there is no index to ask. An answer that arrives after the
    /// text moved on never sets it. A re-query of the same text keeps it.
    private(set) var hasAnswer = false
    /// The one expression the screen's "No matches" reads: answered, and nothing listed.
    /// `hasQuery && results.isEmpty` is also true between a keystroke and its answer.
    var showsNoMatches: Bool { hasAnswer && results.isEmpty }
    /// Why there is no index, when it could not be opened. Nil while it is on its way.
    private(set) var unavailableReason: String?

    private var searching: (any SearchQuerying)?
    private let library: LibraryScreenModel
    private let currentJournal: CurrentJournal
    private let debounce: Duration
    private var debounceTask: Task<Void, Never>?
    /// Bumped by `supersede()` — every query, every change of `text`, an index that went
    /// away — and checked before an answer is kept: one that arrives after any of them is
    /// dropped. Same pattern as `LibraryScreenModel.scanGeneration`.
    private var queryGeneration = 0
    /// The hits of the last completed query, for as long as it is the latest one asked.
    /// Nil once anything supersedes it — a change of text, a newer query, an index that
    /// went away — so hits never outlive the question they answered.
    private var hitsOnHand: [SearchHit]?
    /// The default scope is applied once: on the first appearance, or — when the journals
    /// have not been published by then — when they are.
    private enum ScopeSeed { case unspent, waitingForJournals, spent }
    private var scopeSeed = ScopeSeed.unspent

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
        armEntriesObservation()
    }

    /// The index has been opened, or has failed to open. Text typed before this is
    /// searched now. With no index to ask, whatever an earlier one answered leaves the
    /// screen at once.
    func connect(searching: (any SearchQuerying)?, unavailableReason: String?) {
        self.searching = searching
        self.unavailableReason = unavailableReason
        guard askableIndex != nil else {
            supersede()
            results = []
            hasAnswer = false
            return
        }
        guard hasQuery else { return }
        Task { [weak self] in await self?.refresh() }
    }

    /// Starts the screen in the journal captures are being filed into. First appearance
    /// only: after that the scope is the owner's. If there is a current journal but the
    /// library has not published its journals yet (the launch scan is still running), the
    /// seed waits for them.
    func appeared() {
        guard scopeSeed == .unspent else { return }
        if currentJournal.storedID != nil, library.journals.isEmpty {
            scopeSeed = .waitingForJournals
            armJournalsObservation()
        } else {
            spendScopeSeed()
        }
    }

    /// Asks the index about the current text now, with no debounce, in place of any
    /// debounced query still pending. Publishes only if nothing superseded it while the
    /// index was answering. The one place a query runs; filters and library changes never
    /// come through here.
    func refresh() async {
        let generation = supersede()
        debounceTask?.cancel()
        debounceTask = nil
        guard hasQuery, let searching = askableIndex else {
            results = []
            hasAnswer = false
            return
        }
        let hits: [SearchHit]?
        do {
            hits = try await searching.search(SearchQuery(text: text))
        } catch {
            Self.log.notice("search: query failed (\(Self.failureSummary(error), privacy: .public))")
            hits = nil
        }
        guard generation == queryGeneration else { return }
        guard let hits else {
            // Nothing was found out, so nothing was answered: an empty list, not "No matches".
            results = []
            hasAnswer = false
            return
        }
        hitsOnHand = hits
        rejoin()
        hasAnswer = true
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

    /// The type and the numeric code, nothing else: an FTS5 syntax error's description
    /// quotes the query text. For a GRDB `DatabaseError` the code is SQLite's extended
    /// result code (its `CustomNSError` conformance).
    static func failureSummary(_ error: any Error) -> String {
        "\(String(describing: type(of: error))), code \((error as NSError).code)"
    }

    // MARK: internals

    /// The index to ask, or nil when there is none: not connected yet, or unavailable. A
    /// reason makes it unavailable whether or not an index came with it. The one rule
    /// `connect` and `refresh` both read.
    private var askableIndex: (any SearchQuerying)? {
        unavailableReason == nil ? searching : nil
    }

    private func spendScopeSeed() {
        scopeSeed = .spent
        if let journal = currentJournal.resolve(in: JournalRegistry(journals: library.journals)) {
            journalScope = .journal(journal.id)
        }
    }

    /// Whatever is in flight, and whatever is on hand, answered an earlier question.
    @discardableResult
    private func supersede() -> Int {
        queryGeneration &+= 1
        hitsOnHand = nil
        return queryGeneration
    }

    /// `results` from the hits on hand and the library, filters and clock as they stand.
    /// No query. Does nothing without a current answer, so it cannot paint over a list
    /// that was cleared. Assigns only a real change, so a re-join that moves nothing
    /// invalidates no view.
    private func rejoin() {
        guard let hitsOnHand else { return }
        let joined = Self.filterAndSort(hits: hitsOnHand, entries: library.allEntries, scope: journalScope,
                                        date: dateFilter, calendar: .gregorianCurrent, now: Date())
        if joined != results { results = joined }
    }

    private func textChanged(from old: String) {
        guard text != old else { return }
        supersede()
        hasAnswer = false
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
            guard !Task.isCancelled, let self else { return }
            // Done waiting: `refresh()` must not cancel the task it is running on.
            self.debounceTask = nil
            await self.refresh()
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

    /// The library published its entries again: something was trashed, restored, moved,
    /// backdated or pulled in by sync. None of that changes the index (it holds only
    /// text, trashed entries included), so the hits on hand are joined again rather than
    /// asked for again. Same arming as above.
    private func armEntriesObservation() {
        withObservationTracking {
            _ = library.allEntries
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.armEntriesObservation()
                self.rejoin()
            }
        }
    }

    /// Armed by `appeared()` only while the scope seed waits for the journals. Re-armed
    /// while they are still empty; spends the seed when they arrive. Same arming as above.
    private func armJournalsObservation() {
        withObservationTracking {
            _ = library.journals
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.scopeSeed == .waitingForJournals else { return }
                if self.library.journals.isEmpty {
                    self.armJournalsObservation()
                } else {
                    self.spendScopeSeed()
                }
            }
        }
    }
}
