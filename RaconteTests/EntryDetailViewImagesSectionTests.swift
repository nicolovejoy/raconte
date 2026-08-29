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

    // MARK: - #107: image-first invitation to speak, not type

    /// An image-only entry (no audio, at least one image) invites the owner to speak
    /// about the picture instead of showing the plain "not transcribed" line.
    func testInviteRecordingVisibleForImageOnlyEntry() {
        XCTAssertTrue(EntryDetailView.inviteRecordingVisible(hasAudio: false, imageCount: 1))
    }

    /// An entry that already has audio never shows the invitation, regardless of images —
    /// there is already a recording; the invitation is only for entries with none.
    func testInviteRecordingHiddenWhenAudioExists() {
        XCTAssertFalse(EntryDetailView.inviteRecordingVisible(hasAudio: true, imageCount: 1))
    }

    /// No audio and no images is the plain absent-transcript case, not an invitation —
    /// there is nothing (yet) to invite speaking about.
    func testInviteRecordingHiddenWithNoImagesAndNoAudio() {
        XCTAssertFalse(EntryDetailView.inviteRecordingVisible(hasAudio: false, imageCount: 0))
    }

    /// The invitation and the plain ".absent" transcript string are mutually exclusive:
    /// `transcriptDisplay` still reports `.absent` for an image-only entry (there really
    /// is no transcript), but the invitation flag tells the view to render the invitation
    /// block INSTEAD of the "This entry was not transcribed." text, never both.
    func testInviteReplacesAbsentStringNeverBoth() {
        let transcript = EntryTranscript(state: .absent, text: nil, degradations: [])
        XCTAssertEqual(EntryDetailView.transcriptDisplay(transcript), .absent)
        XCTAssertTrue(EntryDetailView.inviteRecordingVisible(hasAudio: false, imageCount: 1))
    }
}
