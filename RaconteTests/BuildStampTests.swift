#if DEBUG
import XCTest
@testable import Raconte

/// Pure core of the Debug-screen build-date row (see `BuildStamp.swift`):
/// picking which on-disk file's mtime represents "the build" given a Debug
/// build's thin main-executable stub, and formatting that timestamp per the
/// UTC-at-rest/Pacific-on-display convention.
final class BuildStampTests: XCTestCase {
    // MARK: representativeFile

    func testRepresentativeFilePicksNewestModificationDate() {
        let older = BuildFileStamp(
            url: URL(fileURLWithPath: "/app/Raconte"),
            modificationDate: Date(timeIntervalSince1970: 1_000)
        )
        let newer = BuildFileStamp(
            url: URL(fileURLWithPath: "/app/Frameworks/Raconte.debug.dylib"),
            modificationDate: Date(timeIntervalSince1970: 2_000)
        )
        let chosen = BuildStamp.representativeFile(among: [older, newer])
        XCTAssertEqual(chosen, newer)
    }

    func testRepresentativeFilePicksNewestRegardlessOfInputOrder() {
        let older = BuildFileStamp(
            url: URL(fileURLWithPath: "/app/Raconte"),
            modificationDate: Date(timeIntervalSince1970: 1_000)
        )
        let newer = BuildFileStamp(
            url: URL(fileURLWithPath: "/app/Frameworks/Raconte.debug.dylib"),
            modificationDate: Date(timeIntervalSince1970: 2_000)
        )
        // Reversed order from the sibling test — a min-picking bug could
        // still return `newer` here by coincidence if it only failed on
        // ordering, so this pins the *value* comparison, not just order.
        let chosen = BuildStamp.representativeFile(among: [newer, older])
        XCTAssertEqual(chosen, newer)
    }

    func testRepresentativeFileNilForEmptyCandidates() {
        XCTAssertNil(BuildStamp.representativeFile(among: []))
    }

    // MARK: displayString

    func testDisplayStringUsesPacificTimeZoneNotUTC() {
        // 2026-08-12 18:41 PT == 2026-08-13 01:41 UTC (PDT, UTC-7).
        var utcComponents = DateComponents()
        utcComponents.year = 2026
        utcComponents.month = 8
        utcComponents.day = 13
        utcComponents.hour = 1
        utcComponents.minute = 41
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        let date = utcCalendar.date(from: utcComponents)!

        let display = BuildStamp.displayString(for: date)
        XCTAssertEqual(display, "Built 2026-08-12 18:41 PT")
    }

    func testDisplayStringFormatIncludesBuiltPrefixAndPTSuffix() {
        let date = Date(timeIntervalSince1970: 0)
        let display = BuildStamp.displayString(for: date)
        XCTAssertTrue(display.hasPrefix("Built "))
        XCTAssertTrue(display.hasSuffix(" PT"))
    }
}
#endif
