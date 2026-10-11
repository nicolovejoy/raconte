import XCTest
@testable import Raconte

/// #194 Task 8: typed text becomes results. The join against the library, the scope and
/// date filters, and the rule that a superseded query never paints.
@MainActor
final class SearchScreenModelTests: XCTestCase {

    private let cal = Calendar.gregorianCurrent
    private let now = Date(timeIntervalSince1970: 1_790_000_000)   // 21 September 2026
    /// The one entry on disk. A real ULID: the scan reads a date out of the id.
    private let liveID = ULID.make()

    // MARK: Fixtures

    private func writeCapture(_ id: String, capturesRoot: URL) throws {
        let dir = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: id)
        let segs = SegmentLayout.segmentsDirectory(captureDirectory: dir)
        try FileManager.default.createDirectory(at: segs, withIntermediateDirectories: true)
        try Data(count: 48_000 * 4).write(to: SegmentLayout.pcmURL(segmentsDirectory: segs, index: 0))
        let format = AudioFormatDescriptor(sampleRate: 48_000, channels: 1,
                                           commonFormat: .pcmFormatFloat32,
                                           interleaved: false, bytesPerFrame: 4)
        let created = Date(timeIntervalSince1970: 1_000)
        let manifest = Manifest(captureID: id, createdAt: created, state: .captured,
                                stateSeq: 1, stateUpdatedAt: created, format: format)
        try CaptureCoding.encoder().encode(manifest)
            .write(to: SegmentLayout.manifestURL(captureDirectory: dir))
    }

    /// A library over its own temporary container, whose one scan has published `liveID`.
    private func scannedLibrary() async throws -> LibraryScreenModel {
        let containerRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SearchScreenModel-\(UUID().uuidString)", isDirectory: true)
        let capturesRoot = AppContainer.capturesRoot(containerRoot: containerRoot)
        try FileManager.default.createDirectory(at: capturesRoot, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: containerRoot) }
        try writeCapture(liveID, capturesRoot: capturesRoot)
        let library = LibraryScreenModel(capturesRoot: capturesRoot, journalsContainerRoot: containerRoot)
        _ = await library.rescan()
        XCTAssertEqual(library.allEntries.map(\.captureID), [liveID], "fixture sanity")
        return library
    }

    /// The debounce is an hour so only an explicit `refresh()`, a `connect` or the index
    /// observation can start a query: a debounced one firing by itself would satisfy a
    /// `waitForParkedCall` that is there to prove one of the others.
    private func model(searching: (any SearchQuerying)?, unavailableReason: String? = nil,
                       library: LibraryScreenModel,
                       current: CurrentJournal = CurrentJournal(store: InMemoryJournalPreferenceStore())) -> SearchScreenModel {
        SearchScreenModel(searching: searching, unavailableReason: unavailableReason,
                          library: library, currentJournal: current, debounce: .seconds(3600))
    }

    private func item(_ id: String, journalID: String? = nil, capturedAt: Date,
                      backdate: PartialDate? = nil) -> EntryListItem {
        EntryListItem(captureID: id, capturedAt: capturedAt,
                      metadata: EntryMetadata(journalID: journalID, originalDate: backdate))
    }

    private func hit(_ id: String, _ marked: String = "x") -> SearchHit {
        SearchHit(captureID: id, snippet: .parse(marked))
    }

    private func results(_ hits: [SearchHit], _ entries: [EntryListItem], scope: JournalScope = .all,
                         date: SearchDateFilter = .anyTime) -> [SearchResult] {
        SearchScreenModel.filterAndSort(hits: hits, entries: entries, scope: scope, date: date,
                                        calendar: cal, now: now)
    }

    /// Runs one explicit query on `model` and answers it with `hits`.
    private func answerRefresh(_ model: SearchScreenModel, _ fake: FakeSearching, call: Int,
                               with hits: [SearchHit]) async {
        let running = Task { await model.refresh() }        // refresh() runs now, no debounce
        await fake.waitForParkedCall(call)
        let released = await fake.release(hits)
        XCTAssertTrue(released, "query \(call) never reached the index")
        await running.value
    }

    // MARK: filterAndSort

    /// The index holds trashed entries too (restoring one must not need a reindex). They
    /// stay out of the results because a hit with no row in `allEntries` is dropped.
    func testTrashIsExcludedBecauseOnlyAllEntriesAreJoined() {
        let live = ULID.make(), trashed = ULID.make()
        let liveItem = item(live, capturedAt: now)
        let found = results([hit(trashed, "gone"), hit(live, "here")], [liveItem])
        XCTAssertEqual(found.map(\.id), [live])
        XCTAssertEqual(found.first?.item, liveItem)
        XCTAssertEqual(found.first?.snippet, .parse("here"), "the row carries its own hit's snippet")
    }

    func testJournalScopeFilters() {
        let j1 = ULID.make(), j2 = ULID.make()
        let inJ1 = ULID.make(), alsoJ1 = ULID.make(), inJ2 = ULID.make(), unfiled = ULID.make()
        let entries = [item(inJ1, journalID: j1, capturedAt: now),
                       item(alsoJ1, journalID: j1, capturedAt: now.addingTimeInterval(-60)),
                       item(inJ2, journalID: j2, capturedAt: now.addingTimeInterval(-120)),
                       item(unfiled, capturedAt: now.addingTimeInterval(-180))]
        let hits = [inJ1, alsoJ1, inJ2, unfiled].map { hit($0) }
        XCTAssertEqual(results(hits, entries, scope: .journal(j1)).map(\.id), [inJ1, alsoJ1])
        XCTAssertEqual(results(hits, entries, scope: .journal(j2)).map(\.id), [inJ2])
        XCTAssertEqual(results(hits, entries, scope: .unfiled).map(\.id), [unfiled])
        XCTAssertEqual(results(hits, entries, scope: .all).map(\.id), [inJ1, alsoJ1, inJ2, unfiled])
    }

    /// Newest first by EFFECTIVE date, so a backdated entry sorts under the day it is
    /// about; a tie breaks on captureID descending, as in the library.
    func testNewestFirst() {
        let old = ULID.make(), middle = ULID.make(), recent = ULID.make()
        let tied = [ULID.make(), ULID.make()].sorted()
        let entries = [
            // Captured last, but backdated to 1987: the oldest of the five.
            item(old, capturedAt: now, backdate: PartialDate(year: 1987, month: 6, day: 1)),
            item(middle, capturedAt: now.addingTimeInterval(-86_400 * 30)),
            item(recent, capturedAt: now.addingTimeInterval(-60)),
            item(tied[0], capturedAt: now.addingTimeInterval(-86_400)),
            item(tied[1], capturedAt: now.addingTimeInterval(-86_400)),
        ]
        // Index order is none of the orders asked for.
        let hits = [middle, tied[0], old, recent, tied[1]].map { hit($0) }
        XCTAssertEqual(results(hits, entries).map(\.id), [recent, tied[1], tied[0], middle, old])
        // The date filter reads the same effective date.
        XCTAssertEqual(results(hits, entries, date: .custom(from: nil, to: PartialDate(year: 1990))).map(\.id), [old])
    }

    // MARK: Scope seeding

    func testAppearedSeedsScopeFromCurrentJournalOnce() async throws {
        let library = try await scannedLibrary()
        // Two journals, the SECOND current: one cannot tell "the current journal" from
        // "the first journal".
        _ = try await library.journalStore.create(name: "1987")
        let second = try await library.journalStore.create(name: "France")
        _ = await library.rescan()
        XCTAssertEqual(library.journals.count, 2, "fixture sanity")
        let current = CurrentJournal(store: InMemoryJournalPreferenceStore(
            values: [CurrentJournal.defaultsKey: second.id]))
        let model = model(searching: FakeSearching(), library: library, current: current)
        XCTAssertEqual(model.journalScope, .all)
        model.appeared()
        XCTAssertEqual(model.journalScope, .journal(second.id))
        model.journalScope = .all                 // the owner widens the search
        model.appeared()                          // and comes back to the screen
        XCTAssertEqual(model.journalScope, .all, "a later appearance must not undo the owner's choice")
    }

    // MARK: Queries

    /// Typing is enough: nothing else has to ask. Two keystrokes inside one debounce are
    /// one query, for the text as it stands.
    func testTypingQueriesTheLatestTextAfterTheDebounce() async throws {
        let library = try await scannedLibrary()
        let fake = FakeSearching()
        let model = SearchScreenModel(searching: fake, unavailableReason: nil, library: library,
                                      currentJournal: CurrentJournal(store: InMemoryJournalPreferenceStore()),
                                      debounce: .milliseconds(1))
        model.text = "a"
        model.text = "ab"                                   // before the first debounce can end
        await fake.waitForParkedCall(1)
        let asked = await fake.queries
        XCTAssertEqual(asked.first, SearchQuery(text: "ab"), "typing alone never reached the index")
        let released = await fake.release([hit(liveID, "ab")])
        XCTAssertTrue(released)
        await waitForResults(model, count: 1)
        XCTAssertEqual(model.results.map(\.id), [liveID])
        let calls = await fake.calls
        XCTAssertEqual(calls, 1, "the replaced keystroke must not be searched as well")
    }

    // Positive control: the fixture CAN paint a result. Without it the next test proves nothing.
    func testAQueryThatIsNotSupersededPublishesItsHit() async throws {
        let library = try await scannedLibrary()
        let fake = FakeSearching()
        let model = model(searching: fake, library: library)
        model.text = "ab"
        XCTAssertTrue(model.hasQuery)
        await answerRefresh(model, fake, call: 1, with: [hit(liveID, "ab")])
        XCTAssertEqual(model.results.map(\.id), [liveID])
        XCTAssertTrue(model.hasQuery)
    }

    /// Review focus 1: type, then delete to empty while the query is still in the index.
    /// The list clears at once and the late answer does not repaint it.
    func testResultsForASupersededQueryAreDropped() async throws {
        let library = try await scannedLibrary()
        let fake = FakeSearching()
        let model = model(searching: fake, library: library)
        model.text = "ab"
        // One result on screen first, so "cleared at once" has something to clear.
        await answerRefresh(model, fake, call: 1, with: [hit(liveID, "ab")])
        XCTAssertEqual(model.results.map(\.id), [liveID])

        let running = Task { await model.refresh() }
        await fake.waitForParkedCall(2)                     // the query is IN the index, parked
        model.text = ""                                     // superseded while in flight
        XCTAssertTrue(model.results.isEmpty); XCTAssertFalse(model.hasQuery)   // cleared at once
        let released = await fake.release([hit(liveID, "ab")])
        XCTAssertTrue(released); await running.value
        XCTAssertTrue(model.results.isEmpty)                // the late hit did not repaint
        XCTAssertFalse(model.hasQuery)
    }

    func testASearchThatThrowsShowsNoResults() async throws {
        let library = try await scannedLibrary()
        let fake = FakeSearching()
        let model = model(searching: fake, library: library)
        model.text = "ab"
        await answerRefresh(model, fake, call: 1, with: [hit(liveID, "ab")])
        XCTAssertEqual(model.results.map(\.id), [liveID])

        let running = Task { await model.refresh() }
        await fake.waitForParkedCall(2)
        let failed = await fake.fail()
        XCTAssertTrue(failed); await running.value
        XCTAssertTrue(model.results.isEmpty, "a failed query must not leave the previous answer on screen")
        XCTAssertTrue(model.hasQuery)
        XCTAssertNil(model.unavailableReason, "one failed query is not an unavailable index")
    }

    // MARK: Availability

    func testAnUnavailableIndexReportsItsReasonAndNeverHasResults() async throws {
        let library = try await scannedLibrary()
        let model = model(searching: nil, unavailableReason: "disk full", library: library)
        model.text = "alpha"; await model.refresh()
        XCTAssertEqual(model.unavailableReason, "disk full"); XCTAssertTrue(model.results.isEmpty)
        XCTAssertTrue(model.hasQuery)
    }

    /// The index opens off the main actor after launch, so the screen can be typed into
    /// before it exists. Nothing is shown and nothing is wrong until it arrives; then the
    /// text already in the field is searched without another keystroke.
    func testTextTypedBeforeConnectIsSearchedOnceConnected() async throws {
        let library = try await scannedLibrary()
        let model = model(searching: nil, library: library)
        model.text = "ab"
        await model.refresh()
        XCTAssertTrue(model.results.isEmpty); XCTAssertTrue(model.hasQuery)
        XCTAssertNil(model.unavailableReason, "not connected yet is not unavailable")

        let fake = FakeSearching()
        model.connect(searching: fake, unavailableReason: nil)
        await fake.waitForParkedCall(1)                     // connect ran the query on its own
        let asked = await fake.queries
        XCTAssertEqual(asked, [SearchQuery(text: "ab")])
        let released = await fake.release([hit(liveID, "ab")])
        XCTAssertTrue(released)
        await waitForResults(model, count: 1)
        XCTAssertEqual(model.results.map(\.id), [liveID])
    }

    /// Typed during "Indexing…": the first answer is empty because the entry is not in the
    /// index yet. When the pass that indexes it ends, the visible query runs again.
    func testAFinishedReconcileRerunsTheCurrentQuery() async throws {
        let library = try await scannedLibrary()
        let fake = FakeSearching()
        let model = model(searching: fake, library: library)
        let reconciler = FakeReconciler()
        await reconciler.willReport(.init(indexed: 1))
        library.attach(searchReconciler: reconciler)        // a scan has published: a pass starts
        await reconciler.waitForParkedCall(1)

        model.text = "ab"
        await answerRefresh(model, fake, call: 1, with: [])
        XCTAssertTrue(model.results.isEmpty)

        let finished = await reconciler.release()           // the pass ends having indexed one entry
        XCTAssertTrue(finished)
        await waitUntilIdle(library)
        XCTAssertEqual(library.searchIndexRevision, 1, "fixture sanity: the revision moved")
        await fake.waitForParkedCall(2)                     // the model re-queried on its own
        let released = await fake.release([hit(liveID, "ab")])
        XCTAssertTrue(released, "no second query: the model did not follow the index")
        await waitForResults(model, count: 1)
        XCTAssertEqual(model.results.map(\.id), [liveID])
    }
}
