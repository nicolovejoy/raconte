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

    private func store(ids: [String] = [], at date: Date = Date(timeIntervalSince1970: 1),
                       now: (@Sendable () -> Date)? = nil) -> JournalStore {
        let box = IDBox(ids: ids)
        return JournalStore(containerRoot: containerRoot,
                            mintID: { box.next() },
                            now: now ?? { date })
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

    // MARK: M4 T1 — sync stamps (`modified`)

    /// Advances on every call — same frozen-clock trap this codebase always guards
    /// against (memory: frozen-clock-two-mints-coin-flip-order): two writes sharing one
    /// frozen clock could stamp two different keys with the identical instant, letting a
    /// "the other key's stamp is untouched" assertion pass even if every write re-stamped
    /// everything.
    private final class AdvancingClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current: Date
        init(start: Date) { self.current = start }
        func next() -> Date {
            lock.lock(); defer { lock.unlock() }
            let value = current
            current = current.addingTimeInterval(1)
            return value
        }
    }

    func testCreateStampsModifiedName() async throws {
        let stamp = Date(timeIntervalSince1970: 1_650_000_000)
        let s = store(ids: ["J1"], now: { stamp })
        let created = try await s.create(name: "1987 Journal")
        XCTAssertEqual(created.modified, ["name": stamp])
    }

    /// Cardinality (mirrors `EntryMetadataStoreTests`' pin for the sidecar): `rename`
    /// stamps `name` only. A prior `setVoiceLabels` stamp on the SAME journal is left
    /// exactly as it was.
    func testRenameStampsNameAndLeavesVoiceLabelsStampUntouched() async throws {
        let clock = AdvancingClock(start: Date(timeIntervalSince1970: 1_650_000_000))
        let s = store(ids: ["J1"], now: { clock.next() })
        _ = try await s.create(name: "Untitled")
        let labelled = try await s.setVoiceLabels(id: "J1", labels: ["bn": "Grandpa"])
        let voiceLabelsStamp = try XCTUnwrap(labelled.modified?["voiceLabels"])
        XCTAssertNotNil(labelled.modified?["name"], "create already stamped name")

        let renamed = try await s.rename(id: "J1", to: "1987 Journal")
        XCTAssertEqual(renamed.modified?["voiceLabels"], voiceLabelsStamp,
                       "renaming must not touch voiceLabels' own stamp")
        let nameStampAfterRename = try XCTUnwrap(renamed.modified?["name"])
        XCTAssertGreaterThan(nameStampAfterRename, voiceLabelsStamp,
                             "sanity: the clock genuinely advanced")

        // Reaches disk, not just the in-memory return value.
        let reread = try await JournalStore(containerRoot: containerRoot).list()
        XCTAssertEqual(reread.first?.modified, renamed.modified)
    }

    /// The mirror direction: `setVoiceLabels` stamps `voiceLabels` only, leaving a prior
    /// `rename`'s `name` stamp untouched.
    func testSetVoiceLabelsStampsVoiceLabelsAndLeavesNameStampUntouched() async throws {
        let clock = AdvancingClock(start: Date(timeIntervalSince1970: 1_650_000_000))
        let s = store(ids: ["J1"], now: { clock.next() })
        _ = try await s.create(name: "Untitled")
        let renamed = try await s.rename(id: "J1", to: "1987 Journal")
        let nameStamp = try XCTUnwrap(renamed.modified?["name"])
        XCTAssertNil(renamed.modified?["voiceLabels"], "no labels set yet — no stamp for it")

        let labelled = try await s.setVoiceLabels(id: "J1", labels: ["bn": "Grandpa"])
        XCTAssertEqual(labelled.modified?["name"], nameStamp,
                       "setting labels must not touch name's own stamp")
        XCTAssertNotNil(labelled.modified?["voiceLabels"])
    }

    /// Byte-pin, the `Journal` counterpart to `EntryMetadata`'s: a journal nobody has
    /// touched through `create`/`rename`/`setVoiceLabels` (built directly, as every
    /// pre-M4 registry on disk was) carries no `modified` key at all — extends
    /// `testDefaultVoiceLabelsAreOmittedFromTheRegistryBytes`' exact pin.
    func testUntouchedJournalOmitsTheModifiedKeyFromTheRegistryBytes() throws {
        let registry = JournalRegistry(journals: [
            Journal(id: "A", name: "1987 Journal", createdAt: Date(timeIntervalSince1970: 0))
        ])
        let text = String(decoding: try JournalStore.encode(registry), as: UTF8.self)
        XCTAssertFalse(text.contains("modified"))
    }

    func testGarbageModifiedMapDecodesNilWithoutLosingIdentityFields() throws {
        let registry = try JournalStore.load(url: writeRegistry(
            #"{"journals":[{"id":"A","name":"N","createdAt":"1970-01-01T00:00:00.000Z","modified":"oops"}]}"#))
        XCTAssertEqual(registry.journals.first?.modified, nil)
        XCTAssertEqual(registry.journals.first?.id, "A")
    }

    /// A minimal stand-in for "a build that predates `modified`" — mirrors
    /// `EntryMetadataStoreTests.PreM4EntryMetadataShape`.
    private struct PreM4JournalShape: Decodable {
        var id: String
        var name: String
    }

    /// Forward-compat pin (M4 T1): a journal record a NEWER build wrote (carrying
    /// `modified`) must still decode on a build that has never heard of the field.
    func testJournalWithModifiedDecodesInAnOldShapedDecoderIgnoringIt() throws {
        let json = Data(
            #"{"id":"A","name":"N","modified":{"name":"2024-01-01T00:00:00.000Z"}}"#.utf8)
        let decoded = try CaptureCoding.decoder().decode(PreM4JournalShape.self, from: json)
        XCTAssertEqual(decoded.id, "A")
        XCTAssertEqual(decoded.name, "N")
    }

    func testModifiedMapRoundTripsThroughDisk() throws {
        let stamp = Date(timeIntervalSince1970: 1_650_000_000.5)
        let registry = JournalRegistry(journals: [
            Journal(id: "A", name: "N", createdAt: Date(timeIntervalSince1970: 0),
                   modified: ["name": stamp])
        ])
        let data = try JournalStore.encode(registry)
        let reloaded = try JournalStore.load(url: {
            try data.write(to: registryURL)
            return registryURL
        }())
        XCTAssertEqual(reloaded.journals.first?.modified, ["name": stamp])
    }
}
