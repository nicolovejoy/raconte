import XCTest
@testable import Raconte

/// M3 issue #15: the once-only latch. The parser's job is the string; this is the
/// decision about whether we may write at all.
final class SpokenDateDetectionTests: XCTestCase {

    private let dated = "March 4th, 1998, we drove to the coast"
    private let march4 = PartialDate(year: 1998, month: 3, day: 4)

    // MARK: Apply

    func testAppliesToAnUnbackdatedEntry() {
        var metadata = EntryMetadata.defaults
        XCTAssertTrue(SpokenDateDetection.apply(to: &metadata, transcriptText: dated))
        XCTAssertEqual(metadata.originalDate, march4)
        XCTAssertEqual(metadata.detectedDate, march4)
        XCTAssertTrue(metadata.backdateWasDetected)
    }

    func testCarriesItsOwnPrecision() {
        var metadata = EntryMetadata.defaults
        SpokenDateDetection.apply(to: &metadata, transcriptText: "March 1998, I had just moved")
        XCTAssertEqual(metadata.originalDate, PartialDate(year: 1998, month: 3))
        XCTAssertEqual(metadata.originalDate?.precision, .yearMonth)
    }

    func testNoDetectionWritesNothing() {
        var metadata = EntryMetadata.defaults
        XCTAssertFalse(SpokenDateDetection.apply(to: &metadata, transcriptText: "Today I went out"))
        XCTAssertEqual(metadata, .defaults)
    }

    func testAbsentTranscriptWritesNothing() {
        var metadata = EntryMetadata.defaults
        XCTAssertFalse(SpokenDateDetection.apply(to: &metadata, transcriptText: nil))
        XCTAssertFalse(SpokenDateDetection.apply(to: &metadata, transcriptText: ""))
        XCTAssertEqual(metadata, .defaults)
    }

    // MARK: Manual first

    func testManualBackdateWins() {
        let manual = PartialDate(year: 1987, month: 6, day: 2)
        var metadata = EntryMetadata(originalDate: manual)
        XCTAssertTrue(SpokenDateDetection.apply(to: &metadata, transcriptText: dated))
        XCTAssertEqual(metadata.originalDate, manual, "a typed backdate outranks a spoken one")
        // Still recorded — that is what spends the one-shot.
        XCTAssertEqual(metadata.detectedDate, march4)
        XCTAssertFalse(metadata.backdateWasDetected)
    }

    // MARK: The latch

    func testSecondRunIsANoOp() {
        var metadata = EntryMetadata.defaults
        XCTAssertTrue(SpokenDateDetection.apply(to: &metadata, transcriptText: dated))
        let afterFirst = metadata
        XCTAssertFalse(SpokenDateDetection.apply(to: &metadata, transcriptText: dated))
        XCTAssertEqual(metadata, afterFirst)
    }

    /// The bug the latch exists to stop: the owner removes a detected backdate and the
    /// next pass over the same recording puts it straight back.
    func testClearedBackdateIsNotReapplied() {
        var metadata = EntryMetadata.defaults
        SpokenDateDetection.apply(to: &metadata, transcriptText: dated)
        metadata.originalDate = nil  // "Remove backdate" from the detail screen

        XCTAssertFalse(SpokenDateDetection.apply(to: &metadata, transcriptText: dated))
        XCTAssertNil(metadata.originalDate)
        XCTAssertEqual(metadata.detectedDate, march4)
        XCTAssertFalse(metadata.backdateWasDetected)
    }

    func testEditedBackdateIsNotOverwrittenAndLosesTheDetectedLabel() {
        var metadata = EntryMetadata.defaults
        SpokenDateDetection.apply(to: &metadata, transcriptText: dated)
        metadata.originalDate = PartialDate(year: 1998, month: 3, day: 5)

        XCTAssertFalse(SpokenDateDetection.apply(to: &metadata, transcriptText: dated))
        XCTAssertEqual(metadata.originalDate, PartialDate(year: 1998, month: 3, day: 5))
        XCTAssertFalse(metadata.backdateWasDetected)
    }

    /// A detection that never applied still latches — otherwise removing the manual
    /// backdate later would hand the entry the spoken date behind the owner's back.
    func testLatchHoldsEvenWhenTheDetectionWasNotApplied() {
        var metadata = EntryMetadata(originalDate: PartialDate(year: 1987))
        SpokenDateDetection.apply(to: &metadata, transcriptText: dated)
        metadata.originalDate = nil

        XCTAssertFalse(SpokenDateDetection.apply(to: &metadata, transcriptText: dated))
        XCTAssertNil(metadata.originalDate)
    }

    // MARK: Future dates (disallow-future-backdates)
    //
    // Fixed "now" of June 15, 2026 — away from any year boundary, per the house rule
    // that near-epoch/year-boundary backdate fixtures have broken CI under UTC before.

