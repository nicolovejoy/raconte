import XCTest
@testable import Raconte

/// The capture screen's backdate control on macOS.
///
/// Owner smoke, 2026-08-15 (final verdict of the session): "pass, but the date-picker ux is
/// better on the iphone". That followed a same-day fix that swapped the Mac from
/// `.datePickerStyle(.compact)` to `.field` — which made the control *usable* (it had been
/// unpickable) without making it *good*.
///
/// The root problem both styles share is that the calendar is drawn by the system in a
/// presentation this app cannot reach. `.compact` opens an AppKit POPOVER: the capture
/// screen's `.environment(\.colorScheme, .dark)` pin does not travel into it (BackdateField
/// records this in its own comment) while the screen's inherited white foreground plausibly
/// does, so it renders white-on-light and, anchored inside a clipped scroll band, in the
/// wrong place. `.field` has no popup to mis-render, but it is a typed field at the system's
/// own small Mac size, with no calendar at all.
///
/// So the fix is to stop asking the system for a presentation we cannot style, and own it:
/// a button we draw (checkable by `CaptureLabelTests` like every other capture label) that
/// opens a SHEET we paint in the capture surface's own near-black, with the colour scheme
/// pinned and the foreground reset inside it. Nothing about the result depends on whether a
/// modifier propagates into a system-owned presentation — which is the property that made
/// both previous attempts unverifiable from here.
///
/// SwiftUI view bodies cannot be introspected, so these are source-scanning pins, the same
/// shape `CaptureLabelTests.testCaptureViewDoesNotReintroduceTheDimGreyLiteralsThisModelReplaced`
/// uses and for the same reason: without them the model could satisfy every rule while the
/// screen the owner looks at reverted to a system popover.
final class PrecisionDatePickerTests: XCTestCase {

    // MARK: - The Mac no longer routes through a presentation it cannot style

    func testMacOSCaptureDayPickerNoLongerUsesTheTypedFieldWorkaround() throws {
        XCTAssertFalse(
            try pickerSource().contains(".datePickerStyle(.field)"),
            "The Mac capture screen is back on `.field` — a typed date field with no "
            + "calendar, which the owner reported as worse than the iPhone's")
    }

    /// The `.compact` style must stay iOS-only. On the Mac it is the popover that could not
    /// be coloured or anchored; on the iPhone it is a sheet the system styles correctly and
    /// the owner reports reads well, so it is deliberately kept there.
    func testTheCompactSystemStyleIsCompiledForIOSOnly() throws {
        let source = try pickerSource()
        let compactUses = source.components(separatedBy: ".datePickerStyle(.compact)").count - 1
        XCTAssertEqual(
            compactUses, 1,
            "Expected exactly one `.datePickerStyle(.compact)` — the iOS branch. The macOS "
            + "branch must not use it: its calendar popover is a presentation this screen's "
            + "colour-scheme pin cannot reach")
        XCTAssertTrue(
            source.contains("#if os(macOS)"),
            "The macOS and iOS day pickers must stay compile-time separated")
    }

    func testMacOSCaptureDayPickerPresentsItsCalendarInASheetThisAppOwns() throws {
        let source = try pickerSource()
        XCTAssertTrue(
            source.contains(".sheet(isPresented:"),
            "The Mac day picker must open its calendar in a sheet this app presents — the "
            + "whole point is to stop depending on a system popover's styling")
        XCTAssertTrue(
            source.contains(".datePickerStyle(.graphical)"),
            "The sheet must contain a real calendar, not another typed field")
    }

    /// The load-bearing property of the fix. A sheet left on the system's own material would
    /// reintroduce exactly the bug being fixed: this screen sets a white foreground for its
    /// near-black surface, and that white is inherited into nested builders (owner smoke,
    /// 2026-08-15: the New Journal field was white-on-white for precisely this reason). By
    /// painting the capture surface inside the sheet and pinning the scheme to match, the
    /// sheet is self-consistent whatever does or does not propagate into it.
    func testTheMacOSSheetPaintsTheCaptureSurfaceRatherThanTrustingSystemMaterial() throws {
        let source = try pickerSource()
        XCTAssertTrue(
            source.contains("CaptureSurface.backgroundWhite"),
            "The Mac backdate sheet must paint the capture surface's own background — "
            + "hardcoding a colour here would silently drift from CaptureSurface")
        XCTAssertTrue(
            source.contains("\\.colorScheme, .dark"),
            "The sheet must pin the dark colour scheme to match the background it paints")
        XCTAssertTrue(
            source.contains("Color.primary"),
            "The sheet must reset the foreground the capture screen sets to white — under "
            + "the dark pin `Color.primary` resolves to white, so this both neutralises the "
            + "leak and colours the sheet correctly")
    }

