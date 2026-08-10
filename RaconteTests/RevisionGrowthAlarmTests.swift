import XCTest
@testable import Raconte

/// #39, T7 Task 3 work item 3: the revision-count growth alarm is a pure predicate here
/// — Task 8 wires it into the revision-history panel and the diagnostics screen (per
/// the brief's ruling), neither of which this task builds.
final class RevisionGrowthAlarmTests: XCTestCase {

    func testThresholdIsFifty() {
        XCTAssertEqual(RevisionGrowthAlarm.threshold, 50)
    }

    func testBelowThresholdIsNotElevated() {
        XCTAssertFalse(RevisionGrowthAlarm.isElevated(revisionCount: 0))
        XCTAssertFalse(RevisionGrowthAlarm.isElevated(revisionCount: 49))
    }

    /// `>=`, not `>`: reaching the threshold IS the alarm condition, not one short of it.
    func testAtThresholdIsElevated() {
        XCTAssertTrue(RevisionGrowthAlarm.isElevated(revisionCount: 50))
    }

    func testAboveThresholdIsElevated() {
        XCTAssertTrue(RevisionGrowthAlarm.isElevated(revisionCount: 51))
        XCTAssertTrue(RevisionGrowthAlarm.isElevated(revisionCount: 1_000))
    }
}
