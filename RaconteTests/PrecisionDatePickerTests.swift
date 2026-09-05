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
/// screen's `.environment(\.colorScheme, .dark)` pin does not travel into it
/// (`BackdateEditorContent` records this in its own comment) while the screen's inherited
/// white foreground plausibly does, so it renders white-on-light and, anchored inside a
/// clipped scroll band, in the wrong place. `.field` has no popup to mis-render, but it
/// is a typed field at the system's own small Mac size, with no calendar at all.
///
/// So the fix is to stop asking the system for a presentation we cannot style, and own it:
/// a button we draw (checkable by `CaptureLabelTests` like every other capture label) that
/// opens a POPOVER we paint in the capture surface's own near-black, with the colour scheme
/// pinned and the foreground reset inside it, and month + year dropdowns above the calendar.
/// Nothing about the result depends on whether a modifier propagates into a system-owned
/// presentation — which is the property that made both previous attempts unverifiable here.
///
/// It began as a sheet; owner smoke on 2026-08-16 sent it to a popover (dismissal) and added
/// the dropdowns (reaching a past year). See the individual tests for both.
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

    /// A POPOVER, not a sheet — and the change is the owner's, not a preference.
    ///
    /// Smoke, 2026-08-16: "the modal you surface for the day picker is a little bit dumb in
    /// the sense that the escape key doesn't close it, or clicking outside… you have to click
    /// on the Done button, which is excessive." All true, and all inherent to a sheet: on
    /// macOS a sheet is modal to its window and dismisses only through its own controls.
    /// A popover dismisses on Escape and on click-outside natively, which is why it is the
    /// idiom the system's own date chip uses.
    ///
    /// This does NOT reopen the bug the sheet was introduced to fix. What could not be
    /// styled was the popover the SYSTEM builds inside `.datePickerStyle(.compact)`; the
    /// content of a `.popover` this app presents is an ordinary view hierarchy, so the same
    /// background, scheme pin and foreground reset apply exactly as they did to the sheet.
    func testMacOSCaptureDayPickerPresentsItsCalendarInAPopoverThisAppOwns() throws {
        let source = try pickerSource()
        XCTAssertTrue(
            source.contains(".popover(isPresented:"),
            "The Mac day picker must open its calendar in a popover this app presents — a "
            + "sheet cannot be dismissed by Escape or by clicking away, which the owner "
            + "reported as excessive")
        XCTAssertFalse(
            source.contains(".sheet(isPresented:"),
            "the sheet must be gone, not merely supplemented")
        XCTAssertTrue(
            source.contains(".datePickerStyle(.graphical)"),
            "The popover must contain a real calendar, not another typed field")
    }

    /// The Done button was the only way out of the sheet; a popover needs no such button,
    /// and keeping one would preserve the thing that was called excessive.
    func testTheDayCalendarHasNoDoneButton() throws {
        XCTAssertFalse(
            try pickerSource().contains("\"Done\""),
            "a popover dismisses on Escape and click-away — an explicit Done is the "
            + "excessive step the owner asked to remove")
    }

    /// The load-bearing property of the fix. A sheet left on the system's own material would
    /// reintroduce exactly the bug being fixed: this screen sets a white foreground for its
    /// near-black surface, and that white is inherited into nested builders (owner smoke,
    /// 2026-08-15: the New Journal field was white-on-white for precisely this reason). By
    /// painting the capture surface inside the sheet and pinning the scheme to match, the
    /// sheet is self-consistent whatever does or does not propagate into it.
    func testTheMacOSPopoverPaintsTheCaptureSurfaceRatherThanTrustingSystemMaterial() throws {
        let source = try pickerSource()
        XCTAssertTrue(
            source.contains("CaptureSurface.backgroundWhite"),
            "The Mac backdate popover must paint the capture surface's own background — "
            + "hardcoding a colour here would silently drift from CaptureSurface")
        XCTAssertTrue(
            source.contains("\\.colorScheme, .dark"),
            "The popover must pin the dark colour scheme to match the background it paints")
        XCTAssertTrue(
            source.contains("Color.primary"),
            "The sheet must reset the foreground the capture screen sets to white — under "
            + "the dark pin `Color.primary` resolves to white, so this both neutralises the "
            + "leak and colours the popover correctly")
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

    // MARK: - Picking a day in a past year (owner smoke, 2026-08-16)

    /// "if you want to pick a day in a past year it's not very straightforward, as there is
    /// no year picker in the day picker — you have to scroll back month by month."
    ///
    /// macOS's `.graphical` DatePicker offers only prev/next month arrows, so reaching 1998
    /// is ~340 clicks. The workaround he found — drop to Year precision, pick the year, go
    /// back to Day — proves the components exist; they were just not offered where the work
    /// happens. The month and year dropdowns are now part of the Mac day calendar itself.
    func testTheMacOSDayCalendarOffersMonthAndYearDropdowns() throws {
        let source = try pickerSource()
        XCTAssertTrue(
            source.contains("dayCalendarHeader"),
            "The Mac day calendar must carry its own month + year dropdowns — without them "
            + "a 1998 journal page is reachable only by ~340 clicks on the month arrow")
    }

    /// The dropdowns are only worth having if the calendar below follows them, which means
    /// they must write into the SAME binding the calendar reads.
    func testTheDayCalendarDropdownsDriveTheSameDateTheCalendarShows() throws {
        let source = try pickerSource()
        XCTAssertTrue(
            source.contains("componentBinding(.month)") && source.contains("componentBinding(.year)"),
            "month/year dropdowns must write through componentBinding, the same `date` the "
            + "graphical calendar is bound to, or changing them would not move the calendar")
    }

    // MARK: - The month/year setter, now that a month dropdown exists at .day precision

    /// The bug exposing a month dropdown at `.day` precision would otherwise ship.
    ///
    /// `Calendar.date(from:)` is LENIENT: day 31 with month set to February does not clamp,
    /// it rolls forward to March 3. The old setter guarded this for `.yearMonth` and `.year`
    /// (which overwrite the day with 1 anyway) and left `.day` — the one precision that
    /// keeps its day — completely unguarded, because no UI could reach it. The dropdown can.
    func testChangingMonthAtDayPrecisionClampsRatherThanRollingIntoTheNextMonth() {
        let cal = Self.fixedCalendar
        let jan31 = cal.date(from: DateComponents(year: 2026, month: 1, day: 31, hour: 12))!
        let result = PrecisionDatePicker.adjusted(jan31, setting: .month, to: 2,
                                                  precision: .day, calendar: cal)
        XCTAssertEqual(cal.component(.month, from: result), 2,
                       "landed outside February — the lenient roll-forward is back")
        XCTAssertEqual(cal.component(.day, from: result), 28,
                       "day should clamp to the last day of the target month")
    }

    func testChangingYearAtDayPrecisionClampsLeapDay() {
        let cal = Self.fixedCalendar
        let leapDay = cal.date(from: DateComponents(year: 2024, month: 2, day: 29, hour: 12))!
        let result = PrecisionDatePicker.adjusted(leapDay, setting: .year, to: 2025,
                                                  precision: .day, calendar: cal)
        XCTAssertEqual(cal.component(.month, from: result), 2, "rolled out of February")
        XCTAssertEqual(cal.component(.day, from: result), 28, "Feb 29 must clamp to Feb 28")
    }

    /// Clamping must not "fix" dates that were never broken.
    func testAnOrdinaryMonthChangeKeepsTheDay() {
        let cal = Self.fixedCalendar
        let mar15 = cal.date(from: DateComponents(year: 2020, month: 3, day: 15, hour: 12))!
        let result = PrecisionDatePicker.adjusted(mar15, setting: .month, to: 4,
                                                  precision: .day, calendar: cal)
        XCTAssertEqual(cal.component(.month, from: result), 4)
        XCTAssertEqual(cal.component(.day, from: result), 15)
    }

    /// The reduced precisions keep their existing behaviour exactly: day forced to 1, hour
    /// to noon so a westward timezone cannot roll the displayed month back a day.
    func testReducedPrecisionsStillNormaliseToDayOneAtNoon() {
        let cal = Self.fixedCalendar
        let jan31 = cal.date(from: DateComponents(year: 2026, month: 1, day: 31, hour: 12))!

        let month = PrecisionDatePicker.adjusted(jan31, setting: .month, to: 2,
                                                 precision: .yearMonth, calendar: cal)
        XCTAssertEqual(cal.component(.day, from: month), 1)
        XCTAssertEqual(cal.component(.month, from: month), 2)
        XCTAssertEqual(cal.component(.hour, from: month), 12)

        let year = PrecisionDatePicker.adjusted(jan31, setting: .year, to: 1998,
                                                precision: .year, calendar: cal)
        XCTAssertEqual(cal.component(.year, from: year), 1998)
        XCTAssertEqual(cal.component(.month, from: year), 1)
        XCTAssertEqual(cal.component(.day, from: year), 1)
        XCTAssertEqual(cal.component(.hour, from: year), 12)
    }

    /// Fixed zone: a bare `Calendar.current` would make these assertions depend on where the
    /// machine running them happens to be, which this repo has already been bitten by (a
    /// near-epoch backdate fixture that passed in Pacific and failed on CI in UTC).
    private static var fixedCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }

    // MARK: - The precision segmented control (issue #58)

    /// Issue #58 names the entry-date precision segmented control among the capture-screen
    /// controls that render illegibly. It is not a colour-scheme problem — it is arithmetic:
    /// `BackdateEditorContent`'s caller used to wrap this picker in `.tint(.white)` AND
    /// `.foregroundStyle(.white)`, and on a segmented control the tint fills the SELECTED
    /// segment while the foreground draws its label. White fill under a white label is an
    /// invisible selection, in every appearance, on both platforms — so the owner cannot
    /// see which precision is active.
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
        return strippingComments(raw)
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
