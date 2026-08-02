import XCTest
@testable import Raconte

/// M3 T1: the journals registry round-trips, refuses to read an empty registry out of a
/// damaged file, and decodes per the house rule (identity fields strict).
final class JournalStoreTests: XCTestCase {

    private var containerRoot: URL!

    override func setUpWithError() throws {
        containerRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RaconteJournals-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: containerRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: containerRoot)
    }

    private var registryURL: URL { AppContainer.journalsURL(containerRoot: containerRoot) }

    private func store(ids: [String] = [], at date: Date = Date(timeIntervalSince1970: 1)) -> JournalStore {
        let box = IDBox(ids: ids)
        return JournalStore(containerRoot: containerRoot,
                            mintID: { box.next() },
                            now: { date })
    }

    /// Deterministic id sequence; falls back to a real ULID once exhausted.
    private final class IDBox: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String]
        init(ids: [String]) { self.ids = ids }
        func next() -> String {
            lock.lock(); defer { lock.unlock() }
            return ids.isEmpty ? ULID.make() : ids.removeFirst()
        }
    }

    // MARK: Round trip

    func testCreateListLookupRoundTripThroughDisk() async throws {
        let created = Date(timeIntervalSince1970: 1_500_000.25)
        let s = store(ids: ["JOURNALA", "JOURNALB"], at: created)

        let a = try await s.create(name: "1987 Journal")
        let b = try await s.create(name: "Trip to France")
        XCTAssertEqual(a.id, "JOURNALA")
        XCTAssertEqual(a.createdAt, created)

        // A *fresh* store over the same file — the round trip is through disk, not memory.
        let reader = JournalStore(containerRoot: containerRoot)
        let listed = try await reader.list()
        XCTAssertEqual(listed.map(\.id), ["JOURNALA", "JOURNALB"], "insertion order preserved")
        XCTAssertEqual(listed.map(\.name), ["1987 Journal", "Trip to France"])
        let found = try await reader.journal(id: "JOURNALB")
        XCTAssertEqual(found, b)
        let missing = try await reader.journal(id: "nope")
        XCTAssertNil(missing)
    }

    func testAbsentRegistryIsEmptyNotAnError() async throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: registryURL.path))
        let listed = try await store().list()
        XCTAssertEqual(listed, [])
    }

    func testRenameKeepsIDAndCreatedAt() async throws {
        let s = store(ids: ["J1"])
        let original = try await s.create(name: "Untitled")
        let renamed = try await s.rename(id: "J1", to: "1987 Journal")
        XCTAssertEqual(renamed.id, original.id)
        XCTAssertEqual(renamed.createdAt, original.createdAt)
        XCTAssertEqual(renamed.name, "1987 Journal")
        let reread = try await JournalStore(containerRoot: containerRoot).list()
        XCTAssertEqual(reread.map(\.name), ["1987 Journal"])
    }

    func testRenameUnknownJournalThrowsAndLeavesTheFileAlone() async throws {
        let s = store(ids: ["J1"])
        _ = try await s.create(name: "Keep me")
        let before = try Data(contentsOf: registryURL)
        do {
            _ = try await s.rename(id: "missing", to: "x")
            XCTFail("expected unknownJournal")
        } catch {
            XCTAssertEqual(error as? JournalError, .unknownJournal("missing"))
        }
        XCTAssertEqual(try Data(contentsOf: registryURL), before)
    }

    func testNamesAreTrimmedAndBlankNamesRejected() async throws {
        let s = store(ids: ["J1"])
        let j = try await s.create(name: "  Trip to France \n")
        XCTAssertEqual(j.name, "Trip to France")

        for blank in ["", "   ", "\n\t"] {
            do {
                _ = try await s.create(name: blank)
                XCTFail("expected emptyName for \(blank.debugDescription)")
            } catch {
                XCTAssertEqual(error as? JournalError, .emptyName)
            }
            do {
                _ = try await s.rename(id: "J1", to: blank)
                XCTFail("expected emptyName for \(blank.debugDescription)")
            } catch {
                XCTAssertEqual(error as? JournalError, .emptyName)
            }
        }
        let remaining = try await s.list()
        XCTAssertEqual(remaining.count, 1)
    }

    func testDuplicateNamesAreAllowedDuplicateIDsAreNot() throws {
        var registry = JournalRegistry()
        try registry.insert(Journal(id: "A", name: "Journal", createdAt: .distantPast))
        XCTAssertNoThrow(try registry.insert(Journal(id: "B", name: "Journal", createdAt: .distantPast)))
        XCTAssertThrowsError(try registry.insert(Journal(id: "A", name: "Other", createdAt: .distantPast))) {
            XCTAssertEqual($0 as? JournalError, .duplicateID("A"))
        }
        XCTAssertEqual(registry.journals.count, 2)
    }

    // MARK: Damaged registry

    func testUnreadableRegistryThrowsRatherThanReadingEmpty() async throws {
        try Data("not json".utf8).write(to: registryURL)
        do {
            _ = try await store().list()
            XCTFail("expected unreadable")
        } catch {
            guard case .unreadable = (error as? JournalStoreError) else {
                return XCTFail("expected JournalStoreError.unreadable, got \(error)")
            }
        }
    }

    /// The dangerous case: valid JSON that is not a registry. Reading it as "no journals"
    /// and then writing would replace every journal the user has (issue #11's rule).
    func testValidJSONWithoutJournalsKeyThrows() throws {
        XCTAssertThrowsError(try JournalStore.load(url: writeRegistry(#"{"other":1}"#)))
    }

    func testCreateDoesNotOverwriteADamagedRegistry() async throws {
        let damaged = Data(#"{"journals": [{"id":"A"}]}"#.utf8)   // journal missing name/createdAt
        try damaged.write(to: registryURL)
        _ = try? await store().create(name: "New")
        XCTAssertEqual(try Data(contentsOf: registryURL), damaged,
                       "a failed load must abort the write, not replace the file")
    }

    // MARK: Decoder rule (§11)

    func testDecoderIsStrictAboutIdentityFields() throws {
        // All three present: fine.
        let ok = try JournalStore.load(url: writeRegistry(
            #"{"journals":[{"id":"A","name":"N","createdAt":"1970-01-01T00:00:00.000Z"}]}"#))
        XCTAssertEqual(ok.journals, [Journal(id: "A", name: "N", createdAt: Date(timeIntervalSince1970: 0))])

        // Each one missing in turn must throw — a synthesized decoder over a defaulted
        // property would too, but only by accident; this pins the intent.
        for missing in [#"{"name":"N","createdAt":"1970-01-01T00:00:00.000Z"}"#,
                        #"{"id":"A","createdAt":"1970-01-01T00:00:00.000Z"}"#,
                        #"{"id":"A","name":"N"}"#] {
            XCTAssertThrowsError(try JournalStore.load(url: writeRegistry(#"{"journals":[\#(missing)]}"#)),
                                 "expected a throw for \(missing)")
        }
    }

    func testDecoderIgnoresUnknownKeysFromANewerBuild() throws {
        let registry = try JournalStore.load(url: writeRegistry(
            #"{"schemaVersion":9,"journals":[{"id":"A","name":"N","createdAt":"1970-01-01T00:00:00.000Z","color":"red"}]}"#))
        XCTAssertEqual(registry.journals.map(\.id), ["A"])
    }

    func testEncodedShapeIsSingleLineWithSortedKeysAndISO8601Dates() throws {
        let registry = JournalRegistry(journals: [
            Journal(id: "A", name: "1987 Journal", createdAt: Date(timeIntervalSince1970: 0))
        ])
        let text = String(decoding: try JournalStore.encode(registry), as: UTF8.self)
        XCTAssertEqual(text,
            #"{"journals":[{"createdAt":"1970-01-01T00:00:00.000Z","id":"A","name":"1987 Journal"}]}"#)
    }

    /// The registry sits beside `captures/`, never inside it: `DirectorySnapshot.gather`
    /// walks every child of `captures/` and hands it to the recovery planner.
    func testRegistryLivesBesideCapturesNotInside() {
        let capturesRoot = AppContainer.capturesRoot(containerRoot: containerRoot)
        XCTAssertEqual(registryURL, containerRoot.appendingPathComponent("journals.json"))
        XCTAssertEqual(AppContainer.containerRoot(capturesRoot: capturesRoot).standardizedFileURL,
                       containerRoot.standardizedFileURL)
        XCTAssertFalse(registryURL.path.hasPrefix(capturesRoot.path))
    }

    // MARK: Atomic write

    func testWriteLeavesNoStrayPartFile() async throws {
        _ = try await store(ids: ["J1"]).create(name: "N")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SegmentLayout.partURL(for: registryURL).path))
    }

    private func writeRegistry(_ json: String) throws -> URL {
        try Data(json.utf8).write(to: registryURL)
        return registryURL
    }
}
