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
    /// iOS and macOS smart punctuation turns typed `"` into curly quotes; the phrase must still hold.
    func testCurlyQuotedPhraseIsAPhrase() {
        let query = SearchQuery(text: "\u{201C}new strings\u{201D}")
        XCTAssertEqual(query.pattern?.rawPattern, "\"new strings\"")
        XCTAssertEqual(query.terms, ["new", "strings"])
    }
    /// Pins what the pattern is built from: letters and numbers only, lowercased, each a prefix.
    /// A mutation that builds the pattern from the raw text fails the rows whose tokeniser
    /// output differs from that rule (case, punctuation-only, quoted punctuation).
    func testPatternTokenisation() {
        let rows: [(input: String, terms: [String], raw: String?)] = [
            ("Étaient", ["étaient"], "étaient*"),
            ("a-b", ["a", "b"], "a* b*"),
            ("col:x", ["col", "x"], "col* x*"),
            ("NOT x", ["not", "x"], "not* x*"),
            ("(", [], nil),
            ("*", [], nil),
            ("\"…\"", [], nil),
            ("…", [], nil),
            ("a …", ["a"], "a*"),
        ]
        var mismatches: [String] = []
        for row in rows {
            let query = SearchQuery(text: row.input)
            if query.terms != row.terms {
                mismatches.append("terms for \(row.input): \(query.terms)")
            }
            if query.pattern?.rawPattern != row.raw {
                mismatches.append("pattern for \(row.input): \(query.pattern?.rawPattern ?? "nil")")
            }
        }
        XCTAssertEqual(mismatches, [], "rows that differ from the rule")
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
