import XCTest
@testable import Raconte

/// T7 plan step 3: the detail view's pure display-decision function. SwiftUI body
/// rendering isn't unit-testable here (no snapshot harness), so this is the red-first
/// unit for the view layer — `EntryDetailView.transcriptDisplay` is a thin decision
/// function with no I/O, and the view itself is a thin `switch` over its result.
final class EntryDetailViewTranscriptDisplayTests: XCTestCase {

    private func paragraph(voice: String? = "ln", text: String = "hello",
                           approx: Bool = false) -> TranscriptAttribution.Paragraph {
        TranscriptAttribution.Paragraph(voice: voice, text: text, hasApproximateBoundary: approx)
    }

    func testPlainWhenParagraphsAreNil() {
        let transcript = EntryTranscript(state: .present, text: "hello world",
                                         degradations: [], paragraphs: nil)
        XCTAssertEqual(EntryDetailView.transcriptDisplay(transcript), .plain("hello world"))
    }

    func testPlainWhenParagraphsAreEmpty() {
        let transcript = EntryTranscript(state: .present, text: "hello world",
                                         degradations: [], paragraphs: [])
        XCTAssertEqual(EntryDetailView.transcriptDisplay(transcript), .plain("hello world"))
    }

    func testAttributedWhenParagraphsExist() {
        let paragraphs = [paragraph(voice: "ln", text: "first"),
                          paragraph(voice: "bn", text: "second")]
        let transcript = EntryTranscript(state: .present, text: "first second",
                                         degradations: [], paragraphs: paragraphs)
        XCTAssertEqual(EntryDetailView.transcriptDisplay(transcript), .attributed(paragraphs))
    }

    func testEmptyAndAbsentAndUnreadableStatesAreUnchanged() {
        let absent = EntryTranscript(state: .absent, text: nil, degradations: [])
        XCTAssertEqual(EntryDetailView.transcriptDisplay(absent), .absent)

        let unreadable = EntryTranscript(state: .unreadable, text: nil,
                                         degradations: [.transcriptUnreadable])
        XCTAssertEqual(EntryDetailView.transcriptDisplay(unreadable), .unreadable)

        let empty = EntryTranscript(state: .present, text: "", degradations: [], paragraphs: nil)
        XCTAssertEqual(EntryDetailView.transcriptDisplay(empty), .empty)

        // Paragraphs present but text absent (defensive — shouldn't happen from the
        // loader, but the decision function must not crash on it): paragraphs win.
        let paragraphsNoText = EntryTranscript(state: .present, text: nil, degradations: [],
                                               paragraphs: [paragraph()])
        XCTAssertEqual(EntryDetailView.transcriptDisplay(paragraphsNoText), .attributed([paragraph()]))
    }
}
