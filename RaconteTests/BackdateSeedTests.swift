import XCTest
@testable import Raconte

/// #175: the pre-fill for a backdate toggle turned on with nothing carried this session.
/// Pure — every rule about which entry counts and how its date advances is reachable
/// with no disk, no model and no clock beyond the injected `now`.
final class BackdateSeedTests: XCTestCase {

    private let calendar = Calendar.gregorianCurrent

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private func item(journal: String?, capturedAt: Date, backdate: PartialDate?,
                      trashed: Bool = false) -> EntryListItem {
        var item = EntryListItem(captureID: ULID.make(), capturedAt: capturedAt)
        item.journalID = journal
        item.originalDate = backdate
        if trashed { item.metadata.trashedAt = capturedAt }
        return item
    }

    /// The plain case: one day-precision backdated entry seeds the day after.
    func testDayPrecisionSeedsTheNextDay() {
        let entries = [item(journal: "A", capturedAt: date(2026, 9, 1),
                            backdate: PartialDate(year: 1987, month: 6, day: 12))]
        XCTAssertEqual(BackdateSeed.seed(from: entries, journalID: "A", now: date(2026, 9, 25)),
                       PartialDate(year: 1987, month: 6, day: 13))
    }

    /// Ruling 2: month and year precision carry unchanged — a 1998 journal does not turn a
    /// page per year.
    func testCoarserPrecisionSeedsTheSameValue() {
        let month = [item(journal: "A", capturedAt: date(2026, 9, 1),
                          backdate: PartialDate(year: 1987, month: 6))]
        XCTAssertEqual(BackdateSeed.seed(from: month, journalID: "A", now: date(2026, 9, 25)),
                       PartialDate(year: 1987, month: 6))
        let year = [item(journal: "A", capturedAt: date(2026, 9, 1),
                         backdate: PartialDate(year: 1987))]
        XCTAssertEqual(BackdateSeed.seed(from: year, journalID: "A", now: date(2026, 9, 25)),
                       PartialDate(year: 1987))
    }

    /// Ruling 3: never later than today. Yesterday seeds today; today seeds today.
    func testNextDayIsClampedToToday() {
        let now = date(2026, 9, 25)
        let today = PartialDate(from: now, precision: .day, calendar: calendar)
        let yesterday = [item(journal: "A", capturedAt: now,
                              backdate: PartialDate(year: 2026, month: 9, day: 24))]
        XCTAssertEqual(BackdateSeed.seed(from: yesterday, journalID: "A", now: now), today)
        let sameDay = [item(journal: "A", capturedAt: now, backdate: today)]
        XCTAssertEqual(BackdateSeed.seed(from: sameDay, journalID: "A", now: now), today,
                       "tomorrow would be refused at the sidecar — keep today")
    }

    /// Ruling 1: capture order, not date order. Back-filling an older gap after newer
    /// pages means "continue from the gap", so the older date plus one wins.
    func testFollowsCaptureOrderNotDateOrder() {
        let entries = [
            item(journal: "A", capturedAt: date(2026, 9, 1),
                 backdate: PartialDate(year: 1990, month: 1, day: 1)),
            item(journal: "A", capturedAt: date(2026, 9, 2),
                 backdate: PartialDate(year: 1987, month: 6, day: 12)),
        ]
        XCTAssertEqual(BackdateSeed.seed(from: entries, journalID: "A", now: date(2026, 9, 25)),
                       PartialDate(year: 1987, month: 6, day: 13))
        // Order of the array is not the order of capture.
        XCTAssertEqual(BackdateSeed.seed(from: entries.reversed(), journalID: "A",
                                         now: date(2026, 9, 25)),
                       PartialDate(year: 1987, month: 6, day: 13))
    }

    /// A newer entry with no backdate is not "backdated to its capture day"; it is
    /// skipped, and the last backdated entry still seeds.
    func testIgnoresEntriesWithoutABackdate() {
        let entries = [
            item(journal: "A", capturedAt: date(2026, 9, 1),
                 backdate: PartialDate(year: 1987, month: 6, day: 12)),
            item(journal: "A", capturedAt: date(2026, 9, 2), backdate: nil),
        ]
        XCTAssertEqual(BackdateSeed.seed(from: entries, journalID: "A", now: date(2026, 9, 25)),
                       PartialDate(year: 1987, month: 6, day: 13))
    }

    /// A trashed entry is on its way out; it must not steer the next capture.
    func testIgnoresTrashedEntries() {
        let entries = [
            item(journal: "A", capturedAt: date(2026, 9, 1),
                 backdate: PartialDate(year: 1987, month: 6, day: 12)),
            item(journal: "A", capturedAt: date(2026, 9, 2),
                 backdate: PartialDate(year: 1999, month: 1, day: 1), trashed: true),
        ]
        XCTAssertEqual(BackdateSeed.seed(from: entries, journalID: "A", now: date(2026, 9, 25)),
                       PartialDate(year: 1987, month: 6, day: 13))
    }

    /// Per journal: journal B's newer entry is invisible to journal A's seed, and an
    /// unfiled entry belongs to neither.
    func testSeedIsPerJournal() {
        let entries = [
            item(journal: "A", capturedAt: date(2026, 9, 1),
                 backdate: PartialDate(year: 1987, month: 6, day: 12)),
            item(journal: "B", capturedAt: date(2026, 9, 2),
                 backdate: PartialDate(year: 1999, month: 1, day: 1)),
            item(journal: nil, capturedAt: date(2026, 9, 3),
                 backdate: PartialDate(year: 2001, month: 1, day: 1)),
        ]
        XCTAssertEqual(BackdateSeed.seed(from: entries, journalID: "A", now: date(2026, 9, 25)),
                       PartialDate(year: 1987, month: 6, day: 13))
        XCTAssertEqual(BackdateSeed.seed(from: entries, journalID: "B", now: date(2026, 9, 25)),
                       PartialDate(year: 1999, month: 1, day: 2))
        XCTAssertNil(BackdateSeed.seed(from: entries, journalID: "C", now: date(2026, 9, 25)))
    }

