import XCTest
@testable import Raconte

/// The span editor's pure half. `PrecisionDatePicker` speaks (Date, DatePrecision); the
/// registry speaks PartialDate. Getting that conversion wrong is invisible on screen and
/// wrong on disk, so it is pinned here rather than left inside the view.
final class JournalSpanEditorTests: XCTestCase {
    private let cal = Calendar.gregorianCurrent

    func testBuildingASpanFromPickerValuesRoundTrips() throws {
        let start = cal.date(from: DateComponents(year: 1998, month: 3, day: 4))!
        let end = cal.date(from: DateComponents(year: 2001, month: 7, day: 9))!
        let span = try JournalSpanEditorModel.span(startDate: start, startPrecision: .yearMonth,
                                                   endDate: end, endPrecision: .year,
                                                   isOpenEnded: false, calendar: cal)
        XCTAssertEqual(span?.start, PartialDate(year: 1998, month: 3))
        XCTAssertEqual(span?.end, PartialDate(year: 2001))
    }

    func testOpenEndedDropsTheEndEntirely() throws {
        let start = cal.date(from: DateComponents(year: 1998, month: 3, day: 4))!
        let span = try JournalSpanEditorModel.span(startDate: start, startPrecision: .year,
                                                   endDate: Date(), endPrecision: .year,
                                                   isOpenEnded: true, calendar: cal)
        XCTAssertEqual(span?.start, PartialDate(year: 1998))
        XCTAssertNil(span?.end)
    }

    /// #77: the seam nothing composed. A `.year` value anchors to 1 Jan; re-reading that
    /// anchor at `.day` precision would silently promote "1998" to "1 Jan 1998". The round
    /// trip must be the identity at every precision.
    func testPartialDateSurvivesTheAnchorThenPickerThenSpanRoundTripAtEveryPrecision() throws {
        let calendar = Calendar.gregorianCurrent
        let originals = [PartialDate(year: 1998),
                         PartialDate(year: 1998, month: 3),
                         PartialDate(year: 1998, month: 3, day: 4)]
        for original in originals {
            let pickerDate = original.anchorDate(calendar: calendar)
            let span = try XCTUnwrap(JournalSpanEditorModel.span(
                startDate: pickerDate, startPrecision: original.precision,
                endDate: pickerDate, endPrecision: original.precision,
                isOpenEnded: false, calendar: calendar))
            XCTAssertEqual(span.start, original, "\(original) did not survive as start")
            XCTAssertEqual(span.end, original, "\(original) did not survive as end")
        }
    }

    func testAnInvertedPairSurfacesAsAnErrorNotACrash() {
        let start = cal.date(from: DateComponents(year: 2001, month: 1, day: 1))!
        let end = cal.date(from: DateComponents(year: 1998, month: 1, day: 1))!
        XCTAssertThrowsError(try JournalSpanEditorModel.span(
            startDate: start, startPrecision: .year,
            endDate: end, endPrecision: .year,
            isOpenEnded: false, calendar: cal))
    }
}
