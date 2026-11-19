import GRDB
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

    private func writeCapture(_ id: String, capturedAt created: Date, capturesRoot: URL) throws {
        let dir = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: id)
        let segs = SegmentLayout.segmentsDirectory(captureDirectory: dir)
        try FileManager.default.createDirectory(at: segs, withIntermediateDirectories: true)
        try Data(count: 48_000 * 4).write(to: SegmentLayout.pcmURL(segmentsDirectory: segs, index: 0))
        let format = AudioFormatDescriptor(sampleRate: 48_000, channels: 1,
                                           commonFormat: .pcmFormatFloat32,
                                           interleaved: false, bytesPerFrame: 4)
        let manifest = Manifest(captureID: id, createdAt: created, state: .captured,
                                stateSeq: 1, stateUpdatedAt: created, format: format)
        try CaptureCoding.encoder().encode(manifest)
            .write(to: SegmentLayout.manifestURL(captureDirectory: dir))
    }

    /// A library over its own temporary container, whose one scan has published `liveID`
    /// and whatever `others` names.
    private func scannedLibrary(liveCapturedAt: Date = Date(timeIntervalSince1970: 1_000),
                                also others: [(id: String, capturedAt: Date)] = []) async throws -> LibraryScreenModel {
        let containerRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SearchScreenModel-\(UUID().uuidString)", isDirectory: true)
        let capturesRoot = AppContainer.capturesRoot(containerRoot: containerRoot)
        try FileManager.default.createDirectory(at: capturesRoot, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: containerRoot) }
        try writeCapture(liveID, capturedAt: liveCapturedAt, capturesRoot: capturesRoot)
        for other in others {
            try writeCapture(other.id, capturedAt: other.capturedAt, capturesRoot: capturesRoot)
        }
        let library = LibraryScreenModel(capturesRoot: capturesRoot, journalsContainerRoot: containerRoot)
        _ = await library.rescan()
        XCTAssertEqual(Set(library.allEntries.map(\.captureID)), Set([liveID] + others.map(\.id)), "fixture sanity")
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

    /// Types "ab" and answers it with a hit for each of `ids`: the one query the re-join
    /// tests allow. Each of them ends by asserting the index was asked exactly once.
    private func paint(_ model: SearchScreenModel, _ fake: FakeSearching, _ ids: [String]) async {
        model.text = "ab"
        await answerRefresh(model, fake, call: 1, with: ids.map { hit($0, "ab") })
    }

    private func assertAskedOnce(_ fake: FakeSearching, file: StaticString = #filePath, line: UInt = #line) async {
        let calls = await fake.calls
        XCTAssertEqual(calls, 1, "the list must follow the library and the filters without asking the index again",
                       file: file, line: line)
    }

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
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

    // MARK: Journal chip title

    /// What the journal chip says for each scope. Two journals, so the title is the scoped
    /// journal's own name and not the first one's.
    func testTheJournalChipTitleNamesTheScope() {
        let first = Journal(id: ULID.make(), name: "1987", createdAt: now)
        let second = Journal(id: ULID.make(), name: "France", createdAt: now.addingTimeInterval(1))
        let journals = [first, second]
        XCTAssertEqual(SearchScreenModel.journalScopeTitle(.all, in: journals), "All journals")
        XCTAssertEqual(SearchScreenModel.journalScopeTitle(.journal(second.id), in: journals), "France")
        XCTAssertEqual(SearchScreenModel.journalScopeTitle(.journal(first.id), in: journals), "1987")
        XCTAssertEqual(SearchScreenModel.journalScopeTitle(.unfiled, in: journals), "Unfiled")
        // A journal that has left the registry (deleted, or a sync not landed yet) still
        // scopes the list by its id; the chip says so rather than naming another journal.
        XCTAssertEqual(SearchScreenModel.journalScopeTitle(.journal(ULID.make()), in: journals), "Unknown journal")
    }

    // MARK: Scope seeding

    /// Two published journals, the SECOND current (one cannot tell "the current journal" from
    /// "the first journal"), and a real router wired to the model the way `AppServices` wires
    /// it, sitting on All Entries.
    private func routedSearch() async throws
        -> (library: LibraryScreenModel, first: Journal, second: Journal, current: CurrentJournal,
            router: AppRouter, model: SearchScreenModel) {
        let library = try await scannedLibrary()
        let first = try await library.journalStore.create(name: "1987")
        let second = try await library.journalStore.create(name: "France")
        _ = await library.rescan()
        XCTAssertEqual(library.journals.count, 2, "fixture sanity")
        let current = CurrentJournal(store: InMemoryJournalPreferenceStore(
            values: [CurrentJournal.defaultsKey: second.id]))
        let model = model(searching: FakeSearching(), library: library, current: current)
        let router = AppRouter()
        AppServices.wireSearchArrival(router: router, searchScreen: model)
        router.select(.allEntries)
        return (library, first, second, current, router, model)
    }

    /// Ruling 34: the chip defaults to the last-viewed journal on EVERY arrival, not just the
    /// first one in the process. A Mac runs for days; Search opened from journal A must not
    /// stay scoped to whatever journal the first visit saw.
    func testEachArrivalSeedsTheScopeFromTheCurrentJournal() async throws {
        let (_, first, second, current, router, model) = try await routedSearch()
        XCTAssertEqual(model.journalScope, .all)
        router.select(.search)
        XCTAssertEqual(model.journalScope, .journal(second.id))

        router.select(.journal(first.id))         // the owner looks at the other journal
        current.select(first)                     // which capture adopts (#183 rule 1)
        router.select(.search)                    // and arrives at Search again
        XCTAssertEqual(model.journalScope, .journal(first.id), "the second arrival kept the first visit's scope")
    }

    /// Back from an opened result is not an arrival: the place never left `.search`, so the
    /// visit's scope (even one the owner picked), text and results all stay.
    func testBackFromAnOpenedResultKeepsTheVisitsScope() async throws {
        let (_, first, second, current, router, model) = try await routedSearch()
        router.select(.search)
        XCTAssertEqual(model.journalScope, .journal(second.id))
        model.journalScope = .all                 // the owner widens the search
        model.text = "ab"
        current.select(first)                     // the current journal moves meanwhile

        router.detailPath.append(.entry(liveID))  // opens a result
        router.goBack()                           // and comes back
        XCTAssertEqual(router.place, .search, "fixture sanity")
        XCTAssertEqual(model.journalScope, .all, "Back from a result undid the owner's scope")
        XCTAssertEqual(model.text, "ab")
    }

    /// A scope the owner picks lasts for that visit only. With no current journal the next
    /// arrival starts on All journals, the screen's own default.
    func testAPickedScopeLastsOneVisit() async throws {
        let (_, _, second, current, router, model) = try await routedSearch()
        router.select(.search)
        model.journalScope = .unfiled             // the owner's pick
        router.select(.trash)
        router.select(.search)
        XCTAssertEqual(model.journalScope, .journal(second.id), "a pick outlived its visit")

        model.journalScope = .unfiled
        current.select(nil as String?)            // no current journal
        router.select(.about)
        router.select(.search)
        XCTAssertEqual(model.journalScope, .all, "with nothing to seed from, the pick still outlived its visit")
    }

    /// A library whose two journals are on disk but not yet published (no rescan since they
    /// were made), and a current journal pointing at the second.
    private func journalsNotYetPublished() async throws -> (LibraryScreenModel, Journal, CurrentJournal) {
        let library = try await scannedLibrary()
        _ = try await library.journalStore.create(name: "1987")
        let second = try await library.journalStore.create(name: "France")
        XCTAssertTrue(library.journals.isEmpty, "fixture sanity: on disk, not yet published")
        let current = CurrentJournal(store: InMemoryJournalPreferenceStore(
            values: [CurrentJournal.defaultsKey: second.id]))
        return (library, second, current)
    }

    /// The field takes focus once per arrival. The screen's `onAppear` asks on every
    /// appearance, and Back from an opened result is one; there the keyboard would cover the
    /// results he came back to.
    func testTheFieldIsFocusedOncePerArrival() async throws {
        let (_, _, _, _, router, model) = try await routedSearch()
        XCTAssertFalse(model.takeFieldFocusRequest(), "no arrival yet")
        router.select(.search)
        XCTAssertTrue(model.takeFieldFocusRequest(), "arriving focuses the field")

        router.detailPath.append(.entry(liveID))  // opens a result
        router.goBack()                           // and comes back: the screen appears again
        XCTAssertFalse(model.takeFieldFocusRequest(), "Back from a result focused the field")

        router.select(.allEntries)
        router.select(.search)
        XCTAssertTrue(model.takeFieldFocusRequest(), "the next arrival focuses the field again")
        XCTAssertFalse(model.takeFieldFocusRequest(), "one focus per arrival")
    }

    /// The owner can arrive before the launch scan has published the journals. The visit's
    /// seed waits for them, and is spent when they arrive — once per visit.
    func testTheScopeSeedWaitsForTheJournals() async throws {
        let (library, second, current) = try await journalsNotYetPublished()
        let model = model(searching: FakeSearching(), library: library, current: current)
        model.arrived()
        XCTAssertEqual(model.journalScope, .all, "nothing to resolve against yet")

        _ = await library.rescan()                          // the journals arrive
        XCTAssertEqual(library.journals.count, 2, "fixture sanity")
        for _ in 0..<400 where model.journalScope == .all { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(model.journalScope, .journal(second.id), "the seed was spent before the journals arrived")

        model.journalScope = .all                           // the owner widens the search
        _ = try await library.journalStore.create(name: "Later")
        _ = await library.rescan()                          // and the journals change again
        XCTAssertEqual(library.journals.count, 3, "fixture sanity")
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(model.journalScope, .all, "the visit's seed is spent once")
    }

    /// A scope the owner picks while the seed waits is his: the journals arriving later do
    /// not replace it.
    func testAScopeChosenBeforeTheJournalsArriveIsKept() async throws {
        let (library, _, current) = try await journalsNotYetPublished()
        let model = model(searching: FakeSearching(), library: library, current: current)
        model.arrived()
        model.journalScope = .unfiled
        _ = await library.rescan()
        XCTAssertEqual(library.journals.count, 2, "fixture sanity")
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(model.journalScope, .unfiled, "the seed overrode the owner's choice")
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
        let cancelled = await fake.arrivedCancelled
        XCTAssertEqual(cancelled, [false], "the debounced query cancelled itself on its way in")
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

    /// An explicit query takes the pending debounced one's place: the same text is not
    /// searched twice.
    func testRefreshReplacesThePendingDebouncedQuery() async throws {
        let library = try await scannedLibrary()
        let fake = FakeSearching()
        let model = SearchScreenModel(searching: fake, unavailableReason: nil, library: library,
                                      currentJournal: CurrentJournal(store: InMemoryJournalPreferenceStore()),
                                      debounce: .milliseconds(300))
        model.text = "ab"                                   // schedules the debounced query
        await answerRefresh(model, fake, call: 1, with: [hit(liveID, "ab")])
        XCTAssertEqual(model.results.map(\.id), [liveID])
        await fake.waitForParkedCall(2)                     // ~2 s: well past the debounce
        let calls = await fake.calls
        XCTAssertEqual(calls, 1, "the debounced query ran as well")
        await fake.release([])                              // unpark a second call, if there was one
    }

    /// The failure line names the error and its numeric code, never what the error says:
    /// an FTS5 syntax error's message quotes the query.
    func testAFailedSearchIsLoggedByTypeAndCodeOnly() {
        let database = DatabaseError(resultCode: .SQLITE_IOERR_READ,
                                     message: "fts5: syntax error near \"private words\"",
                                     sql: "SELECT captureID FROM entry_text WHERE entry_text MATCH ?",
                                     arguments: ["private words"])
        XCTAssertEqual(SearchScreenModel.failureSummary(database), "DatabaseError, code 266",
                       "the extended result code, not the primary one")
        let cocoa = NSError(domain: NSCocoaErrorDomain, code: 256,
                            userInfo: [NSLocalizedDescriptionKey: "private words"])
        XCTAssertEqual(SearchScreenModel.failureSummary(cocoa), "NSError, code 256")
    }

    // MARK: Answered

    /// "No matches" is an answer, so it waits for one. Between a keystroke and its answer
    /// the list is empty and nothing has been answered; the next keystroke and an emptied
    /// field both take the answer back.
    func testNoMatchesWaitsForTheAnswerToTheCurrentText() async throws {
        let library = try await scannedLibrary()
        let fake = FakeSearching()
        let model = model(searching: fake, library: library)
        model.text = "ab"
        XCTAssertTrue(model.hasQuery && model.results.isEmpty, "fixture sanity: a query and an empty list")
        XCTAssertFalse(model.hasAnswer); XCTAssertFalse(model.showsNoMatches)

        let running = Task { await model.refresh() }
        await fake.waitForParkedCall(1)                     // the query is IN the index, parked
        XCTAssertFalse(model.hasAnswer, "asked is not answered")
        XCTAssertFalse(model.showsNoMatches, "No matches before the index has answered")
        let released = await fake.release([])
        XCTAssertTrue(released); await running.value
        XCTAssertTrue(model.hasAnswer)
        XCTAssertTrue(model.showsNoMatches, "the index answered with nothing")

        model.text = "abc"                                  // the next keystroke
        XCTAssertFalse(model.hasAnswer, "an answer to \"ab\" is not an answer to \"abc\"")
        XCTAssertFalse(model.showsNoMatches)
        await answerRefresh(model, fake, call: 2, with: [])
        XCTAssertTrue(model.showsNoMatches)

        model.text = ""                                     // deleted to empty
        XCTAssertFalse(model.hasAnswer); XCTAssertFalse(model.showsNoMatches)
    }

    /// An answer that arrives after the text moved on answered an earlier question.
    func testASupersededAnswerDoesNotCountAsAnswered() async throws {
        let library = try await scannedLibrary()
        let fake = FakeSearching()
        let model = model(searching: fake, library: library)
        model.text = "ab"
        let running = Task { await model.refresh() }
        await fake.waitForParkedCall(1)
        model.text = "abc"                                  // superseded while in flight
        let released = await fake.release([])
        XCTAssertTrue(released); await running.value
        XCTAssertFalse(model.hasAnswer, "the late answer for \"ab\" was kept for \"abc\"")
        XCTAssertFalse(model.showsNoMatches)
    }

    /// A query that threw found nothing out: the list empties, but it is not "No matches".
    func testAFailedQueryIsNotNoMatches() async throws {
        let library = try await scannedLibrary()
        let fake = FakeSearching()
        let model = model(searching: fake, library: library)
        model.text = "ab"
        await answerRefresh(model, fake, call: 1, with: [])
        XCTAssertTrue(model.showsNoMatches, "fixture sanity: answered with nothing")

        let running = Task { await model.refresh() }
        await fake.waitForParkedCall(2)
        let failed = await fake.fail()
        XCTAssertTrue(failed); await running.value
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertFalse(model.hasAnswer, "a failed query is not an answer")
        XCTAssertFalse(model.showsNoMatches)
    }

    /// Runs one explicit query on `model` and makes the index throw for it.
    private func failRefresh(_ model: SearchScreenModel, _ fake: FakeSearching, call: Int) async {
        let running = Task { await model.refresh() }
        await fake.waitForParkedCall(call)
        let failed = await fake.fail()
        XCTAssertTrue(failed, "query \(call) never reached the index")
        await running.value
    }

    /// A failed query says so, for the text it was asked for, until the next change of
    /// text, a successful answer, or a connect. A failure that arrives late says nothing.
    func testAFailedQueryIsReportedUntilTheTextChangesAnAnswerLandsOrTheIndexConnects() async throws {
        let library = try await scannedLibrary()
        let fake = FakeSearching()
        let model = model(searching: fake, library: library)
        model.text = "ab"
        await answerRefresh(model, fake, call: 1, with: [])
        XCTAssertFalse(model.queryFailed, "fixture sanity: answered")

        await failRefresh(model, fake, call: 2)
        XCTAssertTrue(model.queryFailed, "a failed query must say so")
        XCTAssertFalse(model.showsNoMatches, "a failure is not No matches")
        model.text = "abc"                                  // the next keystroke
        XCTAssertFalse(model.queryFailed, "the failure belonged to the previous text")

        await failRefresh(model, fake, call: 3)
        XCTAssertTrue(model.queryFailed)
        await answerRefresh(model, fake, call: 4, with: [hit(liveID, "abc")])
        XCTAssertFalse(model.queryFailed, "a successful answer clears the failure")
        XCTAssertEqual(model.results.map(\.id), [liveID])

        await failRefresh(model, fake, call: 5)
        XCTAssertTrue(model.queryFailed)
        model.connect(searching: fake, unavailableReason: nil)
        XCTAssertFalse(model.queryFailed, "connect clears the failure")
        await fake.waitForParkedCall(6)                     // connect re-ran the query
        let released = await fake.release([])
        XCTAssertTrue(released)
        for _ in 0..<400 where !model.hasAnswer { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(model.hasAnswer, "fixture sanity: connect's query was answered")

        let late = Task { await model.refresh() }
        await fake.waitForParkedCall(7)
        model.text = "abcd"                                 // superseded while in flight
        let failedLate = await fake.fail()
        XCTAssertTrue(failedLate); await late.value
        XCTAssertFalse(model.queryFailed, "a late failure was reported against newer text")
    }

    /// No index, no answer: not connected yet, unavailable, or gone after answering.
    func testWithoutAnIndexNothingIsAnswered() async throws {
        let library = try await scannedLibrary()
        let notYet = model(searching: nil, library: library)
        notYet.text = "ab"; await notYet.refresh()
        XCTAssertFalse(notYet.hasAnswer, "not connected yet"); XCTAssertFalse(notYet.showsNoMatches)

        let unavailable = model(searching: nil, unavailableReason: "disk full", library: library)
        unavailable.text = "ab"; await unavailable.refresh()
        XCTAssertFalse(unavailable.hasAnswer, "unavailable"); XCTAssertFalse(unavailable.showsNoMatches)

        let fake = FakeSearching()
        let lost = model(searching: fake, library: library)
        lost.text = "ab"
        await answerRefresh(lost, fake, call: 1, with: [])
        XCTAssertTrue(lost.showsNoMatches, "fixture sanity: answered with nothing")
        lost.connect(searching: nil, unavailableReason: "disk full")
        XCTAssertFalse(lost.hasAnswer, "the index went away"); XCTAssertFalse(lost.showsNoMatches)
    }

    // MARK: Availability

    func testAnUnavailableIndexReportsItsReasonAndNeverHasResults() async throws {
        let library = try await scannedLibrary()
        let model = model(searching: nil, unavailableReason: "disk full", library: library)
        model.text = "alpha"; await model.refresh()
        XCTAssertEqual(model.unavailableReason, "disk full"); XCTAssertTrue(model.results.isEmpty)
        XCTAssertTrue(model.hasQuery)
    }

    /// `refresh` and `connect` share one rule: an index that comes with a reason is
    /// unavailable, and is never asked.
    func testAnIndexThatComesWithAReasonIsNeverAsked() async throws {
        let library = try await scannedLibrary()
        let fake = FakeSearching()
        let model = model(searching: fake, unavailableReason: "disk full", library: library)
        model.text = "ab"
        let running = Task { await model.refresh() }
        await fake.waitForParkedCall(1)                     // ~2 s; nothing should arrive
        let calls = await fake.calls
        XCTAssertEqual(calls, 0, "refresh asked an index that connect treats as unavailable")
        await fake.release([hit(liveID, "ab")])             // unpark it, if it was asked
        await running.value
        XCTAssertTrue(model.results.isEmpty); XCTAssertFalse(model.hasAnswer)
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
    // MARK: Results follow the library and the filters, with no query

    func testATrashedResultLeavesTheListWithoutAQuery() async throws {
        let library = try await scannedLibrary()
        let fake = FakeSearching()
        let model = model(searching: fake, library: library)
        await paint(model, fake, [liveID])
        XCTAssertEqual(model.results.map(\.id), [liveID])

        let trashed = await library.trashEntry(liveID)
        XCTAssertTrue(trashed)
        await waitForResults(model, count: 0)
        XCTAssertTrue(model.results.isEmpty, "a trashed entry is still listed")
        await assertAskedOnce(fake)
    }

    /// The index keeps a trashed entry, so the answer on hand already names it. Restoring
    /// it is enough to list it.
    func testARestoredEntryAppearsWithoutAQuery() async throws {
        let library = try await scannedLibrary()
        let trashed = await library.trashEntry(liveID)
        XCTAssertTrue(trashed)
        XCTAssertTrue(library.allEntries.isEmpty, "fixture sanity")
        let fake = FakeSearching()
        let model = model(searching: fake, library: library)
        await paint(model, fake, [liveID])
        XCTAssertTrue(model.results.isEmpty, "fixture sanity: an entry in the trash is not listed")

        let restored = await library.restoreEntry(liveID)
        XCTAssertTrue(restored)
        await waitForResults(model, count: 1)
        XCTAssertEqual(model.results.map(\.id), [liveID])
        await assertAskedOnce(fake)
    }

    /// The row is the library's CURRENT row for the entry, not the one that was there when
    /// the index answered.
    func testAMovedEntryIsListedWithItsNewJournal() async throws {
        let library = try await scannedLibrary()
        let journal = try await library.journalStore.create(name: "France")
        let fake = FakeSearching()
        let model = model(searching: fake, library: library)
        await paint(model, fake, [liveID])
        XCTAssertEqual(model.results.map(\.id), [liveID])
        XCTAssertNil(model.results.first?.item.journalID, "fixture sanity: unfiled to begin with")

        let moved = await library.moveEntry(liveID, toJournal: journal.id)
        XCTAssertTrue(moved)
        for _ in 0..<400 where model.results.first?.item.journalID != journal.id {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(model.results.map(\.id), [liveID])
        XCTAssertEqual(model.results.first?.item.journalID, journal.id)
        XCTAssertEqual(model.results.first?.item.journal?.name, "France")
        await assertAskedOnce(fake)
    }

    func testChangingTheJournalScopeFiltersTheHitsOnHand() async throws {
        let other = ULID.make()
        let library = try await scannedLibrary(also: [(other, Date(timeIntervalSince1970: 2_000))])
        let first = try await library.journalStore.create(name: "1987")
        let second = try await library.journalStore.create(name: "France")
        var moved = await library.moveEntry(liveID, toJournal: first.id)
        XCTAssertTrue(moved)
        moved = await library.moveEntry(other, toJournal: second.id)
        XCTAssertTrue(moved)
        let fake = FakeSearching()
        let model = model(searching: fake, library: library)
        await paint(model, fake, [liveID, other])
        XCTAssertEqual(model.results.map(\.id), [other, liveID])

        // No await between a change and its assertion: the setter itself re-joins.
        model.journalScope = .journal(first.id)
        XCTAssertEqual(model.results.map(\.id), [liveID])
        model.journalScope = .journal(second.id)
        XCTAssertEqual(model.results.map(\.id), [other])
        model.journalScope = .unfiled
        XCTAssertTrue(model.results.isEmpty)
        model.journalScope = .all
        XCTAssertEqual(model.results.map(\.id), [other, liveID])
        await assertAskedOnce(fake)
    }

    func testChangingTheDateFilterFiltersTheHitsOnHand() async throws {
        let later = ULID.make()
        let library = try await scannedLibrary(liveCapturedAt: day(2020, 6, 1), also: [(later, day(2024, 6, 1))])
        let fake = FakeSearching()
        let model = model(searching: fake, library: library)
        await paint(model, fake, [liveID, later])
        XCTAssertEqual(model.results.map(\.id), [later, liveID])

        model.dateFilter = .custom(from: PartialDate(year: 2023), to: nil)
        XCTAssertEqual(model.results.map(\.id), [later])
        model.dateFilter = .custom(from: nil, to: PartialDate(year: 2021))
        XCTAssertEqual(model.results.map(\.id), [liveID])
        model.dateFilter = .custom(from: PartialDate(year: 2021), to: PartialDate(year: 2022))
        XCTAssertTrue(model.results.isEmpty)
        model.dateFilter = .anyTime
        XCTAssertEqual(model.results.map(\.id), [later, liveID])
        await assertAskedOnce(fake)
    }

    /// A real change to the library's entries (a second capture appears) that leaves
    /// `liveID` live and matching, then the model's library observation gets its turn on
    /// the main actor. What is asserted after this must hold at every instant, so there is
    /// no event to wait for; the yields only make sure a re-join, were one coming, has
    /// happened.
    private func changeTheLibrary(_ library: LibraryScreenModel) async throws {
        let before = library.allEntries.count
        try writeCapture(ULID.make(), capturedAt: Date(timeIntervalSince1970: 3_000),
                         capturesRoot: library.capturesRoot)
        _ = await library.rescan()
        XCTAssertEqual(library.allEntries.count, before + 1, "fixture sanity: the library changed")
        for _ in 0..<10 { await Task.yield() }
    }

    /// Review focus 1 from the other side. Deleting the text empties the list; the hits
    /// behind it must go too, or the next filter or library change joins them back under an
    /// empty field.
    func testAClearedListIsNotRepaintedByAFilterOrLibraryChange() async throws {
        let library = try await scannedLibrary()
        let fake = FakeSearching()
        let model = model(searching: fake, library: library)
        await paint(model, fake, [liveID])
        XCTAssertEqual(model.results.map(\.id), [liveID])

        model.text = ""
        XCTAssertTrue(model.results.isEmpty)
        try await changeTheLibrary(library)
        XCTAssertTrue(model.results.isEmpty, "a library change repainted a cleared list")
        model.journalScope = .unfiled                       // the entry is unfiled: it would match
        XCTAssertTrue(model.results.isEmpty, "a scope change repainted a cleared list")
        model.dateFilter = .custom(from: PartialDate(year: 1960), to: nil)
        XCTAssertTrue(model.results.isEmpty, "a date change repainted a cleared list")
        await assertAskedOnce(fake)
    }

    /// Cannot happen today (the index is connected once), but the states allow it: an index
    /// that goes away takes its answers with it, at once.
    func testConnectingAsUnavailableClearsTheResults() async throws {
        let library = try await scannedLibrary()
        let fake = FakeSearching()
        let model = model(searching: fake, library: library)
        await paint(model, fake, [liveID])
        XCTAssertEqual(model.results.map(\.id), [liveID])

        model.connect(searching: nil, unavailableReason: "disk full")
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertEqual(model.unavailableReason, "disk full")
        try await changeTheLibrary(library)
        XCTAssertTrue(model.results.isEmpty, "a library change repainted an unavailable index's answer")
        model.journalScope = .unfiled                       // the entry is unfiled: it would match
        XCTAssertTrue(model.results.isEmpty, "a scope change repainted an unavailable index's answer")
        await assertAskedOnce(fake)
    }
}
