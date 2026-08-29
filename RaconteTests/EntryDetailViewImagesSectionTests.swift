import XCTest
@testable import Raconte

/// Image capture plan Task 6 brief: pins `EntryDetailView.playbackSectionVisible`, the
/// pure decision function the view is a thin `if` over — the design doc's "for an
/// image-only entry, `playbackSection` is empty/hidden (no audio) and the images strip
/// is the primary content, shown first" reduces to exactly this once `imagesSection` is
/// unconditionally rendered between `playbackSection` and `transcriptSection`: omitting
/// playback when there's no audio is sufficient to put images first, with no separate
/// reordering logic needed.
final class EntryDetailViewImagesSectionTests: XCTestCase {

    func testPlaybackSectionVisibleWithAudio() {
        XCTAssertTrue(EntryDetailView.playbackSectionVisible(hasAudio: true))
    }

    func testPlaybackSectionHiddenForImageOnlyEntry() {
        XCTAssertFalse(EntryDetailView.playbackSectionVisible(hasAudio: false))
    }

    /// Task 6 (#55): the images strip is now the whole `imagesSection` — no header, no
    /// empty-state text, no in-body "Capture Image…" button. `imagesStripVisible` is the
    /// pure decision the view is a thin `if` over.
    func testImagesStripVisibleWithImages() {
        XCTAssertTrue(EntryDetailView.imagesStripVisible(imageCount: 1))
        XCTAssertTrue(EntryDetailView.imagesStripVisible(imageCount: 3))
    }

    func testImagesStripHiddenWithNoImages() {
        XCTAssertFalse(EntryDetailView.imagesStripVisible(imageCount: 0))
    }
}
