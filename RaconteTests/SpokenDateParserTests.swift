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

    func testLeadingFillerBeforeBareYear() {
        XCTAssertEqual(SpokenDateParser.detect(in: "Okay. So, 1998."), PartialDate(year: 1998))
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
    func testDatePastTheOpeningWindowIsNotDetected() {
        let preamble = String(repeating: "words and more words ", count: 6)
        XCTAssertNil(SpokenDateParser.detect(in: preamble + "March 4th, 1998"))
    }

    func testWindowIsCharacterLimited() {
        XCTAssertNil(SpokenDateParser.detect(in: "Okay so anyway March 4th, 1998", limit: 5))
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
