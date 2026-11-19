import XCTest
import SwiftUI
@testable import Raconte

final class TranscriptHighlighterTests: XCTestCase {
    func testWordStartPrefixOnly() {
        let t = "strings restring string"
        let r = TranscriptHighlighter.matches(in: t, terms: ["string"])
        // The prefix, not the whole word, and nothing inside "restring".
        XCTAssertEqual(r.map { String(t[$0]) }, ["string", "string"])
        XCTAssertEqual(r.map { t.distance(from: t.startIndex, to: $0.lowerBound) }, [0, 17])
    }
    func testCaseAndDiacriticsFold() {
        let t = "Étaient etaient ÉTAIENT"
        XCTAssertEqual(TranscriptHighlighter.matches(in: t, terms: ["etai"]).count, 3)
    }
    func testMultipleTermsInTextOrder() {
        let t = "b a b"
        XCTAssertEqual(TranscriptHighlighter.matches(in: t, terms: ["a", "b"]).map { t.distance(from: t.startIndex, to: $0.lowerBound) }, [0, 2, 4])
    }
    func testCurrentMatchHasADifferentBackground() {
        let t = "a a"
        let ranges = TranscriptHighlighter.matches(in: t, terms: ["a"])
        let s = TranscriptHighlighter.attributed(t, matches: ranges, current: 1)
        let colours = s.runs.compactMap(\.backgroundColor)
        XCTAssertEqual(colours.count, 2)
        // Compared by resolved opacity: `Color ==` on two `.opacity(_:)` colours is, as observed, not a
        // value comparison, so `XCTAssertNotEqual` on them passes whatever the tones are.
        let opacities = colours.map { $0.resolve(in: EnvironmentValues()).opacity }
        XCTAssertGreaterThan(opacities[1], opacities[0], "the current match is the stronger tone")
        XCTAssertGreaterThan(opacities[0], 0)
    }
    func testNoTermsNoMatches() {
        XCTAssertTrue(TranscriptHighlighter.matches(in: "x", terms: []).isEmpty)
        // An empty term is a prefix of every word; it must not match them all.
        XCTAssertTrue(TranscriptHighlighter.matches(in: "x y", terms: [""]).isEmpty)
    }
    func testDestinationDefaultKeepsOldCallSitesEqual() {
        XCTAssertEqual(LibraryDestination.entry("A"), .entry("A", highlight: nil))
        XCTAssertNotEqual(LibraryDestination.entry("A"), .entry("A", highlight: SearchHighlight(terms: ["x"])))
    }

    // The index splits at an apostrophe (Task 3 pins it); the highlighter must too, or the
    // list promises a match the entry shows as "0 of 0".
    func testElidedWordMatchesItsStem() {
        let t = "l'école d'été"
        XCTAssertEqual(TranscriptHighlighter.matches(in: t, terms: ["ecole"]).map { String(t[$0]) }, ["école"])
    }
    // Terms are folded too: SearchQuery.terms lowercases but keeps accents.
    func testAccentedTermMatchesUnaccentedText() {
        XCTAssertEqual(TranscriptHighlighter.matches(in: "etaient", terms: ["étai"]).count, 1)
    }
}
