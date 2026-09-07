import XCTest
@testable import Raconte

/// #139: journal rows sit under Capture as children of the list, and the owner wants
/// the hierarchy to read at a glance — an indent on the journal rows only.
final class SidebarRowInsetTests: XCTestCase {
    func testJournalRowsAreIndentedAndSystemRowsAreNot() {
        XCTAssertGreaterThan(SidebarRowView.leadingInset(isJournal: true), 0)
        XCTAssertEqual(SidebarRowView.leadingInset(isJournal: false), 0)
    }

    /// The rule must actually be applied to the row, or the test above pins nothing.
    func testTheRowAppliesTheInsetRule() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // RaconteTests
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("Raconte/App/SidebarView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let code = strippingComments(source)
        XCTAssertTrue(code.contains("leadingInset(isJournal: row.journalID != nil)"),
                      "SidebarRowView must pad its title group by leadingInset(isJournal:)")
    }

    // MARK: - Sidebar containment (#67 item 3): the tick-rate read moved out

    /// `CaptureLiveBadge` is the only view that may read `.elapsed`; `SidebarView` must
    /// no longer re-evaluate once per second while a capture is running. A source pin,
    /// not a behavioral test — SwiftUI's fine-grained `@Observable` invalidation isn't
    /// otherwise directly assertable from XCTest.
    func testSidebarViewNoLongerReadsElapsedAndTheBadgeDoes() throws {
        let sidebarView = try source("Raconte/App/SidebarView.swift")
        XCTAssertFalse(sidebarView.contains(".elapsed"),
                       "SidebarView must not read .elapsed itself — CaptureLiveBadge owns that read")

        let badge = try source("Raconte/App/CaptureLiveBadge.swift")
        XCTAssertTrue(badge.contains(".elapsed"),
                      "CaptureLiveBadge must be the view that reads .elapsed")
    }

    // MARK: - Capture screen containment (#155): the same read, moved out of CaptureView

    /// `CaptureStatusReadout` and `CaptureMicMeterReadout` are the only views on the
    /// capture screen that may read tick-rate coordinator state (`.elapsed`, `.micLevel`
    /// — both assigned by `CaptureCoordinator.tick()` on its ~100 ms loop); `CaptureView`
    /// must no longer re-evaluate its whole body on every tick while recording. Same shape
    /// as the sidebar pin above — a source pin, because `@Observable` invalidation
    /// granularity is not assertable from XCTest.
    func testCaptureViewNoLongerReadsTickRateStateAndTheReadoutsDo() throws {
        let captureView = try source("Raconte/Capture/UI/CaptureView.swift")
        XCTAssertFalse(captureView.contains(".elapsed"),
                       "CaptureView must not read .elapsed itself — CaptureStatusReadout owns that read")
        XCTAssertFalse(captureView.contains(".micLevel"),
                       "CaptureView must not read .micLevel itself — CaptureMicMeterReadout owns that read")

        let readout = try source("Raconte/Capture/UI/CaptureStatusReadout.swift")
        XCTAssertTrue(readout.contains(".elapsed"),
                      "CaptureStatusReadout must be the view that reads .elapsed")

        let micReadout = try source("Raconte/Capture/UI/CaptureMicMeterReadout.swift")
        XCTAssertTrue(micReadout.contains(".micLevel"),
                      "CaptureMicMeterReadout must be the view that reads .micLevel")
    }

    /// Repo-relative source, comments stripped, for the containment pins below.
    private func source(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // RaconteTests
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent(relativePath)
        return strippingComments(try String(contentsOf: url, encoding: .utf8))
    }
}
