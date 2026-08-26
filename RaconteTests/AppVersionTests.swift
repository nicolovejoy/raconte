import XCTest
@testable import Raconte

/// #89: the About page's version row. Pure-core matrix — the shell (`current(bundle:)`)
/// is two dictionary reads and is exercised implicitly by the About UI test.
final class AppVersionTests: XCTestCase {

    func testBothComponentsRenderAsMarketingVersionThenBuildInParens() {
        XCTAssertEqual(AppVersion.displayString(short: "1.0", build: "7"), "1.0 (7)")
    }

    func testMissingBuildFallsBackToShortAlone() {
        XCTAssertEqual(AppVersion.displayString(short: "1.0", build: nil), "1.0")
        XCTAssertEqual(AppVersion.displayString(short: "1.0", build: ""), "1.0",
                       "empty string is as absent as nil — never render '1.0 ()'")
    }

    func testMissingShortFallsBackToBuildAlone() {
        XCTAssertEqual(AppVersion.displayString(short: nil, build: "7"), "7")
        XCTAssertEqual(AppVersion.displayString(short: "", build: "7"), "7")
    }

    func testNeitherComponentSaysUnknownRatherThanRenderingEmpty() {
        XCTAssertEqual(AppVersion.displayString(short: nil, build: nil), "unknown")
        XCTAssertEqual(AppVersion.displayString(short: "", build: ""), "unknown")
    }

    func testCurrentReadsTheHostBundlesRealKeys() {
        // The unit suite runs hosted in the real Raconte.app, whose Info.plist
        // carries both keys — so this pins the shell's key names against a live
        // bundle rather than a fixture.
        let result = AppVersion.current()
        XCTAssertNotEqual(result, "unknown")
        XCTAssertTrue(result.contains("("), "expected 'short (build)' from the app bundle, got \(result)")
    }
}
