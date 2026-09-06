import XCTest
@testable import Raconte

/// #141: the About row reads `build N: <date>` — N is CFBundleVersion, bumped for every
/// build the owner is handed, and the date is the link time in Pacific.
final class BuildInfoTests: XCTestCase {
    private let sep5 = ISO8601DateFormatter().date(from: "2026-09-05T17:26:00Z")!  // 10:26 AM PDT

    func testNumberAndDateRenderAsBuildNColonDate() {
        XCTAssertEqual(BuildInfo.stampText(build: "14", builtAt: sep5), "build 14: Sep 5, 10:26 AM PT")
    }

    func testMissingNumberFallsBackToTheOldBuiltForm() {
        XCTAssertEqual(BuildInfo.stampText(build: nil, builtAt: sep5), "built Sep 5, 10:26 AM PT")
        XCTAssertEqual(BuildInfo.stampText(build: "", builtAt: sep5), "built Sep 5, 10:26 AM PT")
    }

    func testMissingDateStillShowsTheNumber() {
        XCTAssertEqual(BuildInfo.stampText(build: "14", builtAt: nil), "build 14: date unavailable")
        XCTAssertEqual(BuildInfo.stampText(build: nil, builtAt: nil), "build date unavailable")
    }

    /// The bundle really carries the number the row shows — the pin against a stale
    /// project.yml comment or an Info.plist that lost the key.
    func testTheLiveStampCarriesTheBundlesBuildNumber() throws {
        let build = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
        XCTAssertTrue(BuildInfo.stamp.hasPrefix("build \(build): "), BuildInfo.stamp)
    }
}
