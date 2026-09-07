import XCTest
@testable import Raconte

/// Spec ruling 3: stored wins when set; derived is the fallback. Never a union — a union
/// silently invents a span nobody typed and hides the disagreement.
final class JournalDateLineTests: XCTestCase {
    private let cal = Calendar.gregorianCurrent

    func testStoredSpanWinsOverTheDerivedRange() throws {
        let span = try JournalSpan(start: PartialDate(year: 1998),
                                   end: PartialDate(year: 2001))
        let derived = JournalDateRange(minDate: cal.date(from: DateComponents(year: 2026, month: 8, day: 1))!,
                                       minPrecision: .day,
                                       maxDate: cal.date(from: DateComponents(year: 2026, month: 8, day: 18))!,
                                       maxPrecision: .day)
        XCTAssertEqual(JournalDateLine.text(span: span, derived: derived, calendar: cal),
                       span.formatted(calendar: cal),
                       "a half-read 1998 journal must not advertise itself as Aug 2026")
    }

    func testDerivedRangeIsUsedWhenNoSpanIsSet() {
        let derived = JournalDateRange(minDate: cal.date(from: DateComponents(year: 2026, month: 8, day: 1))!,
                                       minPrecision: .day,
                                       maxDate: cal.date(from: DateComponents(year: 2026, month: 8, day: 18))!,
                                       maxPrecision: .day)
        XCTAssertEqual(JournalDateLine.text(span: nil, derived: derived, calendar: cal),
                       derived.formatted(calendar: cal))
    }

    func testSpanWinsEvenWhenThereAreNoEntriesAtAll() throws {
        let span = try JournalSpan(start: PartialDate(year: 1998), end: nil)
        XCTAssertEqual(JournalDateLine.text(span: span, derived: nil, calendar: cal),
                       span.formatted(calendar: cal),
                       "an untranscribed journal still knows what it covers")
    }

    func testNothingToSayReturnsNil() {
        XCTAssertNil(JournalDateLine.text(span: nil, derived: nil, calendar: cal))
    }

    /// Task 4 fix round 1, Minor: every other test in this file passes `.gregorianCurrent`
    /// — `text`'s own default — so none of them can tell "forwards the argument" apart
    /// from "always uses `.gregorianCurrent` internally and ignores what it was handed".
    /// Discriminates by comparing two calendars that are guaranteed to disagree on the
    /// YEAR NUMBER for the same instant (Gregorian vs. Hebrew — centuries apart), both
    /// pinned to a fixed (non-"current") time zone so the result is machine-independent.
    /// Exercises the `derived` branch specifically: `JournalDateRange.formatted`'s
    /// non-point path (`minDate != maxDate`) reads `calendar.component(.year, from:)`
    /// directly, with no `PartialDate`/`anchorDate` round trip to cancel the difference
    /// back out (a point-precision fixture very nearly would — the round trip re-derives
    /// an instant close to the original, which a Gregorian-default display formatter
    /// then reports the same either way).
    func testCalendarArgumentIsThreadedThroughRatherThanHardcoded() {
        var gregorianUTC = Calendar(identifier: .gregorian)
        gregorianUTC.timeZone = TimeZone(identifier: "UTC")!
        var hebrewUTC = Calendar(identifier: .hebrew)
        hebrewUTC.timeZone = TimeZone(identifier: "UTC")!

        // Same day, an hour apart — same year in either calendar, so the range collapses
        // to a single year number rather than a "min–max" span, keeping the expected
        // strings simple.
        let minDate = Date(timeIntervalSince1970: 0)
        let maxDate = Date(timeIntervalSince1970: 3_600)
        let derived = JournalDateRange(minDate: minDate, minPrecision: .year,
                                       maxDate: maxDate, maxPrecision: .year)

        let expectedGregorian = derived.formatted(calendar: gregorianUTC)
        let expectedHebrew = derived.formatted(calendar: hebrewUTC)
        XCTAssertNotEqual(expectedGregorian, expectedHebrew,
                          "sanity check on the fixture itself: Gregorian and Hebrew must "
                          + "disagree on the year number here, or this test proves nothing")

        XCTAssertEqual(JournalDateLine.text(span: nil, derived: derived, calendar: gregorianUTC),
                       expectedGregorian)
        XCTAssertEqual(JournalDateLine.text(span: nil, derived: derived, calendar: hebrewUTC),
                       expectedHebrew,
                       "a hardcoded .gregorianCurrent inside JournalDateLine.text would "
                       + "report the Gregorian year here regardless of what was passed in")
    }

