import XCTest
@testable import Raconte

/// The pure sweep core (M3 T5): the decision table, the retention math, and the plan
/// built over a list of candidates. No disk — `TrashSweeperTests` covers the I/O side.
final class TrashSweepTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func daysAgo(_ days: Double) -> Date {
        now.addingTimeInterval(-days * 86_400)
    }

    // MARK: - Decision table

    func testAbsentSidecarIsLeftAlone() {
        XCTAssertEqual(TrashSweep.decide(.absent, now: now), .leaveAlone)
    }

    func testReadableAndNotTrashedIsLeftAlone() {
        let metadata = EntryMetadata(journalID: "J1", originalDate: daysAgo(9_000))
        XCTAssertEqual(TrashSweep.decide(.present(metadata), now: now), .leaveAlone)
    }

    func testReadableAndExpiredIsDeleted() {
        let metadata = EntryMetadata(trashedAt: daysAgo(31))
        XCTAssertEqual(TrashSweep.decide(.present(metadata), now: now), .delete)
    }

    func testReadableAndRecentIsKept() {
        let metadata = EntryMetadata(trashedAt: daysAgo(2))
        XCTAssertEqual(TrashSweep.decide(.present(metadata), now: now),
                       .skip(.withinRetention(daysRemaining: 28)))
    }

    /// The guard this whole task turns on. An `entry.json` we could not parse is neither
    /// "not trashed" (which would be safe but silent) nor "trashed" (which would delete a
    /// recording on the strength of bytes we failed to read) — it is a third answer, and
    /// the sweep does nothing at all to that directory.
    func testUnreadableSidecarIsSkippedNeverDeletedNeverAdopted() {
        XCTAssertEqual(TrashSweep.decide(.unreadable, now: now), .skip(.metadataUnreadable))
    }

    /// Exactly at the boundary the budget is spent — an entry trashed 30 days ago does
    /// not get one more sweep's worth of life.
    func testExactlyThirtyDaysIsExpired() {
        let metadata = EntryMetadata(trashedAt: daysAgo(30))
        XCTAssertEqual(TrashSweep.decide(.present(metadata), now: now), .delete)
    }

    /// A `trashedAt` in the future (a clock change, a synced device ahead of this one) is
    /// not expired. The countdown clamps at the full retention rather than going negative.
    func testFutureTombstoneIsNotExpired() {
        let metadata = EntryMetadata(trashedAt: now.addingTimeInterval(3_600))
        XCTAssertEqual(TrashSweep.decide(.present(metadata), now: now),
                       .skip(.withinRetention(daysRemaining: TrashPolicy.retentionDays + 1)))
    }

    // MARK: - Retention math

    func testDaysRemainingRoundsUpSoTheLastDayIsNotZero() {
        // 30 minutes left is still "today", not "0 days".
        let trashedAt = now.addingTimeInterval(-(TrashPolicy.retentionSeconds - 1_800))
        XCTAssertEqual(TrashPolicy.daysRemaining(trashedAt: trashedAt, now: now), 1)
    }

    func testDaysRemainingFloorsAtZero() {
        XCTAssertEqual(TrashPolicy.daysRemaining(trashedAt: daysAgo(90), now: now), 0)
    }

    func testDaysRemainingAtTheMomentOfDeletionIsTheFullBudget() {
        XCTAssertEqual(TrashPolicy.daysRemaining(trashedAt: now, now: now),
                       TrashPolicy.retentionDays)
    }

    func testExpiryIsThirtyDaysAfterTheTombstone() {
        XCTAssertEqual(TrashPolicy.expiry(trashedAt: now),
                       now.addingTimeInterval(30 * 86_400))
    }

    // MARK: - Plan

    func testPlanEmitsOneActionPerCandidateThatIsOne() {
        let candidates = [
            TrashSweepCandidate(captureID: "A", sidecar: .present(EntryMetadata(trashedAt: daysAgo(31)))),
            TrashSweepCandidate(captureID: "B", sidecar: .present(EntryMetadata(trashedAt: daysAgo(1)))),
            TrashSweepCandidate(captureID: "C", sidecar: .unreadable),
            TrashSweepCandidate(captureID: "D", sidecar: .absent),
            TrashSweepCandidate(captureID: "E", sidecar: .present(EntryMetadata(journalID: "J1"))),
        ]

        XCTAssertEqual(TrashSweep.plan(candidates, now: now), [
            .deleteCaptureDirectory(captureID: "A"),
            .skip(SkippedSweep(captureID: "B", reason: .withinRetention(daysRemaining: 29))),
            .skip(SkippedSweep(captureID: "C", reason: .metadataUnreadable)),
        ])
    }

    func testPlanOverAnEmptyTreeIsEmpty() {
        XCTAssertEqual(TrashSweep.plan([], now: now), [])
    }

    // MARK: - Filter interplay

    /// The trash filter and the sweep must agree about what "trashed" means: everything
    /// the sweep will eventually delete is exactly what the Trash view shows, and nothing
    /// the library list shows is ever a delete candidate.
    func testTrashFilterAndSweepAgreeOnWhatIsTrashed() {
        let live = item("A", trashedAt: nil)
        let recent = item("B", trashedAt: daysAgo(1))
        let expired = item("C", trashedAt: daysAgo(31))
        let all = [live, recent, expired]

        let listed = EntryListFilter(trash: .excludeTrashed).apply(to: all).map(\.captureID)
        let inTrash = EntryListFilter(trash: .trashedOnly).apply(to: all).map(\.captureID)

        XCTAssertEqual(listed, ["A"])
        XCTAssertEqual(Set(inTrash), ["B", "C"])

        for item in all {
            let disposition = TrashSweep.decide(.present(item.metadata), now: now)
            if listed.contains(item.captureID) {
                XCTAssertEqual(disposition, .leaveAlone,
                               "a listed entry must never be a delete candidate")
            }
            if disposition == .delete {
                XCTAssertTrue(inTrash.contains(item.captureID),
                              "everything the sweep deletes must have been visible in the trash")
            }
        }
    }

    private func item(_ id: String, trashedAt: Date?) -> EntryListItem {
        EntryListItem(captureID: id,
                      capturedAt: now,
                      metadata: EntryMetadata(trashedAt: trashedAt))
    }
}
