import XCTest
@testable import Raconte

/// Tripwire over `EntryDegradation`'s flag list and the phrases the UI names them by.
///
/// The same job as T2.5's `Mirror` field-count test on `Manifest`, done with the tool
/// available: Swift has no reflection over a type's static members, so an `OptionSet`
/// cannot be enumerated at runtime. `allDeclared` is the hand-kept list and these tests
/// pin its shape — a seventh flag makes the bit-count assertion fail, which is what sends
/// the author to `reasonTable` a few lines below it.
final class EntryDegradationTableTests: XCTestCase {

    /// Six flags, bits 0…5. Adding one fails here first.
    func testEveryDeclaredFlagIsAccountedFor() {
        XCTAssertEqual(EntryDegradation.allDeclared.rawValue, (1 << 6) - 1,
                       "a flag was added or renumbered — update allDeclared and reasonTable")
    }

    /// The table covers `allDeclared` exactly: no flag without a phrase (it would vanish
    /// from every accessibility label) and no phrase for a flag that no longer exists.
    func testReasonTableCoversExactlyTheDeclaredFlags() {
        let covered = EntryDegradation.reasonTable.reduce(into: EntryDegradation()) {
            $0.insert($1.flag)
        }
        XCTAssertEqual(covered, EntryDegradation.allDeclared)
    }

    /// Each row names a single distinct bit — a typo'd `1 << 3` for two flags would
    /// otherwise make one of them permanently unreportable.
    func testEachTableRowIsOneDistinctBit() {
        var seen: Set<Int> = []
        for row in EntryDegradation.reasonTable {
            XCTAssertEqual(row.flag.rawValue.nonzeroBitCount, 1,
                           "\(row.reason) is not a single flag")
            XCTAssertTrue(seen.insert(row.flag.rawValue).inserted,
                          "duplicate flag for \(row.reason)")
        }
    }

    func testEveryDeclaredFlagProducesAReason() {
        for row in EntryDegradation.reasonTable {
            XCTAssertEqual(EntryDegradation(rawValue: row.flag.rawValue).accessibilityReasons,
                           [row.reason])
        }
        XCTAssertTrue(EntryDegradation().accessibilityReasons.isEmpty)
    }

    /// Absent and corrupt manifests share a phrase; the owner does not need the
    /// difference, and saying it twice reads as two separate problems.
    func testSharedPhrasesAreNotRepeated() {
        let both: EntryDegradation = [.manifestAbsent, .manifestCorrupt]
        XCTAssertEqual(both.accessibilityReasons, ["recording details incomplete"])
    }

    func testReasonsComeOutInTableOrder() {
        XCTAssertEqual(EntryDegradation.allDeclared.accessibilityReasons,
                       ["recording details incomplete",
                        "entry settings unreadable",
                        "journal not found",
                        "transcript unreadable",
                        "transcript may be incomplete"])
    }
}
