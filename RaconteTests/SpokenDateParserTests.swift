import XCTest
@testable import Raconte

/// M3 issue #15: a spoken leading date, read off the opening of a transcript, carrying
/// its own precision.
final class SpokenDateParserTests: XCTestCase {

    // MARK: Month day year → day precision

    func testMonthOrdinalDayYear() {
        XCTAssertEqual(SpokenDateParser.detect(in: "March 4th, 1998, we drove to the coast"),
                       PartialDate(year: 1998, month: 3, day: 4))
    }

    func testMonthBareDayYear() {
        XCTAssertEqual(SpokenDateParser.detect(in: "March 4 1998 and it was raining"),
                       PartialDate(year: 1998, month: 3, day: 4))
    }

    func testOrdinalOfMonthYear() {
        XCTAssertEqual(SpokenDateParser.detect(in: "The 4th of March, 1998."),
                       PartialDate(year: 1998, month: 3, day: 4))
    }

    func testBareDayOfMonthYear() {
        XCTAssertEqual(SpokenDateParser.detect(in: "21 September 1972, a Thursday"),
                       PartialDate(year: 1972, month: 9, day: 21))
    }

    func testCaseInsensitive() {
        XCTAssertEqual(SpokenDateParser.detect(in: "MARCH 4TH, 1998"),
                       PartialDate(year: 1998, month: 3, day: 4))
        XCTAssertEqual(SpokenDateParser.detect(in: "march 4th 1998"),
                       PartialDate(year: 1998, month: 3, day: 4))
    }

    func testEveryOrdinalSuffix() {
        XCTAssertEqual(SpokenDateParser.detect(in: "May 1st, 2001")?.day, 1)
        XCTAssertEqual(SpokenDateParser.detect(in: "May 2nd, 2001")?.day, 2)
        XCTAssertEqual(SpokenDateParser.detect(in: "May 3rd, 2001")?.day, 3)
        XCTAssertEqual(SpokenDateParser.detect(in: "May 4th, 2001")?.day, 4)
        XCTAssertEqual(SpokenDateParser.detect(in: "May 22nd, 2001")?.day, 22)
    }

    func testAbbreviatedMonth() {
        XCTAssertEqual(SpokenDateParser.detect(in: "Sept 4, 1998"),
                       PartialDate(year: 1998, month: 9, day: 4))
        XCTAssertEqual(SpokenDateParser.detect(in: "Feb 2, 1998"),
                       PartialDate(year: 1998, month: 2, day: 2))
    }

    // MARK: Month year → year-month precision

    func testMonthYear() {
        let detected = SpokenDateParser.detect(in: "March 1998. I had just moved.")
        XCTAssertEqual(detected, PartialDate(year: 1998, month: 3))
        XCTAssertEqual(detected?.precision, .yearMonth)
    }

    func testMonthOfYear() {
        XCTAssertEqual(SpokenDateParser.detect(in: "March of 1998, thereabouts"),
                       PartialDate(year: 1998, month: 3))
    }

    /// A month with no year is not a date — there is nothing to anchor it to, and
    /// guessing the current year would silently invent one.
    func testMonthAndDayWithoutYearIsNotDetected() {
        XCTAssertNil(SpokenDateParser.detect(in: "March 4th, we drove to the coast"))
        XCTAssertNil(SpokenDateParser.detect(in: "March, a cold one"))
    }

    // MARK: Bare year → year precision

    func testBareLeadingYear() {
        let detected = SpokenDateParser.detect(in: "1998. What a year that was.")
        XCTAssertEqual(detected, PartialDate(year: 1998))
        XCTAssertEqual(detected?.precision, .year)
    }

    /// The whole defence of the bare-year rule: anywhere but the opening, a four-digit
    /// number is prose.
    func testMidSentenceYearIsNotDetected() {
        XCTAssertNil(SpokenDateParser.detect(in: "I bought 1998 stamps at the post office"))
        XCTAssertNil(SpokenDateParser.detect(in: "We talked about 1998 for hours"))
    }

    /// Issue #12b: filler-stripping used to promote a mid-sentence year to token 0 before
    /// the position check ran, so "so"/"in"/"the" being filler words silently defeated the
    /// bare-year rule's own defence. The gate is now the RAW first token, before any
    /// filler is dropped — filler tolerance is a month-led-pattern feature only.
    func testFillerStrippingDoesNotPromoteAMidSentenceYear() {
        XCTAssertNil(SpokenDateParser.detect(in: "So, in the 1998 election I voted"))
        XCTAssertNil(SpokenDateParser.detect(in: "The 1998 election was close"))
    }

    /// Documented false positive: the bare-year rule has no signal beyond "is this the
    /// first word", so a number that genuinely opens the utterance detects even when it
    /// isn't a year in spirit. Visible and editable in the UI, never applied silently —
    /// this is the accepted cost of the position-0 rule, not a bug to chase further.
    func testBareYearAcceptedFalsePositive() {
        XCTAssertEqual(SpokenDateParser.detect(in: "2000 dollars was a lot back then"),
                       PartialDate(year: 2000))
    }

    func testYearOutsideRangeIsNotDetected() {
        XCTAssertNil(SpokenDateParser.detect(in: "1899 was before the range"))
        XCTAssertNil(SpokenDateParser.detect(in: "2100 is after it"))
        XCTAssertNil(SpokenDateParser.detect(in: "12345 is not a year"))
    }

