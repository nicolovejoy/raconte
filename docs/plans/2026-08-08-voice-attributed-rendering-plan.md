# Voice-attributed transcript rendering (T6 §14 step 7, v1) — implementation plan

Written 2026-08-08 by an Opus planning agent from the code and design docs; executed
subagent-driven. Owner decisions baked in: (1) each span labeled with its voice, displayed
as the uppercased opaque id ("bn" → "BN"); (2) a paragraph break at every paragraph marker
AND every voice switch; (3) entries without markers render exactly as today; (4) markers
whose snap was `approximate` still split/attribute, rendered normally in v1 (T7 surfaces
approximateness).

## Global constraints

- Swift 6 strict concurrency; pure cores stay nonisolated, no actors, no clocks, no I/O.
- Raw marker frames are never mutated; snapping and attribution happen at read time.
- `.unreadable` marker log ≠ `.absent`: an unreadable log assigns NO voices — never render
  a failed read as "single voice".
- The library scanner must never read `markers.jsonl` — attribution is detail-screen only.
- No-marker entries must reproduce today's rendering byte-for-byte (`committedText`).
- TDD red-first per step; `xcodegen generate` after adding files.
- macOS test command: `xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' test`.
  iOS compile check needs `CODE_SIGNING_ALLOWED=NO`.

## What the planner found on the read path

**Transcript text today**
- `Raconte/Library/UI/EntryDetailView.swift:22` holds `@State private var transcript = EntryTranscript(...)`; `:94` fills it via `transcript = await model.transcript(for: captureID)`; `:234-266` is `transcriptSection`, and the whole rendering of prose is one `Text(text)` at `:250` (`.font(.system(.body, design: .serif))`). There is no paragraph handling at all today — the string is `committedText`, i.e. record texts joined with single spaces.
- `Raconte/Library/LibraryScreenModel.swift:360-372` — `nonisolated func transcript(for:) async`, runs `EntryTranscriptLoader.load` inside a `Task.detached`. `:376-381` `committedRecords(captureDirectory:)` decodes the manifest for `TranscriptRef.committedRecords` (this is the hook where the sample rate also comes from — `Manifest.format.sampleRate`, `AudioFormatDescriptor` at `Raconte/Capture/Models/SegmentSidecar.swift:6-21`).
- `Raconte/Library/EntryTranscript.swift:41-60` — `EntryTranscriptLoader.load` is the single implementation shared with `LibraryScanner.transcriptSummary` (`Raconte/Library/LibraryScanner.swift:188-191`). Line 58 is where `LiveTranscriptReader.consolidate(loaded.records).committedText` collapses everything to a `String` — **the consolidated `[TranscriptResult]` with frames is available there and discarded**. That is the seam.

**markers.jsonl on the read path: nowhere.** `MarkerLogReader.load(captureDirectory:)` (`Raconte/Capture/MarkerLog.swift`) has zero callers outside `MarkerLogWriter.open()` and tests. `MarkerSnapping` likewise has no production caller. Step 7 is the first read-path consumer of either.

**No display-name mapping exists.** Only `StructureMarker.Voice.littleNico = "ln"` / `.bigNico = "bn"` (`Raconte/Capture/StructureMarker.swift`, bottom). Display name = `voice.uppercased()`, and that belongs in the pure core so it is testable and unknown ids degrade gracefully.

**Useful invariant for splitting:** `SpeechAnalyzerEngine.runs(of:inputRate:)` (`Raconte/Transcription/SpeechAnalyzerEngine.swift:187-196`) builds each run's text as `String(text[run.range].characters)` of the same `AttributedString` whose flattened characters are `result.text`. So **run texts concatenate exactly to the record text**, with no separator. That is what makes an intra-record split lossless.

---

## Step 1 — `TranscriptAttribution`, the pure core (no UI, no I/O)

**Goal.** A pure enum, sibling in spirit to `MarkerSnapping`: committed results + snapped markers in, ordered attributed paragraphs out.

