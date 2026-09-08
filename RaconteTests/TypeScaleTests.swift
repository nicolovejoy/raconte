import XCTest
import SwiftUI
@testable import Raconte

/// #162: the owner's type-size rulings (2026-09-08) as build-time facts. Sizes are stated in
/// points, per platform — never as text-style names, which differ in size across platforms.
final class TypeScaleTests: XCTestCase {

    private func appSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // RaconteTests
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("Raconte/App/RaconteApp.swift")
        return strippingComments(try String(contentsOf: url))
    }

    /// iOS: smallest text up the most, largest not at all. 13/17/11 were the literals before.
    /// macOS: everything ×1.3.
    func testHomeSizesFollowTheRuling() {
        #if os(macOS)
        XCTAssertEqual(TypeScale.homeFaceOutTitle, 17)
        XCTAssertEqual(TypeScale.homeSpineTitle, 22)
        XCTAssertEqual(TypeScale.homeRelativeTime, 14)
        #else
        XCTAssertEqual(TypeScale.homeFaceOutTitle, 16, "+20% over 13")
        XCTAssertEqual(TypeScale.homeSpineTitle, 19, "+10% over 17")
        XCTAssertEqual(TypeScale.homeRelativeTime, 14, "+30% over 11")
        #endif
    }

    /// The macOS bump is one Dynamic Type step above the default's +24%: `.xxxLarge`.
    func testMacDynamicTypeSizeIsXXXLarge() {
        XCTAssertEqual(TypeScale.macDynamicTypeSize, .xxxLarge)
    }

    /// The bump is applied once, at the scene root, inside the macOS-only block — not
    /// per screen, and never on iOS.
    func testTheSceneAppliesTheMacBumpInsideTheMacOSBlock() throws {
        let source = try appSource()
        guard let macBlock = source.range(of: "#if os(macOS)"),
              let endBlock = source.range(of: "#endif", range: macBlock.upperBound..<source.endIndex) else {
            return XCTFail("RaconteApp.swift has no #if os(macOS) block")
        }
        let inside = source[macBlock.upperBound..<endBlock.lowerBound]
        XCTAssertTrue(inside.contains(".dynamicTypeSize(TypeScale.macDynamicTypeSize)"),
                      "the macOS bump must sit in the scene's #if os(macOS) block")
        XCTAssertEqual(source.components(separatedBy: ".dynamicTypeSize(").count - 1, 1,
                       "exactly one dynamicTypeSize call in the scene")
    }
}