    /// The button is a persistent label on the capture surface, so it is subject to the same
    /// contrast and point-size floors as every other one. Routing it through `captureLabel`
    /// is what puts it under `CaptureLabelTests` — a raw `.font(...)` here would render at
    /// the Mac's smaller default scale and be invisible to those tests, which is how the
    /// original legibility bug got in.
    func testTheMacOSDateButtonIsDrawnAsACheckedCaptureLabel() throws {
        XCTAssertTrue(
            try pickerSource().contains(".captureLabel(.backdateDateButton)"),
            "The Mac backdate button must draw itself with a CaptureLabel so its size and "
            + "contrast are checked by CaptureLabelTests")
        XCTAssertTrue(
            CaptureLabel.allCases.contains(.backdateDateButton),
            "backdateDateButton must be a CaptureLabel case for those floors to apply")
    }

    // MARK: - The precision segmented control (issue #58)

    /// Issue #58 names the entry-date precision segmented control among the capture-screen
    /// controls that render illegibly. It is not a colour-scheme problem — it is arithmetic:
    /// `BackdateField` wraps this picker in `.tint(.white)` AND `.foregroundStyle(.white)`,
    /// and on a segmented control the tint fills the SELECTED segment while the foreground
    /// draws its label. White fill under a white label is an invisible selection, in every
    /// appearance, on both platforms — so the owner cannot see which precision is active.
    ///
    /// Resetting the tint here rather than at the call site is deliberate: the call site's
    /// white tint is what makes the iOS `.compact` chip read well on the near-black surface,
    /// and the owner reports that one works. Only the segmented control needs the reset.
    func testThePrecisionPickerResetsTheCallSitesWhiteTintSoTheSelectionStaysVisible() throws {
        let source = try pickerSource()
        XCTAssertTrue(
            source.contains(".pickerStyle(.segmented)"),
            "Precondition: the precision control is a segmented picker")
        XCTAssertTrue(
            source.contains(".tint(Color.accentColor)"),
            "The segmented precision picker must reset the capture call site's white tint — "
            + "a white selection fill under a white label is an invisible selection")
    }

    /// The file's CODE, with every `//` comment stripped.
    ///
    /// Stripping is not tidiness — it is the difference between these tests meaning
    /// something and meaning nothing. This file documents its own history at length, so it
    /// *names* the very constructs asserted on above: an earlier draft of
    /// `testTheMacOSSheetPaintsTheCaptureSurface…` looked for `\.colorScheme, .dark` and
    /// passed before the fix existed, because a comment explaining that the pin does not
    /// reach a popover contained the phrase. That is the repo's standing vacuous-fixture
    /// shape — an assertion satisfied by prose about the thing rather than the thing.
    ///
    /// Line comments only; this file has no block comments, and no `//` inside a string
    /// literal. `testTheStripperActuallyRemovesProse` pins that the stripping happens.
    private func pickerSource() throws -> String {
        let raw = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()      // RaconteTests
                .deletingLastPathComponent()      // repo root
                .appendingPathComponent("Raconte/Capture/UI/PrecisionDatePicker.swift"),
            encoding: .utf8)
        return raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let slashes = line.range(of: "//") else { return line }
                return line[line.startIndex..<slashes.lowerBound]
            }
            .joined(separator: "\n")
    }

    /// Without this, `pickerSource()` could quietly stop stripping and every assertion above
    /// would go back to being satisfiable by a comment.
    func testTheStripperActuallyRemovesProse() throws {
        let code = try pickerSource()
        XCTAssertFalse(code.contains("owner smoke"), "comments are still present in the scan")
        XCTAssertFalse(code.contains("Owner smoke"), "comments are still present in the scan")
        XCTAssertTrue(code.contains("struct PrecisionDatePicker"), "the code itself was lost")
    }
}
