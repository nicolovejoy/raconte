> **Archived — SUPERSEDED, AND NOW FACTUALLY WRONG.** This was a one-time ground-truth snapshot taken when T6a-e was unbuilt. T6a-e shipped in PR #45; every type it calls missing now exists. Kept only to explain the implementation plan's citations — do not read it as a description of the code.

# Revision-chain build — code maps (2026-08-08)

Ground truth from three Explore passes over current `main` (`d0c18d2c`), gathered before
writing `2026-08-08-revision-chain-implementation-plan.md`. The T6 design doc
(`2026-08-03-t6-revision-chain-design.md`) predates the marker work and #25; its code
citations have drifted. **This file is the citation authority for the implementation plan.**

## Verdict: T6a–T6e are entirely unbuilt

All of the following are ABSENT from the codebase: `TranscriptRevision`, `TranscriptSpan`,
`TranscriptHead`, `TranscriptDraft`, `RevisionSource`, `SpanAnchor`, `DraftCloseReason`,
`TranscriptRevisionStore`, `AtomicFile.createExclusively` (no `O_EXCL`/`renamex_np`/
`RENAME_EXCL` anywhere in the repo), any promotion writer, `TranscriptText.join`,
any splice/draft code, `entry-log.jsonl`/`EntryLogRecord`, any merge/accept/decline/revert
machinery, `DirectorySnapshot.transcriptDirUnreadable`.

What exists are the forward-declared seams, landed ahead of the writer:
`SegmentLayout.canonicalTranscriptURL(revision:)` / `canonicalRevision(fromFileName:)`
(`SegmentLayout.swift:124/130`), `DirectorySnapshot.canonicalRevisions`
(`DirectorySnapshot.swift:33`, populated :206, consumed nowhere), and
`TranscriptRef.latestRevision` (`Manifest.swift:110`, sole write site
`LiveTranscription.swift:134` passes nil).

Recent "T6" commits are **T6 §14** (capture markers / voice-attributed rendering), not
§11's T6a–e.

Baseline: 771 unit tests + 9 UI tests (CLAUDE.md 2026-08-08), 62 test files, flat
`RaconteTests/`. CI: macos-26 / Xcode 26.6, macOS unit + iOS-sim UI with retry.

## Corrected citations (design doc → current main)

