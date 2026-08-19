import XCTest

/// #69: on macOS a `Menu`'s label discards SwiftUI's sizing of a resizable `Image` and
/// paints it at intrinsic size. A 768x1024 cover therefore laid out at 768x1024 POINTS,
/// covering the whole setup region and pushing the picker's own name+chevron off the
/// right edge of the window — which is why the journal picker stopped working entirely.
///
/// Proven by a six-variant harness (spec appendix): no in-place clamp and no `.menuStyle`
/// fixes it; the image must leave the label. There is no UI-test pin available — the bug
/// is macOS-only and this project cannot run macOS UI tests — so this scan is the pin.
final class JournalHeaderSourceTests: XCTestCase {
    private var captureViewSource: String {
        get throws {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()      // RaconteTests
                .deletingLastPathComponent()      // repo root
                .appendingPathComponent("Raconte/Capture/UI/CaptureView.swift")
            return strippingComments(try String(contentsOf: url))
        }
    }

    func testCaptureScreenRendersNoJournalCover() throws {
        XCTAssertFalse(try captureViewSource.contains("JournalCoverThumbnail"),
                       "#69: a cover inside this file's Menu label renders full-bleed on "
                       + "macOS and makes the journal picker unusable")
    }

    func testCapturePickerOffersNoJournalEditing() throws {
        let source = try captureViewSource
        for removed in ["Cover Photo", "Voice Labels", "Rename "] {
            XCTAssertFalse(source.contains(removed),
                           "journal editing moved to JournalEditorView (spec ruling 6); "
                           + "\(removed) must not be back on the capture screen")
        }
    }

    func testCapturePickerStillOffersSelectionAndCreation() throws {
        let source = try captureViewSource
        XCTAssertTrue(source.contains("selectJournal"))
        XCTAssertTrue(source.contains("New Journal"))
    }
}
