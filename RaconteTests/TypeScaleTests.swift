import XCTest
import SwiftUI
@testable import Raconte

/// #162: the owner's type-size rulings (2026-09-08) as build-time facts. Sizes are stated in
/// points, per platform — never as text-style names, which differ in size across platforms.
final class TypeScaleTests: XCTestCase {

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
}
