import XCTest
@testable import Raconte

/// Issue #49: once a backdate is set, the standalone "Backdate this entry…" button
/// disappears — the displayed date itself becomes the edit affordance. Pins
/// `EntryDetailView.backdateButtonVisible`, the pure decision function the view is a
/// thin `if` over, same reasoning as `EntryDetailViewTranscriptDisplayTests`.
final class EntryDetailViewBackdateAffordanceTests: XCTestCase {

    private func item(originalDate: PartialDate?) -> EntryListItem {
        EntryListItem(captureID: "A", capturedAt: Date(timeIntervalSince1970: 1_000),
                     metadata: EntryMetadata(originalDate: originalDate))
    }

    func testButtonVisibleWithNoBackdate() {
        let entry = item(originalDate: nil)
        XCTAssertFalse(entry.isBackdated)
        XCTAssertTrue(EntryDetailView.backdateButtonVisible(for: entry))
    }

    func testButtonHiddenOnceBackdateIsSet() {
        let entry = item(originalDate: PartialDate(year: 1998, month: 3, day: 4))
        XCTAssertTrue(entry.isBackdated)
        XCTAssertFalse(EntryDetailView.backdateButtonVisible(for: entry))
    }

    /// Every precision counts as "set" — the button must not linger for coarse
    /// backdates while only disappearing at day precision.
    func testButtonHiddenAtEveryBackdatePrecision() {
        for date in [PartialDate(year: 1998), PartialDate(year: 1998, month: 3),
                     PartialDate(year: 1998, month: 3, day: 4)] {
            XCTAssertFalse(EntryDetailView.backdateButtonVisible(for: item(originalDate: date)))
        }
    }
}
