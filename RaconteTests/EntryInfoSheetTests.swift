import XCTest
@testable import Raconte

final class EntryInfoSheetTests: XCTestCase {
    func testHeaderSubtitleCarriesRecordedDateAndDuration() {
        let date = Date(timeIntervalSince1970: 1_756_300_000)
        let subtitle = EntryInfoSheet.headerSubtitle(capturedAt: date, durationSeconds: 161)
        XCTAssertTrue(subtitle.contains(CaptureCoordinator.formatDuration(161)))
        XCTAssertTrue(subtitle.contains(date.formatted(date: .abbreviated, time: .shortened)))
    }
}
