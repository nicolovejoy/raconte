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

    // MARK: - Corpus head stamping (T7 Task 3 fix round 2)

    /// **The sweep's whole point.** Every `head.json` on a real device today predates
    /// `fileSizes` and is therefore untrusted forever (fix round 1's own ruling) —
    /// `stampUnstampedHeads` is the ONLY thing that ever fixes that, since
    /// `persistHead`'s one other caller (`append`) never runs again once a chain
    /// exists. Fixture: a real, decodable revision with a hand-written UNSTAMPED head
    /// (everything correct — `current`/`revisionFiles`/`unreadableFiles` — except
    /// `fileSizes: []`, exactly what a pre-fix-round-1 head looks like). After the
    /// sweep: (1) the sweep must have written real sizes, not left the head as it
    /// found it, and (2) a SUBSEQUENT read must be served from that freshly-stamped
    /// cache, proven with the same distinguishing-marker technique used throughout
    /// this round — a marker planted into the sweep's own output survives a further
    /// read only if that read trusts the cache rather than re-decoding.
    func testStampUnstampedHeadsStampsAPreFixRoundOneHeadAndSubsequentReadsAreTrusted() async throws {
        let healthy = revision("R0", text: "healthy revision text")
        try writeRawCanonical(0, try validJSON(for: healthy))

        let summary = TranscriptRevisionStore.headSummary(for: healthy, fileNumber: 0, isForked: false)
        let unstamped = TranscriptHead(current: summary, revisionFiles: [0], unreadableFiles: [],
                                       revisionCount: 1, listingUnreadable: false)  // fileSizes: [] (default)
        try CaptureCoding.encoder().encode(unstamped)
            .write(to: SegmentLayout.transcriptHeadURL(captureDirectory: captureDirectory))

        await store().stampUnstampedHeads()

        let stampedData = try Data(contentsOf: SegmentLayout.transcriptHeadURL(captureDirectory: captureDirectory))
        var stamped = try CaptureCoding.decoder().decode(TranscriptHead.self, from: stampedData)
        XCTAssertFalse(stamped.fileSizes.isEmpty, "the sweep must stamp real sizes, not leave the head as found")
        XCTAssertEqual(stamped.current?.id, "R0")

        // Plant a marker no real decode of R0's body could produce, leaving the sizes
        // the sweep just wrote untouched.
        stamped.current?.snippet = "MARKER FROM CACHE, NEVER DECODED"
        try CaptureCoding.encoder().encode(stamped)
            .write(to: SegmentLayout.transcriptHeadURL(captureDirectory: captureDirectory))

        let read = TranscriptRevisionStore.validatedHead(captureDirectory: captureDirectory)
        XCTAssertEqual(read?.current?.snippet, "MARKER FROM CACHE, NEVER DECODED",
                       "a read after the sweep must be served from the cache the sweep just stamped")
    }

    /// **The sweep must be a no-op for an already-trustworthy head.** Rewriting
    /// `head.json` for every capture on every launch would be churn on the owner's
    /// real data and would defeat the point of caching at all. Proven via mtime, the
    /// same technique the read-path-writes-nothing tests use.
    func testStampUnstampedHeadsDoesNotRewriteAnAlreadyTrustworthyHead() async throws {
        try await store().append(revision("R0"), captureID: captureID)

        let before = try snapshotTree(transcriptDirectory)
        await store().stampUnstampedHeads()
        let after = try snapshotTree(transcriptDirectory)

        XCTAssertEqual(before, after, "the sweep must not rewrite an already-trustworthy head")
    }

    /// The sweep is thin plumbing over `persistHead`, so its guards apply here too —
    /// proven at the sweep's own entry point (not just `persistHead`'s, which is
    /// already covered above) so the delegation itself is what's pinned.
    func testStampUnstampedHeadsLeavesATrashedCaptureUntouched() async throws {
        try await store().append(revision("R0"), captureID: captureID)
        let headURL = SegmentLayout.transcriptHeadURL(captureDirectory: captureDirectory)
        let headBeforeTrash = try Data(contentsOf: headURL)

        var metadata = EntryMetadata.defaults
        metadata.trashedAt = Date()
        try EntryMetadataStore.write(metadata, url: SegmentLayout.entryMetadataURL(captureDirectory: captureDirectory))
        // Force the head untrusted so a bug that skipped the trash guard would have
        // something to stamp.
        var unstamped = try CaptureCoding.decoder().decode(TranscriptHead.self, from: headBeforeTrash)
        unstamped.fileSizes = []
        try CaptureCoding.encoder().encode(unstamped).write(to: headURL)

        await store().stampUnstampedHeads()

        let headAfterSweep = try Data(contentsOf: headURL)
        let afterHead = try CaptureCoding.decoder().decode(TranscriptHead.self, from: headAfterSweep)
        XCTAssertTrue(afterHead.fileSizes.isEmpty,
                     "the sweep must refuse to stamp a trashed capture's head, same as persistHead itself")
    }

    /// **Fix round 3 — the sweep must never stamp a capture that has no chain at
    /// all.** `transcript/` holding only `live.jsonl` (promotion skipped it —
    /// `.skippedNoAudio`/`.skippedNoLog`/`.failed`) is `listing() == .present([])`:
    /// SOME directory exists, but zero canonical files. Before the `!files.isEmpty`
    /// guard, `stampHeadIfNeeded` gated only on `.present`, so it wrote a `head.json`
    /// describing an empty chain here — a wasted write buying nothing, since
    /// `validatedHead` on `.present([])` is already O(1) via `rebuildHead` with no
    /// bodies to decode either way.
    func testStampUnstampedHeadsWritesNothingWhenTranscriptHoldsOnlyLiveLog() async throws {
        try FileManager.default.createDirectory(at: transcriptDirectory, withIntermediateDirectories: true)
        try Data("{\"seq\":0}\n".utf8).write(to: SegmentLayout.liveTranscriptURL(captureDirectory: captureDirectory))

        await store().stampUnstampedHeads()

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SegmentLayout.transcriptHeadURL(captureDirectory: captureDirectory).path),
            "no canonical files means no chain to stamp — the sweep must write nothing")
    }

    /// **The actual stake (fix round 3).** Writing `head.json` into an otherwise-empty
    /// `transcript/` would flip `DirectorySnapshot.holdsIrreplaceableArtifacts` from
    /// false to true — `transcriptPresent` reads "any file at all" under
    /// `transcript/`, which a stray `head.json` alone would satisfy — making a
    /// mis-tapped capture (nothing durable, `transcript/` created but never written
    /// into) permanently undeletable. Exactly the zero-byte-log hazard (rule 10)
    /// `MarkerLog`/`CaptureCoordinator` already guard against elsewhere. Checking the
    /// file's absence alone (the sibling test above) would not state this; asserting
    /// `holdsIrreplaceableArtifacts` directly does.
    func testStampUnstampedHeadsOnAnEmptyTranscriptDirectoryLeavesCaptureStillDeletable() async throws {
        try FileManager.default.createDirectory(at: transcriptDirectory, withIntermediateDirectories: true)

        let before = DirectorySnapshot.gather(capturesRoot: capturesRoot).captures.first
        XCTAssertEqual(before?.holdsIrreplaceableArtifacts, false, "sanity: an empty transcript/ starts deletable")

        await store().stampUnstampedHeads()

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SegmentLayout.transcriptHeadURL(captureDirectory: captureDirectory).path),
            "an empty transcript/ has no chain to stamp — the sweep must write nothing")
        let after = DirectorySnapshot.gather(capturesRoot: capturesRoot).captures.first
        XCTAssertEqual(after?.holdsIrreplaceableArtifacts, false,
                       "a mis-tapped capture must stay deletable — the sweep must never flip this")
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
    /// `revisionFiles`/`unreadableFiles`/`fileSizes` all match the store's own (cheap,
    /// decode-free) checks, `validatedHead` must trust the cache outright — it must not
    /// open or decode any revision body. Proven with a DISTINGUISHING MARKER (the same
    /// technique T7 Task 3 fix round 1's row-level tests use): the persisted
    /// `current.snippet` is overwritten to a value no decode of R1's real, UNCHANGED
    /// body could ever produce. `revisionFiles`/`unreadableFiles`/`fileSizes` are left
    /// exactly as `append` wrote them, so the trust condition still holds — if the
    /// store decoded anyway, the marker would be overwritten by the real "hello".
    ///
    /// (An earlier version of this test proved trust by corrupting `canonical-1.json`'s
    /// BYTES in place and showing the corruption went undetected — that was the exact
    /// defect fix round 1's size-integrity check closes, so a test celebrating it as
    /// "working as designed" was itself pinning a bug. See
    /// `testValidatedHeadDetectsInPlaceCorruptionViaSizeMismatch` below for that
    /// scenario's corrected form.)
    func testValidatedHeadTrustsPersistedHeadWithoutDecodingRevisionBodies() async throws {
        try await store().append(revision("R0"), captureID: captureID)
        try await store().append(revision("R1", parentID: "R0"), captureID: captureID)

        guard var persisted = TranscriptRevisionStore.validatedHead(captureDirectory: captureDirectory) else {
            return XCTFail("append must have persisted a head")
        }
        XCTAssertEqual(persisted.current?.id, "R1")

        persisted.current?.snippet = "MARKER FROM CACHE, NEVER DECODED"
        try CaptureCoding.encoder().encode(persisted)
            .write(to: SegmentLayout.transcriptHeadURL(captureDirectory: captureDirectory))

        let head = TranscriptRevisionStore.validatedHead(captureDirectory: captureDirectory)
        XCTAssertEqual(head?.current?.snippet, "MARKER FROM CACHE, NEVER DECODED",
                       "trusted the cache verbatim — a real decode of R1's body would have produced \"hello\" instead")
    }

    /// T7 Task 3 fix round 1, Important 1: in-place corruption of a canonical file's
    /// BYTES — same filename, so the file-number SET the listing sees never moves —
    /// must now invalidate trust, where the pre-fix design (see the superseded doc
    /// comment above) would have kept trusting the cache unconditionally. Same
    /// filename, different SIZE -> `sizesStillMatch` fails -> forced rebuild -> the
    /// damage is actually found, not silently masked.
    func testValidatedHeadDetectsInPlaceCorruptionViaSizeMismatch() async throws {
        try await store().append(revision("R0"), captureID: captureID)
        try await store().append(revision("R1", parentID: "R0"), captureID: captureID)

        let persistedBeforeCorruption = TranscriptRevisionStore.validatedHead(captureDirectory: captureDirectory)
        XCTAssertEqual(persistedBeforeCorruption?.current?.id, "R1")
        XCTAssertEqual(persistedBeforeCorruption?.unreadableFiles, [])

        // Same filename, garbage bytes of a different length — the file SET is
        // unchanged, but the size no longer matches what head.json recorded.
        let currentRevisionURL = SegmentLayout.canonicalTranscriptURL(captureDirectory: captureDirectory,
                                                                      revision: 1)
        try Data("{ this is not a valid TranscriptRevision at all".utf8).write(to: currentRevisionURL)

        let head = TranscriptRevisionStore.validatedHead(captureDirectory: captureDirectory)
        XCTAssertEqual(head?.current?.id, "R0", "R1 is now unreadable, so R0 is the tip of what's left")
        XCTAssertEqual(head?.unreadableFiles, [1], "the forced rebuild must actually decode and find the damage")
    }

    /// T7 Task 3 fix round 1, Important 1 — the ACCEPTED residual gap, pinned
    /// explicitly so it reads as deliberate rather than an oversight (owner ruling):
    /// corrupting a canonical file's bytes to garbage of the EXACT SAME LENGTH leaves
    /// `sizesStillMatch` satisfied, so the trust condition still holds and the damage
    /// is NOT caught. A content hash would catch this; a size-only fingerprint, by
    /// design and owner's explicit acceptance, does not.
    func testSameSizeCorruptionIsAnAcceptedGapNotCaughtByTheIntegrityCheck() async throws {
        try await store().append(revision("R0", text: "hello"), captureID: captureID)

        guard let before = TranscriptRevisionStore.validatedHead(captureDirectory: captureDirectory) else {
            return XCTFail("append must have persisted a head")
        }
        let url = SegmentLayout.canonicalTranscriptURL(captureDirectory: captureDirectory, revision: 0)
        let originalSize = try Data(contentsOf: url).count

        // Garbage of the EXACT same byte length.
        let sameSizeGarbage = Data(repeating: 0x2E /* "." */, count: originalSize)
        try sameSizeGarbage.write(to: url)

        let after = TranscriptRevisionStore.validatedHead(captureDirectory: captureDirectory)
        XCTAssertEqual(after, before,
                       "ACCEPTED GAP: same-size damage is invisible to this integrity check by design")
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

    /// Gate A finding N1: the C1 dedupe must not make the deduped file vanish from
    /// `revisionFiles` — it WAS seen by the listing, it just isn't part of the chain.
    /// Dropping it from `revisionFiles` means a persisted head can never again match
    /// the store's own listing (which always reports it), permanently defeating the
    /// O(1) trust path for this capture.
    ///
    /// The SECOND half (T7 Task 3 fix round 1, Important 1): corrupting the deduped
    /// file's bytes now DOES invalidate trust — file 1's SIZE no longer matches what
    /// `head.json` recorded, even though the file-number SET is unchanged. This is a
    /// correction, not a new finding: the pre-fix version of this test proved the
    /// corruption went undetected and called that "the trust path still engages,"
    /// which was the same masking defect fix round 1 closes generally, just for a
    /// deduped (non-current, non-chain) file instead of `current` itself.
    func testDedupedDuplicateFileStaysInRevisionFilesAndTrustPathDetectsLaterCorruption() async throws {
        let duplicate = revision("DUP")
        try writeRawCanonical(0, try validJSON(for: duplicate))
        try writeRawCanonical(1, try validJSON(for: duplicate))

        try await store().persistHead(captureID: captureID)

        guard var persisted = TranscriptRevisionStore.validatedHead(captureDirectory: captureDirectory) else {
            return XCTFail("persistHead must have written a head")
        }
        XCTAssertEqual(persisted.revisionFiles, [0, 1], "the deduped file WAS seen by the listing")
        XCTAssertEqual(persisted.unreadableFiles, [],
                       "a duplicate id is not an unreadable file — routing it there would trip I1")

        // Re-pin (fix round 2, property the rewrite above dropped): the trust path
        // must actually be ABLE to engage for a capture that has a deduped file, not
        // merely happen to return the right answer via a rebuild that would produce
        // the same content anyway. Proven with the same distinguishing-marker
        // technique as the non-deduped trust test above: plant a value in
        // `current.snippet` no fresh decode of "DUP"'s real body could produce,
        // leaving `revisionFiles`/`unreadableFiles`/`fileSizes` exactly as `persistHead`
        // wrote them (nothing on disk actually changed) — if the store still decoded
        // instead of trusting, the marker would be overwritten by the real snippet.
        persisted.current?.snippet = "MARKER FROM CACHE, NEVER DECODED"
        try CaptureCoding.encoder().encode(persisted)
            .write(to: SegmentLayout.transcriptHeadURL(captureDirectory: captureDirectory))

        let trusted = TranscriptRevisionStore.validatedHead(captureDirectory: captureDirectory)
        XCTAssertEqual(trusted?.current?.snippet, "MARKER FROM CACHE, NEVER DECODED",
                       "the trust path must be able to engage even for a capture with a deduped file")

        // Corrupt the DEDUPED file's bytes (file 1, dropped from the chain but not from
        // revisionFiles) with content of a DIFFERENT length — listing() still reports
        // {0,1} (the file SET is unchanged), but the size no longer matches.
        let dedupedURL = SegmentLayout.canonicalTranscriptURL(captureDirectory: captureDirectory, revision: 1)
        try Data("{ not valid json at all, corrupted after persisting".utf8).write(to: dedupedURL)

        let second = TranscriptRevisionStore.validatedHead(captureDirectory: captureDirectory)
        XCTAssertEqual(second?.current?.id, "DUP", "file 0 is untouched and still the current revision")
        XCTAssertEqual(second?.unreadableFiles, [1],
                       "the forced rebuild must actually decode file 1 and find the damage")
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
