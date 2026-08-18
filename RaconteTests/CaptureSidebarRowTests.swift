import XCTest
@testable import Raconte

/// Nav T6, design §5: the sidebar's Capture row shows whether a recording is under way
/// from *any* other place — the visibility guarantee that makes "recording survives
/// navigation" trustworthy rather than a leap of faith. `CaptureSidebarRow` is the pure
/// core; `SidebarView`/`SidebarRowView` (untestable SwiftUI, pinned by
/// `NavigationUITests.testARecordingSurvivesNavigatingAwayAndComingBack`) only render it.
final class CaptureSidebarRowTests: XCTestCase {

    /// Quantified over EVERY `CaptureState` — the repo's own precedent
    /// (`MarkerControlsModel`'s `isEnabled == (phase == .recording)` across all cases,
    /// `CaptureLayoutModel.make`'s exhaustive switch). A hand-picked subset is how a new
    /// phase silently gets the wrong answer.
    func testIsLiveHoldsForExactlyTheCapturingPhases() {
        let capturing: Set<CaptureState> = [.preparing, .recording, .interrupted, .resuming, .stopping]
        for phase in CaptureState.allCases {
            XCTAssertEqual(CaptureSidebarRow.make(phase: phase, elapsed: 12).isLive,
                           capturing.contains(phase),
                           "\(phase)")
        }
    }

    func testElapsedTextIsPresentOnlyWhileLive() {
        XCTAssertEqual(CaptureSidebarRow.make(phase: .recording, elapsed: 65).elapsedText, "1:05")
        XCTAssertNil(CaptureSidebarRow.make(phase: .idle, elapsed: 65).elapsedText,
                     "an idle row showing a stale duration reads as a recording that is still running")
    }
}
