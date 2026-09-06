import XCTest
import SwiftUI
@testable import Raconte

/// #118 §5. The live transcript dims the HYPOTHESIS, wherever it sits — never "the tail".
final class LiveTranscriptTextTests: XCTestCase {

    private func run(_ text: String, _ start: Int64, provisional: Bool) -> ConsolidatedTranscriptRun {
        ConsolidatedTranscriptRun(text: text, range: FrameRange(start: start, end: start + 100), isProvisional: provisional)
    }

    private func run(_ text: String, _ range: Range<Int64>) -> ConsolidatedTranscriptRun {
        ConsolidatedTranscriptRun(text: text, range: FrameRange(start: range.lowerBound, end: range.upperBound), isProvisional: false)
    }

    private func colours(_ s: AttributedString) -> [(String, Color?)] {
        s.runs.map { (String(s[$0.range].characters), $0.foregroundColor) }
    }

    /// The trap: a provisional run that precedes committed text is dim in the MIDDLE.
    func testAMidTextHypothesisIsDimAndTheTailIsNot() {
        let runs = [run("earlier", 0, provisional: true),
                    run("later", 1_000, provisional: false),
                    run("last", 2_000, provisional: false)]
        let s = LiveTranscriptText.attributed(runs, ink: .white, dim: .gray)
        XCTAssertEqual(String(s.characters), "earlier later last")
        let c = colours(s)
        XCTAssertEqual(c.first?.1, .gray, "the hypothesis is dim")
        XCTAssertEqual(c.last?.1, .white, "the committed tail is NOT dim")
    }

    func testCommittedIsInkAndProvisionalIsDim() {
        let runs = [run("settled", 0, provisional: false), run("guessing", 100, provisional: true)]
        let c = colours(LiveTranscriptText.attributed(runs, ink: .white, dim: .gray))
        XCTAssertEqual(c.map(\.1), [.white, .gray])
        XCTAssertEqual(c.map(\.0), ["settled ", "guessing"],
                       "the separator takes the PRECEDING run's colour — 'settled ' carries " +
                       "the space, not 'guessing'")
    }

    func testEmptyRunsIsEmptyText() {
        XCTAssertEqual(String(LiveTranscriptText.attributed([], ink: .white, dim: .gray).characters), "")
    }

    /// Adjacent runs of the same kind may merge into one attributed run; the words and
    /// the separator must survive that.
    func testWordsAreSeparatedBySingleSpaces() {
        let runs = [run("a", 0, provisional: false), run("b", 100, provisional: false),
                    run("c", 200, provisional: true)]
        XCTAssertEqual(String(LiveTranscriptText.attributed(runs, ink: .white, dim: .gray).characters), "a b c")
    }

    /// An empty-text run is a revoked hypothesis (`TranscriptConsolidator.applyVolatile`)
    /// still present in the frame-ordered list — `attributed` must skip it entirely, not
    /// leave a blank word that would print as a double space between its neighbours.
    func testEmptyRunsAreSkippedNotRenderedAsBlankWords() {
        let runs = [run("a", 0, provisional: false), run("", 100, provisional: true),
                    run("b", 200, provisional: false)]
        XCTAssertEqual(String(LiveTranscriptText.attributed(runs, ink: .white, dim: .gray).characters), "a b")
    }

    /// No committed text at all yet — every run is a live hypothesis. The whole line must
    /// read dim, not just the runs after some notional first "settled" word. (Adjacent
    /// same-colour text coalesces into one `AttributedString` run, so this checks every
    /// run present is dim rather than pinning a run count.)
    func testAllProvisionalRunsAreAllDim() {
        let runs = [run("still", 0, provisional: true), run("guessing", 100, provisional: true)]
        let attributed = LiveTranscriptText.attributed(runs, ink: .white, dim: .gray)
        let c = colours(attributed)
        XCTAssertFalse(c.isEmpty)
        XCTAssertTrue(c.allSatisfy { $0.1 == .gray }, "every run must be dim: \(c)")
        XCTAssertEqual(String(attributed.characters), "still guessing")
    }

    /// #136: a ¶ tapped between two runs starts a new line where the words after it begin.
    func testAParagraphFrameBetweenRunsBecomesABlankLine() {
        let runs = [run("one two", 0..<100), run("three", 100..<200)]
        let text = String(LiveTranscriptText.attributed(runs, paragraphFrames: [100], ink: .white, dim: .gray).characters)
        XCTAssertEqual(text, "one two\n\nthree")
    }

    /// The same nearer-edge rule the detail screen uses — a frame inside a run cuts at the
    /// nearer edge, never mid-word.
    func testAParagraphFrameInsideARunCutsAtTheNearerEdge() {
        let runs = [run("one", 0..<100), run("two", 100..<200), run("three", 200..<300)]
        XCTAssertEqual(String(LiveTranscriptText.attributed(runs, paragraphFrames: [110], ink: .white, dim: .gray).characters), "one\n\ntwo three")
        XCTAssertEqual(String(LiveTranscriptText.attributed(runs, paragraphFrames: [190], ink: .white, dim: .gray).characters), "one two\n\nthree")
    }

    func testFramesAtTheEdgesRenderNoBreak() {
        let runs = [run("one", 0..<100), run("two", 100..<200)]
        XCTAssertEqual(String(LiveTranscriptText.attributed(runs, paragraphFrames: [0, 500], ink: .white, dim: .gray).characters), "one two")
    }

    func testTwoFramesInOneGapMakeOneBreak() {
        let runs = [run("one", 0..<100), run("two", 100..<200)]
        XCTAssertEqual(String(LiveTranscriptText.attributed(runs, paragraphFrames: [100, 100], ink: .white, dim: .gray).characters), "one\n\ntwo")
    }
}
