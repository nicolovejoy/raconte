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

    // MARK: voiceLabels (T7 Mark Voices, issue #56)
    //
    // Additive and lenient, like `EntryMetadata.multiVoice`/`detectedDate`: every
    // registry on disk predates this field, and a damaged label map must not take a
    // journal's id/name/createdAt down with it. Encoded only when non-empty, so a
    // journal nobody has labelled yet keeps producing exactly today's bytes.

    func testVoiceLabelsAbsentDecodesEmpty() throws {
        let registry = try JournalStore.load(url: writeRegistry(
            #"{"journals":[{"id":"A","name":"N","createdAt":"1970-01-01T00:00:00.000Z"}]}"#))
        XCTAssertEqual(registry.journals.first?.voiceLabels, [:])
    }

    func testVoiceLabelsRoundTrip() async throws {
        let s = store(ids: ["J1"])
        _ = try await s.create(name: "Untitled")
        let updated = try await s.setVoiceLabels(id: "J1", labels: ["bn": "Grandpa", "ln": "Nico"])
        XCTAssertEqual(updated.voiceLabels, ["bn": "Grandpa", "ln": "Nico"])

        // A *fresh* store over the same file — the round trip is through disk.
        let reread = try await JournalStore(containerRoot: containerRoot).list()
        XCTAssertEqual(reread.first?.voiceLabels, ["bn": "Grandpa", "ln": "Nico"])
    }

    /// Extends `testEncodedShapeIsSingleLineWithSortedKeysAndISO8601Dates` above: a
    /// default (unlabelled) journal's serialized bytes are UNCHANGED from before this
    /// field existed — the exact same literal string that test already pins.
    func testDefaultVoiceLabelsAreOmittedFromTheRegistryBytes() throws {
        let registry = JournalRegistry(journals: [
            Journal(id: "A", name: "1987 Journal", createdAt: Date(timeIntervalSince1970: 0))
        ])
        let text = String(decoding: try JournalStore.encode(registry), as: UTF8.self)
        XCTAssertEqual(text,
            #"{"journals":[{"createdAt":"1970-01-01T00:00:00.000Z","id":"A","name":"1987 Journal"}]}"#)
        XCTAssertFalse(text.contains("voiceLabels"))
    }

    func testVoiceLabelsGarbageDecodesEmpty() throws {
        let registry = try JournalStore.load(url: writeRegistry(
            #"{"journals":[{"id":"A","name":"N","createdAt":"1970-01-01T00:00:00.000Z","voiceLabels":"oops"}]}"#))
        XCTAssertEqual(registry.journals.first?.voiceLabels, [:])
        XCTAssertEqual(registry.journals.first?.id, "A")
    }

    func testSetVoiceLabelsUnknownJournalThrows() async throws {
        let s = store(ids: ["J1"])
        _ = try await s.create(name: "Keep me")
        let before = try Data(contentsOf: registryURL)
        do {
            _ = try await s.setVoiceLabels(id: "missing", labels: ["bn": "Grandpa"])
            XCTFail("expected unknownJournal")
        } catch {
            XCTAssertEqual(error as? JournalError, .unknownJournal("missing"))
        }
        XCTAssertEqual(try Data(contentsOf: registryURL), before)
    }

    func testSetVoiceLabelsTrimsAndDropsEmptyValues() async throws {
        let s = store(ids: ["J1"])
        _ = try await s.create(name: "Untitled")
        let updated = try await s.setVoiceLabels(id: "J1", labels: [
            "bn": "  Grandpa  ",
            "ln": "   ",
            "x-third": "",
        ])
        XCTAssertEqual(updated.voiceLabels, ["bn": "Grandpa"])
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

    // MARK: - span (spec ruling 2)

    func testSpanIsAdditiveAndLenient() throws {
        // Every registry on disk predates this field. Absent -> nil, garbage -> nil, and
        // neither may take the journal's identity down with it.
        let absent = Data(#"{"id":"J1","name":"N","createdAt":"1998-03-04T00:00:00.000Z"}"#.utf8)
        XCTAssertNil(try CaptureCoding.decoder().decode(Journal.self, from: absent).span)

        let garbage = Data(#"{"id":"J1","name":"N","createdAt":"1998-03-04T00:00:00.000Z","span":7}"#.utf8)
        let decoded = try CaptureCoding.decoder().decode(Journal.self, from: garbage)
        XCTAssertNil(decoded.span)
        XCTAssertEqual(decoded.name, "N", "a damaged span must cost only the span")
    }

    /// `JournalSpan.init(from:)` re-checks the inverted-bounds invariant on every decode
    /// (Task 2), so a structurally valid span object with end < start throws from inside
    /// `container.decodeIfPresent`. This project's decoder rule treats any span decode
    /// failure identically, whether the JSON shape is wrong (`"span":7` above) or the
    /// shape is right but the value violates an invariant: both are "a damaged span",
    /// and a damaged span must cost only the span, never the journal's identity.
    func testInvertedSpanOnDiskDecodesToNilNotThrow() throws {
        let inverted = Data(#"""
        {"id":"J1","name":"N","createdAt":"1998-03-04T00:00:00.000Z",
         "span":{"start":"2001","end":"1998"}}
        """#.utf8)
        let decoded = try CaptureCoding.decoder().decode(Journal.self, from: inverted)
        XCTAssertNil(decoded.span)
        XCTAssertEqual(decoded.name, "N", "an invariant-violating span must cost only the span")
    }

    func testAJournalWithoutASpanEncodesByteIdentically() throws {
        // The bytes of every registry already on disk must not change.
        let journal = Journal(id: "J1", name: "N",
                              createdAt: Date(timeIntervalSince1970: 0))
        let data = try JournalStore.encode(JournalRegistry(journals: [journal]))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("span"))
    }

    func testSetSpanPersistsAndReloads() async throws {
        let s = store(ids: ["J1"])
        let created = try await s.create(name: "1998 Journal")
        let span = try JournalSpan(start: PartialDate(year: 1998),
                                   end: PartialDate(year: 2001))
        _ = try await s.setSpan(id: created.id, span: span)
        let reloaded = try await s.journal(id: created.id)
        XCTAssertEqual(reloaded?.span, span)
    }

    func testSetSpanOnAnUnknownJournalThrowsAndLeavesTheFileAlone() async throws {
        let s = store(ids: ["J1"])
        _ = try await s.create(name: "Keep me")
        let before = try Data(contentsOf: registryURL)
        let span = try JournalSpan(start: PartialDate(year: 1998), end: nil)
        do {
            _ = try await s.setSpan(id: "missing", span: span)
            XCTFail("expected unknownJournal")
        } catch {
            XCTAssertEqual(error as? JournalError, .unknownJournal("missing"))
        }
        XCTAssertEqual(try Data(contentsOf: registryURL), before)
    }

    func testClearingASpanRemovesTheKey() async throws {
        let s = store(ids: ["J1"])
        let created = try await s.create(name: "N")
        _ = try await s.setSpan(id: created.id,
                                span: try JournalSpan(start: PartialDate(year: 1998), end: nil))
        _ = try await s.setSpan(id: created.id, span: nil)
        let reloaded = try await s.journal(id: created.id)
        XCTAssertNil(reloaded?.span)
        XCTAssertFalse(String(decoding: try Data(contentsOf: registryURL), as: UTF8.self)
                        .contains("span"))
    }

    /// A tripwire, not a style check. `Journal.encode(to:)` enumerates fields by hand, so a
    /// field added to `Journal` is dropped on every write by default and no existing test
    /// notices. If this fails: carry the new field over in `encode(to:)` AND `init(from:)`,
    /// assert it round-trips above, then bump the count.
    ///
    /// The SYNC half of this enforcement lives on `m4/sync` (spec, "Branch split") — that
    /// branch enumerates journal fields in six more places this branch cannot see.
    func testJournalFieldCountIsPinnedSoNewFieldsGetEncoded() {
        let journal = Journal(id: "J1", name: "N", createdAt: Date())
        XCTAssertEqual(Mirror(reflecting: journal).children.count, 5,
                       "Journal gained or lost a field — see Journal.encode(to:)")
    }
}