**Files to touch**
- new `Raconte/Library/TranscriptAttribution.swift`
- new `RaconteTests/TranscriptAttributionTests.swift`
- `xcodegen generate` after adding files (sources are directory globs; no `project.yml` edit).

**API (exact).**

```swift
enum TranscriptAttribution {
    struct Paragraph: Sendable, Equatable {
        var voice: String?              // nil = unattributed (no voice marker in force)
        var text: String
        var hasApproximateBoundary: Bool
    }
    static func attribute(committed: [TranscriptResult],
                          snapped: [MarkerSnapping.SnappedMarker]) -> [Paragraph]
    static func displayName(forVoice voice: String) -> String   // "bn" -> "BN"
}
```

One voice per paragraph, deliberately — owner requirement 2 makes **every** voice switch a paragraph break, so a `[Span]`-inside-`Paragraph` model would have exactly one span in every case it can produce. Record that rejection in the doc comment; T7 can widen it if editing ever decouples the two.

**Algorithm (spelled out; this is the whole step).**

1. **Pieces.** Walk `committed` in order (it is already sorted by `range.start`; sort defensively). Per record, mirror `MarkerSnapping.intervals(fromCommitted:)` exactly: if the record has ≥1 run and *every* run is timed, emit one piece per run `(start, end, text: run.text, recordIndex, isWholeRecord: false)`; otherwise emit one piece `(record.range.start, record.range.end, text: record.text, recordIndex, isWholeRecord: true)`. Any divergence from `MarkerSnapping`'s interval rule means a marker can snap to a boundary that doesn't exist in the piece stream.
2. **Markers.** Keep only `.voice` and `.paragraph` kinds (`.unknown` is preserved on disk and ignored here — design §4). Sort by `(snappedFrame, marker.seq)`.
3. **Cut position.** For each marker, find the piece index to cut before: the first piece whose `start >= snappedFrame`; if the frame lands strictly *inside* a piece (`start < f < end`), cut at the **nearer edge** of that piece (before it if `f - start < end - f`, else after it). Never split a run's text mid-word — frames give no character offset, and inventing one is worse than a one-word error. When a cut falls inside a piece, mark the resulting boundary paragraph `hasApproximateBoundary = true` *in addition to* the marker's own `approximate` flag.
4. **Voice in force.** Active voice = the voice of the most recent `.voice` marker at or before the cut (design §2 decision 4 — the frame-0 opener is what removes the special case for the beginning). Markers before the first piece set the voice without emitting an empty leading paragraph.
5. **Break rules.** A `.paragraph` marker always breaks. A `.voice` marker breaks **only when it changes the active voice** (a re-tap of the same voice, and the frame-0 opener, must not produce an empty paragraph).
6. **Text assembly — the exactness rule.** Group a paragraph's pieces by `recordIndex`. If a group contains *all* pieces of its record, use `record.text` verbatim; otherwise join that group's run texts with `""`. Join groups with `" "`. Then trim whitespace/newlines; drop paragraphs whose text is empty. This is what guarantees the no-marker case reproduces `TranscriptConsolidator.committedText` byte-for-byte (requirement 3) instead of "almost".
7. Totality: empty `committed` → `[]`. Empty `snapped` → one paragraph, `voice == nil`, text `== committedText`.

