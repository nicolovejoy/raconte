import XCTest
import SwiftUI
@testable import Raconte

/// #118 §5. The live transcript dims the HYPOTHESIS, wherever it sits — never "the tail".
final class LiveTranscriptTextTests: XCTestCase {

    private func run(_ text: String, _ start: Int64, provisional: Bool) -> ConsolidatedTranscriptRun {
        ConsolidatedTranscriptRun(text: text, range: FrameRange(start: start, end: start + 100), isProvisional: provisional)
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
        XCTAssertEqual(c.map(\.0), ["settled ", "guessing"])
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
}
