import XCTest
@testable import Raconte

/// The post-stop receipt's rules (owner ruling 2026-08-15, capture-landing option B).
///
/// Its reason for existing is a UX report — after Done, the finished transcript sat on the
/// landing screen as loose, unheaded, untappable text — but the rules it encodes are
/// ordinary and checkable: what the summary line says, and how it behaves when the
/// transcript is anything other than perfect. The degraded cases are the ones worth
/// pinning: they run on the path that has just made a recording safe, and a receipt that
/// renders a blank box there reads as "your recording is gone".
@MainActor
final class CaptureReceiptTests: XCTestCase {

    private func entry(captureID: String = "01ABC",
                       duration: Double = 16,
                       multiVoice: Bool = false,
                       backdate: PartialDate? = nil) -> EntryListItem {
        var metadata = EntryMetadata.defaults
        metadata.multiVoice = multiVoice
        metadata.originalDate = backdate
        return EntryListItem(captureID: captureID,
                             capturedAt: Date(timeIntervalSince1970: 1_770_000_000),
                             durationSeconds: duration,
                             metadata: metadata)
    }

    private func paragraph(_ voice: String?, _ text: String) -> TranscriptAttribution.Paragraph {
        TranscriptAttribution.Paragraph(voice: voice, text: text, hasApproximateBoundary: false)
    }

    private func transcript(text: String?,
                            paragraphs: [TranscriptAttribution.Paragraph]? = nil,
                            state: EntryTranscriptState = .present) -> EntryTranscript {
        EntryTranscript(state: state, text: text, degradations: [], paragraphs: paragraphs)
    }

    // MARK: - Summary line

    /// One voice is the unremarkable case and says nothing; a single paragraph is not a
    /// structure worth counting. The line states only what is actually notable.
    func testSummaryIsJustTheDurationForAPlainSingleVoiceReading() {
        let receipt = CaptureReceipt.make(entry: entry(duration: 16),
                                          transcript: transcript(text: "hello there"))
        XCTAssertEqual(receipt.summaryLine, "0:16")
    }

    func testSummaryNamesTwoVoicesWhenTheCaptureWasMultiVoice() {
        let receipt = CaptureReceipt.make(entry: entry(duration: 75, multiVoice: true),
                                          transcript: transcript(text: "hello there"))
        XCTAssertEqual(receipt.summaryLine, "1:15 · 2 voices")
    }

    func testSummaryCountsParagraphsOnlyWhenThereIsMoreThanOne() {
        let one = CaptureReceipt.make(
            entry: entry(duration: 16),
            transcript: transcript(text: "a b", paragraphs: [paragraph(nil, "a b")]))
        XCTAssertEqual(one.summaryLine, "0:16",
                       "a single paragraph is not a structure worth reporting")

        let three = CaptureReceipt.make(
            entry: entry(duration: 16, multiVoice: true),
            transcript: transcript(text: "a b c",
                                   paragraphs: [paragraph("bn", "a"),
                                                paragraph("ln", "b"),
                                                paragraph("bn", "c")]))
        XCTAssertEqual(three.summaryLine, "0:16 · 2 voices · 3 paragraphs")
    }

    /// A `.plain` transcript has no paragraph structure. Counting one — from line breaks,
    /// say — would be inventing a fact about the reading that nothing measured.
    func testSummaryNeverCountsParagraphsForUnattributedProse() {
        let receipt = CaptureReceipt.make(
            entry: entry(duration: 16),
            transcript: transcript(text: "first line\n\nsecond line\n\nthird"))
        XCTAssertEqual(receipt.summaryLine, "0:16")
        XCTAssertFalse(receipt.summaryLine.contains("paragraph"))
    }

    // MARK: - Degraded transcripts

    /// Absent, unreadable and present-but-empty stay three distinct answers (issue #11's
    /// rule) — and crucially none of them suppresses the receipt, because the RECORDING is
    /// safe in all three and that is the thing the owner needs told.
    func testEveryDegradedTranscriptStillProducesAReceiptThatSaysWhatHappened() {
        let cases: [(String, EntryTranscript?)] = [
            ("no transcript object at all", nil),
            ("absent", transcript(text: nil, state: .absent)),
            ("unreadable", transcript(text: nil, state: .unreadable)),
            ("present but empty", transcript(text: "", state: .present)),
        ]

        var messages: Set<String> = []
        for (name, t) in cases {
            let receipt = CaptureReceipt.make(entry: entry(duration: 16), transcript: t)
            XCTAssertFalse(receipt.hasProse, "\(name): claims prose it does not have")
            let message = try? XCTUnwrap(receipt.proseUnavailableText, "\(name): no explanation")
            XCTAssertFalse((message ?? "").isEmpty, "\(name): empty explanation")
            XCTAssertEqual(receipt.summaryLine, "0:16",
                           "\(name): the duration is known even when the words are not")
            messages.insert(message ?? "")
        }

        // Three answers, not one collapsed one. `.absent` and "no transcript at all" share
        // a message deliberately — both mean "there is no transcript" — so three distinct
        // strings across four cases is the correct count.
        XCTAssertEqual(messages.count, 3,
                       "absent / unreadable / empty must not collapse into one message")
    }

    /// The inverse: real prose reports itself as prose and offers no excuse line.
    func testRealProseHasNoUnavailableMessage() {
        let plain = CaptureReceipt.make(entry: entry(), transcript: transcript(text: "words"))
        XCTAssertTrue(plain.hasProse)
        XCTAssertNil(plain.proseUnavailableText)

        let attributed = CaptureReceipt.make(
            entry: entry(),
            transcript: transcript(text: "words", paragraphs: [paragraph("bn", "words")]))
        XCTAssertTrue(attributed.hasProse)
        XCTAssertNil(attributed.proseUnavailableText)
    }

    // MARK: - Identity

    /// The date shown is the entry's own formatted effective date, not a re-derivation.
    /// A receipt and the library row for the same entry disagreeing about its date would
    /// be exactly the kind of quiet wrongness backdating already makes easy.
    func testDateTextMatchesTheEntrysOwnFormattingIncludingABackdate() {
        let plain = entry()
        XCTAssertEqual(CaptureReceipt.make(entry: plain, transcript: nil).dateText,
                       plain.formattedEffectiveDate())

        let backdated = entry(backdate: PartialDate(year: 1987, month: 3, day: 4))
        XCTAssertEqual(CaptureReceipt.make(entry: backdated, transcript: nil).dateText,
                       backdated.formattedEffectiveDate())
        XCTAssertTrue(CaptureReceipt.make(entry: backdated, transcript: nil)
                        .dateText.contains("1987"),
                      "a backdated entry's receipt must show the backdate, not today")
    }

    /// The receipt carries the id the "Open" action navigates to.
    func testCaptureIDIsCarriedThroughForTheOpenAction() {
        let receipt = CaptureReceipt.make(entry: entry(captureID: "01XYZ"), transcript: nil)
        XCTAssertEqual(receipt.captureID, "01XYZ")
        XCTAssertEqual(receipt.id, "01XYZ")
    }
}
