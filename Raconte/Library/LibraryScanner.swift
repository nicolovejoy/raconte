import Foundation

/// A capture directory the scan produced no row for, and why. Recorded rather than
/// dropped: a silent skip is how an entry disappears without anyone noticing.
struct SkippedCapture: Sendable, Equatable {
    enum Reason: Sendable, Equatable {
        /// No audio frames, no `.m4a` (or `.part`), and no `transcript/`. Nothing to
        /// show and nothing to lose — the same condition recovery answers with
        /// `.deleteCaptureDirectory`. A mis-tap, mid-flight capture setup, or a stray
        /// directory someone dropped into `captures/`.
        case noDurableContent
    }

    var captureID: String
    var reason: Reason
    /// The journal this capture's `entry.json` names, when it has one that decoded.
    /// Carried so a destructive caller can see it: a capture skipped for having no
    /// durable content YET is still filed somewhere, and `LibraryScreenModel
    /// .hasIndeterminateContent(forJournal:)` refuses to call that journal empty (gate
    /// finding, Important 3). `nil` covers both "unfiled" and "the sidecar did not
    /// decode" — neither names a journal to protect, and neither holds anything durable
    /// to orphan, which is why they read the same here.
    var journalID: String? = nil
}

struct LibraryScanResult: Sendable, Equatable {
    /// Filtered and sorted per the requested `EntryListFilter`.
    var items: [EntryListItem] = []
    var skipped: [SkippedCapture] = []
    /// `journals.json` exists and did not decode. Every `journalID` is then unresolved,
    /// which is a registry problem and not a per-entry one — without this flag the UI
    /// would show every filed entry as having a dangling journal.
    var journalsUnreadable: Bool = false
}

/// Builds the library's `[EntryListItem]` by walking `captures/`.
///
/// Reads disk directly rather than through an index, per the M3 plan: at dogfood scale
/// (tens to low hundreds of entries) the scan is what recovery already does at every
/// launch, and GRDB arrives with search as a rebuildable index *over* this, never as a
/// second source of truth.
///
/// **Isolation:** the type carries no mutable state and is not `@MainActor`, so `scan`
/// is a nonisolated `async` method and runs on the cooperative pool, never on the main
/// actor — the caller `await`s it from a view model. The stores it reuses
/// (`JournalStore`, `EntryMetadataStore`) expose sync static seams for exactly this: the
/// scan needs their formats, not their write serialization.
///
/// **Known cost:** every capture's `live.jsonl` is read and folded through
/// `TranscriptConsolidator` on every scan, because the log alone does not reproduce the
/// live view (issue #10) and the snippet must not show text the transcriber retracted.
/// That is O(records) per entry per scan. Acceptable at dogfood scale, and the first
/// thing to cache when it stops being — a canonical transcript (T6) removes the need.
struct LibraryScanner: Sendable {
    let capturesRoot: URL
    let containerRoot: URL

    init(capturesRoot: URL, containerRoot: URL? = nil) {
        self.capturesRoot = capturesRoot
        self.containerRoot = containerRoot ?? AppContainer.containerRoot(capturesRoot: capturesRoot)
    }

    /// Walk the tree and build the library. Never throws: a scan that fails wholesale is
    /// an empty library, and an empty library over a disk full of recordings is the
    /// worst possible answer. Every failure degrades to a flag on the row that owns it.
    func scan(filter: EntryListFilter = .default) async -> LibraryScanResult {
        Self.build(snapshot: DirectorySnapshot.gather(capturesRoot: capturesRoot),
                   journals: Self.loadRegistry(containerRoot: containerRoot),
                   filter: filter)
    }

    // MARK: - Registry

    /// `.some` registry, or `nil` when the file exists and could not be decoded. Absent
    /// is an empty registry, which is a fresh install (`JournalStore.load` already draws
    /// that line, and drawing it twice is how the two stop agreeing).
    static func loadRegistry(containerRoot: URL) -> JournalRegistry? {
        try? JournalStore.load(url: AppContainer.journalsURL(containerRoot: containerRoot))
    }

    // MARK: - Building

    /// Snapshot + registry → the library. Split out from `scan` so the whole mapping is
    /// exercisable from a synthesized snapshot, the way `RecoveryPlanner.plan` is.
    ///
    /// Still touches disk for the two per-capture files `DirectorySnapshot` deliberately
    /// does not parse: `entry.json` (not the capture machine's business) and
    /// `live.jsonl` (the gather stays a stat-level walk on purpose).
    static func build(snapshot: DirectorySnapshot,
                      journals: JournalRegistry?,
                      filter: EntryListFilter = .default) -> LibraryScanResult {
        var result = LibraryScanResult(journalsUnreadable: journals == nil)
        let registry = journals ?? JournalRegistry()
        var items: [EntryListItem] = []

        for capture in snapshot.captures {
            let (metadata, metadataDegradation) = Self.metadata(for: capture)
            // A tombstone outranks the durable-content gate (#25). An entry the owner deleted
            // must stay reachable in the Trash view — to restore or to delete now — whatever
            // state its files are in, including the half-destroyed directories a pre-staging
            // permanent delete could leave behind. An UNREADABLE sidecar is not a tombstone and
            // is not the absence of one: it falls through to the gate exactly as before, because
            // answering "trashed" or "live" from a read that failed is the one thing
            // `SidecarState`'s three answers exist to prevent.
            guard metadata.isTrashed || holdsSomethingToShow(capture) else {
                result.skipped.append(SkippedCapture(captureID: capture.captureID,
                                                    reason: .noDurableContent,
                                                    journalID: metadata.journalID))
                continue
            }
            items.append(item(for: capture, metadata: metadata,
                              metadataDegradation: metadataDegradation, registry: registry))
        }

        result.items = filter.apply(to: items)
        return result
    }

