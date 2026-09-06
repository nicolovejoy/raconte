import XCTest
@testable import Raconte

/// T6b: the pure chain derivation (design §2.2–§2.3). No filesystem — every walk here
/// is a value transform over hand-built `TranscriptRevision`s.
final class TranscriptChainTests: XCTestCase {

    // MARK: - Fixtures

    private func revision(_ id: String, source: RevisionSource, secondsOffset: Double,
                          parentID: String? = nil, basedOnMachineID: String? = nil,
                          text: String = "x") -> TranscriptRevision {
        TranscriptRevision(id: id, source: source,
                           createdAt: Date(timeIntervalSince1970: 1_700_000_000 + secondsOffset),
                           spans: [TranscriptSpan(text: text, anchor: .none)],
                           parentID: parentID, basedOnMachineID: basedOnMachineID)
    }

    // MARK: - 3.1 Order

    func testOrderedIsStableUnderShuffleAndRenumbering() {
        let a = revision("A", source: .machineLive, secondsOffset: 0)
        let b = revision("B", source: .userEdit, secondsOffset: 10, parentID: "A")
        let c = revision("C", source: .userEdit, secondsOffset: 20, parentID: "B")
        let d = revision("D", source: .machineRetranscribe, secondsOffset: 30, parentID: "A")

        let expected = [a, b, c, d]
        // Every permutation of input order must yield the same output — ids and
        // createdAt are fixed, only the array order (i.e. "filename renumbering") varies.
        let permutations: [[TranscriptRevision]] = [
            [a, b, c, d], [d, c, b, a], [b, d, a, c], [c, a, d, b],
        ]
        for permuted in permutations {
            XCTAssertEqual(TranscriptChain.ordered(permuted), expected)
        }
    }

    func testOrderedBreaksCreatedAtTieByID() {
        // Same createdAt, different (ULID-sortable) ids: id order wins.
        let earlyID = revision("01AAAAAAAAAAAAAAAAAAAAAAAA", source: .machineLive, secondsOffset: 0)
        let lateID = revision("01ZZZZZZZZZZZZZZZZZZZZZZZZ", source: .machineLive, secondsOffset: 0)
        XCTAssertEqual(TranscriptChain.ordered([lateID, earlyID]), [earlyID, lateID])
    }

    // MARK: - 3.2 Named attachment walks (design §10)

    /// machineLive → userEdit A → userEdit B → retranscribe M1(parent rev0) →
    /// retranscribe M2(parent M1) ⇒ M1, M2 both detached; current == B.
    func testF1MachineAfterMachineIsDetached() {
        let rev0 = revision("REV0", source: .machineLive, secondsOffset: 0)
        let a = revision("A", source: .userEdit, secondsOffset: 10, parentID: "REV0")
        let b = revision("B", source: .userEdit, secondsOffset: 20, parentID: "A")
        let m1 = revision("M1", source: .machineRetranscribe, secondsOffset: 30, parentID: "REV0")
        let m2 = revision("M2", source: .machineRetranscribe, secondsOffset: 40, parentID: "M1")

        let ordered = TranscriptChain.ordered([rev0, a, b, m1, m2])
        XCTAssertFalse(TranscriptChain.isAttached(m1, in: ordered))
        XCTAssertFalse(TranscriptChain.isAttached(m2, in: ordered))
        XCTAssertTrue(TranscriptChain.isAttached(a, in: ordered))
        XCTAssertTrue(TranscriptChain.isAttached(b, in: ordered))
        XCTAssertEqual(TranscriptChain.current(ordered)?.id, "B")
    }

    /// {rev0 machine, M retranscribe(parent rev0, latest createdAt)} current == M;
    /// insert userEdit Y with createdAt between ⇒ current == Y, M detached. No file
    /// involved — pure.
    func testA1DataLossWalk() {
        let rev0 = revision("REV0", source: .machineLive, secondsOffset: 0)
        let m = revision("M", source: .machineRetranscribe, secondsOffset: 20, parentID: "REV0")

        let orderedNoHuman = TranscriptChain.ordered([rev0, m])
        XCTAssertEqual(TranscriptChain.current(orderedNoHuman)?.id, "M",
                       "no human tip ⇒ everything attached, current is simply the latest")

        let y = revision("Y", source: .userEdit, secondsOffset: 10, parentID: "REV0")
        let ordered = TranscriptChain.ordered([rev0, y, m])
        XCTAssertEqual(TranscriptChain.current(ordered)?.id, "Y")
        XCTAssertFalse(TranscriptChain.isAttached(m, in: ordered), "M's parent predates the human tip")
    }