    /// Nothing backdated in the journal: no seed, so the caller falls back to today.
    func testNoBackdatedEntryMeansNoSeed() {
        let entries = [item(journal: "A", capturedAt: date(2026, 9, 1), backdate: nil)]
        XCTAssertNil(BackdateSeed.seed(from: entries, journalID: "A", now: date(2026, 9, 25)))
        XCTAssertNil(BackdateSeed.seed(from: [], journalID: "A", now: date(2026, 9, 25)))
    }

    // MARK: #183 — the automatic default

    /// #183 rule 2: the journal's LATEST untrashed capture is backdated, so the toggle
    /// starts on, at the same seed the manual path gives.
    func testAutomaticSeedWhenTheLatestEntryIsBackdated() {
        let entries = [item(journal: "A", capturedAt: date(2026, 9, 1),
                            backdate: PartialDate(year: 1987, month: 6, day: 12))]
        XCTAssertEqual(BackdateSeed.automatic(from: entries, journalID: "A", now: date(2026, 9, 25)),
                       PartialDate(year: 1987, month: 6, day: 13))
    }

    /// #183 rule 3 beside rule 5: an undated capture AFTER the backdated one means the
    /// toggle starts off — while a manual toggle-on still seeds from the backdated one.
    func testNoAutomaticSeedWhenTheLatestEntryIsUndated() {
        let entries = [
            item(journal: "A", capturedAt: date(2026, 9, 1),
                 backdate: PartialDate(year: 1987, month: 6, day: 12)),
            item(journal: "A", capturedAt: date(2026, 9, 2), backdate: nil)
        ]
        XCTAssertNil(BackdateSeed.automatic(from: entries, journalID: "A", now: date(2026, 9, 25)))
        XCTAssertEqual(BackdateSeed.seed(from: entries, journalID: "A", now: date(2026, 9, 25)),
                       PartialDate(year: 1987, month: 6, day: 13),
                       "the manual seed is unchanged (rule 5)")
    }

    /// Coarser precision comes through the automatic path unchanged too.
    func testAutomaticSeedKeepsCoarserPrecision() {
        let entries = [item(journal: "A", capturedAt: date(2026, 9, 1),
                            backdate: PartialDate(year: 1987, month: 6))]
        XCTAssertEqual(BackdateSeed.automatic(from: entries, journalID: "A", now: date(2026, 9, 25)),
                       PartialDate(year: 1987, month: 6))
    }

    /// A trashed latest capture does not decide the default; the newest untrashed one does.
    func testAutomaticSeedSkipsATrashedLatestEntry() {
        let entries = [
            item(journal: "A", capturedAt: date(2026, 9, 1),
                 backdate: PartialDate(year: 1987, month: 6, day: 12)),
            item(journal: "A", capturedAt: date(2026, 9, 2), backdate: nil, trashed: true)
        ]
        XCTAssertEqual(BackdateSeed.automatic(from: entries, journalID: "A", now: date(2026, 9, 25)),
                       PartialDate(year: 1987, month: 6, day: 13))
    }

    /// "Latest" is by `capturedAt`, whatever order the list arrives in — `allEntries` is
    /// not promised to be ascending, and a `.last`/`.first` shortcut would read the wrong
    /// entry. Newest-first here; every other fixture in this file is oldest-first.
    func testAutomaticSeedReadsTheLatestRegardlessOfListOrder() {
        let newestFirst = [
            item(journal: "A", capturedAt: date(2026, 9, 2), backdate: nil),
            item(journal: "A", capturedAt: date(2026, 9, 1),
                 backdate: PartialDate(year: 1987, month: 6, day: 12))
        ]
        XCTAssertNil(BackdateSeed.automatic(from: newestFirst, journalID: "A", now: date(2026, 9, 25)),
                     "the newest capture is the undated one, wherever it sits in the list")
        let newestFirstBackdated = [
            item(journal: "A", capturedAt: date(2026, 9, 2),
                 backdate: PartialDate(year: 1987, month: 6, day: 12)),
            item(journal: "A", capturedAt: date(2026, 9, 1), backdate: nil)
        ]
        XCTAssertEqual(BackdateSeed.automatic(from: newestFirstBackdated, journalID: "A",
                                              now: date(2026, 9, 25)),
                       PartialDate(year: 1987, month: 6, day: 13))
    }

    /// Another journal's newer undated capture is not this journal's latest.
    func testAutomaticSeedIsPerJournal() {
        let entries = [
            item(journal: "A", capturedAt: date(2026, 9, 1),
                 backdate: PartialDate(year: 1987, month: 6, day: 12)),
            item(journal: "B", capturedAt: date(2026, 9, 2), backdate: nil)
        ]
        XCTAssertEqual(BackdateSeed.automatic(from: entries, journalID: "A", now: date(2026, 9, 25)),
                       PartialDate(year: 1987, month: 6, day: 13))
        XCTAssertNil(BackdateSeed.automatic(from: entries, journalID: "B", now: date(2026, 9, 25)))
    }
}