    // MARK: Filler tolerance

    func testLeadingFillerIsTolerated() {
        let expected = PartialDate(year: 1998, month: 3, day: 4)
        XCTAssertEqual(SpokenDateParser.detect(in: "Okay, um, March 4th, 1998"), expected)
        XCTAssertEqual(SpokenDateParser.detect(in: "So this is March 4th, 1998"), expected)
        XCTAssertEqual(SpokenDateParser.detect(in: "Uh, entry for March 4th 1998"), expected)
    }

    /// Bare year does NOT tolerate leading filler (see `testFillerStrippingDoesNotPromoteAMidSentenceYear`)
    /// — filler tolerance is a month-led-pattern feature only, so a year preceded by even
    /// "Okay. So," is not a detected opening.
    func testLeadingFillerBeforeBareYearIsNotDetected() {
        XCTAssertNil(SpokenDateParser.detect(in: "Okay. So, 1998."))
    }

    func testTodayIsMonthDayYear() {
        XCTAssertEqual(SpokenDateParser.detect(in: "Today is March 4th, 1998"),
                       PartialDate(year: 1998, month: 3, day: 4))
    }

    func testItWasMonthYear() {
        let detected = SpokenDateParser.detect(in: "It was March 1998, we had just moved")
        XCTAssertEqual(detected, PartialDate(year: 1998, month: 3))
        XCTAssertEqual(detected?.precision, .yearMonth)
    }

    func testLetMeSeeMonthDayYear() {
        XCTAssertEqual(SpokenDateParser.detect(in: "Let me see, March 4th, 1998"),
                       PartialDate(year: 1998, month: 3, day: 4))
    }

    func testImRecordingThisOnMonthDayYear() {
        XCTAssertEqual(SpokenDateParser.detect(in: "I'm recording this on March 4th, 1998"),
                       PartialDate(year: 1998, month: 3, day: 4))
    }

    /// Interior "the" between month and day — the filler run only strips leading tokens,
    /// so "March the 4th" needs `monthDayYear` itself to skip it.
    func testMonthTheDayYear() {
        XCTAssertEqual(SpokenDateParser.detect(in: "March the 4th, 1998"),
                       PartialDate(year: 1998, month: 3, day: 4))
    }

    /// "May" is a month and a filler-shaped word; the filler run must never eat it.
    func testMonthNameIsNeverEatenAsFiller() {
        XCTAssertEqual(SpokenDateParser.detect(in: "In May 1998"), PartialDate(year: 1998, month: 5))
    }

    func testFillerRunStopsAtFirstRealWord() {
        XCTAssertNil(SpokenDateParser.detect(in: "So my grandmother turned 1998 pages"))
    }

    // MARK: Impossible dates

    func testImpossibleDayIsNotDetected() {
        XCTAssertNil(SpokenDateParser.detect(in: "February 30th, 1998, we drove north"))
        XCTAssertNil(SpokenDateParser.detect(in: "April 31st, 1998"))
    }

    func testLeapDayIsDetectedOnlyInALeapYear() {
        XCTAssertEqual(SpokenDateParser.detect(in: "February 29th, 1996"),
                       PartialDate(year: 1996, month: 2, day: 29))
        XCTAssertNil(SpokenDateParser.detect(in: "February 29th, 1998"))
    }

    func testDayOutOfRangeIsNotDetected() {
        XCTAssertNil(SpokenDateParser.detect(in: "March 32nd, 1998"))
        XCTAssertNil(SpokenDateParser.detect(in: "March 0, 1998"))
    }

    // MARK: Position

    /// Only the opening is scanned — a date named a paragraph in dates something else.
    /// The preamble here is pure filler, so a failure could only come from the character
    /// window cutting the date off, not from a non-filler word defeating the filler run
    /// (that would pass even with the window deleted — the bug this replaces).
    func testDatePastTheOpeningWindowIsNotDetected() {
        let preamble = String(repeating: "um ", count: 40)
        XCTAssertNil(SpokenDateParser.detect(in: preamble + "March 4th, 1998"))
    }

    /// Same string, two limits: nil at a limit that truncates before the date, detected at
    /// the default window. Pins the window itself, not incidental non-filler content —
    /// the old version of this test passed at `limit: 5` regardless of what the window
    /// was, because "Okay so anyway" contains a non-filler word ("anyway") that already
    /// defeats the filler run.
    func testWindowIsCharacterLimited() {
        XCTAssertNil(SpokenDateParser.detect(in: "Okay, um, March 4th, 1998", limit: 9))
        XCTAssertEqual(SpokenDateParser.detect(in: "Okay, um, March 4th, 1998"),
                       PartialDate(year: 1998, month: 3, day: 4))
    }

    // MARK: Nothing there

    func testEmptyAndGarbage() {
        XCTAssertNil(SpokenDateParser.detect(in: ""))
        XCTAssertNil(SpokenDateParser.detect(in: "     "))
        XCTAssertNil(SpokenDateParser.detect(in: "...,,,;;;"))
        XCTAssertNil(SpokenDateParser.detect(in: "Okay um so uh well"))
        XCTAssertNil(SpokenDateParser.detect(in: "Today I went to the shop"))
    }
}
