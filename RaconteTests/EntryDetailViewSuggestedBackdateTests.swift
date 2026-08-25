import XCTest
@testable import Raconte

/// Image capture plan Task 8: pins `EntryDetailView.suggestedBackdate`, the pure
/// gating function the "does adding an image reopen the backdate sheet" decision
/// reduces to. CLAUDE.md's hard rule — "Backdates are sticky: editable with explicit
/// overrides, never clearable by one tap" — is the sticky-backdate case below: an
/// entry that already has a date must never have the sheet reopened out from under
/// the owner just because a second image happens to carry EXIF data.
final class EntryDetailViewSuggestedBackdateTests: XCTestCase {

    private let exifDate = Date(timeIntervalSince1970: 1_000_000)

    func testNoExistingDateWithEXIFSuggestsTheEXIFDate() {
        let suggested = EntryDetailView.suggestedBackdate(hadOriginalDateBeforeAdd: false,
                                                           exifCapturedAt: exifDate)
        XCTAssertEqual(suggested, exifDate)
    }

    /// The sticky-backdate rule: a second image with EXIF must not reopen/alter the
    /// sheet once a date already exists.
    func testExistingDateWithEXIFDoesNotSuggest() {
        let suggested = EntryDetailView.suggestedBackdate(hadOriginalDateBeforeAdd: true,
                                                           exifCapturedAt: exifDate)
        XCTAssertNil(suggested)
    }

    func testNoExistingDateWithoutEXIFLeavesTodaysDefaultUnchanged() {
        let suggested = EntryDetailView.suggestedBackdate(hadOriginalDateBeforeAdd: false,
                                                           exifCapturedAt: nil)
        XCTAssertNil(suggested)
    }

    /// Belt and suspenders: an already-backdated entry with no EXIF also suggests
    /// nothing (both gates independently say no).
    func testExistingDateWithoutEXIFDoesNotSuggest() {
        let suggested = EntryDetailView.suggestedBackdate(hadOriginalDateBeforeAdd: true,
                                                           exifCapturedAt: nil)
        XCTAssertNil(suggested)
    }
}