    /// Two concurrent userEdits, neither in other's ancestry ⇒ current = later by
    /// (createdAt,id); forkedHumanLineage == true.
    func testA1DivergenceWalk() {
        let rev0 = revision("REV0", source: .machineLive, secondsOffset: 0)
        let editA = revision("EDITA", source: .userEdit, secondsOffset: 10, parentID: "REV0")
        let editB = revision("EDITB", source: .userEdit, secondsOffset: 20, parentID: "REV0")

        let ordered = TranscriptChain.ordered([rev0, editA, editB])
        XCTAssertTrue(TranscriptChain.forkedHumanLineage(ordered))
        XCTAssertEqual(TranscriptChain.current(ordered)?.id, "EDITB", "later by (createdAt, id)")
        XCTAssertTrue(TranscriptChain.isAttached(editA, in: ordered), "human revisions are always attached")
    }

    /// A chain with no machine revision at all ⇒ no machine ancestor for a diff.
    func testNilBase() {
        let a = revision("A", source: .userEdit, secondsOffset: 0)
        let b = revision("B", source: .userEdit, secondsOffset: 10, parentID: "A")
        let ordered = TranscriptChain.ordered([a, b])

        XCTAssertEqual(TranscriptChain.humanTip(ordered)?.id, "B")
        // ancestry(B) contains A (its parent) but no machine-sourced revision exists
        // anywhere in the chain to find as a "machine ancestor".
        XCTAssertEqual(TranscriptChain.ancestry(of: b, among: ordered), ["A"])
        XCTAssertTrue(ordered.allSatisfy(\.source.isHumanLineage),
                      "no machine revision exists anywhere in this chain")
    }

    /// An `.unknown("x")` revision never becomes humanTip.
    func testUnknownSourceIsMachineLineage() {
        let rev0 = revision("REV0", source: .machineLive, secondsOffset: 0)
        let mystery = revision("MYSTERY", source: .unknown("futureSource"), secondsOffset: 10, parentID: "REV0")
        let ordered = TranscriptChain.ordered([rev0, mystery])

        XCTAssertNil(TranscriptChain.humanTip(ordered))
        // With no human tip, everything is attached — including the unknown-source one.
        XCTAssertTrue(TranscriptChain.isAttached(mystery, in: ordered))
        XCTAssertEqual(TranscriptChain.current(ordered)?.id, "MYSTERY")
    }

    // MARK: - plainText

    // MARK: - mintInstant (#43, #51)

    /// #43: `createdAt` is encoded at millisecond precision, so a mint must already be at
    /// that precision or the in-memory chain and its re-decoded self can order differently.
    func testMintInstantTruncatesToMilliseconds() {
        let now = Date(timeIntervalSince1970: 1_000.123_456_789)
        XCTAssertEqual(TranscriptChain.mintInstant(now: now, after: []).timeIntervalSince1970,
                       1_000.123, accuracy: 0.000_000_1)
    }

    /// #51: two mints inside one millisecond tied on `createdAt` and fell to a random
    /// ULID suffix, so `current` could land on the earlier one. A mint is always strictly
    /// after the chain's last revision.
    func testMintInstantIsStrictlyAfterTheChainTipUnderAFrozenClock() {
        let frozen = Date(timeIntervalSince1970: 2_000)
        let tip = TranscriptRevision(id: ULID.make(now: frozen), source: .userEdit, createdAt: frozen, spans: [])
        let minted = TranscriptChain.mintInstant(now: frozen, after: TranscriptChain.ordered([tip]))
        XCTAssertGreaterThan(minted, tip.createdAt)
        XCTAssertEqual(minted.timeIntervalSince(tip.createdAt), 0.001, accuracy: 0.000_000_1)
    }

    func testMintInstantLeavesALaterClockAlone() {
        let tip = TranscriptRevision(id: "01J0000000000000000000T1", source: .userEdit,
                                     createdAt: Date(timeIntervalSince1970: 2_000), spans: [])
        let later = Date(timeIntervalSince1970: 2_005)
        XCTAssertEqual(TranscriptChain.mintInstant(now: later, after: [tip]), later)
    }

    func testPlainTextJoinsSpansWithTheOneJoinRule() {
        let revision = TranscriptRevision(
            id: "R", source: .machineLive, createdAt: Date(timeIntervalSince1970: 0),
            spans: [TranscriptSpan(text: "hello", anchor: .none),
                    TranscriptSpan(text: "", anchor: .none),
                    TranscriptSpan(text: "world", anchor: .none)])
        XCTAssertEqual(TranscriptChain.plainText(revision), "hello world")
    }
}
