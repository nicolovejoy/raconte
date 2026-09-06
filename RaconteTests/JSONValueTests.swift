import XCTest
@testable import Raconte

final class JSONValueTests: XCTestCase {
    func testRoundTripsEveryShapeByteForByteUnderSortedKeys() throws {
        let text = #"{"a":[1,2.5,"x",true,null],"b":{"c":false},"d":"s","e":123456789012345678}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(String(decoding: try encoder.encode(value), as: UTF8.self), text)
    }
}