| Design doc says | Current main |
| --- | --- |
| `TranscriptConsolidator.swift:125-129` join | :127-129, and `private`. `committedText` :113. Extraction must change access. |
| `TranscriptLogReadResult` three-answer enum | No such symbol. It is `LiveTranscriptSource` (`LiveTranscriptStore.swift:20-28`) + `LiveTranscriptReader.LoadResult` (:210-222). `MarkerLogSource` (`MarkerLog.swift:20-27`) is a third hand copy of the same shape. |
| `CaptureView.swift:405-412` writer-race comment / `:414-415` promotion slot / `:448-463` recordTranscriptRef | :450-455 / **:456-457** (between `recordTranscriptRef` loop :456 and `detectSpokenDate` loop :457; `finishCurrentCapture` is :442) / :490-506 |
| `SegmentLayout.swift:116-133` canonical pair, `:123` `.json` check | :124-141, suffix check :131. `:116` is now `markerLogURL`. |
| §4.1 layout; §4.6 "nothing else writes into `transcript/` except `LiveTranscriptWriter`" | **Stale**: `transcript/markers.jsonl` exists (`markerLogFileName` :13, writer `MarkerLog.swift`). Second sanctioned writer; alone keeps `transcriptPresent` true. §4.6's rule must read "…except `LiveTranscriptWriter` and `MarkerLogWriter`". |
| Mirror tripwire "on `writeCapturedManifest`" | Production code has no `Mirror`. The tripwire is test-side: `RecoveryExecutorTests.swift:206` (`Mirror(reflecting: manifest).children.count == 16`). Pattern to copy, not a helper to reuse. `writeCapturedManifest` is `RecoveryExecutor.swift:114`. |
| `EntryMetadata` has five fields | **Six** — `multiVoice` (`EntryMetadata.swift:97`) landed with markers. T7's audit field list and tripwire count must include it. `setOriginalDate` :148. |
| `LibraryScreenModel.swift:74-78`, thirteen `rescan()` sites | Comment :77-82; **18** sites. |
| `EntryMetadataStore.swift:20-54 / 41-43 / 47-54 / 85-89` | :19-70 / :51-53 (instance `write`, bypass still open) / :57-70 (`update` funnel; `captureMissing` guard :60-65, new with #25) / :101-105 (static `write`, bypass still open) |
| `AtomicFile.swift:26-49` | :20-56 (open `O_WRONLY|O_CREAT|O_TRUNC` :27, POSIX `rename` :46). `writeAll` is `private`. |
| `Manifest.swift:109` latestRevision; `LiveTranscription.swift:135` | :110; :134 |
| `DirectorySnapshot` `:203` listing collapse, `:207-215`, `:72` | :203 ✅ (`(try? contentsOfDirectory) ?? []` — the exact two-answer collapse §4.5a names), :207-216, :71-73. Adding `transcriptDirUnreadable` requires restructuring :203 to `do/catch` (the `try?` discards the error). |

## Design-level findings (not just line drift)

1. **B1 recurs on the launch-recovery path.** `CaptureView.swift:215-220` runs
   `runFinalizer(recoveredQueue)` → `detectSpokenDate` → `rescan()` with **no
   `recordTranscriptRef`** — a recovered capture reaches promotion with
   `manifest.transcript == nil`, so `coverageFrames`/`skippedRanges` cannot be copied.
   The plan handles this honestly (nil provenance, documented) rather than fabricating.
2. **`deleteEntryPermanently`** (`LibraryScreenModel.swift:325-336`) is a second,
   user-driven stage path (inline stage+purge) the design's §4.6 race analysis doesn't
   mention. Same `trashedAt` skip protects it.
3. Three-answer enum now exists in **three** hand copies; the store adds a fourth
   (`TranscriptChainListing`, different payload). Decision recorded in the plan: keep it a
   deliberate copy — the payloads differ (`present(files: [Int])` vs `present(Data)`), and
   genericizing enums over payloads buys nothing but indirection.

## Seams the build will consume (verified signatures)

- `LiveTranscriptReader.load(captureDirectory:) -> LoadResult` (`LiveTranscriptStore.swift:238`);
  `consolidate(_:) -> TranscriptConsolidator` (:287-293); `completeness(lines:expected:)` (:271).
  Writer throw-on-unreadable precedent :83-91; torn-tail newline fuse :116-118.
- `TranscriptConsolidator.committed: [TranscriptResult]` (:18, ordered by `range.start`);
  `committedText` (:113); `displayText` (:121); private `join` (:127-129).
- `TranscriptResult` (`TranscriptionEngine.swift:15`): `text`, `range: FrameRange`,
  `isVolatile`, `confidence: Double?`, `finalizedThroughFrame: Int64?`,
  `runs: [TranscriptRun]`, `analyzerStart/End: CMTime?`.
- `TranscriptRun` (`TranscriptRecord.swift:39`): `text`, `captureFrameStart/End: Int64?`,
  `confidence: Double?`. `TranscriptRecord` (:61): strict decode on seq/text/frames/
  generator/locale, lenient on stamps/runs (:127).
- `AtomicFile.replace(at:writing:beforeRename:)` (`AtomicFile.swift:20-56`);
  `AtomicFileError.posix(operation:code:)` (:3).
- `SegmentLayout`: `transcriptDirectory` :103, `liveTranscriptURL` :109, `markerLogURL`
  :116, `canonicalTranscriptURL` :124, `canonicalRevision(fromFileName:)` :130 (`.json`
  suffix :131, leading-zero rejection :139), `partURL(for:)` :157, `entryMetadataURL` :79,
  `manifestURL` :68, `captureDirectory(capturesRoot:captureID:)` :64.
  `CaptureCoding.encoder()` :200 (pretty, sortedKeys) / `lineEncoder()` :215 / `decoder()` :221.
- `DirectorySnapshot`/`CaptureSnapshot`: `canonicalRevisions` :33, `transcriptPresent` :27
  (= "any file at all", comment :207-215), `holdsIrreplaceableArtifacts` :71-73,
  `manifestCorrupt` :15, `gather` :136, `gatherCapture` transcript block :202-216.
- `LibraryScanner`: `scan(filter:)` :58-62 (nonisolated, stateless);
  `build(snapshot:journals:filter:)` :81-108 with the #25 trash gate :97;
  `metadata(for:)` :122-130; `item(for:...)` :132-156;
  `transcriptSummary(_:)` :188-191 (→ `EntryTranscriptLoader.load` with `.skip`);
  `holdsSomethingToShow` :113-116. Overlap warning `LibraryScreenModel.swift:77-82`.
- `EntryTranscriptLoader.load(captureDirectory:expectedRecords:attribution:) -> EntryTranscript`
  (`EntryTranscript.swift:68-99`) — reads `live.jsonl` unconditionally today; three answers
  preserved (`.absent`/:73, `.unreadable`/:76, `.present`/:78). `AttributionMode` :41-47.
  Attribution pipeline :101-121 (MarkerLogReader → MarkerSnapping → TranscriptAttribution).
- `TranscriptAttribution.Paragraph` (`TranscriptAttribution.swift:12-23`):
  `(voice: String?, text: String, hasApproximateBoundary: Bool)` — **no frames, no offsets**.
  `attribute(committed:snapped:)` :43-85; no-marker case reproduces `committedText`
  byte-for-byte (:203 exactness rule).
- `EntryDetailView.transcriptDisplay(_:) -> TranscriptDisplay` (`EntryDetailView.swift:246-261`,
  pure, tested); `TranscriptDisplay` :234-240; transcriptSection :276-319;
  `attributedParagraph` :326-338 (Text concatenation). `refresh()` :92-99 is the reload funnel.
- `LibraryScreenModel`: `item(_:)` :209-213 (items → allEntries → trashed);
  mutation contract = `entryMetadataStore.update` + `rescan()` + `Bool` return
  (`moveEntry` :222, `setBackdate` :239, `trashEntry` :285, `restoreEntry` :300,
  `deleteEntryPermanently` :325, `sweepTrash` :340-347);
  `transcript(for:)` :364-375 (detached; `manifestFacts` :390-397, 48 kHz fallback :394);
  `lastMultiVoice(forJournal:)` :179.
- `CaptureScreenModel.finishCurrentCapture()` (`CaptureView.swift:442-459`):
  finalize :449 → race comment :450-455 → `recordTranscriptRef` loop :456 →
  `detectSpokenDate` loop :457 → `rescan` :458 → respawn :459.
  Launch path :215-220 (no recordTranscriptRef). `recordTranscriptRef(for:)` :490-506;
  `detectSpokenDate(for:)` :471-489.
- `TrashSweeper.run()` (`TrashSweeper.swift:31-44`, detached `.utility`);
  `apply` stage call :89; `StagedRemover.stage(captureID:) -> String`
  (`StagedRemoval.swift:39-62`, `rename` :58); `sidecarState` :66-74 (sanctioned static seam).
  `LibraryScreenModel.sweepTrash()` :340-347 (once per launch, after first scan).
- `EntryMetadataStore` (actor :30): `update` :57-70 (guard :60-65, read :66, mutate :67,
  write :68); bypasses :51-53 and :101-105.
- `ULID.make(now:)` (`ULID.swift:14-21`), lexicographically time-sortable (:3-5);
  `timestamp(from:)` :29; `isWellFormed` :42.
- Playback (for T7 tap-to-play, unchanged since design): `CapturePlayback.seek(to: TimeInterval)`
  :162-175 (seconds only); `SegmentPlayer.seek(toFrame: Int)` :99; `PlaybackSeek.frame(forSeconds:
  sampleRate:) -> Int` :41 / `seconds(forFrame:sampleRate:)` :48 — `Int` vs `Int64` width
  mismatch still unresolved, by design to be fixed in `PlaybackSeek` once.
- Editor context: **no `TextEditor` exists anywhere** (only two `TextField`s,
  `CaptureView.swift:868/874`). Detail screen is NOT dark-pinned; capture screen is.
- Decoder/three-answer exemplars to copy: `MarkerLog.swift` and `LiveTranscriptStore.swift`
  (hand-written decoders, unknown-enum leniency, `O_APPEND` + newline fuse).
- Test-side patterns to copy: `RecoveryExecutorTests.swift:206` (Mirror count tripwire),
  `EntryDegradationTableTests.swift` (+ `EntryDegradation.allDeclared`,
  `EntryListItem.swift:51-54`).
