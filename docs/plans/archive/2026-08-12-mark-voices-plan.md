> **Archived — shipped (PR #57).** #56 closed. Follow-ups are open as #59 (undo) and #60 (visible structure).

# Mark Voices Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps
> use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the machine-shaped "Correct markers" screen with a WYSIWYG "Mark voices"
mode (tap a paragraph to flip its voice, drag across words to mark a sub-range), plus
per-journal voice display config (labels off by default, main voice italic).

**Architecture:** All marking operations compile down to two new append-only record
semantics on `markers.jsonl` — a frame-0 opening-voice add and a voice-carrying
word-anchored boundary add — planned by a pure `VoiceMarkingPlan`, executed by a
`VoiceMarkingModel` over the existing store seam, rendered by a new token-flow marking
view. Raw capture taps stay immutable; every write is an additive correction record.

**Tech Stack:** Swift 6 strict concurrency, SwiftUI (iOS 26 + macOS 26), XCTest.
Xcode project is GENERATED — after checkout or `project.yml` edit: `xcodegen generate`.

**Issue:** #56 (all owner rulings recorded there, 2026-08-12).

## Owner rulings (verbatim intent — the spec)

1. Natural unit is the **paragraph** (tap to flip), but exchanges sometimes switch at
   **sentence level** — sub-paragraph range marking is required.
2. **Default-voice model**: unmarked text is implicitly the main voice (BN). The user
   marks the parts in a secondary voice. Must generalize to tertiary voices later
   (voice ids are already opaque strings — no format change).
3. **Display, per journal**: default is **no labels** — main voice *italic*, alternative
   *regular* (matches his two-handwriting-styles paper convention). Labels (e.g. "BN",
   "LN") are **opt-in per journal**.
4. **Explicit mode**: reading view's touches never change anything. "Mark voices" is
   entered deliberately, shows a clear marking state, edits render live (WYSIWYG), Done
   exits. Replaces "Correct markers…" as the human-facing surface.
5. Must work with **mouse/trackpad on macOS** — owner tests there first.

## Global Constraints

- Swift 6 strict concurrency; the project builds for macOS and iOS from one target.
- TDD: every behavior lands RED first, with the failure message quoted in the task
  report. **Compile-error "red" is not acceptable evidence** — the test must fail as an
  assertion for the reason the step names.
- Every task includes at least one **mutation check** (revert/logic-flip the key line,
  watch the named test fail, restore). Mutation scripts must assert their pattern matched.
- Never copy store primitives — call the shared ones (standing branch rule).
- Fixture cardinality ≥ 2 wherever a rule is pinned (vacuous-fixture countermeasure).
- Frozen `TestClock` + two mints ⇒ random ULID order — advance the clock between mints.
- Commit per green step. Branch `feat/mark-voices` in worktree `/Users/nico/src/raconte-mv`
  (create with `git worktree add /Users/nico/src/raconte-mv -b feat/mark-voices main`);
  run `xcodegen generate` in the worktree before the first build.
- Test command (macOS, from the worktree):
  `xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' test CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO`
- Baseline before Task 1: run the full suite on the worktree's main base and record the
  count (expected 1124 green).
- Never pipe `xcodebuild` through `head`.

## Locked design decisions

**D1 — Voice-carrying boundary add.** `StructureMarker` already has optional `voice`
(encoded `encodeIfPresent`, decoded leniently) — no wire change. A
`.correctionBoundaryAdd` record **with** a voice folds to a synthesized `.voice` marker;
**without** a voice it folds to `.paragraph` exactly as today (existing device logs keep
their meaning). Synthesized adds keep the correction's own seq (retract-cancellable) and
are `isExact` (never snapped) — both behaviors already exist for paragraph adds.

**D2 — Opening voice from the correction path.** Capture writes a frame-0 `bn` `.voice`
marker when multi-voice is on (`CaptureCoordinator.markOpeningVoice`,
`CaptureCoordinator.swift:277`). The correction path gets the equivalent:
`addOpeningVoice` writes a voice-carrying `.correctionBoundaryAdd` at **frame 0**. The
planner ensures one exists before the first voice marking lands in an unmarked entry, so
"unmarked = main voice" becomes explicit on disk and §16.4's honest-nil read rule is
untouched — we never *guess* a voice at read time; the write made it true.

**D3 — Append-only planning; no correct/retract in the planner.** Markers landing at the
same attribution cut collapse into one breakpoint with **later seq winning** the voice
(`TranscriptAttribution.swift:405-409`). So "change this boundary's voice" is just
"append a voice add at the same anchor" — the planner emits only two command kinds:

```swift
enum Command: Equatable {
    case addOpeningVoice(voice: String)
    case addVoiceBoundary(spanIndex: Int, voice: String)
}
```

`MarkerCorrectionWriter.retract` / `.correctVoice` stay (format capabilities, tests keep
pinning them) but gain no new callers.

**D4 — Paragraph↔span mapping.** `TranscriptAttribution.Paragraph` gains
`var spanRange: Range<Int>? = nil`, populated only by the span path (the range is already
computed and discarded at `TranscriptAttribution.swift:142-149`). The committed-pieces
path leaves it nil; the marking mode always runs over spans.

**D5 — Tokens are spans.** One draggable token per `TranscriptSpan` (the same grain the
old word list used — `MarkerCorrectionModel.swift:60-68`); boundaries can only anchor at
span starts anyway. Non-placeable spans (typed insertions, `.none` anchors) render dimmed
and cannot be selection endpoints. In practice SpeechTranscriber emits per-word runs, so
tokens ≈ words.

**D6 — Central invariant (the property every planner test enforces):** apply a plan's
commands to a real log on disk, re-derive attribution through the production read path,
and **the paragraph TEXTS are unchanged while the paragraph VOICES equal the intent**.
Marking a sub-range splits the paragraph at the range edges (voice switch = paragraph
break — existing owner-decided rendering rule; the plan makes no attempt to hide it).

**D7 — Display config.** `Journal` gains `voiceLabels: [String: String]` (voice id →
label; empty = no labels, the default). Encoded only when non-empty (a default-config
journal serializes byte-identical to today — the byte-shape test
`JournalStoreTests.swift:177` is the tripwire). Italic rule: `voice == "bn"` stays the
main-voice rule, now living in one config-aware `VoiceDisplay` enum;
`TranscriptAttribution.displayName/isItalic` are deleted. This supersedes the 2026-08-08
always-on-label decision (owner re-ruled 2026-08-12, recorded on #56). **Accessibility:**
italic is invisible to VoiceOver, so attributed paragraphs carry the voice in their
accessibility label regardless of visual labels.

**D8 — The old surface.** `EntryDetailView`'s "Correct markers…" button, destination,
`MarkerCorrectionView`, `MarkerCorrectionModel`, `MarkerCorrectionModelTests`, and
`MarkerCorrectionUITests` are **deleted** in Task 6 (owner: the screen is unusable).
`MarkerCorrectionWriter`, `MarkerCorrections`, `MarkerLog*`, and their unit tests all
stay — they are the format and the fold, and the new feature is built on them.
Deliberately dropped capability (note in docs): retracting a mis-tap and adding a bare
paragraph break no longer have UI. Both can return inside the marking mode later.

**D9 — Voice constants.** Two voices in v1: main `StructureMarker.Voice.bigNico` ("bn"),
alternative `StructureMarker.Voice.littleNico` ("ln"). `other(_:)` maps between them.
Everything stores/compares opaque strings; only `VoiceDisplay` and the flip rule know
there are exactly two.

## File structure

Create:
- `Raconte/Library/VoiceDisplay.swift` — pure display mapping (label/italic, config-aware)
- `Raconte/Library/VoiceMarkingPlan.swift` — pure planner (operations → commands)
- `Raconte/Library/VoiceMarkingModel.swift` — @MainActor model + `VoiceMarkingStore` protocol
- `Raconte/Library/UI/VoiceMarkingView.swift` — mode screen, token flow, gestures
- `Raconte/Library/UI/TokenFlowLayout.swift` — wrapping `Layout` + pure hit-test helper
- `Raconte/Library/UI/JournalVoiceLabelsSheet.swift` — per-journal labels editor
- Tests: `VoiceDisplayTests.swift`, `VoiceMarkingPlanTests.swift`,
  `VoiceMarkingModelTests.swift`, `TokenSelectionTests.swift`,
  `RaconteUITests/VoiceMarkingUITests.swift`

Modify:
- `Raconte/Capture/MarkerCorrections.swift` — voice-carrying add folds to `.voice`
- `Raconte/Capture/MarkerCorrectionWriter.swift` — `addVoiceBoundary`, `addOpeningVoice`
- `Raconte/Library/TranscriptAttribution.swift` — `Paragraph.spanRange`; delete
  `displayName`/`isItalic`
- `Raconte/Library/EntryTranscript.swift` — internal `voiceMarkingLayout` (three-answer)
- `Raconte/Library/Journal.swift` — `voiceLabels` field + hand-written `encode(to:)`,
  `JournalRegistry.setVoiceLabels`
- `Raconte/Library/JournalStore.swift` — `setVoiceLabels`
- `Raconte/Library/LibraryScreenModel.swift` — `VoiceMarkingStore` conformance,
  `setJournalVoiceLabels`
- `Raconte/Library/UI/EntryDetailView.swift` — button swap, config-aware rendering, a11y
- `Raconte/Capture/UI/CaptureView.swift` (`JournalHeaderView`) — "Voice Labels…" menu item
- `Raconte/Capture/Debug/UITestSupport.swift` — marking-mode seed

Delete (Task 6): `Raconte/Library/UI/MarkerCorrectionView.swift`,
`Raconte/Library/MarkerCorrectionModel.swift`,
`RaconteTests/MarkerCorrectionModelTests.swift`,
`RaconteUITests/MarkerCorrectionUITests.swift`.

---

### Task 1: Voice-carrying boundary adds (record semantics + writer)

**Files:**
- Modify: `Raconte/Capture/MarkerCorrections.swift` (fold, ~line 49-88)
- Modify: `Raconte/Capture/MarkerCorrectionWriter.swift`
- Test: `RaconteTests/MarkerCorrectionsTests.swift` (extend)

**Interfaces:**
- Consumes: `StructureMarker` (`voice: String?` already on the wire, encoded
  `encodeIfPresent`, decoded leniently — `StructureMarker.swift:91-110`); existing fold
  in `MarkerCorrections.effectiveMarkers(_:) -> [EffectiveMarker]`.
- Produces (later tasks call these exactly):

```swift
// MarkerCorrectionWriter
@discardableResult
static func addVoiceBoundary(atSpanIndex spanIndex: Int, spans: [TranscriptSpan],
                             voice: String, captureDirectory: URL) throws -> Int64
static func addOpeningVoice(voice: String, captureDirectory: URL) throws
```

Both append a `StructureMarker(seq: 0, frame: <anchor>, kind: .correctionBoundaryAdd,
voice: voice)` via the existing `appendOne`; `addVoiceBoundary` reuses `addBoundary`'s
placeable-anchor rule verbatim (same `TranscriptAttribution.isPlaceableSpan` guard, same
`BoundaryAddError` cases); `addOpeningVoice` anchors at frame 0 with no span requirement.

Fold change in `effectiveMarkers`: where a `.correctionBoundaryAdd` currently synthesizes
`StructureMarker(seq: marker.seq, frame: marker.frame, kind: .paragraph)`
(`MarkerCorrections.swift:56-60`), a non-nil `marker.voice` now synthesizes
`kind: .voice, voice: marker.voice` instead. Everything else (retract-cancellable by the
correction's own seq, `isExact` membership) is unchanged and must be shown unchanged.

**Steps:**

- [ ] **RED:** in `MarkerCorrectionsTests`, add:
  - `testVoiceCarryingBoundaryAddSynthesizesAVoiceMarker` — fold a raw list containing
    `.correctionBoundaryAdd` with `voice: "ln"`; assert the effective marker has
    `kind == .voice`, `voice == "ln"`, the correction's seq, `isExact == true`.
  - `testVoicelessBoundaryAddStillSynthesizesAParagraphMarker` — the compat pin; a nil
    voice add folds exactly as before (kind `.paragraph`).
  - `testRetractCancelsAVoiceCarryingAddRegardlessOfAppendOrder` — mirror of the existing
    `:113` test with a voice on the add.
  Run; all three must fail as assertions (the first and third because the synthesized kind
  is `.paragraph`).
- [ ] **GREEN:** implement the fold branch. Run the three tests, then the whole
  `MarkerCorrectionsTests` file.
- [ ] **RED:** writer tests (same file, real temp capture dir, following `:180`'s shape):
  - `testAddVoiceBoundaryAppendsOneRecordCarryingTheVoiceAtTheSpansOwnStartFrame`
  - `testAddVoiceBoundaryRejectsANonPlaceableSpanAndWritesNothing` (assert `.absent`
    after, like `:202`)
  - `testAddOpeningVoiceAppendsAVoiceCarryingAddAtFrameZero`
  - `testAddOpeningVoiceOnAnEntryWithNoMarkerFileCreatesTheLog` (empty capture dir; one
    decodable record after)
- [ ] **GREEN:** implement both writer functions. Full file green.
- [ ] **Mutation check:** flip the fold branch condition (`voice != nil` → `voice == nil`);
  `testVoiceCarryingBoundaryAddSynthesizesAVoiceMarker` AND
  `testVoicelessBoundaryAddStillSynthesizesAParagraphMarker` must BOTH fail; restore.
- [ ] **End-to-end pin (RED then GREEN if needed):** in
  `TranscriptAttributionLoadTests`, `testVoiceCarryingAddEndToEndChangesTheRenderedVoice`
  — real disk: canonical revision + `addOpeningVoice("bn")` + `addVoiceBoundary(..,
  voice: "ln")` at a mid span; load via `EntryTranscript.load(... .compute)`; assert two
  paragraphs, voices `["bn", "ln"]`, texts rejoin to the original. Also assert the add is
  NOT snapped (abutting-runs fixture, mirroring `:492`).
- [ ] **Commit:** `feat(#56): voice-carrying boundary adds — fold + writer`

### Task 2: Per-journal voice labels + VoiceDisplay

**Files:**
- Modify: `Raconte/Library/Journal.swift`, `Raconte/Library/JournalStore.swift`,
  `Raconte/Library/LibraryScreenModel.swift`
- Create: `Raconte/Library/VoiceDisplay.swift`
- Modify: `Raconte/Library/TranscriptAttribution.swift` (delete `displayName`/`isItalic`),
  `Raconte/Library/UI/EntryDetailView.swift` (rendering + a11y)
- Test: `RaconteTests/JournalStoreTests.swift`, new `RaconteTests/VoiceDisplayTests.swift`,
  `RaconteTests/TranscriptAttributionTests.swift` (migrate `:550`/`:556`),
  `RaconteTests/EntryDetailViewTranscriptDisplayTests.swift`

**Interfaces (produces):**

```swift
// Journal.swift — additive field, house decoder rule (identity strict, additive lenient)
var voiceLabels: [String: String] = [:]
// decode: ((try? container.decodeIfPresent([String: String].self, forKey: .voiceLabels)) ?? nil) ?? [:]
// NEW hand-written encode(to:): id/name/createdAt always; voiceLabels ONLY when !isEmpty

// JournalRegistry — mirrors rename's shape (Journal.swift:90-99)
@discardableResult
mutating func setVoiceLabels(id: String, labels: [String: String]) throws -> Journal
// values whitespace-trimmed; empty-after-trim values dropped from the dict

// JournalStore — mirrors rename (JournalStore.swift:58-64): load → mutate → save
@discardableResult
func setVoiceLabels(id: String, labels: [String: String]) throws -> Journal

// LibraryScreenModel — mirrors setJournalCover (:291): store call, rescan, Bool result
func setJournalVoiceLabels(_ journalID: String, labels: [String: String]) async -> Bool

// VoiceDisplay.swift — the ONLY display mapping (replaces TranscriptAttribution's two)
enum VoiceDisplay {
    static let mainVoice = StructureMarker.Voice.bigNico
    static func other(_ voice: String) -> String   // bn<->ln (v1 flip rule lives here too)
    static func label(forVoice voice: String?, voiceLabels: [String: String]) -> String?
    // nil unless voice != nil AND voiceLabels[voice] is non-empty
    static func isItalic(voice: String?) -> Bool   // voice == mainVoice; nil is never italic
    static func accessibilityName(forVoice voice: String, voiceLabels: [String: String]) -> String
    // label if set, else voice.uppercased() — VoiceOver always hears the voice
}
```

`EntryDetailView.attributedParagraph` becomes
`attributedParagraph(_ paragraph:, voiceLabels: [String: String])`, called with
`item.journal?.voiceLabels ?? [:]` (unfiled/dangling → defaults): prefix label only when
`VoiceDisplay.label(...)` is non-nil; italic via `VoiceDisplay.isItalic`. The paragraph's
selectable `Text` gains, when `voice != nil`,
`.accessibilityLabel("\(VoiceDisplay.accessibilityName(...)): \(paragraph.text)")`.

**Steps:**

- [ ] **RED:** `JournalStoreTests` additions (mirror the `EntryMetadataStoreTests`
  additive-field quartet at `:308-338`):
  `testVoiceLabelsAbsentDecodesEmpty`, `testVoiceLabelsRoundTrip`,
  `testDefaultVoiceLabelsAreOmittedFromTheRegistryBytes` (extend the byte-shape test
  `:177` — a default journal's serialized bytes are UNCHANGED from today's),
  `testVoiceLabelsGarbageDecodesEmpty`, `testSetVoiceLabelsUnknownJournalThrows`,
  `testSetVoiceLabelsTrimsAndDropsEmptyValues`.
- [ ] **GREEN:** field + decoder line + hand-written `encode(to:)` + both mutators.
- [ ] **RED:** `VoiceDisplayTests`: `testLabelIsNilByDefault`,
  `testLabelReturnsTheConfiguredLabel`, `testEmptyOrWhitespaceLabelYieldsNil`,
  `testIsItalicIsTrueOnlyForTheMainVoice` (bn true; ln, "x-third", nil false),
  `testOtherFlipsBetweenTheTwoVoices`,
  `testAccessibilityNameFallsBackToUppercasedVoiceID`.
- [ ] **GREEN:** implement `VoiceDisplay`; delete
  `TranscriptAttribution.displayName`/`isItalic` and their two tests (`:550`, `:556`);
  rewrite `attributedParagraph` + call site; fix any test/UI-test asserting on `"BN: "`
  prefixes (search `RaconteTests` + `RaconteUITests` for `BN:`/`displayName`/`isItalic`).
- [ ] **Mutation check:** make `label(forVoice:)` return `voice.uppercased()`
  unconditionally; `testLabelIsNilByDefault` must fail. Make `encode(to:)` always encode
  `voiceLabels`; `testDefaultVoiceLabelsAreOmittedFromTheRegistryBytes` must fail. Restore.
- [ ] Full suite green. **Commit:** `feat(#56): per-journal voice labels, no-label default`

### Task 3: Attribution exposes span structure

**Files:**
- Modify: `Raconte/Library/TranscriptAttribution.swift`, `Raconte/Library/EntryTranscript.swift`
- Test: `RaconteTests/TranscriptAttributionTests.swift`,
  `RaconteTests/TranscriptAttributionLoadTests.swift`

**Interfaces (produces):**

```swift
// TranscriptAttribution.Paragraph gains (span path populates; pieces path leaves nil):
var spanRange: Range<Int>? = nil   // indices into the spans array this paragraph rendered

// EntryTranscript — internal, three answers, the marking mode's one read primitive.
// Composes the EXISTING internals (loadChain-current spans, live.jsonl consolidation for
// snap intervals, snappedMarkers, attribute(spans:snapped:)) — copy nothing.
enum VoiceMarkingLayout: Equatable {
    case unavailable                      // no readable canonical revision (degraded/unpromoted)
    case markersUnreadable(String)        // log exists but can't be read — refuse to mark
    case ready(spans: [TranscriptSpan],
               paragraphs: [TranscriptAttribution.Paragraph],
               hasAnyVoiceMarker: Bool)   // any effective .voice marker (incl. synthesized)
}
static func voiceMarkingLayout(captureDirectory: URL, sampleRate: Double) -> VoiceMarkingLayout
```

Key difference from the reading path: an **absent or empty** marker log still returns
`.ready` (attribution over spans with `snapped: []` → one nil-voice paragraph spanning
all spans) — the marking mode's whole point is entries with no markers yet.

**Steps:**

- [ ] **RED:** `TranscriptAttributionTests`:
  `testSpanPathPopulatesSpanRangesThatPartitionTheSpans` (multi-paragraph fixture:
  ranges are contiguous, non-overlapping, cover `0..<spans.count`),
  `testNoMarkersYieldsOneParagraphSpanningAllSpans` (spanRange `0..<n`),
  `testPiecesPathLeavesSpanRangeNil`.
- [ ] **GREEN:** thread the already-computed `groupStart..<index` range through
  `spanParagraph` (`TranscriptAttribution.swift:289-296`) into the memberwise inits.
  Empty-text paragraphs are filtered after assembly (`:152`) — the partition property is
  asserted over the SURVIVING paragraphs, so the test fixture must avoid empty-text spans
  (and one test pins that a filtered-out empty paragraph doesn't break contiguity of the
  ranges that remain: cardinality ≥ 2 fixtures).
- [ ] **RED:** `TranscriptAttributionLoadTests`:
  `testVoiceMarkingLayoutReadyOnAnEntryWithNoMarkerFile` (spans non-empty, one nil-voice
  paragraph, `hasAnyVoiceMarker == false`),
  `testVoiceMarkingLayoutUnreadableMarkerLogIsItsOwnAnswer` (chmod-0 log →
  `.markersUnreadable`, not `.ready`),
  `testVoiceMarkingLayoutUnavailableWithoutACanonicalRevision`,
  `testVoiceMarkingLayoutParagraphsMatchTheReadingPath` (same fixture through
  `EntryTranscript.load(.compute)` and `voiceMarkingLayout` — paragraph texts and voices
  identical; this is the WYSIWYG guarantee).
- [ ] **GREEN:** implement `voiceMarkingLayout`.
- [ ] **Mutation check:** hardcode `spanRange = nil` in `spanParagraph`;
  `testSpanPathPopulatesSpanRangesThatPartitionTheSpans` must fail. Restore.
- [ ] Full suite green. **Commit:** `feat(#56): Paragraph.spanRange + voiceMarkingLayout`

### Task 4: VoiceMarkingPlan (pure planner)

**Files:**
- Create: `Raconte/Library/VoiceMarkingPlan.swift`
- Test: `RaconteTests/VoiceMarkingPlanTests.swift`

**Interfaces:**
- Consumes: `TranscriptAttribution.Paragraph` (with `spanRange`), `[TranscriptSpan]`,
  `TranscriptAttribution.isPlaceableSpan`, `VoiceDisplay.mainVoice`/`.other`.
- Produces:

```swift
enum VoiceMarkingPlan {
    enum Command: Equatable {
        case addOpeningVoice(voice: String)
        case addVoiceBoundary(spanIndex: Int, voice: String)
    }
    enum PlanError: Error, Equatable { case notMarkable }

    static func flipParagraph(at index: Int,
                              paragraphs: [TranscriptAttribution.Paragraph],
                              spans: [TranscriptSpan],
                              hasAnyVoiceMarker: Bool) throws -> [Command]
    static func markRange(_ range: ClosedRange<Int>,   // span indices, placeable endpoints
                          to voice: String,
                          paragraphs: [TranscriptAttribution.Paragraph],
                          spans: [TranscriptSpan],
                          hasAnyVoiceMarker: Bool) throws -> [Command]
}
```

**Planner rules (normative):**

- `firstPlaceable(in:)` = lowest span index in a range with
  `TranscriptAttribution.isPlaceableSpan`. A flip target paragraph with none throws
  `.notMarkable`.
- **Opener rule:** if `hasAnyVoiceMarker == false` AND the operation's anchor span is not
  the first placeable span of the whole transcript, prepend
  `.addOpeningVoice(VoiceDisplay.mainVoice)`. (Anchoring AT the first placeable span
  already voices the leading text; an opener would collide at the same cut.)
- **flipParagraph(i):** `target = VoiceDisplay.other(paragraphs[i].voice ?? mainVoice)`.
  Emit `.addVoiceBoundary(firstPlaceable(paragraphs[i].spanRange), target)`. Then the
  **restore rule**: if a paragraph i+1 exists, emit
  `.addVoiceBoundary(firstPlaceable(walking forward from paragraphs[i+1]), v)` where
  `v = paragraphs[i+1].voice ?? mainVoice` (its pre-change voice) — UNLESS paragraph i+1
  is already opened by its own voice declaration (its `voice != paragraphs[i].voice`
  before the change, meaning a voice marker re-declares there; appending a duplicate
  restore is harmless but noisy — skip it). Walking forward: if paragraph i+1 has no
  placeable span, continue into i+2, etc.; if none exists to the end, emit no restore
  (the flip legitimately runs to the end of the entry).
- **markRange(r, target):** emit `.addVoiceBoundary(r.lowerBound, target)`. Restore: the
  first placeable span strictly AFTER `r.upperBound` gets
  `.addVoiceBoundary(thatSpan, v)` where `v` = the voice governing it pre-change (the
  voice of the paragraph containing it, `?? mainVoice`); if no placeable span follows,
  no restore. Endpoints are guaranteed placeable by the caller; throw `.notMarkable`
  otherwise.
- Later-seq-wins makes re-flipping and re-marking the same spot safe: a new add at an
  already-marked cut simply overrides it. No retract, no correct.

**Steps:**

- [ ] **RED (unit, command-shape):** table-driven tests, cardinality ≥ 2 per rule:
  `testFlipOfAnUnmarkedEntrysOnlyParagraphAnchorsAtItsFirstPlaceableSpanWithNoOpener`,
  `testFlipOfAMiddleParagraphInAnUnmarkedEntryEmitsOpenerFlipAndRestore`,
  `testFlipOfTheLastParagraphEmitsNoRestore`,
  `testFlipOfAMarkedParagraphEmitsNoOpener`,
  `testFlipSkipsTheRestoreWhenTheNextParagraphDeclaresItsOwnVoice`,
  `testFlipThrowsNotMarkableWhenTheParagraphHasNoPlaceableSpan`,
  `testMarkRangeMidParagraphEmitsSwitchAndRestoreAtTheFollowingSpan`,
  `testMarkRangeToTheEndOfTheEntryEmitsNoRestore`,
  `testRestoreWalksPastAParagraphWithNoPlaceableSpans`.
- [ ] **GREEN:** implement the planner.
- [ ] **RED (the D6 property — this is the task's core):**
  `testAppliedPlansPreserveParagraphTextsAndProduceTheIntendedVoices` — for each of ≥6
  disk fixtures (unmarked single-paragraph; unmarked multi-paragraph via ¶ adds; captured
  two-voice with raw taps; entry with leading non-placeable span; abutting exact-frame
  runs; already-corrected entry): plan an operation, execute its commands through the
  REAL `MarkerCorrectionWriter` against a real temp capture dir, re-derive via
  `EntryTranscript.voiceMarkingLayout`, assert `TranscriptText`-joined texts of the
  before/after paragraph lists are equal AND the voice of every span index matches the
  intent (target inside the flipped paragraph/range, pre-change voice outside). Marking
  a mid-paragraph range asserts the split: before-range text, range text, after-range
  text as separate paragraphs with voices `[prev, target, prev]`.
- [ ] **GREEN** (fix planner and/or Task 1 fold edges until the property holds).
- [ ] **Mutation check (named in this brief as INPUT to the implementer):** delete the
  restore-command emission from `flipParagraph`;
  `testAppliedPlansPreserveParagraphTextsAndProduceTheIntendedVoices` must fail on the
  multi-paragraph fixture (the following paragraph's voice flips too). Restore. Also
  swap the opener condition to `hasAnyVoiceMarker == true`; the opener test must fail.
- [ ] Full suite green. **Commit:** `feat(#56): VoiceMarkingPlan — flip + range planner`

### Task 5: VoiceMarkingModel + store seam

**Files:**
- Create: `Raconte/Library/VoiceMarkingModel.swift`
- Modify: `Raconte/Library/LibraryScreenModel.swift` (conformance; delete the old
  `MarkerCorrectionStore` conformance only in Task 6)
- Test: `RaconteTests/VoiceMarkingModelTests.swift`

**Interfaces:**

```swift
@MainActor
protocol VoiceMarkingStore: AnyObject {
    func voiceMarkingLayout(for captureID: String) async -> EntryTranscript.VoiceMarkingLayout
    @discardableResult
    func addVoiceBoundary(atSpanIndex: Int, voice: String, captureID: String) async throws -> Int64
    func addOpeningVoice(voice: String, captureID: String) async throws
}

@MainActor @Observable
final class VoiceMarkingModel {
    struct Token: Identifiable, Equatable {
        var id: Int              // span index — global across paragraphs
        var text: String
        var isPlaceable: Bool
    }
    struct ParagraphRow: Identifiable, Equatable {
        var id: Int              // paragraph index this load
        var voice: String?
        var tokens: [Token]
        var hasApproximateBoundary: Bool
    }
    enum State: Equatable { case loading, ready, nothingToMark, unreadable(String) }

    private(set) var state: State
    private(set) var rows: [ParagraphRow]
    private(set) var errorMessage: String?
    let captureID: String
    init(captureID: String, store: any VoiceMarkingStore)

    func open() async                      // load layout, build rows
    func flipParagraph(_ rowID: Int) async // plan → execute commands in order → open()
    func markRange(first: Int, last: Int, to voice: String) async
    func alternativeVoice(forRangeStartingAt tokenID: Int) -> String
    // the voice the confirmation button offers: VoiceDisplay.other(governing voice ?? main)
    func acknowledgeError()
}
```

`LibraryScreenModel` conformance mirrors the old one's shape
(`LibraryScreenModel.swift:235-286`): resolve the capture dir, `Task.detached`, call
`EntryTranscript.voiceMarkingLayout` (sample rate via the same manifest read
`transcript(for:)` uses, 48 kHz fallback) / `MarkerCorrectionWriter.addVoiceBoundary`
(re-reading spans from the chain, never trusting the caller — same rule as `:275-285`) /
`MarkerCorrectionWriter.addOpeningVoice`.

Error copy (house honest-copy rule): write failures set
`errorMessage = "That couldn't be saved. Try again."`; `.notMarkable` sets
`errorMessage = MarkerCorrectionWriter.boundaryAddRejectionMessage()`.

**Steps:**

- [ ] **RED:** with a `FakeVoiceMarkingStore` that (like the old fake,
  `MarkerCorrectionModelTests.swift:338`) holds real records and re-derives its layout
  from them on every call, so a second `open()` observes the fold:
  `testOpenBuildsParagraphRowsWithGlobalSpanIndexedTokens`,
  `testOpenMapsUnreadableAndUnavailableToTheirOwnStates`,
  `testFlipParagraphWritesThePlannedCommandsInOrderAndReloads` (voice visibly flipped in
  `rows` after),
  `testFlipOnAnUnmarkedEntryWritesOpenerThenBoundary` (order pinned),
  `testMarkRangeMarksAndRestores`,
  `testWriteFailureSurfacesTheErrorAndLeavesRowsUnchanged`,
  `testAlternativeVoiceOffersTheOtherOfTheGoverningVoice`.
- [ ] **GREEN:** implement model + conformance.
- [ ] **Mutation check:** reorder flip's command execution (restore before switch) — with
  the fake's re-derivation the visible voices still end correct (append-only!), so THIS
  mutation must be caught by the order-pinning assertion on the fake's write log, not by
  rendering; the brief requires `testFlipOnAnUnmarkedEntryWritesOpenerThenBoundary` to
  assert recorded call order explicitly. Run it, watch it fail, restore.
- [ ] Full suite green. **Commit:** `feat(#56): VoiceMarkingModel over VoiceMarkingStore`

### Task 6: Mark voices UI (mode screen, token flow, gestures) + old surface removal

**Files:**
- Create: `Raconte/Library/UI/VoiceMarkingView.swift`, `Raconte/Library/UI/TokenFlowLayout.swift`
- Modify: `Raconte/Library/UI/EntryDetailView.swift`,
  `Raconte/Capture/Debug/UITestSupport.swift`
- Delete: `Raconte/Library/UI/MarkerCorrectionView.swift`,
  `Raconte/Library/MarkerCorrectionModel.swift`,
  `RaconteTests/MarkerCorrectionModelTests.swift`,
  `RaconteUITests/MarkerCorrectionUITests.swift`
- Test: `RaconteTests/TokenSelectionTests.swift`, `RaconteUITests/VoiceMarkingUITests.swift`

**Interfaces:**

```swift
// TokenFlowLayout.swift
struct TokenFlowLayout: Layout { /* leading-aligned wrap; spacing 4pt h, 6pt v */ }

enum TokenSelection {   // pure — the gesture math, fully unit-tested
    static func tokenIndex(at point: CGPoint, frames: [(id: Int, rect: CGRect)]) -> Int?
    // hit = smallest id whose rect (expanded 3pt vertically) contains the point; nil if none
    static func selectedRange(anchor: Int, current: Int,
                              placeable: Set<Int>) -> ClosedRange<Int>?
    // min...max, then endpoints clamped INWARD to the nearest placeable id inside the
    // range; nil when the clamped range is empty or contains no placeable id
}
```

**View behavior (normative):**

- `VoiceMarkingView(model: VoiceMarkingModel, voiceLabels: [String: String])`, pushed via
  `navigationDestination` from the detail screen exactly like its siblings
  (`EntryDetailView.swift:86-136`), `.navigationTitle("Mark voices")`, with an
  always-visible header bar: tinted capsule, `Text("Marking voices — tap a paragraph to
  switch its voice, or drag across words")` + the system Back/Done navigation ending the
  mode (a11y id `voiceMarking.header`).
- `.ready`: a scrollable `VStack` of paragraph blocks. Each block: the same
  italic/label treatment as the reading view (via `VoiceDisplay` + `voiceLabels`), but
  each paragraph's text rendered as a `TokenFlowLayout` of `Text(token.text)` tokens
  (serif body font; non-placeable tokens `.foregroundStyle(.tertiary)`). Block a11y id:
  `voiceMarking.paragraph.<index>.<voice ?? "none">` (the UI test's observable).
- One `DragGesture(minimumDistance: 0)` per paragraph block in the block's coordinate
  space, token rects captured via `onGeometryChange` into the `frames` array:
  - drag ends where it began (start token == end token, or both nil):
    **tap → `model.flipParagraph(rowID)`**.
  - otherwise `TokenSelection.selectedRange` over the drag's anchor/current tokens;
    while dragging, tokens in the live range render with a selection background
    (`.tint.opacity(0.25)`); on end, a `.confirmationDialog` offers one action —
    `"Mark as \(VoiceDisplay.accessibilityName(forVoice: target, voiceLabels:))"` where
    `target = model.alternativeVoice(forRangeStartingAt: range.lowerBound)` — calling
    `model.markRange(first:last:to:)`; Cancel dismisses with no write.
  - a nil selection (no placeable token) shows no dialog.
- `.nothingToMark` / `.unreadable`: `ContentUnavailableView`s with honest copy —
  unreadable keeps the old screen's refusal rationale ("This entry's marker log could
  not be read (\(reason)), so voices can't be changed right now."), a11y ids
  `voiceMarking.empty` / `voiceMarking.unreadable`.
- Error alert: same `.alert("Couldn't save", ...)` shape as the old view.
- Detail screen: `Button("Mark voices…") { showingVoiceMarking = true }`
  (`detail.markVoicesButton`) replaces the correct-markers button and destination; the
  `onChange` close handler does the same `rescan()`/`refresh()` the old one did, so the
  reading view repaints with the new voices on exit.
- Works with mouse on macOS: `DragGesture` handles click (tap) and click-drag natively;
  no `#if os` needed in this view.

**Steps:**

- [ ] **RED:** `TokenSelectionTests`:
  `testTapHitTestFindsTheContainingTokenRect`, `testMissReturnsNil`,
  `testRangeIsOrderedRegardlessOfDragDirection`,
  `testEndpointsClampInwardToPlaceableTokens`,
  `testRangeWithNoPlaceableTokenIsNil`, `testVerticalSlopCatchesBetweenLineDrags`.
- [ ] **GREEN:** implement `TokenSelection` + `TokenFlowLayout` (layout itself needs no
  unit test — it's exercised by the UI test; keep it dumb).
- [ ] **Build the view + detail swap.** Delete the four old files, remove the old
  `MarkerCorrectionStore` protocol + `LibraryScreenModel` conformance (keep
  `MarkerCorrectionWriter`/`MarkerCorrections` and their tests), `xcodegen generate`,
  full unit suite green.
- [ ] **RED (UI):** repoint the seed: `UITestMarkerCorrectionSeed` →
  `UITestVoiceMarkingSeed` (env `RACONTE_UITEST_SEED_MARKER_ENTRY` kept so CI wiring is
  untouched; same 3-span shape, plus a second seeded entry with NO markers).
  `VoiceMarkingUITests.testTapFlipsAParagraphAndTheDetailViewShowsIt` — open entry →
  Mark voices → assert `voiceMarking.paragraph.0.bn` exists → press it → assert
  `voiceMarking.paragraph.0.ln` (and a restore paragraph if a second paragraph exists) →
  back → assert the detail paragraph's a11y label now begins "LN". Use the house
  `press(_:)` click/tap helper (`MarkerCorrectionUITests.swift:28-34` shape).
  `testMarkVoicesOnAnUnmarkedEntryOffersMarkingAndWrites` — the no-marker entry: flip
  its single paragraph, assert the flipped a11y id.
- [ ] **GREEN:** run UI tests on the iPhone simulator
  (`-scheme RaconteUI -destination 'platform=iOS Simulator,name=iPhone 17'`).
- [ ] **Commit:** `feat(#56): Mark voices mode; retire the Correct markers screen`

### Task 7: Journal voice-labels settings UI

**Files:**
- Create: `Raconte/Library/UI/JournalVoiceLabelsSheet.swift`
- Modify: `Raconte/Capture/UI/CaptureView.swift` (`JournalHeaderView` menu + sheet wiring,
  model wrapper `setCurrentJournalVoiceLabels`)
- Test: `RaconteTests/JournalCaptureContextTests.swift` (or the model's own suite) — the
  wrapper; sheet itself is closure-shaped and dumb.

**Interfaces:**

```swift
// Mirrors JournalCoverPickerSheet's closure shape (JournalCoverPickerSheet.swift:12-22)
struct JournalVoiceLabelsSheet: View {
    let journalName: String
    let currentLabels: [String: String]        // keys: "bn", "ln"
    let onSave: ([String: String]) async -> Bool
    // Two TextFields: "Main voice label (italic)" -> "bn", "Alternative voice label" -> "ln",
    // both prefilled, placeholder "No label"; footer: "Leave empty to distinguish voices
    // by style alone." Save trims; empty fields mean no label. Cancel discards.
}

// CaptureScreenModel — mirrors setCurrentJournalCover (CaptureView.swift:363)
func setCurrentJournalVoiceLabels(_ labels: [String: String]) async -> Bool
// store.setVoiceLabels + patch journals[index] in place (renameCurrentJournal's shape, :350)
```

Menu gains `Button("Voice Labels…") { showingVoiceLabels = true }` after "Cover Photo…"
(`CaptureView.swift:881-884`), sheet presented like the cover sheet (`:923-935`), a11y id
`capture.voiceLabelsMenuItem`.

**Steps:**

- [ ] **RED:** model-level test: `testSetCurrentJournalVoiceLabelsPersistsAndPatchesInPlace`
  (temp container, real `JournalStore`: labels visible via `journalStore.journal(id:)`
  AND in the model's `journals` array without a rescan);
  `testSetCurrentJournalVoiceLabelsFailureReturnsFalse` (unwritable registry).
- [ ] **GREEN:** wrapper + sheet + menu item. `xcodegen generate`, full suite green.
- [ ] **Manual check on macOS build:** sheet opens, saves, reading view of a two-voice
  entry in that journal shows the labels; clearing them returns to italic-only.
- [ ] **Commit:** `feat(#56): per-journal voice label settings UI`

### Task 8: Docs + final gate

**Files:**
- Modify: `docs/overview.md` (the editing story section), the T6 design doc gains a §17
  "Mark voices (as-built)" recording D1-D9, `CLAUDE.md` next-steps refresh.

**Steps:**

- [ ] Write §17: voice-carrying adds, opening-voice rule, append-only planning
  (later-seq-wins), display-config default flip and what it supersedes, D8's deliberately
  dropped capabilities (retract / bare ¶ add have no UI until marking mode grows them).
- [ ] **Gate (adversarial whole-branch review, Opus, house rules):** independently re-run
  the full suite; probe-confirm findings with throwaway tests before reporting; audit
  that fixtures exercise the non-degenerate path (the standing vacuous-fixture agenda
  item); specifically probe: (1) flip on an entry whose restore span is non-placeable,
  (2) marking while a transcript-edit draft is open (the writers don't touch the chain,
  so this should be safe — prove it), (3) a voice-carrying add on a pre-feature device
  log decoded by the OLD build (leniency means the voice is ignored and the add reads as
  a paragraph marker — acceptable-forward-compat, but verify nothing crashes), (4) the
  byte-shape of an untouched journals.json.
- [ ] Fix round(s) per gate findings; full suite green.
- [ ] **Commit + push branch; open PR** (auto-mode can't merge — end at an open PR),
  then build macOS app from the branch and hand the owner a smoke script.

## Self-review (done at plan time)

- Spec coverage: ruling 1 → Tasks 4/6 (flip + range); ruling 2 → D2/D3 opener rule +
  `hasAnyVoiceMarker` (Tasks 1/3/4); ruling 3 → D7 (Task 2) + settings UI (Task 7);
  ruling 4 → Task 6 (mode, WYSIWYG via voiceMarkingLayout parity test in Task 3);
  ruling 5 → DragGesture-only interaction + owner macOS smoke (Tasks 6/8).
- Placeholder scan: none — every step names its tests; code blocks given where a later
  task consumes the shape.
- Type consistency: `VoiceMarkingStore` methods (Task 5) match `MarkerCorrectionWriter`
  additions (Task 1) and `voiceMarkingLayout` (Task 3); `Token.id` = span index feeds
  `VoiceMarkingPlan.markRange(ClosedRange<Int>)`; `VoiceDisplay` (Task 2) is consumed by
  Tasks 4/6/7 under the same names.
