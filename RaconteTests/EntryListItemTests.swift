import XCTest
@testable import Raconte

/// M3 T2, pure half: dates, order, filters and the snippet. No filesystem — every rule
/// the library screens depend on is decidable from values alone.
final class EntryListItemTests: XCTestCase {

    private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

    private func item(_ id: String,
                      capturedAt: Double,
                      journalID: String? = nil,
                      originalDate: PartialDate? = nil,
                      trashedAt: Double? = nil,
                      journal: Journal? = nil,
                      snippet: String? = nil,
                      transcript: EntryTranscriptState = .absent,
                      degradations: EntryDegradation = []) -> EntryListItem {
        EntryListItem(
            captureID: id,
            capturedAt: date(capturedAt),
            durationSeconds: 1,
            metadata: EntryMetadata(journalID: journalID,
                                    originalDate: originalDate,
                                    trashedAt: trashedAt.map(date)),
            journal: journal,
            snippet: snippet,
            transcript: transcript,
            degradations: degradations)
    }

    // MARK: effectiveDate

    func testEffectiveDateIsCapturedAtWhenNotBackdated() {
        let entry = item("A", capturedAt: 1_000)
        XCTAssertEqual(entry.effectiveDate, date(1_000))
        XCTAssertNil(entry.originalDate)
        XCTAssertFalse(entry.isBackdated)
    }

    func testEffectiveDateIsTheBackdateWhenSet() {
        let backdate = PartialDate(year: 1970, month: 1, day: 1)
        let entry = item("A", capturedAt: 1_000, originalDate: backdate)
        XCTAssertEqual(entry.effectiveDate, backdate.anchorDate(calendar: .gregorianCurrent))
        XCTAssertEqual(entry.capturedAt, date(1_000), "capturedAt is never rewritten by a backdate")
        XCTAssertTrue(entry.isBackdated)
    }

    /// The rule is defined once, in `EntryMetadata`. This pins the item to it so the two
    /// cannot drift into disagreeing about what a library row is sorted by.
    func testEffectiveDateAgreesWithEntryMetadata() {
        for original in [nil, PartialDate(year: 1970, month: 1, day: 1),
                          PartialDate(year: 1987, month: 6)] as [PartialDate?] {
            let metadata = EntryMetadata(originalDate: original)
            let entry = EntryListItem(captureID: "A", capturedAt: date(1_000), metadata: metadata)
            XCTAssertEqual(entry.effectiveDate, metadata.effectiveDate(capturedAt: date(1_000)))
        }
    }

