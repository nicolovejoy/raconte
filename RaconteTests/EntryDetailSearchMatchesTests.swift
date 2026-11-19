import XCTest
@testable import Raconte

/// #194 Task 12: the match bar of an entry opened from Search, as a pure value. The view
/// highlights paragraph `i` with `matches(inParagraph: i)` and marks
/// `currentIndexWithin(i)` of them as current; the bar shows `label`.
final class SearchMatchCursorTests: XCTestCase {

    func testLabelAndWrap() {
        var c = SearchMatchCursor(paragraphTexts: ["a b", "c a"], terms: ["a"])
        XCTAssertEqual(c.label, "1 of 2"); XCTAssertEqual(c.currentParagraph, 0)
        c.next(); XCTAssertEqual(c.label, "2 of 2"); XCTAssertEqual(c.currentParagraph, 1)
        c.next(); XCTAssertEqual(c.label, "1 of 2")        // wraps
        c.previous(); XCTAssertEqual(c.label, "2 of 2")
    }

    /// Review focus 3: an entry edited after it was indexed can hold none of the words the
    /// list found. The bar says so and nothing it does can index past the matches.
    func testNoMatchesIsZeroOfZeroAndNextIsANoOp() {
        var c = SearchMatchCursor(paragraphTexts: ["x"], terms: ["q"])
        XCTAssertEqual(c.label, "0 of 0"); XCTAssertNil(c.currentParagraph)
        c.next(); XCTAssertEqual(c.label, "0 of 0")
        c.previous(); XCTAssertEqual(c.label, "0 of 0"); XCTAssertNil(c.current)
        XCTAssertEqual(c.total, 0)
        XCTAssertNil(c.currentIndexWithin(0))
        XCTAssertEqual(c.matches(inParagraph: 0), [])
    }

    /// The current match is named inside its own paragraph only, as an index into the same
    /// array that paragraph is highlighted with (Task 11 review).
    func testCurrentIndexWithinNamesTheMatchInItsOwnParagraphOnly() {
        let texts = ["a x a", "b a"]
        var c = SearchMatchCursor(paragraphTexts: texts, terms: ["a"])
        XCTAssertEqual(c.total, 3)
        XCTAssertEqual(c.paragraphMatches.map(\.count), [2, 1])

        XCTAssertEqual(c.currentIndexWithin(0), 0); XCTAssertNil(c.currentIndexWithin(1))
        c.next()
        XCTAssertEqual(c.currentIndexWithin(0), 1); XCTAssertNil(c.currentIndexWithin(1))
        let second = c.matches(inParagraph: 0)[1]
        XCTAssertEqual(texts[0].distance(from: texts[0].startIndex, to: second.lowerBound), 4,
                       "the second match of paragraph 0 is the last `a`")
        c.next()
        XCTAssertNil(c.currentIndexWithin(0)); XCTAssertEqual(c.currentIndexWithin(1), 0)
        XCTAssertEqual(c.currentParagraph, 1)

        XCTAssertNil(c.currentIndexWithin(7), "a paragraph past the end has no current match")
        XCTAssertEqual(c.matches(inParagraph: 7), [], "a paragraph past the end has no matches")
        XCTAssertEqual(c.matches(inParagraph: -1), [])
    }

    /// `SearchView` passes a highlight even for no terms; an empty term is a prefix of every
    /// word. No terms is no highlight: no cursor, so no bar and today's rendering.
    func testNoTermsIsNoCursor() {
        XCTAssertNil(SearchMatchCursor.forEntry(highlight: nil, paragraphTexts: ["a"]))
        XCTAssertNil(SearchMatchCursor.forEntry(highlight: SearchHighlight(terms: []), paragraphTexts: ["a"]))
        XCTAssertNil(SearchMatchCursor.forEntry(highlight: SearchHighlight(terms: [""]), paragraphTexts: ["a"]))
        // Positive control: a real term over the same text is a cursor.
        let c = SearchMatchCursor.forEntry(highlight: SearchHighlight(terms: ["a"]), paragraphTexts: ["a"])
        XCTAssertEqual(c?.label, "1 of 1")
        // And a real term that finds nothing is still a cursor: the bar says "0 of 0".
        XCTAssertEqual(SearchMatchCursor.forEntry(highlight: SearchHighlight(terms: ["q"]),
                                                  paragraphTexts: ["a"])?.label, "0 of 0")
    }

    // MARK: The texts the cursor is built over

    private func paragraph(_ text: String) -> TranscriptAttribution.Paragraph {
        TranscriptAttribution.Paragraph(voice: nil, text: text, hasApproximateBoundary: false)
    }

    /// The cursor's paragraphs are the paragraphs the screen renders, one for one: the
    /// paragraph branch's texts, or the single text. `paragraphs == []` with text present
    /// renders the single text (`transcriptDisplay`), so it is one paragraph here too.
    @MainActor
    func testSearchParagraphTextsFollowWhatTheScreenRenders() {
        XCTAssertEqual(EntryDetailView.searchParagraphTexts(.attributed([paragraph("one"), paragraph("two")])),
                       ["one", "two"])
        XCTAssertEqual(EntryDetailView.searchParagraphTexts(.plain("only")), ["only"])
        XCTAssertEqual(EntryDetailView.searchParagraphTexts(.absent), [])
        XCTAssertEqual(EntryDetailView.searchParagraphTexts(.unreadable), [])
        XCTAssertEqual(EntryDetailView.searchParagraphTexts(.empty), [])

        let emptyParagraphs = EntryTranscript(state: .present, text: "hello world",
                                              degradations: [], paragraphs: [])
        XCTAssertEqual(EntryDetailView.searchParagraphTexts(EntryDetailView.transcriptDisplay(emptyParagraphs)),
                       ["hello world"])
    }
}
