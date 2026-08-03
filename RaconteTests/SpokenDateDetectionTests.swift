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
}