    /// A backdate whose anchor happens to equal the capture instant is still a backdate.
    /// The sidecar keeps them distinguishable and so must the item.
    func testBackdateEqualToCapturedAtIsStillABackdate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let noon = calendar.date(from: DateComponents(year: 1998, month: 3, day: 4, hour: 12))!
        let entry = EntryListItem(captureID: "A", capturedAt: noon,
                                  metadata: EntryMetadata(originalDate: PartialDate(year: 1998, month: 3, day: 4)))
        XCTAssertTrue(entry.isBackdated)
        XCTAssertEqual(entry.effectiveDate, entry.capturedAt)
    }

    // MARK: Precision

    func testOriginalDatePrecisionDefaultsToDay() {
        let entry = item("A", capturedAt: 1_000, originalDate: PartialDate(year: 1970, month: 1, day: 1))
        XCTAssertEqual(entry.originalDatePrecision, .day)
    }

    func testOriginalDatePrecisionPassesThroughFromMetadata() {
        let metadata = EntryMetadata(originalDate: PartialDate(year: 1970))
        let entry = EntryListItem(captureID: "A", capturedAt: date(1_000), metadata: metadata)
        XCTAssertEqual(entry.originalDatePrecision, .year)
    }

    // MARK: Sorting

    func testSortsByEffectiveDateDescendingNotByCaptureTime() {
        // The 1900 entry was recorded most recently and must sort last.
        let recent = item("C", capturedAt: 3_000)
        let backdated = item("D", capturedAt: 4_000, originalDate: PartialDate(year: 1900, month: 1, day: 1))
        let older = item("A", capturedAt: 1_000)
        let sorted = EntryListItem.sortedByEffectiveDate([older, backdated, recent])
        XCTAssertEqual(sorted.map(\.captureID), ["C", "A", "D"])
    }

    func testEqualEffectiveDatesBreakTiesOnCaptureIDDescending() {
        let shared = PartialDate(year: 1980, month: 5, day: 1)
        let a = item("01AAA", capturedAt: 9_000, originalDate: shared)
        let b = item("01BBB", capturedAt: 1, originalDate: shared)
        let c = item("01CCC", capturedAt: 5, originalDate: shared)
        XCTAssertEqual(EntryListItem.sortedByEffectiveDate([a, b, c]).map(\.captureID),
                       ["01CCC", "01BBB", "01AAA"])
        // Total order, so the result does not depend on input order.
        XCTAssertEqual(EntryListItem.sortedByEffectiveDate([c, a, b]).map(\.captureID),
                       ["01CCC", "01BBB", "01AAA"])
    }

    // MARK: Filtering — trash

    func testDefaultFilterExcludesTrashed() {
        let live = item("A", capturedAt: 100)
        let trashed = item("B", capturedAt: 200, trashedAt: 300)
        XCTAssertEqual(EntryListFilter.default.apply(to: [live, trashed]).map(\.captureID), ["A"])
    }

    func testTrashedOnlyShowsOnlyTombstoned() {
        let live = item("A", capturedAt: 100)
        let trashed = item("B", capturedAt: 200, trashedAt: 300)
        let filter = EntryListFilter(trash: .trashedOnly)
        XCTAssertEqual(filter.apply(to: [live, trashed]).map(\.captureID), ["B"])
    }

    func testAllScopeShowsBoth() {
        let live = item("A", capturedAt: 100)
        let trashed = item("B", capturedAt: 200, trashedAt: 300)
        let filter = EntryListFilter(trash: .all)
        XCTAssertEqual(Set(filter.apply(to: [live, trashed]).map(\.captureID)), ["A", "B"])
    }

    /// An entry whose `entry.json` did not decode has an *unknown* trash state. It shows
    /// in the library and stays out of the Trash view: a visible entry that might be
    /// deleted is a nuisance; an invisible one looks exactly like data loss.
    func testUnreadableMetadataStaysVisibleInTheLibraryAndOutOfTrash() {
        let degraded = item("A", capturedAt: 100, degradations: [.metadataUnreadable])
        XCTAssertEqual(EntryListFilter.default.apply(to: [degraded]).map(\.captureID), ["A"])
        XCTAssertTrue(EntryListFilter(trash: .trashedOnly).apply(to: [degraded]).isEmpty)
    }

    // MARK: Filtering — journal

    func testJournalScopeFiltersOnTheRawID() {
        let filed = item("A", capturedAt: 100, journalID: "J1")
        let other = item("B", capturedAt: 200, journalID: "J2")
        let unfiled = item("C", capturedAt: 300)
        let items = [filed, other, unfiled]
        XCTAssertEqual(EntryListFilter(journal: .journal("J1")).apply(to: items).map(\.captureID), ["A"])
        XCTAssertEqual(EntryListFilter(journal: .unfiled).apply(to: items).map(\.captureID), ["C"])
        XCTAssertEqual(EntryListFilter(journal: .all).apply(to: items).count, 3)
    }

    /// A dangling reference still belongs to the journal it names. Filtering on the
    /// resolved `Journal` instead would make those entries reachable from no journal
    /// view at all — findable only by scrolling "all".
    func testDanglingJournalStillMatchesItsJournalScopeAndIsNotUnfiled() {
        let dangling = item("A", capturedAt: 100, journalID: "GONE",
                            degradations: [.journalUnresolved])
        XCTAssertTrue(dangling.hasDanglingJournal)
        XCTAssertNil(dangling.journal)
        XCTAssertEqual(EntryListFilter(journal: .journal("GONE")).apply(to: [dangling]).count, 1)
        XCTAssertTrue(EntryListFilter(journal: .unfiled).apply(to: [dangling]).isEmpty)
    }

    func testResolvedJournalIsNotDangling() {
        let journal = Journal(id: "J1", name: "1987 Journal", createdAt: date(0))
        let filed = item("A", capturedAt: 100, journalID: "J1", journal: journal)
        XCTAssertFalse(filed.hasDanglingJournal)
        XCTAssertEqual(filed.journal?.name, "1987 Journal")
    }

    func testUnfiledEntryIsNotDangling() {
        XCTAssertFalse(item("A", capturedAt: 100).hasDanglingJournal)
    }

    func testFilterCombinesJournalAndTrash() {
        let items = [item("A", capturedAt: 100, journalID: "J1"),
                     item("B", capturedAt: 200, journalID: "J1", trashedAt: 1),
                     item("C", capturedAt: 300, journalID: "J2", trashedAt: 1)]
        let filter = EntryListFilter(journal: .journal("J1"), trash: .trashedOnly)
        XCTAssertEqual(filter.apply(to: items).map(\.captureID), ["B"])
    }

    func testFilterAlsoSorts() {
        let items = [item("A", capturedAt: 100), item("B", capturedAt: 300), item("C", capturedAt: 200)]
        XCTAssertEqual(EntryListFilter.default.apply(to: items).map(\.captureID), ["B", "C", "A"])
    }

    // MARK: Snippet

    func testSnippetCollapsesWhitespace() {
        XCTAssertEqual(EntrySnippet.make(from: "  hello   there\nworld \t"), "hello there world")
    }

    func testEmptyTextHasNoSnippet() {
        XCTAssertNil(EntrySnippet.make(from: ""))
        XCTAssertNil(EntrySnippet.make(from: "   \n  "))
    }

    func testSnippetTruncatesAtAWordBoundary() {
        let text = String(repeating: "alpha beta ", count: 40)
        let snippet = try? XCTUnwrap(EntrySnippet.make(from: text, limit: 20))
        XCTAssertEqual(snippet, "alpha beta alpha…")
        XCTAssertFalse(snippet?.contains("  ") ?? true)
    }

    /// One unbroken token longer than the limit still has to be cut somewhere.
    func testSnippetTruncatesAWordThatExceedsTheLimitOnItsOwn() {
        XCTAssertEqual(EntrySnippet.make(from: String(repeating: "x", count: 30), limit: 5), "xxxxx…")
    }

    func testShortTextIsNotTruncated() {
        XCTAssertEqual(EntrySnippet.make(from: "short one", limit: 160), "short one")
    }

    // MARK: hasTranscriptText

    /// A readable-but-empty log is `.present` and still has nothing to show. Collapsing
    /// the two would render a blank snippet row for a capture that transcribed silence.
    func testPresentTranscriptWithNoTextHasNoText() {
        let entry = item("A", capturedAt: 100, snippet: nil, transcript: .present)
        XCTAssertFalse(entry.hasTranscriptText)
        XCTAssertEqual(entry.transcript, .present)
    }

    func testUnreadableTranscriptIsNotAbsent() {
        let entry = item("A", capturedAt: 100, transcript: .unreadable,
                         degradations: [.transcriptUnreadable])
        XCTAssertNotEqual(entry.transcript, .absent)
        XCTAssertFalse(entry.hasTranscriptText)
    }

    // MARK: weekdayText (issue #48) — forwarding to PartialDate, plus the no-backdate case
    // PartialDate itself owns.

    func testWeekdayTextIsNilWithNoBackdate() {
        let entry = item("A", capturedAt: 100)
        XCTAssertNil(entry.weekdayText())
        XCTAssertFalse(entry.isBackdated)
    }

    func testWeekdayTextIsPresentForADayPrecisionBackdate() {
        let entry = item("A", capturedAt: 100,
                         originalDate: PartialDate(year: 1998, month: 3, day: 4))
        XCTAssertNotNil(entry.weekdayText())
    }

    func testWeekdayTextIsNilForCoarserPrecisionBackdates() {
        XCTAssertNil(item("A", capturedAt: 100,
                          originalDate: PartialDate(year: 1998, month: 3)).weekdayText())
        XCTAssertNil(item("A", capturedAt: 100,
                          originalDate: PartialDate(year: 1998)).weekdayText())
    }

    // MARK: monthGroups (Task 11: library month sub-headers within a year section)

    private var utc: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func item(_ captureID: String, year: Int, month: Int, day: Int) -> EntryListItem {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day; comps.timeZone = utc.timeZone
        let date = utc.date(from: comps)!
        return EntryListItem(captureID: captureID, capturedAt: date)
    }

    func testMonthGroupsEmptyInputProducesNoGroups() {
        XCTAssertEqual(EntryListItem.monthGroups(of: [], calendar: utc), [])
    }

    /// Entries spanning two months, already in the descending order the library screen
    /// always hands `monthGroups` (same input-order assumption as `groupedByYear`):
    /// one group per month, in the order encountered, items preserved within each.
    func testMonthGroupsSpanningTwoMonthsProducesOneGroupEach() {
        let items = [
            item("A", year: 2026, month: 7, day: 20),
            item("B", year: 2026, month: 7, day: 3),
            item("C", year: 2026, month: 6, day: 15),
        ]
        let groups = EntryListItem.monthGroups(of: items, calendar: utc)
        XCTAssertEqual(groups.map(\.month), ["July", "June"])
        XCTAssertEqual(groups[0].items.map(\.captureID), ["A", "B"])
        XCTAssertEqual(groups[1].items.map(\.captureID), ["C"])
    }

    /// Non-contiguous input (unsorted) splits into separate groups rather than merging —
    /// mirrors `EntryYearGroupTests.testNonContiguousSameYearSplitsIntoSeparateGroups`.
    func testMonthGroupsNonContiguousSameMonthSplitsIntoSeparateGroups() {
        let items = [
            item("A", year: 2026, month: 7, day: 1),
            item("B", year: 2026, month: 6, day: 1),
            item("C", year: 2026, month: 7, day: 2),
        ]
        let groups = EntryListItem.monthGroups(of: items, calendar: utc)
        XCTAssertEqual(groups.map(\.month), ["July", "June", "July"])
    }

    /// Final-review finding 1: a `.year`-precision backdate has no month of its own —
    /// `PartialDate.anchorDate` fills the absent month with January, and formatting
    /// that anchor would fabricate a "January" header the entry's own row (which reads
    /// "1998", no month) does not claim. It must land in its own nil-header group, not
    /// merge into an adjacent named month nor split one — same contiguous-run rule as
    /// every other key here.
    func testMonthGroupsYearPrecisionEntryProducesNilHeaderNotFabricatedMonth() {
        let items = [
            item("A", year: 2026, month: 7, day: 20),
            item("B", capturedAt: 1_000, originalDate: PartialDate(year: 1998)),
            item("C", year: 2026, month: 6, day: 15),
        ]
        let groups = EntryListItem.monthGroups(of: items, calendar: utc)
        XCTAssertEqual(groups.map(\.month), ["July", nil, "June"])
        XCTAssertEqual(groups[1].items.map(\.captureID), ["B"])
    }

    /// `.yearMonth` precision names a real month — only `.year` (no month at all) must
    /// suppress the header.
    func testMonthGroupsYearMonthPrecisionGetsRealMonthHeader() {
        let backdated = item("A", capturedAt: 1_000, originalDate: PartialDate(year: 1998, month: 3))
        let groups = EntryListItem.monthGroups(of: [backdated], calendar: utc)
        XCTAssertEqual(groups.map(\.month), ["March"])
    }

    // MARK: formattedLibraryRowDate (#125: current-week rows carry the time of day)

    /// The calendar every #125 assertion is made against — Gregorian, pinned to
    /// `America/Los_Angeles`, exactly what `showsCaptureTime` defaults to. Passed
    /// EXPLICITLY in every test below alongside an injected `now`, so no assertion
    /// depends on when or where the suite runs.
    private var pacific: Calendar { .gregorianPacific }

    /// Wednesday 2026-08-26, 2:30 PM Pacific. Mid-week on purpose: the week it belongs to
    /// has room on both sides, so "earlier this week" and "later this week" are both
    /// expressible without leaving it.
    private var wednesdayAfternoon: Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 8; comps.day = 26
        comps.hour = 14; comps.minute = 30
        comps.timeZone = pacific.timeZone
        return pacific.date(from: comps)!
    }

    /// The week interval `showsCaptureTime` itself computes for `wednesdayAfternoon` —
    /// boundary cases are built from THIS, never by adding or subtracting a fixed number
    /// of seconds from a hand-picked midnight (the repo's fake-inclusive-bound trap).
    private var currentWeek: DateInterval {
        pacific.dateInterval(of: .weekOfYear, for: wednesdayAfternoon)!
    }

    private func entry(capturedAt: Date, originalDate: PartialDate? = nil) -> EntryListItem {
        EntryListItem(captureID: "A",
                      capturedAt: capturedAt,
                      durationSeconds: 1,
                      metadata: EntryMetadata(originalDate: originalDate))
    }

    /// The owner's case: a reading from earlier the same day reads "Aug 26, 9:30 AM", not
    /// a bare "Aug 26" indistinguishable from the other three readings that day.
    func testCurrentWeekEntryShowsTheTimeOfDay() {
        let morning = pacific.date(byAdding: .hour, value: -5, to: wednesdayAfternoon)!
        let row = entry(capturedAt: morning)
        XCTAssertTrue(row.showsCaptureTime(now: wednesdayAfternoon, calendar: pacific))
        XCTAssertEqual(row.formattedLibraryRowDate(now: wednesdayAfternoon, calendar: pacific),
                       morning.formatted(date: .abbreviated, time: .shortened))
    }

    /// "Current week", not "today": Monday still carries a time on Wednesday.
    func testEarlierInTheSameWeekStillShowsTheTime() {
        let monday = pacific.date(byAdding: .day, value: -2, to: wednesdayAfternoon)!
        XCTAssertTrue(entry(capturedAt: monday).showsCaptureTime(now: wednesdayAfternoon,
                                                                calendar: pacific))
    }

    /// Eight days back is a different week — the row falls back to the bare date, byte for
    /// byte what `formattedEffectiveDate()` renders.
    func testEntryOlderThanThisWeekShowsDateOnly() {
        let lastWeek = pacific.date(byAdding: .day, value: -8, to: wednesdayAfternoon)!
        let row = entry(capturedAt: lastWeek)
        XCTAssertFalse(row.showsCaptureTime(now: wednesdayAfternoon, calendar: pacific))
        XCTAssertEqual(row.formattedLibraryRowDate(now: wednesdayAfternoon, calendar: pacific),
                       row.formattedEffectiveDate())
    }

    /// Decision 1, the one that keeps the row honest: a backdated entry read aloud TODAY
    /// shows its user-authored date and no time. `capturedAt` is inside the week and the
    /// unbackdated twin proves it — the backdate alone suppresses the time.
    func testBackdatedEntryCapturedThisWeekShowsNoTime() {
        let backdated = entry(capturedAt: wednesdayAfternoon,
                              originalDate: PartialDate(year: 1998, month: 3, day: 4))
        XCTAssertFalse(backdated.showsCaptureTime(now: wednesdayAfternoon, calendar: pacific))
        XCTAssertEqual(backdated.formattedLibraryRowDate(now: wednesdayAfternoon, calendar: pacific),
                       backdated.formattedEffectiveDate())
        XCTAssertTrue(entry(capturedAt: wednesdayAfternoon)
            .showsCaptureTime(now: wednesdayAfternoon, calendar: pacific))
    }

    /// The week's first instant is IN the week (`>= start`).
    func testWeekStartInstantIsInsideTheWeek() {
        XCTAssertTrue(entry(capturedAt: currentWeek.start)
            .showsCaptureTime(now: wednesdayAfternoon, calendar: pacific))
    }

    /// `dateInterval(of:for:).end` is the first instant of the NEXT week, so it is OUT
    /// (`< end`) — the half-open bound `JournalSpan.contains` uses. One second before it
    /// is still in, which is what proves the boundary lands in the right place rather
    /// than the whole comparison being false.
    func testWeekEndInstantIsTheNextWeekAndIsExcluded() {
        XCTAssertFalse(entry(capturedAt: currentWeek.end)
            .showsCaptureTime(now: wednesdayAfternoon, calendar: pacific))
        XCTAssertTrue(entry(capturedAt: currentWeek.end.addingTimeInterval(-1))
            .showsCaptureTime(now: wednesdayAfternoon, calendar: pacific))
    }

    /// The instant right before the week begins belongs to last week.
    func testInstantBeforeWeekStartIsExcluded() {
        XCTAssertFalse(entry(capturedAt: currentWeek.start.addingTimeInterval(-1))
            .showsCaptureTime(now: wednesdayAfternoon, calendar: pacific))
    }

    /// The zone is pinned, not inherited: a `capturedAt` that is Sunday in UTC but still
    /// Saturday evening in Pacific is bucketed by the Pacific day, so it stays in the week
    /// Pacific says it is in. This is the "never bucket by UTC" rule with teeth — under a
    /// UTC calendar this same instant lands in the following week.
    func testWeekBoundaryIsComputedInPacificNotUTC() {
        // Six hours before the Pacific week rolls over: still Pacific-evening on the
        // week's last day, but already past midnight UTC (PDT is UTC-7), so UTC has
        // moved on to the next week. Derived from the interval rather than a named
        // weekday, so it holds whichever day the locale starts its week on.
        let lastEveningOfPacificWeek = currentWeek.end.addingTimeInterval(-6 * 3_600)
        let row = entry(capturedAt: lastEveningOfPacificWeek)
        XCTAssertTrue(row.showsCaptureTime(now: wednesdayAfternoon, calendar: pacific))
        XCTAssertFalse(row.showsCaptureTime(now: wednesdayAfternoon, calendar: utc))
    }
}
