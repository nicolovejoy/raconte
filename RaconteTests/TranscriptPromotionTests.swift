import XCTest
@testable import Raconte

/// Promotion driven by `resultsFinalizationTime` (design §4), and replay of the log
/// it produces (issue #10).
///
/// These cover the defect that motivated both: Apple documents that a module *is not
/// required* to reissue a final result over a range it finalizes through when the
/// volatile hypothesis was unchanged. Waiting for `isVolatile == false` therefore loses
/// every phrase recognized correctly on the first try — visible nowhere, because the
/// live screen shows the volatile overlay the whole time.
final class TranscriptPromotionTests: XCTestCase {

    private func result(_ text: String, _ start: Int64, _ end: Int64,
                        volatile: Bool = false,
                        finalizedThrough: Int64? = nil) -> TranscriptResult {
        TranscriptResult(text: text,
                         range: FrameRange(start: start, end: end),
                         isVolatile: volatile,
                         confidence: nil,
                         finalizedThroughFrame: finalizedThrough)
    }

    // MARK: Promotion

    /// The bug, stated directly. A correct hypothesis is never reissued; only the
    /// marker moves. Without promotion "hello" reaches the transcript nowhere.
    func testHypothesisNeverReissuedIsStillCommittedWhenTheMarkerPassesIt() {
        var c = TranscriptConsolidator()
        c.apply(result("hello", 0, 100, volatile: true))
        XCTAssertEqual(c.committedText, "", "not settled yet")

        // A later result over a *different* span carries the marker past [0,100).
        c.apply(result("world", 100, 200, volatile: true, finalizedThrough: 100))

        XCTAssertEqual(c.committedText, "hello")
        XCTAssertEqual(c.displayText, "hello world")
    }

    func testMarkerDoesNotPromoteAHypothesisItHasNotReached() {
        var c = TranscriptConsolidator()
        c.apply(result("half spoken", 0, 100, volatile: true))
        c.apply(result("more", 100, 200, volatile: true, finalizedThrough: 50))
        XCTAssertEqual(c.committedText, "", "the marker stops inside the range")
        XCTAssertEqual(c.provisional.count, 2)
    }

    func testPromotedResultIsNoLongerVolatile() {
        var c = TranscriptConsolidator()
        c.apply(result("settled", 0, 100, volatile: true))
        c.apply(result("later", 100, 200, volatile: true, finalizedThrough: 100))
        XCTAssertEqual(c.committed.map(\.isVolatile), [false])
    }

    /// A hypothesis must never displace a result that actually arrived final —
    /// out-of-order arrival otherwise lets the weaker answer win.
    func testPromotionNeverDisplacesACommittedFinal() {
        var c = TranscriptConsolidator()
        c.apply(result("considered answer", 0, 100))
        c.apply(result("guess", 0, 100, volatile: true))
        c.apply(result("next", 100, 200, volatile: true, finalizedThrough: 100))
        XCTAssertEqual(c.committedText, "considered answer")
    }

    func testEmptyHypothesisIsNotPromotedIntoTheTranscript() {
        var c = TranscriptConsolidator()
        c.apply(result("", 0, 100, volatile: true))
        c.apply(result("after", 100, 200, volatile: true, finalizedThrough: 100))
        XCTAssertEqual(c.committedText, "", "an empty hypothesis carries no words")
    }

    /// A final result that *is* reissued must still win over the promoted copy rather
    /// than sitting beside it.
    func testReissuedFinalRevisesThePromotedHypothesis() {
        var c = TranscriptConsolidator()
        c.apply(result("teh cat", 0, 100, volatile: true))
        c.apply(result("next", 100, 200, volatile: true, finalizedThrough: 100))
        XCTAssertEqual(c.committedText, "teh cat")

        c.apply(result("the cat", 0, 100))
        XCTAssertEqual(c.committedText, "the cat", "one entry, corrected — not two")
        XCTAssertEqual(c.committed.count, 1)
    }

    // MARK: What gets logged

    func testFinalResultsAreLoggedIncludingEmptyOnes() {
        var c = TranscriptConsolidator()
        XCTAssertEqual(c.apply(result("words", 0, 100)).map(\.text), ["words"])
        // The deletion. Dropping it makes a revoked span reappear on replay.
        XCTAssertEqual(c.apply(result("", 0, 100)).map(\.text), [""])
    }

    func testPromotionIsLogged() {
        var c = TranscriptConsolidator()
        c.apply(result("hello", 0, 100, volatile: true))
        let logged = c.apply(result("world", 100, 200, volatile: true, finalizedThrough: 100))
        XCTAssertEqual(logged.map(\.text), ["hello"],
                       "a promoted hypothesis exists only in memory unless it is written")
        XCTAssertEqual(logged.map(\.isVolatile), [false])
    }

    func testVolatileResultAloneIsNeverLogged() {
        var c = TranscriptConsolidator()
        XCTAssertTrue(c.apply(result("maybe", 0, 100, volatile: true)).isEmpty)
    }

    // MARK: Replay (issue #10)

    /// The property the log exists to satisfy: fold it back and you get the live view.
    private func assertReplayMatchesLive(_ script: [TranscriptResult],
                                         file: StaticString = #filePath,
                                         line: UInt = #line) {
        var live = TranscriptConsolidator()
        var log: [TranscriptRecord] = []
        for result in script {
            for logged in live.apply(result) {
                log.append(TranscriptRecord(logged, generator: "SpeechTranscriber", locale: "en_US"))
            }
        }
        let replayed = LiveTranscriptReader.consolidate(log)
        XCTAssertEqual(replayed.committedText, live.committedText, file: file, line: line)
        XCTAssertEqual(replayed.committed.map(\.range), live.committed.map(\.range),
                       file: file, line: line)
    }

    func testReplayReproducesARevision() {
        assertReplayMatchesLive([
            result("teh cat", 0, 100),
            result("the cat", 0, 100),      // revises — must not appear twice
            result("sat", 100, 200),
        ])
    }

    func testReplayReproducesADeletion() {
        assertReplayMatchesLive([
            result("misheard", 0, 100),
            result("", 0, 100),             // revokes — must not appear at all
            result("real words", 100, 200),
        ])
    }

    func testReplayReproducesPromotedHypotheses() {
        assertReplayMatchesLive([
            result("hello", 0, 100, volatile: true),
            result("world", 100, 200, volatile: true, finalizedThrough: 100),
            result("again", 200, 300, volatile: true, finalizedThrough: 200),
        ])
    }

    func testReplayReproducesOutOfOrderArrival() {
        assertReplayMatchesLive([
            result("third", 200, 300),
            result("first", 0, 100),
            result("second", 100, 200),
        ])
    }

    /// The raw read is what the issue says it is: wrong. Kept as a test so the reason
    /// `consolidate` exists stays visible rather than looking like ceremony.
    func testRawRecordsDoNotReproduceTheLiveView() {
        var live = TranscriptConsolidator()
        var log: [TranscriptRecord] = []
        for result in [result("misheard", 0, 100), result("", 0, 100)] {
            for logged in live.apply(result) {
                log.append(TranscriptRecord(logged, generator: "g", locale: "en_US"))
            }
        }
        XCTAssertEqual(live.committedText, "", "revoked live")
        XCTAssertEqual(log.count, 2, "both the text and its revocation are on disk")
        XCTAssertEqual(log.map(\.text).filter { !$0.isEmpty }, ["misheard"],
                       "read raw, the revoked span is still there")
        XCTAssertEqual(LiveTranscriptReader.consolidate(log).committedText, "",
                       "folded through the consolidator, it is gone")
    }
}
