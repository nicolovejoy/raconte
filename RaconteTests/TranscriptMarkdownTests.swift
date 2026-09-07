import XCTest
@testable import Raconte

/// T11: `TranscriptMarkdown.render` derives `entries/<captureID>/transcript.md` from a
/// capture's current revision. Pure string transform — no I/O, no clock — so these are
/// plain value tests.
final class TranscriptMarkdownTests: XCTestCase {

    private func revision(id: String = ULID.make(), text: String = "hello world",
                          createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> TranscriptRevision {
        TranscriptRevision(id: id, source: .userEdit, createdAt: createdAt,
                           spans: [TranscriptSpan(text: text, anchor: .none)])
    }

    // MARK: render → body round-trips

    func testRenderThenBodyRoundTripsToTheRevisionsPlainText() {
        let captureID = ULID.make()
        let journalID = ULID.make()
        let revision = revision(text: "the quick brown fox")

        let document = TranscriptMarkdown.render(
            captureID: captureID, journalID: journalID, originalDate: "1998-03-04", revision: revision)

        XCTAssertEqual(TranscriptMarkdown.body(of: document), TranscriptChain.plainText(revision))
    }

    // MARK: nil revision renders an empty body

    func testNilRevisionRendersAnEmptyBody() {
        let document = TranscriptMarkdown.render(
            captureID: ULID.make(), journalID: nil, originalDate: nil, revision: nil)

        XCTAssertEqual(TranscriptMarkdown.body(of: document), "")
    }

    // MARK: nil journalID/originalDate/revision still produce well-formed frontmatter

    func testNilFieldsStillProduceParseableFrontmatterKeys() {
        let captureID = ULID.make()
        let document = TranscriptMarkdown.render(
            captureID: captureID, journalID: nil, originalDate: nil, revision: nil)

        XCTAssertTrue(document.contains("captureID: \(captureID)"))
        XCTAssertTrue(document.contains("revisionID: \n") || document.contains("revisionID: \n---"))
        XCTAssertTrue(document.contains("journalID: \n") || document.hasSuffix("journalID: "))
    }

    // MARK: frontmatter keys appear in a fixed order

    func testFrontmatterKeysAppearInAFixedOrder() {
        let document = TranscriptMarkdown.render(
            captureID: ULID.make(), journalID: ULID.make(), originalDate: "1998-03-04",
            revision: revision())

        let keys = ["captureID:", "revisionID:", "source:", "createdAt:", "journalID:", "originalDate:"]
        let indices = keys.map { key -> String.Index in
            guard let range = document.range(of: key) else {
                XCTFail("missing key \(key)")
                return document.startIndex
            }
            return range.lowerBound
        }
        XCTAssertEqual(indices, indices.sorted(),
                       "frontmatter keys must appear in the order \(keys)")
    }

    // MARK: A real revision's fields all land in the frontmatter

    func testFrontmatterCarriesCaptureRevisionJournalAndOriginalDate() {
        let captureID = ULID.make()
        let journalID = ULID.make()
        let rev = revision(text: "hello")

        let document = TranscriptMarkdown.render(
            captureID: captureID, journalID: journalID, originalDate: "1998-03-04", revision: rev)

        XCTAssertTrue(document.contains("captureID: \(captureID)"))
        XCTAssertTrue(document.contains("revisionID: \(rev.id)"))
        XCTAssertTrue(document.contains("source: userEdit"))
        XCTAssertTrue(document.contains("journalID: \(journalID)"))
        XCTAssertTrue(document.contains("originalDate: 1998-03-04"))
        XCTAssertEqual(TranscriptMarkdown.body(of: document), "hello")
    }
}
