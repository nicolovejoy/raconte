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

    /// Gate A finding C2 (verified by the reviewer): once `TrashSweeper`/`StagedRemover`
    /// has renamed `captures/<id>/` away, the sidecar read returns `.defaults` (absent
    /// looks identical to "not trashed"), and `append`'s
    /// `createDirectory(withIntermediateDirectories: true)` would silently RECREATE the
    /// whole capture tree — resurrecting a deletion the owner already confirmed. `append`
    /// must refuse before any mkdir when `captures/<id>/` itself doesn't exist.
    func testAppendIntoVanishedCaptureDirectoryThrowsAndCreatesNothing() async throws {
        try FileManager.default.removeItem(at: captureDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: captureDirectory.path))

        do {
            _ = try await store().append(revision(), captureID: captureID)
            XCTFail("expected .captureMissing")
        } catch let error as TranscriptRevisionStoreError {
            XCTAssertEqual(error, .captureMissing)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: captureDirectory.path),
                       "append must not resurrect a vanished capture directory")
    }

    /// Gate A finding C1-trigger: a caller retrying a thrown `append` would rewrite the
    /// same revision id at a fresh `n+1`, landing exactly two files with the same id —
    /// C1. Forced here by making `head.json`'s own path an existing DIRECTORY: the
    /// revision write succeeds first (transcript/ is otherwise untouched), then
    /// `persistHead`'s `AtomicFile.replace` rename fails (EISDIR — a real, reproducible
    /// failure, no seam needed) while the caller is inside `append`. `append` must
    /// still return the allocated `n`, not throw.
    func testAppendSucceedsWhenHeadPersistenceFails() async throws {
        try FileManager.default.createDirectory(
            at: SegmentLayout.transcriptHeadURL(captureDirectory: captureDirectory),
            withIntermediateDirectories: true)

        let n = try await store().append(revision("R0"), captureID: captureID)
        XCTAssertEqual(n, 0, "the revision is durable even though head persistence failed")

        let revisionURL = SegmentLayout.canonicalTranscriptURL(captureDirectory: captureDirectory, revision: 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: revisionURL.path))

        // A later read still works, rebuilding in memory over the still-broken
        // head.json (listing() itself never even opens head.json).
        let head = TranscriptRevisionStore.validatedHead(captureDirectory: captureDirectory)
        XCTAssertEqual(head?.current?.id, "R0")
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

    // MARK: - Gate A finding I3: persistHead's own trash/missing guards

    /// §4.6: head rebuild is FIRST among the writer-side actions that must skip a
    /// trashed capture. `persistHead` had no such guard at all before this fix.
    func testPersistHeadOnTrashedCaptureIsANoOpAndDoesNotRewriteHead() async throws {
        try await store().append(revision("R0"), captureID: captureID)
        let headURL = SegmentLayout.transcriptHeadURL(captureDirectory: captureDirectory)
        let headBeforeTrash = try Data(contentsOf: headURL)

        var metadata = EntryMetadata.defaults
        metadata.trashedAt = Date()
        try EntryMetadataStore.write(metadata, url: SegmentLayout.entryMetadataURL(captureDirectory: captureDirectory))

        // Plant a second revision file directly (bypassing append's own trash guard)
        // so a naive persistHead would have something new to summarize if it ran.
        try writeRawCanonical(1, try validJSON(for: revision("R1", parentID: "R0")))

        try await store().persistHead(captureID: captureID)

        let headAfterTrash = try Data(contentsOf: headURL)
        XCTAssertEqual(headBeforeTrash, headAfterTrash,
                       "persistHead must refuse to touch head.json for a trashed capture")
    }

    /// Mirrors C2's lesson: `persistHead` must never resurrect a vanished capture
    /// directory. It must simply do nothing — no throw required, since callers
    /// (append) already guard the directory themselves before ever calling this.
    func testPersistHeadOnVanishedCaptureDirectoryIsANoOp() async throws {
        try FileManager.default.removeItem(at: captureDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: captureDirectory.path))

        try await store().persistHead(captureID: captureID)

        XCTAssertFalse(FileManager.default.fileExists(atPath: captureDirectory.path),
                       "persistHead must not create anything under a missing capture directory")
    }

    /// A capture with NO sidecar at all (mid-finalize, legitimate — not trashed, not
    /// missing) must stay fully persistable; sidecar-absent is not sidecar-trashed.
    func testPersistHeadWithNoSidecarAtAllStillPersists() async throws {
        try await store().append(revision("R0"), captureID: captureID)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SegmentLayout.entryMetadataURL(captureDirectory: captureDirectory).path))

        try? FileManager.default.removeItem(at: SegmentLayout.transcriptHeadURL(captureDirectory: captureDirectory))
        try await store().persistHead(captureID: captureID)

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: SegmentLayout.transcriptHeadURL(captureDirectory: captureDirectory).path),
            "a sidecar-absent capture is not a trashed one and must stay persistable")
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

    /// Gate A finding I1: a head persisted while `canonical-1.json` was undecodable
    /// must NOT be trusted once that file becomes readable again, even though its
    /// `revisionFiles` ([0,1]) still matches the directory listing — trusting it would
    /// keep serving the damaged-era `current`/`unreadableFiles` forever, masking the
    /// recovery. `unreadableFiles.isEmpty` is now part of the trust condition, so this
    /// case must fall back to a full rebuild and reflect the recovered revision.
    func testValidatedHeadRebuildsAndReflectsRecoveryWhenAPreviouslyUnreadableFileBecomesReadable() async throws {
        try await store().append(revision("R0"), captureID: captureID)
        try writeRawCanonical(1, "{ not valid json at all")
        // Persist a head that HONESTLY admits the damage — this is the state I1 guards.
        try await store().persistHead(captureID: captureID)

        let damaged = TranscriptRevisionStore.validatedHead(captureDirectory: captureDirectory)
        XCTAssertEqual(damaged?.unreadableFiles, [1])
        XCTAssertEqual(damaged?.current?.id, "R0")

        // The file recovers (e.g. a sync brought the real bytes) with no file-set
        // change at all — same file name, now valid content.
        try writeRawCanonical(1, try validJSON(for: revision("R1", parentID: "R0")))

        let recovered = TranscriptRevisionStore.validatedHead(captureDirectory: captureDirectory)
        XCTAssertEqual(recovered?.unreadableFiles, [],
                       "the recovered file must not still be reported as unreadable")
        XCTAssertEqual(recovered?.current?.id, "R1",
                       "a head that admitted damage must never be trusted — this must be a fresh rebuild")
    }

    /// F6, corrected to construct an actual fixed point (Gate A finding I2 — the prior
    /// version never persisted between calls, so both calls silently took the rebuild
    /// path regardless of any caching logic, proving nothing about repeated reads).
    /// Persisting between the two calls means the SECOND call is the one under real
    /// test: per I1, a head admitting `unreadableFiles` is never trusted, so this still
    /// takes the rebuild path — the fixed point this proves is narrower than "the O(1)
    /// path engages": it's that repeated in-memory rebuilds of the same damaged chain
    /// converge to an identical value with ZERO additional filesystem writes, which is
    /// what actually stops F6's rebuild-and-rewrite loop from returning.
    func testValidatedHeadRebuildConvergesToIdenticalValueWithZeroWritesAfterPersistingDamagedHead() async throws {
        try await store().append(revision("R0"), captureID: captureID)
        try writeRawCanonical(1, "{ not valid json at all")

        let first = TranscriptRevisionStore.validatedHead(captureDirectory: captureDirectory)
        XCTAssertEqual(first?.unreadableFiles, [1])
        XCTAssertEqual(first?.current?.id, "R0")

        // Construct the actual fixed point: persist the rebuilt head to disk. Its own
        // revisionFiles ([0,1]) now matches the directory listing again, but I1 means a
        // head that admits unreadableFiles is never trusted outright, so the SECOND
        // call below still rebuilds rather than taking the O(1) trust path.
        try await store().persistHead(captureID: captureID)

        let beforeSnapshot = try snapshotTree(transcriptDirectory)
        let second = TranscriptRevisionStore.validatedHead(captureDirectory: captureDirectory)
        let afterSnapshot = try snapshotTree(transcriptDirectory)

        XCTAssertEqual(first, second, "repeated rebuilds over the same damaged chain converge")
        XCTAssertEqual(beforeSnapshot, afterSnapshot, "validatedHead must write nothing, even on this rebuild path")
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

    /// Gate A finding C1: two `canonical-<n>.json` files sharing the same revision id
    /// (a sync duplicate, or a hand-corrupted tree) must never crash the read path —
    /// `Dictionary(uniqueKeysWithValues:)` over `id -> fileNumber` traps on a duplicate
    /// key. `validatedHead` must simply return, and `loadChain` must dedupe to one
    /// instance of the id, keeping the lowest file number.
    func testDuplicateRevisionIDAcrossFilesDoesNotCrashAndDedupes() throws {
        let duplicate = revision("DUP")
        try writeRawCanonical(0, try validJSON(for: duplicate))
        try writeRawCanonical(1, try validJSON(for: duplicate))

        let head = TranscriptRevisionStore.validatedHead(captureDirectory: captureDirectory)
        XCTAssertNotNil(head, "must not crash")
        XCTAssertEqual(head?.current?.id, "DUP")
        XCTAssertEqual(head?.current?.fileNumber, 0, "the lowest file number wins")

        let chain = TranscriptRevisionStore.loadChain(captureDirectory: captureDirectory)
        XCTAssertEqual(chain?.revisions.map(\.id), ["DUP"],
                       "duplicate id across files dedupes to exactly one revision instance")
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
