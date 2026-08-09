import XCTest
@testable import Raconte

/// T6b: `TranscriptRevisionStore` — listing, create-once append, and the validated
/// (never-trusted) head cache.
final class TranscriptRevisionStoreTests: XCTestCase {

    private var containerRoot: URL!
    private var capturesRoot: URL { AppContainer.capturesRoot(containerRoot: containerRoot) }
    private let captureID = "01KYX77KK5QM15915EZBVXTQZ4"

    override func setUpWithError() throws {
        containerRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RaconteRevisionStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: containerRoot)
    }

    private var captureDirectory: URL {
        SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
    }

    private var transcriptDirectory: URL {
        SegmentLayout.transcriptDirectory(captureDirectory: captureDirectory)
    }

    private func store() -> TranscriptRevisionStore { TranscriptRevisionStore(capturesRoot: capturesRoot) }

    private func revision(_ id: String = "01ARZ3NDEKTSV4RRFFQ69G5FAV", text: String = "hello",
                          source: RevisionSource = .machineLive,
                          parentID: String? = nil) -> TranscriptRevision {
        TranscriptRevision(id: id, source: source,
                           createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                           spans: [TranscriptSpan(text: text, anchor: .none)],
                           parentID: parentID)
    }

    @discardableResult
    private func writeRawCanonical(_ n: Int, _ json: String) throws -> URL {
        try FileManager.default.createDirectory(at: transcriptDirectory, withIntermediateDirectories: true)
        let url = SegmentLayout.canonicalTranscriptURL(captureDirectory: captureDirectory, revision: n)
        try Data(json.utf8).write(to: url)
        return url
    }

    private func validJSON(for revision: TranscriptRevision) throws -> String {
        String(data: try CaptureCoding.encoder().encode(revision), encoding: .utf8)!
    }

    // MARK: - 3.3 Listing

    func testListingOnAbsentDirectoryIsAbsent() {
        XCTAssertEqual(TranscriptRevisionStore.listing(captureDirectory: captureDirectory), .absent)
    }

    func testListingWithOnlySidecarFilesIsPresentEmpty() throws {
        try FileManager.default.createDirectory(at: transcriptDirectory, withIntermediateDirectories: true)
        try Data().write(to: transcriptDirectory.appendingPathComponent("live.jsonl"))
        try Data().write(to: transcriptDirectory.appendingPathComponent("markers.jsonl"))
        try Data().write(to: transcriptDirectory.appendingPathComponent("head.json"))
        try Data().write(to: transcriptDirectory.appendingPathComponent("canonical-3.json.part"))
        XCTAssertEqual(TranscriptRevisionStore.listing(captureDirectory: captureDirectory),
                       .present(files: []))
    }

    func testListingFindsCanonicalFilesByNumber() throws {
        try writeRawCanonical(0, try validJSON(for: revision("R0")))
        try writeRawCanonical(7, try validJSON(for: revision("R7")))
        XCTAssertEqual(TranscriptRevisionStore.listing(captureDirectory: captureDirectory),
                       .present(files: [0, 7]))
    }

    func testListingOnUnreadableTranscriptDirectoryIsUnreadable() throws {
        // A plain file where transcript/ should be a directory: contentsOfDirectory
        // fails with something other than "no such file".
        try Data("not a directory".utf8).write(to: transcriptDirectory)
        guard case .unreadable = TranscriptRevisionStore.listing(captureDirectory: captureDirectory) else {
            return XCTFail("expected .unreadable when transcript/ exists but cannot be listed")
        }
    }

    /// Mutation check (A3): the do/catch in `listing` must be load-bearing. Simulating
    /// the mutation `(try? FileManager.default.contentsOfDirectory(atPath:)) ?? []` in
    /// place of the real do/catch collapses "unreadable" into "present, empty" — this
    /// test proves that collapse is observably different from the real behaviour, i.e.
    /// that mutation would fail `testListingOnUnreadableTranscriptDirectoryIsUnreadable`.
    func testMutationCheckUnreadableDoesNotCollapseToEmptyPresent() throws {
        try Data("not a directory".utf8).write(to: transcriptDirectory)
        let mutated = (try? FileManager.default.contentsOfDirectory(atPath: transcriptDirectory.path)) ?? []
        XCTAssertEqual(mutated, [], "the mutated form silently reports empty, not unreadable")
        XCTAssertNotEqual(TranscriptRevisionStore.listing(captureDirectory: captureDirectory),
                          .present(files: []),
                          "the real implementation must disagree with the mutated one here")
    }

    // MARK: - 3.4 Append

    func testFirstAppendCreatesTranscriptDirAndCanonicalZero() async throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: transcriptDirectory.path))
        let n = try await store().append(revision(), captureID: captureID)
        XCTAssertEqual(n, 0)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: transcriptDirectory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)

        let url = SegmentLayout.canonicalTranscriptURL(captureDirectory: captureDirectory, revision: 0)
        let data = try Data(contentsOf: url)
        let decoded = try CaptureCoding.decoder().decode(TranscriptRevision.self, from: data)
        XCTAssertEqual(decoded, revision())
    }

    func testSecondAppendLandsAtOne() async throws {
        let s = store()
        try await s.append(revision("R0"), captureID: captureID)
        let n = try await s.append(revision("R1"), captureID: captureID)
        XCTAssertEqual(n, 1)
    }

    func testAppendOntoPreSeededCanonicalThreeLandsAtFour() async throws {
        try writeRawCanonical(3, try validJSON(for: revision("R3")))
        let n = try await store().append(revision("R4"), captureID: captureID)
        XCTAssertEqual(n, 4)
    }

    /// A hand-planted collision: `beforeWrite` plants `canonical-<n>.json` at the slot
    /// the store already computed, forcing the real EEXIST path. The store must re-list
    /// and land at the next free number, and the planted file's bytes must survive
    /// byte-for-byte.
    func testCollisionDuringAppendRelistsAndLandsAtNextFreeNumber() async throws {
        let plantedRevision = revision("PLANTED")
        let plantedJSON = try validJSON(for: plantedRevision)

        let plantedDirectory = transcriptDirectory
        let plantedTargetURL = SegmentLayout.canonicalTranscriptURL(captureDirectory: captureDirectory,
                                                                    revision: 0)
        let n = try await store().append(revision("NEW"), captureID: captureID, beforeWrite: {
            try? FileManager.default.createDirectory(at: plantedDirectory, withIntermediateDirectories: true)
            try? Data(plantedJSON.utf8).write(to: plantedTargetURL)
        })

        XCTAssertEqual(n, 1, "the planted file occupies slot 0, so the retry must land at 1")

        let plantedURL = SegmentLayout.canonicalTranscriptURL(captureDirectory: captureDirectory, revision: 0)
        let plantedOnDisk = try Data(contentsOf: plantedURL)
        XCTAssertEqual(String(data: plantedOnDisk, encoding: .utf8), plantedJSON,
                       "the planted file must be byte-untouched by the losing create")

        let wonURL = SegmentLayout.canonicalTranscriptURL(captureDirectory: captureDirectory, revision: 1)
        let won = try CaptureCoding.decoder().decode(TranscriptRevision.self, from: try Data(contentsOf: wonURL))
        XCTAssertEqual(won.id, "NEW")
    }

    func testAppendOnTrashedCaptureThrowsAndCreatesNoTranscriptDir() async throws {
        var metadata = EntryMetadata.defaults
        metadata.trashedAt = Date()
        try EntryMetadataStore.write(metadata, url: SegmentLayout.entryMetadataURL(captureDirectory: captureDirectory))

        do {
            _ = try await store().append(revision(), captureID: captureID)
            XCTFail("expected .trashedCapture")
        } catch let error as TranscriptRevisionStoreError {
            XCTAssertEqual(error, .trashedCapture)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: transcriptDirectory.path),
                       "a refused append must not create transcript/")
    }

    func testAppendOnUnreadableTranscriptDirThrowsAndWritesNothing() async throws {
        try Data("not a directory".utf8).write(to: transcriptDirectory)
        do {
            _ = try await store().append(revision(), captureID: captureID)
            XCTFail("expected .transcriptDirUnreadable")
        } catch let error as TranscriptRevisionStoreError {
            guard case .transcriptDirUnreadable = error else {
                return XCTFail("expected .transcriptDirUnreadable, got \(error)")
            }
        }
        // transcript/ is still just the plain file it was — nothing new landed inside it
        // (it isn't even a directory, so contentsOfDirectory below would throw if we tried).
        let attrs = try FileManager.default.attributesOfItem(atPath: transcriptDirectory.path)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeRegular)
    }

    // MARK: - 3.5 Head + read-only

    func testValidatedHeadOnAbsentHeadRebuildsMatchingDirectory() async throws {
        try await store().append(revision("R0"), captureID: captureID)
        // Delete head.json so we exercise "absent head" specifically.
        try? FileManager.default.removeItem(at: SegmentLayout.transcriptHeadURL(captureDirectory: captureDirectory))

        let head = TranscriptRevisionStore.validatedHead(captureDirectory: captureDirectory)
        XCTAssertEqual(head?.current?.id, "R0")
        XCTAssertEqual(head?.revisionFiles, [0])
        XCTAssertEqual(head?.unreadableFiles, [])
        XCTAssertEqual(head?.revisionCount, 1)
    }

    func testValidatedHeadOnCorruptHeadJSONRebuilds() async throws {
        try await store().append(revision("R0"), captureID: captureID)
        try Data("{ not json".utf8).write(to: SegmentLayout.transcriptHeadURL(captureDirectory: captureDirectory))

        let head = TranscriptRevisionStore.validatedHead(captureDirectory: captureDirectory)
        XCTAssertEqual(head?.current?.id, "R0")
    }

    /// THE O(1) trust-path test (design §4.3, finding 1): once `head.json`'s
    /// `revisionFiles` matches the store's own (decode-free) listing, `validatedHead`
    /// must trust the cache outright — it must not open or decode any revision body.
    /// Proven by corrupting the bytes of a `canonical-<n>.json` *without* changing
    /// which filenames exist: if the store were still decoding bodies, this corrupted
    /// revision would show up in `unreadableFiles` and `current` would be lost. It does
    /// not — the persisted (pre-corruption) values come back unchanged.
    func testValidatedHeadTrustsPersistedHeadWithoutDecodingRevisionBodies() async throws {
        try await store().append(revision("R0"), captureID: captureID)
        try await store().append(revision("R1", parentID: "R0"), captureID: captureID)

        let persistedBeforeCorruption = TranscriptRevisionStore.validatedHead(captureDirectory: captureDirectory)
        XCTAssertEqual(persistedBeforeCorruption?.current?.id, "R1")
        XCTAssertEqual(persistedBeforeCorruption?.revisionFiles, [0, 1])
        XCTAssertEqual(persistedBeforeCorruption?.unreadableFiles, [])

        // Same filename, garbage bytes — the file SET the listing sees is unchanged.
        let currentRevisionURL = SegmentLayout.canonicalTranscriptURL(captureDirectory: captureDirectory,
                                                                      revision: 1)
        try Data("{ this is not a valid TranscriptRevision at all".utf8).write(to: currentRevisionURL)

        let head = TranscriptRevisionStore.validatedHead(captureDirectory: captureDirectory)
        XCTAssertEqual(head?.current?.id, "R1",
                       "trusted the cache — a decode of the corrupted body would have lost this")
        XCTAssertEqual(head?.unreadableFiles, [],
                       "a real decode of canonical-1.json would have added 1 here")
        XCTAssertEqual(head, persistedBeforeCorruption,
                       "the trust path must return exactly what was persisted, untouched")
    }

    /// Fixed point (F6): an undecodable `canonical-1.json` must show up in
    /// `unreadableFiles`, and a second `validatedHead` call must return byte-for-byte
    /// the same value with zero writes to disk.
    func testValidatedHeadFixedPointOverUndecodableRevision() async throws {
        try await store().append(revision("R0"), captureID: captureID)
        try writeRawCanonical(1, "{ not valid json at all")

        let first = TranscriptRevisionStore.validatedHead(captureDirectory: captureDirectory)
        XCTAssertEqual(first?.unreadableFiles, [1])
        XCTAssertEqual(first?.current?.id, "R0")

        let beforeSnapshot = try snapshotTree(transcriptDirectory)
        let second = TranscriptRevisionStore.validatedHead(captureDirectory: captureDirectory)
        let afterSnapshot = try snapshotTree(transcriptDirectory)

        XCTAssertEqual(first, second)
        XCTAssertEqual(beforeSnapshot, afterSnapshot, "validatedHead must write nothing")
    }

    func testLoadChainReportsUndecodableFileInUnreadableFiles() async throws {
        try await store().append(revision("R0"), captureID: captureID)
        try writeRawCanonical(1, "{ not valid json at all")

        let chain = TranscriptRevisionStore.loadChain(captureDirectory: captureDirectory)
        XCTAssertEqual(chain?.revisions.map(\.id), ["R0"])
        XCTAssertEqual(chain?.unreadableFiles, [1])
    }

    func testLoadChainOnAbsentDirectoryIsNil() {
        XCTAssertNil(TranscriptRevisionStore.loadChain(captureDirectory: captureDirectory))
    }

    // MARK: - 3.6 THE read-path test

    /// The single most important test in T6 (design §10): every static read — listing,
    /// loadChain, validatedHead — plus a full `LibraryScanner.scan` must leave the tree
    /// byte-identical and mtime-identical. Includes revisions, no head, and a stale
    /// draft.json, so every kind of file the read path might be tempted to "fix" is
    /// present.
    func testReadPathWritesNothingAcrossListingLoadChainValidatedHeadAndFullScan() async throws {
        try await store().append(revision("R0"), captureID: captureID)
        try await store().append(revision("R1", parentID: "R0"), captureID: captureID)
        // A stray draft with no writer touching it in this test.
        let draft = TranscriptDraft(captureID: captureID, parentID: "R1",
                                    openedAt: Date(timeIntervalSince1970: 1_700_000_100),
                                    lastWriteAt: Date(timeIntervalSince1970: 1_700_000_200),
                                    text: "in progress")
        try CaptureCoding.encoder().encode(draft)
            .write(to: SegmentLayout.transcriptDraftURL(captureDirectory: captureDirectory))
        // Delete head.json so validatedHead exercises the "absent, must rebuild" path too.
        try? FileManager.default.removeItem(at: SegmentLayout.transcriptHeadURL(captureDirectory: captureDirectory))

        let before = try snapshotTree(captureDirectory)

        _ = TranscriptRevisionStore.listing(captureDirectory: captureDirectory)
        _ = TranscriptRevisionStore.loadChain(captureDirectory: captureDirectory)
        _ = TranscriptRevisionStore.validatedHead(captureDirectory: captureDirectory)
        _ = await LibraryScanner(capturesRoot: capturesRoot, containerRoot: containerRoot).scan()

        let after = try snapshotTree(captureDirectory)
        XCTAssertEqual(before, after, "the read path must never write")
    }

    // MARK: - Helpers

    private struct FileSnapshot: Equatable {
        var relativePath: String
        var contents: Data
        var modificationDate: Date?
    }

    private func snapshotTree(_ root: URL) throws -> [FileSnapshot] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                             options: [], errorHandler: nil) else {
            return []
        }
        var snapshots: [FileSnapshot] = []
        for case let url as URL in enumerator {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            let attrs = try fm.attributesOfItem(atPath: url.path)
            snapshots.append(FileSnapshot(
                relativePath: url.path.replacingOccurrences(of: root.path, with: ""),
                contents: try Data(contentsOf: url),
                modificationDate: attrs[.modificationDate] as? Date))
        }
        return snapshots.sorted { $0.relativePath < $1.relativePath }
    }
}
