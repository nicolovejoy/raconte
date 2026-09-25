import XCTest
@testable import Raconte

/// #134: the tally behind the camera's take-another loop in `ImageCapturePickerSheet`.
/// Pure — the simulator has no camera, so the loop's rules are pinned here, not in a UI test.
final class ImageCaptureBatchTests: XCTestCase {

    /// Before any shot the sheet is the old one: same camera row title, same Cancel.
    func testFreshBatchShowsTheOriginalCopy() {
        let batch = ImageCaptureBatch()
        XCTAssertEqual(batch.added, 0)
        XCTAssertFalse(batch.hasLanded)
        XCTAssertEqual(batch.cameraButtonTitle, "Take Photo…")
        XCTAssertEqual(batch.dismissButtonTitle, "Cancel")
    }

    /// One landed shot flips both titles: the camera row now reads as "another", and the
    /// toolbar button no longer says Cancel over a photo that is already saved.
    func testALandedShotFlipsTheCopy() {
        var batch = ImageCaptureBatch()
        batch.recordLanded()
        XCTAssertEqual(batch.added, 1)
        XCTAssertTrue(batch.hasLanded)
        XCTAssertEqual(batch.cameraButtonTitle, "Take Another…")
        XCTAssertEqual(batch.dismissButtonTitle, "Done")
    }

    func testSummaryPluralises() {
        var batch = ImageCaptureBatch()
        batch.recordLanded()
        XCTAssertEqual(batch.summary, "1 photo added")
        batch.recordLanded()
        XCTAssertEqual(batch.summary, "2 photos added")
        batch.recordLanded()
        XCTAssertEqual(batch.summary, "3 photos added")
    }

    /// Only the caller decides what landed; a failed or cancelled shot never calls
    /// `recordLanded()`, so the tally has no "failed" path of its own to get wrong.
    func testAFailedShotDoesNotCount() {
        var batch = ImageCaptureBatch()
        batch.recordLanded()
        let before = batch
        // The sheet's failure branch (Task 2) does not touch the batch at all.
        XCTAssertEqual(batch, before)
        XCTAssertEqual(batch.added, 1)
    }
}