    /// Anything durable at all. Mirrors `holdsIrreplaceableArtifacts` plus raw frames:
    /// a capture recording *right now* has neither an `.m4a` nor a transcript, only
    /// segments, and must still appear. Also true whenever `manifest.final.verifiedAt`
    /// is set (image capture plan, design doc "Entry existence with no audio") — a
    /// blank entry minted by `BlankEntryMinter` is finalized from the instant it's
    /// written and has none of the above (no m4a, no transcript, no images yet, no raw
    /// segments), so without this it would read as `noDurableContent` and vanish from
    /// the library the moment it's created. The library scan reads `verifiedAt != nil`
    /// and nothing else about *why* it's set, per the design doc — same stance
    /// `FinalizeArtifactPush.isFinalized` and `RecoveryPlanner` already take.
    static func holdsSomethingToShow(_ capture: CaptureSnapshot) -> Bool {
        if capture.holdsIrreplaceableArtifacts { return true }
        if capture.manifest?.final.verifiedAt != nil { return true }
        return PlayableSourceSelector.frameTotal(of: PlayableSourceSelector.rawSegments(capture)) > 0
    }

    /// Reads `entry.json` alone, ahead of everything else `item(for:)` computes — split
    /// out so `build` can gate on trash state before deciding whether the capture even
    /// gets a row (#25). An unreadable sidecar shows the defaults *and says so* — it has
    /// not adopted them, and nothing may write those defaults back over the file.
    static func metadata(for capture: CaptureSnapshot) -> (EntryMetadata, EntryDegradation) {
        do {
            let metadata = try EntryMetadataStore.read(
                url: SegmentLayout.entryMetadataURL(captureDirectory: capture.directory))
            return (metadata, [])
        } catch {
            return (.defaults, [.metadataUnreadable])
        }
    }

    static func item(for capture: CaptureSnapshot, metadata: EntryMetadata,
                     metadataDegradation: EntryDegradation, registry: JournalRegistry) -> EntryListItem {
        var degradations: EntryDegradation = metadataDegradation
        if capture.manifestCorrupt {
            degradations.insert(.manifestCorrupt)
        } else if capture.manifest == nil {
            degradations.insert(.manifestAbsent)
        }

        let journal = metadata.journalID.flatMap(registry.journal(id:))
        if metadata.journalID != nil, journal == nil { degradations.insert(.journalUnresolved) }

        let transcript = transcriptSummary(capture)
        degradations.formUnion(transcript.degradations)

        return EntryListItem(
            captureID: capture.captureID,
            capturedAt: capturedAt(capture),
            durationSeconds: durationSeconds(capture),
            // Final-review I3: the row needs the m4a's PRESENCE, not just its duration —
            // a verified `.m4a` whose manifest carries no `durationFrames` reads as
            // `durationSeconds == 0` below but is perfectly playable. See
            // `EntryListItem.hasAudio`.
            finalM4APresent: capture.finalM4APresent,
            metadata: metadata,
            journal: journal,
            snippet: transcript.snippet,
            transcript: transcript.state,
            degradations: degradations,
            images: ImageStore.readSidecars(captureDirectory: capture.directory))
    }

    // MARK: - Per-capture facts

    /// The manifest's `createdAt`, else the ULID's millisecond prefix, else the epoch.
    /// Falls back through the ULID's own timestamp so a capture whose manifest went bad
    /// still shows the right date instead of vanishing from the sort.
    static func capturedAt(_ capture: CaptureSnapshot) -> Date {
        capture.manifest?.createdAt
            ?? ULID.timestamp(from: capture.captureID)
            ?? Date(timeIntervalSince1970: 0)
    }

    /// Frame math only — sidecar `frameCount`s (file size as fallback) for raw segments,
    /// `final.durationFrames` once the segments are gone. No audio file is opened: a
    /// library scan that decodes every recording is a library scan that stops being run.
    static func durationSeconds(_ capture: CaptureSnapshot) -> Double {
        let rate = Double(max(1, capture.format.sampleRate))
        let rawFrames = PlayableSourceSelector.frameTotal(
            of: PlayableSourceSelector.rawSegments(capture))
        if rawFrames > 0 { return Double(rawFrames) / rate }
        // Finalize deletes `segments/`, so after it the manifest is the only frame count
        // left. Reached for every finished entry, not just the odd one.
        if let frames = capture.manifest?.final.durationFrames, frames > 0 {
            return Double(frames) / rate
        }
        return 0
    }

    /// The row's view of the log — `EntryTranscriptLoader` is the one implementation,
    /// shared with the detail screen; the row takes the truncated snippet and the screen
    /// takes the full text, from the same read.
    static func transcriptSummary(_ capture: CaptureSnapshot) -> EntryTranscript {
        EntryTranscriptLoader.load(captureDirectory: capture.directory,
                                   expectedRecords: capture.manifest?.transcript?.committedRecords)
    }
}
