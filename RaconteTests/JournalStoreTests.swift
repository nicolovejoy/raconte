import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
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

    /// M4 sync (for #70): `setSpan` must stamp `modified["span"]`, mirroring
    /// `setVoiceLabels`'s own stamp exactly — without it span can never take part in LWW at
    /// all, and every span edit silently loses every cross-device race.
    func testSetSpanStampsModifiedSpanAndLeavesNameStampUntouched() async throws {
        let clock = AdvancingClock(start: Date(timeIntervalSince1970: 1_650_000_000))
        let s = store(ids: ["J1"], now: { clock.next() })
        let created = try await s.create(name: "1998 Journal")
        let nameStamp = try XCTUnwrap(created.modified?["name"])
        XCTAssertNil(created.modified?["span"], "no span set yet — no stamp for it")

        let span = try JournalSpan(start: PartialDate(year: 1998), end: PartialDate(year: 2001))
        let stamped = try await s.setSpan(id: created.id, span: span)
        XCTAssertEqual(stamped.modified?["name"], nameStamp,
                       "setting the span must not touch name's own stamp")
        XCTAssertNotNil(stamped.modified?["span"])

        // Reaches disk, not just the in-memory return value.
        let reread = try await JournalStore(containerRoot: containerRoot).list()
        XCTAssertEqual(reread.first?.modified, stamped.modified)
    }

    /// The exact bug class the cover work hit on this branch: a CLEAR must also stamp, or
    /// the deletion loses every LWW race against a peer that has not yet heard about it.
    func testClearingASpanAlsoStampsModifiedSpan() async throws {
        let clock = AdvancingClock(start: Date(timeIntervalSince1970: 1_650_000_000))
        let s = store(ids: ["J1"], now: { clock.next() })
        let created = try await s.create(name: "1998 Journal")
        let span = try JournalSpan(start: PartialDate(year: 1998), end: nil)
        let withSpan = try await s.setSpan(id: created.id, span: span)
        let setStamp = try XCTUnwrap(withSpan.modified?["span"])

        let cleared = try await s.setSpan(id: created.id, span: nil)
        let clearStamp = try XCTUnwrap(cleared.modified?["span"],
                                       "clearing a span must stamp it too, or the deletion "
                                       + "cannot win a later LWW comparison")
        XCTAssertGreaterThan(clearStamp, setStamp, "sanity: the clock genuinely advanced")
        XCTAssertNil(cleared.span)
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
        // "span" alone is no longer a safe discriminator: clearing now stamps
        // `modified["span"]` (M4 sync, #70), which legitimately contains the substring
        // "span" as a STRING-valued key (`"span":"2026-..."`). The actual `Journal.span`
        // field, when present, is OBJECT-valued (`"span":{"start":...}`) — `"span":{` is
        // therefore still an honest test for "the span field itself is gone".
        XCTAssertFalse(String(decoding: try Data(contentsOf: registryURL), as: UTF8.self)
                        .contains(#""span":{"#),
                       "the span field itself must be gone, even though its modified stamp remains")
    }

    /// A tripwire, not a style check. `Journal.encode(to:)` enumerates fields by hand, so a
    /// field added to `Journal` is dropped on every write by default and no existing test
    /// notices. If this fails: carry the new field over in `encode(to:)` AND `init(from:)`,
    /// assert it round-trips above, then bump the count.
    ///
    /// The SYNC half of this enforcement lives on `m4/sync` (this branch, post-merge): six
    /// more sites enumerate journal fields (`SyncJournalField`, `journalRecord`,
    /// `RemoteJournal`'s property/init?/memberwise-init, `JournalMerge.merge`'s
    /// `resolve("span")`, `adopted(remote:)`) and are pinned separately by
    /// `SyncJournalRoundTripTests`.
    func testJournalFieldCountIsPinnedSoNewFieldsGetEncoded() {
        let journal = Journal(id: "J1", name: "N", createdAt: Date())
        XCTAssertEqual(Mirror(reflecting: journal).children.count, 6,
                       "Journal gained or lost a field — see Journal.encode(to:)")
    }

    // MARK: Delete (#80, v1: empty journals only — emptiness itself is enforced one
    // layer up, by `LibraryScreenModel.deleteJournal`; see `LibraryScreenModelTests`)

    func testDeleteJournalRemovesFromRegistryAndDiskBytes() async throws {
        let s = store(ids: ["J1", "J2"])
        _ = try await s.create(name: "Keep me")
        let toDelete = try await s.create(name: "Delete me")

        try await s.deleteJournal(id: toDelete.id)

        let remaining = try await s.list()
        XCTAssertEqual(remaining.map(\.id), ["J1"])
        let bytes = String(decoding: try Data(contentsOf: registryURL), as: UTF8.self)
        XCTAssertFalse(bytes.contains(toDelete.id),
                       "the deleted journal's id must not survive on disk")
    }

    func testDeleteJournalUnknownIDThrowsAndLeavesTheFileAlone() async throws {
        let s = store(ids: ["J1", "J2"])
        _ = try await s.create(name: "Keep me")
        _ = try await s.create(name: "Also keep me")
        let before = try Data(contentsOf: registryURL)

        do {
            try await s.deleteJournal(id: "missing")
            XCTFail("expected unknownJournal")
        } catch {
            XCTAssertEqual(error as? JournalError, .unknownJournal("missing"))
        }
        XCTAssertEqual(try Data(contentsOf: registryURL), before)
    }

    /// Every device always needs somewhere for capture to point — deleting the only
    /// journal left would leave nothing to file into and no UI for the resulting state.
    func testDeleteJournalRefusesTheLastRemainingJournalAndLeavesTheFileAlone() async throws {
        let s = store(ids: ["J1"])
        let only = try await s.create(name: "The only one")
        let before = try Data(contentsOf: registryURL)

        do {
            try await s.deleteJournal(id: only.id)
            XCTFail("expected lastRemainingJournal")
        } catch {
            XCTAssertEqual(error as? JournalError, .lastRemainingJournal(only.id))
        }
        XCTAssertEqual(try Data(contentsOf: registryURL), before)
    }

    /// The last-remaining guard must still let deletion through once a second journal
    /// exists — the count check has to discriminate, not just always refuse.
    func testDeleteJournalSucceedsOnceASecondJournalExists() async throws {
        let s = store(ids: ["J1", "J2"])
        _ = try await s.create(name: "First")
        let second = try await s.create(name: "Second")

        try await s.deleteJournal(id: second.id)

        let remaining = try await s.list()
        XCTAssertEqual(remaining.map(\.id), ["J1"])
    }

    func testDeleteJournalRemovesItsCoverDirectory() async throws {
        let s = store(ids: ["J1", "J2"])
        _ = try await s.create(name: "Keep me")
        let toDelete = try await s.create(name: "Delete me")
        let covers = JournalCoverStore(containerRoot: containerRoot, journalStore: s)
        try await covers.write(imageData: Self.makePNG(), journalID: toDelete.id)
        let coverDir = AppContainer.journalCoverURL(containerRoot: containerRoot, journalID: toDelete.id)
            .deletingLastPathComponent()
        let beforeDelete = await covers.read(journalID: toDelete.id)
        XCTAssertNotNil(beforeDelete, "fixture sanity: the cover really wrote")
        XCTAssertTrue(FileManager.default.fileExists(atPath: coverDir.path),
                     "fixture sanity: the cover directory really exists")

        try await s.deleteJournal(id: toDelete.id)

        let afterDelete = await covers.read(journalID: toDelete.id)
        XCTAssertNil(afterDelete)
        XCTAssertFalse(FileManager.default.fileExists(atPath: coverDir.path),
                      "the whole journals/<id>/ directory must be gone, not just cover.jpg")
    }

    func testDeleteJournalFiresTheSyncDeleteHook() async throws {
        let hooks = DeletionRecordingSyncHooks()
        let s = JournalStore(containerRoot: containerRoot, syncHooks: hooks)
        _ = try await s.create(name: "Keep me")
        let toDelete = try await s.create(name: "Delete me")
        await hooks.reset()

        try await s.deleteJournal(id: toDelete.id)

        let deletes = await hooks.deletedNames
        XCTAssertEqual(deletes, [.journal(id: toDelete.id)])
        let changes = await hooks.changedNames
        XCTAssertEqual(changes, [], "a delete is not also a change")
    }

    // MARK: applySyncDelete (#80, B2 — inbound deletion ingest)

    /// The no-echo rule (design §6, same reasoning as `applySyncMerge`): an INBOUND
    /// deletion must never look like a local edit, or two devices trading the same
    /// journal's delete would bounce it back and forth. `SyncIngest` is the only
    /// legitimate caller, and it has already run the not-empty-locally guard
    /// (`LibraryScreenModel.isJournalEmptyAfterRescan`) before ever reaching here — this
    /// method has no way to see entries at all, only `journals.json`.
    func testApplySyncDeleteFiresNoSyncHookAtAll() async throws {
        let hooks = DeletionRecordingSyncHooks()
        let s = JournalStore(containerRoot: containerRoot, syncHooks: hooks)
        let keep = try await s.create(name: "Keep me")
        let toDelete = try await s.create(name: "Delete me")
        await hooks.reset()

        try await s.applySyncDelete(id: toDelete.id)

        let deletes = await hooks.deletedNames
        let changes = await hooks.changedNames
        XCTAssertEqual(deletes, [], "an inbound delete must never announce itself as a local one")
        XCTAssertEqual(changes, [])
        let remaining = try await s.list()
        XCTAssertEqual(remaining.map(\.id), [keep.id], "the removal itself must still have happened")
    }

    func testApplySyncDeleteRemovesFromRegistryAndDiskBytes() async throws {
        let s = store(ids: ["J1", "J2"])
        _ = try await s.create(name: "Keep me")
        let toDelete = try await s.create(name: "Delete me")

        try await s.applySyncDelete(id: toDelete.id)

        let remaining = try await s.list()
        XCTAssertEqual(remaining.map(\.id), ["J1"])
        let bytes = String(decoding: try Data(contentsOf: registryURL), as: UTF8.self)
        XCTAssertFalse(bytes.contains(toDelete.id),
                       "the deleted journal's id must not survive on disk")
    }

    func testApplySyncDeleteRemovesItsCoverDirectory() async throws {
        let s = store(ids: ["J1", "J2"])
        _ = try await s.create(name: "Keep me")
        let toDelete = try await s.create(name: "Delete me")
        let covers = JournalCoverStore(containerRoot: containerRoot, journalStore: s)
        try await covers.write(imageData: Self.makePNG(), journalID: toDelete.id)
        let coverDir = AppContainer.journalCoverURL(containerRoot: containerRoot, journalID: toDelete.id)
            .deletingLastPathComponent()

        try await s.applySyncDelete(id: toDelete.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: coverDir.path),
                      "the whole journals/<id>/ directory must be gone, not just cover.jpg")
    }

    /// An unknown id is a no-op, the same as an inbound deletion arriving for a journal
    /// this device never heard of, or already deleted here too.
    func testApplySyncDeleteUnknownIDThrowsAndLeavesTheFileAlone() async throws {
        let s = store(ids: ["J1"])
        _ = try await s.create(name: "Keep me")
        let before = try Data(contentsOf: registryURL)

        do {
            try await s.applySyncDelete(id: "missing")
            XCTFail("expected unknownJournal")
        } catch {
            XCTAssertEqual(error as? JournalError, .unknownJournal("missing"))
        }
        XCTAssertEqual(try Data(contentsOf: registryURL), before)
    }

    /// Same UI-story guard as a local delete: refuse to leave a device with zero
    /// journals, even when the deletion is inbound.
    func testApplySyncDeleteRefusesTheLastRemainingJournalAndLeavesTheFileAlone() async throws {
        let s = store(ids: ["J1"])
        let only = try await s.create(name: "The only one")
        let before = try Data(contentsOf: registryURL)

        do {
            try await s.applySyncDelete(id: only.id)
            XCTFail("expected lastRemainingJournal")
        } catch {
            XCTAssertEqual(error as? JournalError, .lastRemainingJournal(only.id))
        }
        XCTAssertEqual(try Data(contentsOf: registryURL), before)
    }

    // MARK: Test helpers — pure CoreGraphics/ImageIO, no UIKit/AppKit (mirrors
    // JournalCoverStoreTests' own copy; this file needs only one trivial fixture image)

    private static func makePNG() -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
                                bytesPerRow: 0, space: colorSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let image = context.makeImage()!
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }
}

/// Records both verbs `SyncHooks` offers, so a delete test can assert it fired
/// `noteLocalDelete` and NOT `noteLocalChange` — unlike `RecordingSyncHooks`
/// (`SyncJournalIngestTests.swift`), which predates #80 and only records changes.
actor DeletionRecordingSyncHooks: SyncHooks {
    private(set) var changedNames: [SyncRecordName] = []
    private(set) var deletedNames: [SyncRecordName] = []

    func noteLocalChange(_ name: SyncRecordName) async {
        changedNames.append(name)
    }

    func noteLocalDelete(_ name: SyncRecordName) async {
        deletedNames.append(name)
    }

    func reset() {
        changedNames = []
        deletedNames = []
    }
}
