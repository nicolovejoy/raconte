import XCTest
@testable import Raconte

/// T6e: `TranscriptMerge` — pure minting of accept/decline/revert (design §6). No
/// filesystem for 6.1-6.4; 6.5 uses the real store to walk `basedOnMachineID`
/// propagation through an actual append + closeDraft.
final class TranscriptMergeTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func exact(_ text: String, _ start: Int64, _ end: Int64,
                       sourceRevisionID: String? = nil) -> TranscriptSpan {
        TranscriptSpan(text: text, anchor: .exact, frameStart: start, frameEnd: end,
                       sourceRevisionID: sourceRevisionID)
    }

    // MARK: - 6.1 Accept

    func testAcceptAdoptsMachineSpansVerbatimTextAndFrames() {
        // The F18 merge-exemption case: the machine revision's own span is `.exact`
        // with real frames — accept must carry BOTH across unchanged, not just the text.
        let machine = TranscriptRevision(id: "M1", source: .machineRetranscribe, createdAt: t0,
                                         spans: [exact("hello world", 0, 100)])
        let current = TranscriptRevision(id: "C1", source: .userEdit, createdAt: t0,
                                         spans: [TranscriptSpan(text: "hello there", anchor: .none)])

        let merged = TranscriptMerge.accept(current: current, machine: machine,
                                            id: "MG1", createdAt: t0, deviceID: "dev-1")

        XCTAssertEqual(merged.spans, [exact("hello world", 0, 100, sourceRevisionID: "M1")])
    }

    func testAcceptSetsParentBasedOnMachineIDAndSource() {
        let machine = TranscriptRevision(id: "M1", source: .machineRetranscribe, createdAt: t0,
                                         spans: [exact("hello world", 0, 100)])
        let current = TranscriptRevision(id: "C1", source: .userEdit, createdAt: t0,
                                         spans: [TranscriptSpan(text: "hello there", anchor: .none)])

        let merged = TranscriptMerge.accept(current: current, machine: machine,
                                            id: "MG1", createdAt: t0, deviceID: "dev-1")

        XCTAssertEqual(merged.source, .merge)
        XCTAssertEqual(merged.parentID, "C1")
        XCTAssertEqual(merged.basedOnMachineID, "M1")
        XCTAssertEqual(merged.deviceID, "dev-1")
    }

    func testAcceptDropsSourceRevisionIDWhenItEqualsTheMintedID() {
        // The caller-side omit-when-equal economy (TranscriptSpan.swift:150-156): if the
        // fresh merge id happens to equal the resolved source (pathological but the
        // rule must hold regardless), the field is written back to nil rather than a
        // redundant explicit self-reference.
        let machine = TranscriptRevision(id: "SAME-ID", source: .machineLive, createdAt: t0,
                                         spans: [exact("hi", 0, 10)])
        let current = TranscriptRevision(id: "C1", source: .userEdit, createdAt: t0, spans: [])

        let merged = TranscriptMerge.accept(current: current, machine: machine,
                                            id: "SAME-ID", createdAt: t0, deviceID: nil)

        XCTAssertNil(merged.spans[0].sourceRevisionID)
    }

    func testAcceptAfterAppendMakesTheMergeCurrent() async throws {
        // After-append derivation assertion via the real store + chain: TranscriptChain
        // must resolve the merge, not the machine revision it accepted, as `current`.
        let harness = try Harness()
        let machine = TranscriptRevision(id: "01M0000000000000000000000A", source: .machineLive,
                                         createdAt: t0, spans: [exact("hello world", 0, 100)])
        try await harness.store.append(machine, captureID: harness.captureID)

        let current = machine
        let merged = TranscriptMerge.accept(current: current, machine: machine,
                                            id: "01MG00000000000000000000B", createdAt: t0.addingTimeInterval(1),
                                            deviceID: nil)
        try await harness.store.append(merged, captureID: harness.captureID)

        let load = TranscriptRevisionStore.loadChain(captureDirectory: harness.captureDirectory)
        XCTAssertEqual(TranscriptChain.current(load!.revisions)?.id, merged.id)
    }

    // MARK: - 6.2 Decline

    func testDeclineSpansByteIdenticalToCurrent() {
        let current = TranscriptRevision(id: "C1", source: .userEdit, createdAt: t0,
                                         spans: [exact("kept as-is", 0, 50)])
        let machine = TranscriptRevision(id: "M1", source: .machineRetranscribe, createdAt: t0,
                                         spans: [exact("different text", 0, 60)])

        let declined = TranscriptMerge.decline(current: current, machine: machine,
                                               id: "MG1", createdAt: t0, deviceID: nil)

        XCTAssertEqual(declined.spans, [exact("kept as-is", 0, 50, sourceRevisionID: "C1")])
    }

    func testDeclineAdvancesBasedOnMachineIDToTheDeclinedRevision() {
        let current = TranscriptRevision(id: "C1", source: .userEdit, createdAt: t0,
                                         spans: [exact("kept as-is", 0, 50)])
        let machine = TranscriptRevision(id: "M1", source: .machineRetranscribe, createdAt: t0,
                                         spans: [exact("different text", 0, 60)])

        let declined = TranscriptMerge.decline(current: current, machine: machine,
                                               id: "MG1", createdAt: t0, deviceID: nil)

        XCTAssertEqual(declined.source, .merge)
        XCTAssertEqual(declined.parentID, "C1")
        XCTAssertEqual(declined.basedOnMachineID, "M1")
    }

    func testDeclinedMachineRevisionStaysDetachedAfterDeclineIsCurrent() async throws {
        // Next attachment derivation: a declined machine revision is NOT an ancestor of
        // the decline (decline's parentID is current, not the machine revision), so it
        // stays detached even though the decline is now current.
        let harness = try Harness()
        let current = TranscriptRevision(id: "01C0000000000000000000000A", source: .userEdit,
                                         createdAt: t0, spans: [exact("kept as-is", 0, 50)])
        try await harness.store.append(current, captureID: harness.captureID)
        let machine = TranscriptRevision(id: "01M0000000000000000000000B", source: .machineRetranscribe,
                                         createdAt: t0.addingTimeInterval(1),
                                         spans: [exact("different text", 0, 60)])
        try await harness.store.append(machine, captureID: harness.captureID)

        let declined = TranscriptMerge.decline(current: current, machine: machine,
                                               id: "01MG0000000000000000000C", createdAt: t0.addingTimeInterval(2),
                                               deviceID: nil)
        try await harness.store.append(declined, captureID: harness.captureID)

        let load = TranscriptRevisionStore.loadChain(captureDirectory: harness.captureDirectory)!
        XCTAssertEqual(TranscriptChain.current(load.revisions)?.id, declined.id)
        XCTAssertFalse(TranscriptChain.isAttached(machine, in: load.revisions))
    }

    // MARK: - 6.3 Revert

    func testRevertUntouchedEntryShapeRestoresExactAnchorsLegitimately() async throws {
        // Untouched-entry shape (design §6.2/§6.5): rev0 machine -> retranscribe M
        // (current, attached, no human lineage yet) -> revert to rev0 => current is the
        // merge, spans byte-equal rev0's, `.exact` anchors restored legitimately.
        let harness = try Harness()
        let rev0 = TranscriptRevision(id: "01R0000000000000000000000A", source: .machineLive,
                                      createdAt: t0, spans: [exact("original words", 0, 200)])
        try await harness.store.append(rev0, captureID: harness.captureID)

        let m = TranscriptRevision(id: "01M0000000000000000000000B", source: .machineRetranscribe,
                                   createdAt: t0.addingTimeInterval(1),
                                   spans: [exact("worse retranscription", 0, 200)])
        try await harness.store.append(m, captureID: harness.captureID)

        // With no human lineage, m is attached and current (design §6.2).
        var load = TranscriptRevisionStore.loadChain(captureDirectory: harness.captureDirectory)!
        XCTAssertEqual(TranscriptChain.current(load.revisions)?.id, m.id)

        let reverted = TranscriptMerge.revert(current: m, toMachine: rev0,
                                              id: "01MG0000000000000000000C", createdAt: t0.addingTimeInterval(2),
                                              deviceID: nil)
        try await harness.store.append(reverted, captureID: harness.captureID)

        load = TranscriptRevisionStore.loadChain(captureDirectory: harness.captureDirectory)!
        XCTAssertEqual(TranscriptChain.current(load.revisions)?.id, reverted.id)
        XCTAssertEqual(reverted.spans, [exact("original words", 0, 200, sourceRevisionID: rev0.id)])
        XCTAssertEqual(reverted.parentID, m.id)
        XCTAssertEqual(reverted.basedOnMachineID, rev0.id)
    }

    // MARK: - 6.4 F11 overlap

    func testDegradingOverlapsDemotesRetainedSpanIntersectingAdoptedSpan() {
        let retained = [exact("I went to the store", 0, 100)]
        let adopted = [exact("the store", 45, 100)]

        let result = TranscriptMerge.degradingOverlaps(retained: retained, adopted: adopted)

        XCTAssertEqual(result, [
            TranscriptSpan(text: "I went to the store", anchor: .inherited, frameStart: 0, frameEnd: 100),
        ])
    }

    func testDegradingOverlapsLeavesNonIntersectingRetainedSpanExact() {
        let retained = [exact("untouched elsewhere", 200, 300)]
        let adopted = [exact("the store", 45, 100)]

        let result = TranscriptMerge.degradingOverlaps(retained: retained, adopted: adopted)

        XCTAssertEqual(result, retained)
    }

    func testDegradingOverlapsNoTwoExactSpansIntersectAfterward() {
        // The property, not just the worked example: any retained span overlapping ANY
        // adopted span degrades, so `retained' + adopted` never has two intersecting
        // `.exact` spans.
        let retained = [
            exact("a", 0, 50),      // overlaps adopted[0]
            exact("b", 500, 600),   // clear
            exact("c", 95, 150),    // overlaps adopted[0] at the boundary
        ]
        let adopted = [exact("x", 40, 100)]

        let result = TranscriptMerge.degradingOverlaps(retained: retained, adopted: adopted)
        let all = result + adopted

        for i in all.indices {
            guard all[i].anchor == .exact, let iStart = all[i].frameStart, let iEnd = all[i].frameEnd else { continue }
            for j in all.indices where j != i {
                guard all[j].anchor == .exact, let jStart = all[j].frameStart, let jEnd = all[j].frameEnd else { continue }
                let overlaps = iStart < jEnd && jStart < iEnd
                XCTAssertFalse(overlaps, "two .exact spans intersect: \(all[i]) and \(all[j])")
            }
        }
        // And concretely: only "b" (clear of the adopted range) stays .exact.
        XCTAssertEqual(result[0].anchor, .inherited)
        XCTAssertEqual(result[1].anchor, .exact)
        XCTAssertEqual(result[2].anchor, .inherited)
    }

    func testDegradingOverlapsSkipsSpansWithNoUsableBounds() {
        let retained = [TranscriptSpan(text: "no bounds", anchor: .none)]
        let adopted = [exact("x", 0, 100)]

        let result = TranscriptMerge.degradingOverlaps(retained: retained, adopted: adopted)

        XCTAssertEqual(result, retained)
    }

    // MARK: - 6.5 basedOnMachineID propagation (§6.4/F13)

    func testUserEditAfterMergeCopiesTheMergesStoredBasedOnMachineIDNotNearestAncestor() async throws {
        // Construct the case where "stored" and "nearest machine ancestor" DIFFER
        // (F13): rev0 machine M0 -> user edit U1 (parent M0, so U1.basedOnMachineID ==
        // M0.id via the store's own propagation rule) -> a SECOND, unrelated machine
        // revision M2 arrives (parentID = M0, so M2 is detached under U1) -> accept M2
        // on top of U1, producing merge G (parentID = U1, basedOnMachineID = M2.id) ->
        // a further user edit U3 opened against G.
        //
        // Walking U3's PARENTID chain only (the wrong "nearest machine ancestor" reading)
        // reaches U3 -> G -> U1 -> M0: the nearest machine revision on that chain is M0.
        // The correct, STORED answer is M2 (what accept actually recorded on G, and what
        // U3 must copy per §6.4). M0 != M2, so this is a genuine divergent case.
        let harness = try Harness()

        let m0 = TranscriptRevision(id: "01M0000000000000000000000A", source: .machineLive,
                                    createdAt: t0, spans: [exact("original", 0, 100)])
        try await harness.store.append(m0, captureID: harness.captureID)

        try await harness.store.writeDraft(captureID: harness.captureID, text: "original edited",
                                     now: t0.addingTimeInterval(1))
        let u1ID = try await harness.store.closeDraft(captureID: harness.captureID, reason: .sessionEnd,
                                                 now: t0.addingTimeInterval(2))
        XCTAssertNotNil(u1ID)
        var load = TranscriptRevisionStore.loadChain(captureDirectory: harness.captureDirectory)!
        let u1 = load.revisions.first { $0.id == u1ID }!
        XCTAssertEqual(u1.basedOnMachineID, m0.id, "sanity: U1 propagated M0's id as its parent's own id")

        let m2 = TranscriptRevision(id: "01M2000000000000000000000B", source: .machineRetranscribe,
                                    createdAt: t0.addingTimeInterval(3), spans: [exact("retranscribed", 0, 100)],
                                    parentID: m0.id)
        try await harness.store.append(m2, captureID: harness.captureID)

        let g = TranscriptMerge.accept(current: u1, machine: m2,
                                       id: "01G0000000000000000000000C", createdAt: t0.addingTimeInterval(4),
                                       deviceID: nil)
        try await harness.store.append(g, captureID: harness.captureID)
        XCTAssertEqual(g.basedOnMachineID, m2.id)

        try await harness.store.writeDraft(captureID: harness.captureID, text: "retranscribed further edited",
                                     now: t0.addingTimeInterval(5))
        let u3ID = try await harness.store.closeDraft(captureID: harness.captureID, reason: .sessionEnd,
                                                 now: t0.addingTimeInterval(6))
        XCTAssertNotNil(u3ID)

        load = TranscriptRevisionStore.loadChain(captureDirectory: harness.captureDirectory)!
        let u3 = load.revisions.first { $0.id == u3ID }!

        XCTAssertEqual(u3.basedOnMachineID, m2.id,
                       "must copy the merge's STORED basedOnMachineID")
        XCTAssertNotEqual(u3.basedOnMachineID, m0.id,
                          "the wrong 'nearest machine ancestor' reading would have said M0 — proves the two answers actually diverge here")
    }

    // MARK: - Test harness

    /// Thin real-filesystem harness for the after-append derivation assertions (6.1,
    /// 6.2, 6.3, 6.5) — a fresh temp captures root + one pre-existing capture directory
    /// per test.
    private final class Harness {
        let containerRoot: URL
        let captureID = "01KYX77KK5QM15915EZBVXTQZ4"
        let store: TranscriptRevisionStore

        var capturesRoot: URL { AppContainer.capturesRoot(containerRoot: containerRoot) }
        var captureDirectory: URL {
            SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
        }

        init() throws {
            let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("RaconteMergeTests-\(UUID().uuidString)", isDirectory: true)
            containerRoot = root
            let roots = AppContainer.capturesRoot(containerRoot: root)
            store = TranscriptRevisionStore(capturesRoot: roots)
            try FileManager.default.createDirectory(
                at: SegmentLayout.captureDirectory(capturesRoot: roots, captureID: captureID),
                withIntermediateDirectories: true)
        }

        deinit {
            try? FileManager.default.removeItem(at: containerRoot)
        }
    }
}