    // MARK: - journalDateLines (#67 item 3): one grouped pass per rescan, not one
    // `dateLine(forJournal:)` filter of `allEntries` per journal per sidebar body eval.

    /// Cardinality 4, on purpose: two journals WITH entries (so "matches for every
    /// journal" isn't vacuously true for a single one), one SPANLESS journal with NONE
    /// (must be absent from the dictionary rather than present with a nil/empty value —
    /// `dateLine(forJournal:)` already returns nil for that case, `testNothingToSayReturnsNil`
    /// above, so the dictionary must agree), and one journal that HAS a span but no
    /// entries (must be PRESENT with the span's text — `JournalDateLine.text` returns the
    /// span regardless of `derived`, spec ruling 3 — so "no entries" alone is never
    /// sufficient to omit a journal; the earlier version of this test only ever exercised
    /// the spanless case and its assertion message overclaimed the rule).
    ///
    /// The equality checks below recompute the expected line independently via
    /// `JournalDateRange.compute` + `JournalDateLine.text` rather than calling
    /// `dateLine(forJournal:)` — after Task 9's refactor that method IS the dictionary
    /// lookup under test, so comparing against it would make the assertion tautological.
    @MainActor
    func testJournalDateLinesMatchesDateLineForEveryJournalAndOmitsOnesWithNoEntries() async throws {
        let containerRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("JournalDateLines-\(UUID().uuidString)", isDirectory: true)
        let capturesRoot = AppContainer.capturesRoot(containerRoot: containerRoot)
        try FileManager.default.createDirectory(at: capturesRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: containerRoot) }

        let j1 = Journal(id: ULID.make(), name: "1987", createdAt: Date(timeIntervalSince1970: 0))
        let j2 = Journal(id: ULID.make(), name: "France", createdAt: Date(timeIntervalSince1970: 100))
        let j3 = Journal(id: ULID.make(), name: "Empty", createdAt: Date(timeIntervalSince1970: 200))
        let spanOnly = try JournalSpan(start: PartialDate(year: 1998), end: nil)
        let j4 = Journal(id: ULID.make(), name: "Paper only", createdAt: Date(timeIntervalSince1970: 300),
                          span: spanOnly)
        try JournalStore.encode(JournalRegistry(journals: [j1, j2, j3, j4]))
            .write(to: AppContainer.journalsURL(containerRoot: containerRoot))

        func writeCapture(_ id: String, capturedAt: Double, journalID: String) throws {
            let dir = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: id)
            let segs = SegmentLayout.segmentsDirectory(captureDirectory: dir)
            try FileManager.default.createDirectory(at: segs, withIntermediateDirectories: true)
            try Data(count: 48_000 * 4).write(to: SegmentLayout.pcmURL(segmentsDirectory: segs, index: 0))
            let format = AudioFormatDescriptor(sampleRate: 48_000, channels: 1,
                                               commonFormat: .pcmFormatFloat32,
                                               interleaved: false, bytesPerFrame: 4)
            let created = Date(timeIntervalSince1970: capturedAt)
            let manifest = Manifest(captureID: id, createdAt: created, state: .captured,
                                    stateSeq: 1, stateUpdatedAt: created, format: format)
            try CaptureCoding.encoder().encode(manifest)
                .write(to: SegmentLayout.manifestURL(captureDirectory: dir))
            try EntryMetadataStore.write(EntryMetadata(journalID: journalID),
                                         url: SegmentLayout.entryMetadataURL(captureDirectory: dir))
        }

        try writeCapture(ULID.make(), capturedAt: 1_000, journalID: j1.id)
        try writeCapture(ULID.make(), capturedAt: 2_000, journalID: j2.id)
        // j3 gets no entries at all.

        let model = LibraryScreenModel(capturesRoot: capturesRoot, journalsContainerRoot: containerRoot)
        await model.rescan()

        for journal in [j1, j2] {
            let expected = JournalDateLine.text(
                span: journal.span,
                derived: JournalDateRange.compute(from: model.allEntries.filter { $0.journalID == journal.id }))
            XCTAssertEqual(model.journalDateLines[journal.id], expected, "\(journal.name)")
            XCTAssertNotNil(model.journalDateLines[journal.id], "\(journal.name) has an entry")
        }
        XCTAssertNil(model.journalDateLines[j3.id],
                     "a SPANLESS journal with no entries must be absent, not present with an empty/nil line")
        XCTAssertEqual(model.journalDateLines[j4.id], spanOnly.formatted(calendar: cal),
                       "a journal with a stored span but no entries must still be present, showing the span")
    }
}