    private var referenceNow: Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 12))!
    }

    /// A future spoken date is a misrecognition, not a real backdate to clamp — it must
    /// be discarded outright, not applied and not clamped to today.
    func testFutureDetectionIsDiscardedNotApplied() {
        var metadata = EntryMetadata.defaults
        XCTAssertFalse(SpokenDateDetection.apply(
            to: &metadata, transcriptText: "March 4th, 2027, we drove to the coast", now: referenceNow))
        XCTAssertNil(metadata.originalDate)
        XCTAssertEqual(metadata, .defaults)
    }

    /// Discarding a future detection must not spend the latch — unlike a detection that
    /// correctly declined to apply because a manual backdate already existed, this one
    /// was never valid, so a later re-derivation gets another try.
    func testFutureDetectionDoesNotLatch() {
        var metadata = EntryMetadata.defaults
        SpokenDateDetection.apply(
            to: &metadata, transcriptText: "March 4th, 2027, we drove to the coast", now: referenceNow)
        XCTAssertNil(metadata.detectedDate)
    }

    func testPastDetectionAtTheSameReferenceStillApplies() {
        var metadata = EntryMetadata.defaults
        XCTAssertTrue(SpokenDateDetection.apply(to: &metadata, transcriptText: dated, now: referenceNow))
        XCTAssertEqual(metadata.originalDate, march4)
    }

    // MARK: On-disk shape

    func testDetectedDateRoundTripsAndDoesNotDisturbTheEmptyDefault() throws {
        XCTAssertEqual(String(data: try EntryMetadataStore.encode(.defaults), encoding: .utf8), "{}")

        var metadata = EntryMetadata.defaults
        SpokenDateDetection.apply(to: &metadata, transcriptText: dated)
        let data = try EntryMetadataStore.encode(metadata)
        XCTAssertTrue(String(data: data, encoding: .utf8)!.contains("\"detectedDate\":\"1998-03-04\""))
        XCTAssertEqual(try EntryMetadataStore.decode(data), metadata)
    }

    func testSidecarWithoutTheFieldStillDecodes() throws {
        let decoded = try EntryMetadataStore.decode(Data(#"{"journalID":"j1"}"#.utf8))
        XCTAssertEqual(decoded.journalID, "j1")
        XCTAssertNil(decoded.detectedDate)
    }

    /// Additive and lenient, unlike `originalDate`: a derived field we cannot read must
    /// not take the journal and the trash state down with it.
    func testUnreadableDetectedDateDegradesToNilRatherThanFailingTheWholeSidecar() throws {
        let decoded = try EntryMetadataStore.decode(
            Data(#"{"journalID":"j1","detectedDate":"not-a-date"}"#.utf8))
        XCTAssertEqual(decoded.journalID, "j1")
        XCTAssertNil(decoded.detectedDate)

        let wrongType = try EntryMetadataStore.decode(Data(#"{"journalID":"j1","detectedDate":7}"#.utf8))
        XCTAssertEqual(wrongType.journalID, "j1")
        XCTAssertNil(wrongType.detectedDate)
    }

    /// `originalDate` stays strict — the contrast is the point.
    func testUnreadableOriginalDateStillThrows() {
        XCTAssertThrowsError(try EntryMetadataStore.decode(Data(#"{"originalDate":"nope"}"#.utf8)))
    }

    // MARK: Issue #21 — the latch must not fail open when `detectedDate` is unreadable

    /// The hazard: `detectedDate` decoding leniently to nil (correct, on its own) must not
    /// look identical to "detection never ran" — that would reopen the latch and let a
    /// later pass resurrect a backdate the owner may have deliberately cleared.
    func testDetectionDoesNotRerunWhenDetectedDateIsPresentButUnreadable() throws {
        var metadata = try EntryMetadataStore.decode(
            Data(#"{"journalID":"j1","detectedDate":"not-a-date"}"#.utf8))
        XCTAssertNil(metadata.detectedDate, "sanity: still decodes leniently to nil")

        XCTAssertFalse(SpokenDateDetection.apply(to: &metadata, transcriptText: dated),
                        "an unreadable detectedDate must fail the latch closed, not open")
        XCTAssertNil(metadata.originalDate, "must not resurrect a backdate from re-detection")
    }

    /// Same hazard, wrong-JSON-type variant.
    func testDetectionDoesNotRerunWhenDetectedDateIsTheWrongType() throws {
        var metadata = try EntryMetadataStore.decode(Data(#"{"journalID":"j1","detectedDate":7}"#.utf8))
        XCTAssertNil(metadata.detectedDate)

        XCTAssertFalse(SpokenDateDetection.apply(to: &metadata, transcriptText: dated))
        XCTAssertNil(metadata.originalDate)
    }

    /// A genuinely absent `detectedDate` key is "never ran" — must still latch open so a
    /// fresh entry gets a first detection pass.
    func testDetectionStillRunsWhenDetectedDateKeyIsAbsent() throws {
        var metadata = try EntryMetadataStore.decode(Data(#"{"journalID":"j1"}"#.utf8))
        XCTAssertTrue(SpokenDateDetection.apply(to: &metadata, transcriptText: dated))
        XCTAssertEqual(metadata.originalDate, march4)
    }

    /// The closed latch must survive a write that happens while the value is still
    /// unreadable in memory — otherwise a routine edit (e.g. filing into a journal) would
    /// silently reopen it by dropping the on-disk signal that detection had already run.
    func testClosedLatchSurvivesAReencodeWithTheUnreadableValueStillInMemory() throws {
        let corrupted = try EntryMetadataStore.decode(
            Data(#"{"journalID":"j1","detectedDate":"not-a-date"}"#.utf8))
        let reencoded = try EntryMetadataStore.encode(corrupted)
        var roundTripped = try EntryMetadataStore.decode(reencoded)

        XCTAssertFalse(SpokenDateDetection.apply(to: &roundTripped, transcriptText: dated),
                        "the latch must stay closed across a write that doesn't recover the value")
        XCTAssertNil(roundTripped.originalDate)
    }
}
