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
        let s = SearchSnippet.parse("x \(o)y\(c) z \(o)w\(c)")
        let attributed = s.attributed
        let highlighted = attributed.runs.filter { $0.backgroundColor != nil }
            .map { String(attributed[$0.range].characters) }
        XCTAssertEqual(highlighted, ["y", "w"])
        XCTAssertEqual(String(attributed.characters), "x y z w")
    }

    private func markerScalars(in text: String) -> [Unicode.Scalar] {
        text.unicodeScalars.filter { $0 == "\u{E000}" || $0 == "\u{E001}" }
    }

    /// FTS5 ends a token before a combining mark it does not fold, so the close marker lands
    /// directly in front of one. As Characters the two are one grapheme, which is neither the
    /// marker nor text: the marker leaked into the snippet and the match was lost. These are
    /// FTS5's own outputs for the three bodies.
    func testACloseMarkerInFrontOfACombiningMarkNeverLeaks() {
        let rows: [(name: String, marked: String, text: String, match: String)] = [
            // Keycap one: digit, U+FE0F, U+20E3.
            ("keycap", "step \(o)1\(c)\u{FE0F}\u{20E3} done", "step 1\u{FE0F}\u{20E3} done", "1"),
            // Devanagari: the token ends before the virama U+094D.
            ("devanagari", "\(o)\u{928}\u{92E}\u{938}\(c)\u{94D}\u{924}\u{947}",
             "\u{928}\u{92E}\u{938}\u{94D}\u{924}\u{947}", "\u{928}\u{92E}\u{938}"),
            // Arabic with harakat: each letter is followed by a fatha U+064E.
            ("arabic", "\(o)\u{643}\(c)\u{64E}\u{62A}\u{64E}\u{628}\u{64E}",
             "\u{643}\u{64E}\u{62A}\u{64E}\u{628}\u{64E}", "\u{643}"),
        ]
        for row in rows {
            let s = SearchSnippet.parse(row.marked)
            XCTAssertEqual(markerScalars(in: s.text), [], row.name)
            XCTAssertEqual(Array(s.text.unicodeScalars), Array(row.text.unicodeScalars), row.name)
            XCTAssertEqual(s.matches.map { Array(s.text[$0].unicodeScalars) },
                           [Array(row.match.unicodeScalars)], row.name)
        }
    }

    func testAnUnclosedOpenMarkerIsDropped() {
        let s = SearchSnippet.parse("\(o)a\(c) b \(o)c")
        XCTAssertEqual(markerScalars(in: s.text), [])
        XCTAssertEqual(s.text, "a b c")
        XCTAssertEqual(s.matches.map { String(s.text[$0]) }, ["a"])
    }

    func testAStrayCloseMarkerIsDropped() {
        let s = SearchSnippet.parse("a\(c) b \(o)c\(c)\(c) d")
        XCTAssertEqual(markerScalars(in: s.text), [])
        XCTAssertEqual(s.text, "a b c d")
        XCTAssertEqual(s.matches.map { String(s.text[$0]) }, ["c"])
    }
}
