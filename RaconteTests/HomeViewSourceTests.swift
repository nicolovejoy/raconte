import XCTest
@testable import Raconte

/// #162: pins that `HomeView` reads its three graded sizes off `TypeScale`, never a bare
/// `.font(.system(size:))` literal for those rows — a source-level check because the actual
/// rendered size is not reachable from XCUITest (repo memory: SwiftUI text styles differ in
/// size across platforms, and literal sizes don't come back out through the AX tree either).
final class HomeViewSourceTests: XCTestCase {

    private func homeSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // RaconteTests
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("Raconte/Home/UI/HomeView.swift")
        return strippingComments(try String(contentsOf: url))
    }

    func testHomeViewUsesTypeScaleTokensNotBareLiterals() throws {
        let source = try homeSource()
        XCTAssertTrue(source.contains("TypeScale.homeFaceOutTitle"))
        XCTAssertTrue(source.contains("TypeScale.homeSpineTitle"))
        XCTAssertTrue(source.contains("TypeScale.homeRelativeTime"))
        XCTAssertFalse(source.contains(".font(.system(size: 13, weight: .medium))"),
                       "the face-out title must not fall back to the old bare literal")
        XCTAssertFalse(source.contains(".font(.system(size: 11))"),
                       "the relative-time row must not fall back to the old bare literal")
        XCTAssertFalse(source.contains(".font(.system(size: 17, design: .serif))"),
                       "the spine title must not fall back to the old bare literal")
    }
}
