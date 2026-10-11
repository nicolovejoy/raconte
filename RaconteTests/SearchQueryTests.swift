import XCTest
import GRDB
@testable import Raconte

final class SearchQueryTests: XCTestCase {
    func testTwoWordsBecomePrefixTokens() {
        let pattern = SearchQuery(text: "new str").pattern
        XCTAssertEqual(pattern?.rawPattern, "new* str*")
    }
    func testPunctuationOnlyHasNoPattern() {
        XCTAssertNil(SearchQuery(text: " … - ").pattern)
        XCTAssertNil(SearchQuery(text: "").pattern)
    }
    func testWhollyQuotedInputIsAPhrase() {
        XCTAssertEqual(SearchQuery(text: "\"new strings\"").pattern?.rawPattern, "\"new strings\"")
    }
    func testUnbalancedQuoteIsOrdinaryText() {
        XCTAssertEqual(SearchQuery(text: "\"new").pattern?.rawPattern, "new*")
    }
    func testTermsAreTheLowercasedTokens() {
        XCTAssertEqual(SearchQuery(text: "New  Strings").terms, ["new", "strings"])
        XCTAssertEqual(SearchQuery(text: "\"new strings\"").terms, ["new", "strings"])
    }
}

final class SearchSnippetTests: XCTestCase {
    private let o = SearchSnippet.openMarker, c = SearchSnippet.closeMarker
    func testMarkersBecomeRanges() {
        let s = SearchSnippet.parse("the new \(o)strings\(c) arrived")
        XCTAssertEqual(s.text, "the new strings arrived")
        XCTAssertEqual(s.matches.map { String(s.text[$0]) }, ["strings"])
    }
    func testNoMarkersNoMatches() {
        let s = SearchSnippet.parse("plain")
        XCTAssertEqual(s.text, "plain"); XCTAssertTrue(s.matches.isEmpty)
    }
    func testTwoMatchesAndOneAtTheEnd() {
        let s = SearchSnippet.parse("\(o)a\(c) b \(o)c\(c)")
        XCTAssertEqual(s.matches.map { String(s.text[$0]) }, ["a", "c"])
    }
    func testAttributedCarriesABackgroundOnEachMatch() {
        let s = SearchSnippet.parse("x \(o)y\(c) z")
        let runs = s.attributed.runs.filter { $0.backgroundColor != nil }
        XCTAssertEqual(runs.count, 1)
    }
}