**Tests — write first, red before implementation.** Literal frame numbers on a 48 kHz axis, `MarkerSnappingTests` house style (helpers `result(_:runs:)`, `mark(_:kind:voice:)`; snapped markers built by hand as `MarkerSnapping.SnappedMarker(marker:snappedFrame:approximate:)` so the fixtures don't depend on the snapping rules).

- `testNoMarkersYieldsOneUnattributedParagraphEqualToCommittedText` — asserts equality against `LiveTranscriptReader.consolidate(...)`-style `committedText` join, i.e. the requirement-3 regression.
- `testParagraphMarkerOnlySplitsWithoutAnyVoiceLabel` — both paragraphs `voice == nil`.
- `testVoiceSwitchStartsANewParagraph` — bn opener at frame 0, ln marker mid-way: two paragraphs, voices `"bn"`, `"ln"`.
- `testOpeningVoiceMarkerAtFrameZeroDoesNotEmitAnEmptyParagraph`.
- `testRepeatedVoiceMarkerForTheSameVoiceDoesNotBreak`.
- `testMarkerInsideARecordSplitsBetweenWordRuns` — one record, four timed runs, marker frame on the gap between runs 2 and 3: two paragraphs whose texts concatenate back to the record text.
- `testMarkerInsideASingleRunCutsAtTheNearerEdge` — both halves (nearer-start and nearer-end), text never torn mid-word.
- `testRecordWithAnyUntimedRunIsNeverSplitInternally` — piece rule matches `MarkerSnapping.intervals`.
- `testApproximateMarkerStillSplitsAndAttributes` — requirement 4: the split happens; `hasApproximateBoundary` is set; nothing else changes.
- `testUnknownKindMarkersAreIgnoredForRendering`.
- `testMarkersAtIdenticalSnappedFramesProduceNoEmptyParagraphs`.
- `testMarkersOrderByFrameThenSeq` — deliberately hand a reversed input array.
- `testMarkersWithNoCommittedTranscriptYieldNoParagraphs` — design §7 ("no transcript ⇒ assign nothing").
- `testDisplayNameUppercasesTheOpaqueVoiceID` — `"bn" → "BN"`, `"ln" → "LN"`, `"x-third" → "X-THIRD"`.
- `testParagraphTextsRejoinToCommittedTextInEveryFixture` — one property-ish test over the fixtures above.

**Acceptance evidence.** Paste the red run of `-only-testing:RaconteTests/TranscriptAttributionTests` against stubs (`attribute` returning `[]`); paste green; paste full-suite green with the test count delta. Two mutation checks, each must fail its named test, reverted after: (a) make a same-voice re-tap break → `testRepeatedVoiceMarkerForTheSameVoiceDoesNotBreak`; (b) always join a paragraph's pieces with `" "` instead of the whole-record rule → `testNoMarkersYieldsOneUnattributedParagraphEqualToCommittedText`.

---

## Step 2 — Read-path wiring: markers → snap → attribution, off the main actor

**Goal.** `EntryTranscript` carries paragraphs for the detail screen, and **only** for the detail screen.

**Files to touch**
- `Raconte/Library/EntryTranscript.swift`
- `Raconte/Library/LibraryScreenModel.swift` (`:360-381`)
- new `RaconteTests/TranscriptAttributionLoadTests.swift` (disk fixtures; copy the setup style of `LibraryScreenModelTests.testTranscriptReturnsTheConsolidatedTextAndItsDegradations`, `LibraryScreenModelTests.swift:234-249`, plus `MarkerLogWriter` for markers)

**Design.**
- `EntryTranscript` gains `var paragraphs: [TranscriptAttribution.Paragraph]? = nil` appended **after** `degradations` so every existing `EntryTranscript(state:text:degradations:)` call site still compiles (`EntryDetailView.swift:22`, `EntryTranscript.swift:45/48/56`). `nil` means exactly one thing: *render as today*.
- `EntryTranscriptLoader.load` gains `attribution: AttributionMode = .skip`, where `enum AttributionMode: Sendable { case skip; case compute(sampleRate: Double) }`. `LibraryScanner.transcriptSummary` keeps the default and therefore pays **zero** extra file reads per row — do not let the scanner compute attribution.
- In the `.present` branch, keep the existing `consolidate` call but bind the consolidator once: `text` from `.committedText`, and for `.compute` also `MarkerLogReader.load(captureDirectory:)` → `MarkerSnapping.intervals(fromCommitted: consolidator.committed)` → `MarkerSnapping.snap(markers:intervals:windowFrames: MarkerSnapping.windowFrames(sampleRate:))` → `TranscriptAttribution.attribute`.
- Marker-source rules, non-negotiable (design §7): `.absent` → `paragraphs = nil`; `.unreadable` → `paragraphs = nil` (**never** infer single-voice from a failed read); `.present` with zero usable markers → `nil`; otherwise the computed array, or `nil` if it came back empty.
- `LibraryScreenModel`: replace `committedRecords(captureDirectory:)` with one manifest decode returning both `committedRecords` and `format.sampleRate`. When the manifest is missing or undecodable, fall back to `48_000` with a comment: the rate only scales the snap window, and a missing manifest already means a capture that never closed cleanly.

**Tests — write first.**
- `testDetailTranscriptAttributesVoicesFromTheMarkerLog` — write `live.jsonl` with two timed records and `markers.jsonl` with `{frame 0, voice bn}` + `{voice ln}`; assert paragraph voices and texts through `model.transcript(for:)`.
- `testEntryWithNoMarkerFileHasNilParagraphsAndUnchangedText` — the requirement-3 end-to-end guard.
- `testUnreadableMarkerLogAssignsNoVoices` — make `markers.jsonl` unreadable (chmod 000 on the file, matching the existing unreadable-log fixtures); assert `paragraphs == nil` and `text` still correct.
- `testParagraphOnlyMarkersProduceUnlabeledParagraphs`.
- `testMarkersWithoutATranscriptLeaveTheAbsentStateAlone`.
- `testLibraryScanDoesNotComputeAttribution` — `LibraryScanner`-produced `EntryTranscript.paragraphs == nil` even when a marker log exists (this is the performance contract, asserted).
- `testSampleRateComesFromTheManifest` — write a manifest at 16 kHz and assert the window used differs (easiest as a direct `EntryTranscriptLoader.load(..., attribution: .compute(sampleRate:))` call with a fixture where 48 k and 16 k windows disagree).

**Acceptance evidence.** Red output for the new file; green; full macOS suite green with the count delta; confirm `LibraryScannerTests`, `LibraryScreenModelTests`, `EntryDegradationTableTests` and `EntryListItemTests` are all still green untouched (they are the ones that construct/compare `EntryTranscript`).

---

## Step 3 — Detail-view rendering

**Goal.** Paragraphs with voice labels; every other state byte-identical to today.

**Files to touch**
- `Raconte/Library/UI/EntryDetailView.swift:234-266`
- optional: `RaconteUITests` sibling only if a UI test is cheap; otherwise skip UI tests this step.

**Design.**
- `.present` branch: if `transcript.paragraphs` is non-nil and non-empty, render `VStack(alignment: .leading, spacing: 16)` over `Array(paragraphs.enumerated())` keyed by `\.offset`. Per paragraph: optional label `Text(TranscriptAttribution.displayName(forVoice: voice))` in `.caption2.weight(.semibold)`, `.foregroundStyle(.secondary)`, `.tracking(0.5)`, above the prose; then `Text(paragraph.text).font(.system(.body, design: .serif)).textSelection(.enabled)`.
- Else fall through to the existing `Text(text)` path unchanged.
- Keep `.accessibilityIdentifier("detail.transcript.text")` on the container so any identifier a future UI test reaches for still resolves. Add `detail.transcript.paragraph.<i>` and `detail.transcript.voice.<i>`.
- **No `colorScheme` pinning** — that rule belongs to the capture screen's near-black background only (design §5). Semantic colors only, so both platforms and both appearances work.
- **Approximate markers: render normally.** No badge, no italics, no affordance. Requirement 4's decision, and the `hasApproximateBoundary` flag exists in the model so T7 can surface it without a re-derivation. Write that sentence into the view's doc comment so the next reader doesn't think it was forgotten.
- Typeface is *not* used to distinguish voices in v1 (design §10 floats print-vs-cursive as T7's call) — a text label is the cheap, legible, accessible version. Note it.

**Tests — write first.** SwiftUI body rendering isn't unit-testable here and the repo has no snapshot harness, so the red-first unit for this step is a small view-model function rather than the view: extract `EntryDetailView`'s decision into a pure `static func transcriptDisplay(_ transcript: EntryTranscript) -> TranscriptDisplay` (`.absent` / `.unreadable` / `.empty` / `.plain(String)` / `.attributed([Paragraph])`) in the same file or beside it, and test it:
- `testPlainWhenParagraphsAreNil`, `testPlainWhenParagraphsAreEmpty`, `testAttributedWhenParagraphsExist`, `testEmptyAndAbsentAndUnreadableStatesAreUnchanged`.
Then the view is a thin `switch` with no logic. This keeps the step honestly TDD-able.

**Acceptance evidence.** Red/green for the display-decision tests; full macOS suite green; a macOS **and** iOS-simulator build (`CODE_SIGNING_ALLOWED=NO` on iOS per CLAUDE.md).

---

## Step 4 — Docs

**Files:** `docs/plans/2026-08-05-capture-structure-markers-design.md` and `docs/plans/2026-08-05-structure-markers-implementation-plan.md`.

- Design §6: append a short "§6.1 Rendering" — the piece rule, the nearer-edge cut, "paragraph at every paragraph marker *and* every voice change", the whole-record text rule, and the v1 decision that `approximate` renders normally.
- Design §9 item 7: change "deferred to T7, not this build" to "v1 rendering shipped (`TranscriptAttribution` + detail view); editing/mis-tap correction and approximate-surfacing remain T7".
- Design §10: strike "±1.5 s is a guess" (now 0.75 s, tuned) and record that voice distinction shipped as an uppercase text label, typeface deferred.
- Implementation plan "Step 7 — deferred to T7 (recorded, not built)" (line ~1261): rewrite as "Step 7 — shipped" with the new API and what genuinely remains for T7.
- CLAUDE.md next-steps update belongs to the `/handoff` skill, not to an implementer step.

---

## Hazards

1. **Do not attribute in `LibraryScanner`.** It runs `EntryTranscriptLoader.load` per entry; adding a `markers.jsonl` read there is an extra file read per row on every rescan for data the list never shows. The `.skip` default is the guard, and step 2 asserts it.
2. **`markers.jsonl` decoding leniency.** `MarkerLogReader` already drops a torn trailing line and skips undecodable interior lines; `StructureMarker.init(from:)` is strict on `seq`/`frame`/`kind` and lenient on `voice`. Never add a required field. `.unknown` kinds are preserved on disk and ignored for rendering — ignoring is not dropping.
3. **`.unreadable` ≠ `.absent`.** The single sharpest rule here (design §7, the `journals.json` lesson): an unreadable marker log assigns *no* voices; it must never render as "single-voice, nothing to see".
4. **Markers with no transcript.** Real case (transcription never ran). `attribute` returns `[]`; the loader must turn that into `nil`, not an empty-paragraph list, or the detail view will show a blank transcript area instead of "This entry was not transcribed."
5. **Tail loss in the marker log is undetectable** (design §4). The last voice span will sometimes run long. Do not add a "possibly incomplete" note in v1 — there is no signal to base it on.
6. **Swift 6 concurrency.** `TranscriptAttribution.Paragraph` must be `Sendable, Equatable` because `EntryTranscript` is; the pure core stays `nonisolated`, no actor, no clock, `import Foundation` only. `EntryTranscriptLoader.load` stays synchronous and nonisolated — all the new work runs inside `LibraryScreenModel.transcript(for:)`'s existing `Task.detached`, so the main actor gains nothing.
7. **Sample rate is not on `TranscriptRef`** — it's `Manifest.format.sampleRate` (`Int`). One decode for both facts, documented 48 kHz fallback.
8. **The join contract.** `committedText` joins record texts with single spaces (`TranscriptConsolidator.join`). If the attribution assembly ever diverges (e.g. joining run texts with spaces), unmarked entries stop rendering as today and requirement 3 silently breaks — hence the whole-record rule and its dedicated test.
9. **Snapping already merges overlapping intervals**, but the piece list does not. A revised, overlapping record pair can produce overlapping pieces; ordering by `(start, recordIndex)` and cutting by piece index (not by frame comparison per piece) keeps that harmless.
10. `xcodegen generate` after adding files, and before any `xcodebuild` on a fresh checkout.
