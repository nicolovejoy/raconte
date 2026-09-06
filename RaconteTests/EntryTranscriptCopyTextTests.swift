import XCTest
@testable import Raconte

/// #105: one action copies the whole transcript. Paragraph structure (voice/¶ markers)
/// is kept as blank-line breaks, so what lands on the clipboard reads like the screen.
final class EntryTranscriptCopyTextTests: XCTestCase {
    func testPlainTextCopiesVerbatim() {
        let t = EntryTranscript(state: .present, text: "one two", degradations: [])
        XCTAssertEqual(t.copyText, "one two")
    }

    func testAttributedParagraphsAreJoinedWithBlankLines() {
        var t = EntryTranscript(state: .present, text: "one two three", degradations: [])
        t.paragraphs = [
            TranscriptAttribution.Paragraph(voice: "bn", text: "one two", hasApproximateBoundary: false),
            TranscriptAttribution.Paragraph(voice: "ln", text: "three", hasApproximateBoundary: false),
        ]
        XCTAssertEqual(t.copyText, "one two\n\nthree")
    }

    func testNothingToCopyIsNil() {
        XCTAssertNil(EntryTranscript(state: .absent, text: nil, degradations: []).copyText)
        XCTAssertNil(EntryTranscript(state: .present, text: "", degradations: []).copyText)
    }
}
