import XCTest
@testable import Raconte

/// Task A1 (issue #79): the journals list shows a different order on every device and
/// every surface, because no surface ever sorted and the underlying array order is
/// per-device history — local creates append locally, CloudKit-adopted journals append
/// in arrival order. `Array<Journal>.displayOrdered` is the ONE place order is decided;
/// every UI surface reads journals only through it.
@MainActor
final class JournalOrderingTests: XCTestCase {

    private func journal(_ id: String, _ name: String = "J", createdAt: Date) -> Journal {
        Journal(id: id, name: name, createdAt: createdAt)
    }

    // MARK: Pure helper

    /// Two devices with mirror-image histories — one created J1 locally and adopted J2
    /// from a sync merge, the other created J2 locally and adopted J1 — must converge on
    /// the SAME display order even though their raw storage order (registry insertion
    /// order, deliberately unsorted per `JournalRegistry`'s own doc comment) differs.
    ///
    /// `createdAt` values are distinct constants, not minted under one frozen clock via
    /// a real ID generator: the tie-break-by-id half is a different, deliberately tied
    /// test below. Mixing the two into one test would make this one flake on ULID
    /// suffix ordering for no reason connected to what it is pinning (memory:
    /// frozen-clock-two-mints-coin-flip-order).
    func testInterleavedCreateAndSyncAdoptHistoriesConverge() throws {
        let t1 = Date(timeIntervalSince1970: 1_000)
        let t2 = Date(timeIntervalSince1970: 2_000)
        let j1 = journal("J1", "One", createdAt: t1)
        let j2 = journal("J2", "Two", createdAt: t2)

        // Registry A: created J1 locally, then adopted J2 via a sync merge.
        var registryA = JournalRegistry()
        try registryA.insert(j1, now: t1)
        registryA.applySyncMerge(j2)

        // Registry B: created J2 locally, then adopted J1 via a sync merge — the
        // mirror-image history a second device genuinely produces.
        var registryB = JournalRegistry()
        try registryB.insert(j2, now: t2)
        registryB.applySyncMerge(j1)

        // Raw storage order differs — that per-device divergence is #79 itself.
        XCTAssertEqual(registryA.journals.map(\.id), ["J1", "J2"],
                       "registry A's own insertion order")
        XCTAssertEqual(registryB.journals.map(\.id), ["J2", "J1"],
                       "registry B's own insertion order — the mirror image of A's")

        // Display order must converge regardless.
        XCTAssertEqual(registryA.journals.displayOrdered.map(\.id), ["J1", "J2"])
        XCTAssertEqual(registryB.journals.displayOrdered.map(\.id), ["J1", "J2"],
                       "both devices must show journals in the same order")
    }

    /// A genuine tie on `createdAt` — e.g. two journals adopted in the same sync batch,
    /// stamped identically — breaks by id, deterministically, regardless of which order
    /// they arrive in. Minted at one frozen instant on purpose: the tie IS the point.
    func testTiedCreatedAtBreaksByID() {
        let frozen = Date(timeIntervalSince1970: 5_000)
        let higher = journal("ZZZ", "Z", createdAt: frozen)
        let lower = journal("AAA", "A", createdAt: frozen)

        XCTAssertEqual([higher, lower].displayOrdered.map(\.id), ["AAA", "ZZZ"])
        XCTAssertEqual([lower, higher].displayOrdered.map(\.id), ["AAA", "ZZZ"],
                       "order must not depend on the array's incoming order")
    }

    // MARK: Surfaces

    private var containerRoot: URL!

    override func setUpWithError() throws {
        containerRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("JournalOrdering-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: containerRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let containerRoot { try? FileManager.default.removeItem(at: containerRoot) }
    }

    /// Writes a `journals.json` fixture deliberately out of `createdAt` order — exactly
    /// what a real device's per-device append history produces (#79) — and returns the
    /// expected display-order id sequence.
    @discardableResult
    private func writeShuffledJournals() throws -> [String] {
        let j1 = journal("J1", "One", createdAt: Date(timeIntervalSince1970: 1_000))
        let j2 = journal("J2", "Two", createdAt: Date(timeIntervalSince1970: 3_000))
        let j3 = journal("J3", "Three", createdAt: Date(timeIntervalSince1970: 2_000))
        let onDisk = [j2, j3, j1] // arbitrary, unsorted append order
        try JournalStore.encode(JournalRegistry(journals: onDisk))
            .write(to: AppContainer.journalsURL(containerRoot: containerRoot))
        return ["J1", "J3", "J2"] // ascending by createdAt: 1_000, 2_000, 3_000
    }

    func testLibraryScreenModelExposesJournalsInDisplayOrderAfterRescan() async throws {
        let expected = try writeShuffledJournals()
        let capturesRoot = AppContainer.capturesRoot(containerRoot: containerRoot)
        try FileManager.default.createDirectory(at: capturesRoot, withIntermediateDirectories: true)

        let model = LibraryScreenModel(capturesRoot: capturesRoot, journalsContainerRoot: containerRoot)
        await model.rescan()

        XCTAssertEqual(model.journals.map(\.id), expected)
    }

    func testCaptureScreenModelExposesJournalsInDisplayOrderAfterBootstrap() async throws {
        let expected = try writeShuffledJournals()
        let capturesRoot = AppContainer.capturesRoot(containerRoot: containerRoot)
        try FileManager.default.createDirectory(at: capturesRoot, withIntermediateDirectories: true)

        let model = CaptureScreenModel(
            capturesRoot: capturesRoot,
            makeSession: { ModelFakeSession() },
            makeRecorder: { ModelFakeRecorder() },
            encoder: FakeAudioEncoder(),
            journalsContainerRoot: containerRoot)
        await model.bootstrap()

        XCTAssertEqual(model.journals.map(\.id), expected)
    }
}
