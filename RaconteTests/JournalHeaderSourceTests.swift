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

    /// Task 4 fix round 1, Important: the picker's `menuTitle` used to format
    /// `dateRange(forJournal:)` (the derived range) directly, so a journal with a stored
    /// `JournalSpan` could read "1998 – 2001" in the sidebar but "(August 2026)" here —
    /// two surfaces disagreeing about the same journal's dates. There is no SwiftUI unit
    /// test available for a private `View` method's return value in this repo (macOS UI
    /// tests aren't run here — see the file-level doc comment), so this is a source scan,
    /// same shape as the other tests in this class. It can confirm the call site was
    /// swapped; it cannot confirm the menu actually RENDERS the shared value correctly at
    /// runtime.
    func testJournalPickerMenuTitleRoutesThroughTheSharedDateLine() throws {
        let source = try captureViewSource
        XCTAssertTrue(source.contains("dateLine(forJournal:"),
                      "the picker menu must call the shared LibraryScreenModel.dateLine(forJournal:), "
                      + "not format a derived range itself")
        XCTAssertFalse(source.contains("dateRange(forJournal:"),
                       "standing branch rule: call the shared primitive, never copy it — "
                       + "dateRange(forJournal:) is JournalDateLine's own fallback input, "
                       + "not something this file should call directly")
    }
}
