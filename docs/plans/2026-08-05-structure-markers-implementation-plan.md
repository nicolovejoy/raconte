# Capture-time structure markers — implementation plan (T6 §14)

**Status: UNVERIFIED — pending local run.** Written 2026-08-05 on a machine that cannot
build (no Xcode). Every signature and line number below was checked against the code maps
(`2026-08-05-structure-markers-code-maps.md`, captured at commit `1f2a44b5`) and
spot-checked against source, but **no command in this document has been executed**. The
first machine with Xcode must treat every step's red/green run as the actual verification.

Design of record: `2026-08-05-capture-structure-markers-design.md`. This plan implements
its §9 steps 1–6; step 7 (T7 renders the voice attribute) is deferred to T7 by design.
Nothing here revisits an owner decision — where the design was silent, the plan-level
calls are listed in §0.3 so they are visible rather than smuggled.

## 0. Conventions for every step

### 0.1 Build/test commands

The Xcode project is generated. **After adding or moving any file, and once after clone:**

```
xcodegen generate
```

Full unit suite (the green gate for every step):

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' test
```

Focused run (for red-first evidence — substitute the step's test class):

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' test -only-testing:RaconteTests/<TestClass>
```

UI tests (step 5 only; simulator only — macOS needs interactive automation permission):

```
xcodebuild -project Raconte.xcodeproj -scheme RaconteUI -destination 'platform=iOS Simulator,name=iPhone 17' test
```

(Check `xcrun simctl list devices` if the iPhone 17 name differs.)

### 0.2 House rules that bite here (from the design appendix + maps)

- **XCTest only** — no Swift Testing. `final class XxxTests: XCTestCase`, files flat in
  `RaconteTests/`.
- **Red first or mutation-verified.** Each step names which tests must be seen failing
  before the implementation lands, or the exact mutation that must make them fail.
  Subagent prompts require the pasted failing output.
- **JSONL uses `CaptureCoding.lineEncoder()`**, never the shared `.prettyPrinted`
  `encoder()` (`SegmentLayout.swift:202-211`).
- **Hand-written `init(from:)`** for any persisted struct: identity fields strict,
  additive fields lenient. Synthesized decoding ignores property defaults.
- **Lazy log open** — never create `transcript/` before the first append
  (`holdsIrreplaceableArtifacts` treats any file there as irreplaceable; a zero-byte log
  makes a mis-tap's directory permanently undeletable).
- **`O_APPEND` torn-tail handling** — terminate a torn tail before the first new record,
  in-process and across reopens, or both records are lost.
- **Concurrency primitive** is `NSLock` + `@unchecked Sendable` (`LevelBox` is the
  canonical example, `CaptureCoordinator.swift:757-764`). No package deps exist; do not
  add swift-atomics.
- **Capture-screen controls pin `.environment(\.colorScheme, .dark)`** (the two existing
  sites are `CaptureView.swift:866,882`).
- Subagent builds: **leave changes uncommitted** — the parent session reviews the diff,
  then commits. Report red-run and green-run output verbatim.

### 0.3 Plan-level decisions (the design was silent; recorded here, not hidden)

1. **`FrameClockSink` uses `NSLock`, not an atomic.** The design says "atomic `Int64`";
   there is no atomics dependency and the house pattern is `NSLock` (map 1 §7). The
   requirement — `currentFrame` readable from any thread, one cheap addition per chunk on
   the tap thread — is met identically.
2. **The coordinator constructs its own `FrameClockSink`** per capture; it is not
   injected. It is pure counting with nothing to fake. Consequence: the UI-test harness
   *does* get a frame clock (the `SyntheticRecorder` feeds real chunks), so the step-5 UI
   test can drive markers end-to-end. Design §7's "no frame clock installed → markers
   disabled outright" is enforced as a guard in the marker entry points
   (`currentFrameClock != nil`), so any path where the clock is absent — mis-sequenced
   calls, a phase where wiring is torn down — disables markers rather than writing
   frame-0 garbage.
3. **Open-failure latches, append-failure does not.** A failed `MarkerLogWriter.open()`
   sets a `markerLoggingBroken` latch (mirrors `TranscriptionSession.loggingBroken`); a
   failed `append` sets `lastError` and leaves the writer open — its torn-tail machinery
   keeps the file safe and the next tap retries.
4. **Haptic fires on successful append** (trigger = published `markerCount`), not on raw
   tap. The haptic is the felt confirmation the design asks for; a failed append is felt
   as its absence, plus the existing red `lastError` line. "The control shows a failure
   state" (§7) is satisfied by that `lastError` rendering (`CaptureView.swift:640-645`);
   no bespoke error UI. The feedback modifier must use the **condition variant**, firing
   only when the count *increases* — `markerCount` resets at capture teardown and the
   coordinator is respawned per capture, and a bare `trigger:` fires on any change,
   which would buzz on `done()`.
5. **The Two-voices toggle is disabled while a capture is live.** Design §5 places it
   "pre-record, in the setup area"; the frame-0 `bn` opener can only be written at
   recording start, so mid-capture enabling has no coherent meaning in this build.
6. **Carry-over is a computed property, not an imperative refresh.** `multiVoiceEnabled`
   is derived on read: an in-session per-journal override map (mirrors
   `carriedBackdates`) consulted first, else the journal's most recent entry on disk via
   `library.lastMultiVoice(forJournal:)`. Two reasons. (a) Disk alone cannot satisfy
   §8's "survives a journal switch and back" for a journal that has no entries yet:
   toggle on in journal A, switch to B and back, and a disk-only read would drop the
   choice — the override map holds it. (b) The library's launch `rescan()` is **async**:
   an imperative read at `onAppear` would race it and show the toggle off until the next
   journal switch. Computing through `library.allEntries` (`@Observable` state) means
   SwiftUI re-renders the toggle the moment the scan lands — durable-across-launch
   carry-over with zero new storage and no refresh choreography.
7. **Snapping details** (§6 left three micro-choices open):
   - Rule 0: a marker whose raw frame already lies outside every spoken interval is
     already in a gap — keep the raw frame, not approximate. This is what makes the
     frame-0 opener, marker-before-first-run, and marker-after-last-run cases exact
     rather than pulled toward speech.
   - Candidate gaps are ranked by the length of their **intersection with the window**
     (a gap is only as useful as the part inside ±1.5 s), and the snapped frame is the
     **midpoint of that intersection** — so the snap never lands more than the window
     away from the tap. Ties resolve to the candidate nearest the raw frame, per §6.
   - A record containing any untimed run contributes its record-level range as one
     interval (no interior gaps — conservative); a fully-timed record contributes
     per-run intervals. Overlapping intervals merge before gaps are computed.
8. **`MarkerLog` deliberately duplicates the `LiveTranscriptStore` shape** rather than
   generalizing it. The design says "built like", and refactoring a shipped, reviewed
   writer inside a feature step is the wrong risk. If a third JSONL log ever appears,
   factor then.

### 0.4 Step order and dependencies

Steps land in design order 1→6; each is one reviewed diff, one commit. 3 depends on 1+2;
4 depends on 3 (the opener call); 5 depends on 3+4; 6 depends only on 2. If a session
must parallelize, 6 can run alongside 3–5.

---

## Step 1 — `FrameClockSink` + tee wiring + resume regression test

### Files

**New: `Raconte/Capture/FrameClockSink.swift`**

```swift
/// Third tee branch (design §3): the capture-frame clock the marker entry points read
/// on the main actor. Accumulates on the audio tap thread — one lock, one addition,
/// nothing else. `currentFrame` is on the same axis as `StampedChunk.startFrame` and
/// `SegmentSidecar.startFrameOffset`: position in `final/recording.m4a`.
final class FrameClockSink: PCMSink, @unchecked Sendable {
    private let lock = NSLock()
    private var frames: Int64 = 0

    var currentFrame: Int64 { lock.withLock { frames } }

    nonisolated func receive(_ chunk: PCMChunk) {
        lock.lock()
        frames += Int64(chunk.frameCount)
        lock.unlock()
    }
}
```

**Edit: `Raconte/Capture/CaptureCoordinator.swift`**

- New stored property beside `currentTee` (line ~127):
  `private var currentFrameClock: FrameClockSink?`
- `configureAndStart(captureID:)` — construct once per capture and append as the **last**
  branch (after the disk forwarder and any secondary sink, per design §3), replacing
  line 364:

  ```swift
  let frameClock = FrameClockSink()
  let tee = TeeSink(branches: [forwarder] + (secondary.map { [$0] } ?? []) + [frameClock])
  ```

  and set `currentFrameClock = frameClock` beside `currentTee = tee` (line ~383), i.e.
  only after `recorder.start` succeeded and the format guard passed.
- `rebuildAndReacquire()` — **no change.** It already reuses `currentTee`
  (line 429-431), which is the whole point: the clock must not reset on resume. The new
  test pins this.
- `resetCaptureWiring()` (lines 624-634) — add `currentFrameClock = nil`.
- New read-only accessor for markers (step 3) and tests:

  ```swift
  /// Current position on the capture-frame axis, nil when no capture is wired.
  var currentCaptureFrame: Int64? { currentFrameClock?.currentFrame }
  ```

### Tests — write first, watch them fail

**New: `RaconteTests/FrameClockSinkTests.swift`**

```swift
final class FrameClockSinkTests: XCTestCase
```

- `testStartsAtZero`
- `testAccumulatesFrameCountsAcrossChunks` — three chunks of 4_800/250/1 frames →
  `currentFrame == 5_051`.
- `testConcurrentReceivesLoseNothing` — `DispatchQueue.concurrentPerform(iterations: 200)`
  each receiving a 100-frame chunk → exactly 20_000.

**Edit: `RaconteTests/CaptureCoordinatorTests.swift`** — new section
`// MARK: T6 §14 step 1 — the frame clock survives resume`, reusing the file's private
`FakeSession` / `FakeRecorder` / `makeCoordinator` / `waitUntil` fixtures (lines 10-130):

- `testFrameClockSurvivesInterruptionResume` — mirror of
  `testSecondBranchSurvivesInterruptionResume` (line 663): `record()`, `feed(frames: 750)`,
  emit `.interrupted`, wait interrupted, emit `.resumeAvailable(shouldResume: true)`,
  wait recording, `feed(frames: 250)`, then assert
  `coordinator.currentCaptureFrame == 1000` **while still recording** (wiring is torn
  down after `done()`).
- `testFrameClockSurvivesRouteLossResume` — same over `.routeLost`, waiting on
  `recorder.startCount >= 2` (mirror of line 690).

### Red/green evidence

Red: add the `currentCaptureFrame` accessor as a stub returning `nil` and the sink file
with `receive` as a no-op, run

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' test -only-testing:RaconteTests/FrameClockSinkTests -only-testing:RaconteTests/CaptureCoordinatorTests
```

and paste the failures. Then implement and re-run to green.

Mutation checks (run after green, revert after):
1. In `receive`, replace `frames += Int64(chunk.frameCount)` with
   `frames = Int64(chunk.frameCount)` → `testAccumulatesFrameCountsAcrossChunks` must fail.
2. In `rebuildAndReacquire()`, temporarily construct a fresh clock and tee
   (`currentFrameClock = FrameClockSink(); let tee = TeeSink(branches: [forwarder…, currentFrameClock!])`
   — any variant that swaps clock identity on resume) →
   `testFrameClockSurvivesInterruptionResume` must fail at 250 ≠ 1000. This is the
   design's named mutation ("mutation-verified that both `recorder.start` sites install
   it", §8), inherited for free from tee identity — the mutation proves the test would
   catch anyone breaking that inheritance.

Green gate: full `-scheme Raconte` suite, then commit
`capture: FrameClockSink tee branch — frame clock for structure markers (T6 §14 step 1)`.

### Subagent prompt — step 1

```
You are implementing step 1 of docs/plans/2026-08-05-structure-markers-implementation-plan.md
in the raconte repo (read that file's §0 and Step 1 in full first; the design is
docs/plans/2026-08-05-capture-structure-markers-design.md §3, §7, §8).

Task: add FrameClockSink (new file Raconte/Capture/FrameClockSink.swift, exact shape in
the plan), wire it as the LAST tee branch in CaptureCoordinator.configureAndStart, hold
it as currentFrameClock, clear it in resetCaptureWiring(), expose
`var currentCaptureFrame: Int64?`. Do NOT touch rebuildAndReacquire — it must keep
reusing currentTee.

TDD, in this order:
1. Write RaconteTests/FrameClockSinkTests.swift (testStartsAtZero,
   testAccumulatesFrameCountsAcrossChunks, testConcurrentReceivesLoseNothing) and the two
   coordinator tests (testFrameClockSurvivesInterruptionResume,
   testFrameClockSurvivesRouteLossResume) as a new MARK section in
   RaconteTests/CaptureCoordinatorTests.swift, mirroring
   testSecondBranchSurvivesInterruptionResume (line ~663) and its route-loss companion.
   Assert currentCaptureFrame == 1000 while phase is still .recording.
2. Add stubs only (no-op receive, currentCaptureFrame returning nil), run
   `xcodegen generate` then
   `xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' test -only-testing:RaconteTests/FrameClockSinkTests -only-testing:RaconteTests/CaptureCoordinatorTests`
   and CAPTURE the failing output.
3. Implement, re-run to green, then run the FULL suite:
   `xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' test`
4. Mutation checks (then revert both): (a) `frames = …` instead of `+=` must fail the
   accumulation test; (b) swapping in a fresh FrameClockSink inside rebuildAndReacquire
   must fail testFrameClockSurvivesInterruptionResume at 250 ≠ 1000.

Constraints: NSLock + @unchecked Sendable (no atomics package — none exists in this
repo), no mutable state on TeeSink, no allocation in receive. Swift 6 strict concurrency
is on. Do not commit. Report: the diff, the red output, the green output, both mutation
results.
```

---

## Step 2 — `StructureMarker` + `MarkerLog`

### Files

**New: `Raconte/Capture/StructureMarker.swift`**

```swift
/// One capture-time observation about the audio that the audio does not contain
/// (design §0). `frame` is the RAW tap frame on the capture-frame axis — stored
/// untouched forever; snapping (MarkerSnapping) is derived and re-derivable.
struct StructureMarker: Codable, Sendable, Equatable {

    enum Kind: Sendable, Equatable {
        case voice
        case paragraph
        /// Preserved and ignored (design §4): a kind written by a newer build must
        /// survive a read-rewrite cycle on this one. Reachable the moment M4 syncs.
        case unknown(String)

        init(string: String)      // "voice" | "paragraph" | anything → .unknown(it)
        var string: String        // exact round-trip, including unknown
    }

    var seq: Int
    var frame: Int64
    var kind: Kind
    /// Voice id — present only on `.voice` markers. Stored as a free string
    /// (owner decision 3); the two UI values are `Voice.littleNico` / `Voice.bigNico`.
    var voice: String?

    init(seq: Int, frame: Int64, kind: Kind, voice: String? = nil)
}

extension StructureMarker {
    /// Exactly two voices in the UI; storage stays a string (owner decision 3).
    enum Voice {
        static let littleNico = "ln"
        static let bigNico = "bn"
    }
}
```

Codable: hand-written both directions (house rule).
- `init(from:)` — `seq`, `frame` strict `decode`; `kind` strict on key presence
  (`Kind(string: try container.decode(String.self, forKey: .kind))` — an *unrecognized
  value* is `.unknown`, a *missing key* throws); `voice` lenient
  (`try? container.decodeIfPresent`, garbage → nil).
- `encode(to:)` — `seq`, `frame`, `kind.string`; `encodeIfPresent(voice)` so a paragraph
  line carries no `voice` key (matches design §4's example lines byte-for-byte under
  `.sortedKeys`).

**Edit: `Raconte/Capture/SegmentLayout.swift`**

- Constant after `liveTranscriptFileName` (line 12):
  `static let markerLogFileName = "markers.jsonl"`
- Helper between `liveTranscriptURL` (ends line 111) and `canonicalTranscriptURL`:

  ```swift
  /// Capture-time structure markers (T6 §14): raw tap frames, append-only JSONL.
  /// Lives in transcript/ so issue #8's guard already covers it with zero changes.
  static func markerLogURL(captureDirectory: URL) -> URL {
      transcriptDirectory(captureDirectory: captureDirectory)
          .appendingPathComponent(markerLogFileName)
  }
  ```

**New: `Raconte/Capture/MarkerLog.swift`** — a deliberate structural copy of
`LiveTranscriptStore.swift` (see §0.3.8), including its own fileprivate
`FileDescriptorBox`:

```swift
enum MarkerLogError: Error, Equatable {
    case posix(operation: String, code: Int32)
    case notOpen
    case multilineRecord
    case unreadableExistingLog(String)
}

/// Three answers, never a bare array (the #11 rule): absent, unreadable, present.
enum MarkerLogSource: Equatable {
    case absent
    case unreadable(String)
    case present(Data)
}

final class MarkerLogWriter {
    private(set) var recordsWritten: Int   // 0
    private(set) var nextSeq: Int          // 0, resumed from the file on open()

    init(captureDirectory: URL)            // url = SegmentLayout.markerLogURL(...)
    func open() throws                     // creates transcript/, O_WRONLY|O_CREAT|O_APPEND,
                                           // throws unreadableExistingLog rather than
                                           // resuming nextSeq from a failed read;
                                           // terminates a pre-existing torn tail
    @discardableResult
    func append(_ marker: StructureMarker) throws -> StructureMarker
                                           // stamps seq, lineEncoder(), rejects any
                                           // encoded newline, in-process tornTail flag
    func sync() throws
    func close() throws                    // sync + close, idempotent
}

enum MarkerLogReader {
    struct ParseResult: Equatable { var markers: [StructureMarker] = []; var completeLines: Int = 0 }
    struct LoadResult: Equatable {
        var source: MarkerLogSource = .absent
        var markers: [StructureMarker] = []
        /// Complete lines, decodable or not — what nextSeq must respect.
        var completeLines: Int = 0
    }
    static func loadBytes(at url: URL) -> MarkerLogSource
    static func load(url: URL) -> LoadResult
    static func load(captureDirectory: URL) -> LoadResult
    static func parse(_ data: Data) -> ParseResult   // torn trailing line dropped
}
```

Copy the semantics line-for-line from `LiveTranscriptStore.swift`: the
`nextSeq = max(last.seq + 1, completeLines)` rule, the newline-termination of an
inherited torn tail in `open()`, the in-process `tornTail` flag in `append`, `writeAll`,
`Foundation.open` qualification, and the `.fileReadNoSuchFile || .fileNoSuchFile` absent
mapping. One stated difference, restated from design §4: there is **no** `completeness`
check — the marker log has no `committedRecords` analogue, so **tail loss is
undetectable**; the final voice span runs long, visible and editable in T7. Put that
sentence in the type's doc comment.

### Tests — write first

**New: `RaconteTests/MarkerLogTests.swift`** — setup/teardown copied from
`LiveTranscriptStoreTests.swift:6-36` (nested `captures/<id>/` shape), plus a
`marker(_:_:)` fixture helper.

Writer/reader (each mirrors a named `LiveTranscriptStoreTests` case; the T3 bugs these
pin were real):
- `testAppendedMarkersRoundTrip` — voice(bn)@0, paragraph@812_544, voice(ln)@1_104_128
  → read back equal, seqs 0,1,2 (design §4's exact example).
- `testParagraphLineOmitsTheVoiceKey` — raw bytes of the encoded line contain no
  `"voice"`.
- `testTornTrailingLineIsDiscardedAndEarlierMarkersSurvive`
- `testASingleTornLineWithNoNewlineReadsAsEmpty`
- `testReopeningAfterATornLineDoesNotCorruptNewMarkers` — the O_APPEND fuse bug;
  asserts `second.nextSeq` skips nothing it shouldn't and both markers read back.
- `testSeqDoesNotCollideWithAnUndecodableLine` — garbage complete line consumed a seq.
- `testOpenOnAnUnreadableLogThrowsRatherThanRenumbering` — `chmod 000` +
  `XCTSkipIf(isReadableFile)` idiom (`LiveTranscriptIntegrityTests.swift:42-82`).
- `testAbsentVsUnreadableVsPresentAreThreeAnswers` — no file → `.absent`; unreadable →
  `.unreadable` (never empty-array collapse); real file → `.present`.
- `testAppendBeforeOpenThrows`
- `testCloseIsIdempotent`
- `testAMultilineVoiceStringThrowsRatherThanTrapping` — voice id containing `\n`.

Decoder (same file, `// MARK: Decoding`):
- `testUnknownKindRoundTripsIntact` — decode `{"frame":10,"kind":"chapter","seq":0}` →
  `.unknown("chapter")`; re-encode → `"kind":"chapter"` byte-identical field.
- `testMissingIdentityFieldThrows` — a line without `frame`, a line without `kind`,
  a line without `seq`: all fail to decode (and `parse` skips them as undecodable
  complete lines).
- `testVoiceMarkerWithoutVoiceStringStillDecodes` — lenient additive field; `voice`
  reads nil, the marker survives.
- `testLazyDirectoryCreation` — constructing `MarkerLogWriter` creates nothing;
  `transcript/` exists only after `open()`. (The *call-site* laziness — no open until
  first append — is step 3's test.)

### Red/green evidence

Red: write the test file, add skeletal types (`open`/`append` throwing `notOpen`
unconditionally, `parse` returning empty), run

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' test -only-testing:RaconteTests/MarkerLogTests
```

paste the failures, then implement to green.

Mutation checks (run, observe failure, revert):
1. Delete the torn-tail newline block in `open()` →
   `testReopeningAfterATornLineDoesNotCorruptNewMarkers` must fail.
2. Swap `lineEncoder()` for `encoder()` in `append` →
   `testAMultilineVoiceStringThrowsRatherThanTrapping` is joined by every round-trip
   test failing (the multiline guard trips on pretty-printing).
3. In `Kind.init(string:)`, map unknown strings to `.paragraph` →
   `testUnknownKindRoundTripsIntact` must fail.

Green gate: full suite. Commit:
`capture: StructureMarker + MarkerLog append-only JSONL (T6 §14 step 2)`.

### Subagent prompt — step 2

```
You are implementing step 2 of docs/plans/2026-08-05-structure-markers-implementation-plan.md
in the raconte repo. Read that plan's §0 and Step 2 in full, the design doc
docs/plans/2026-08-05-capture-structure-markers-design.md (§4, §8, appendix), and — this
is the template you are mirroring — Raconte/Transcription/LiveTranscriptStore.swift plus
its tests RaconteTests/LiveTranscriptStoreTests.swift and
RaconteTests/LiveTranscriptIntegrityTests.swift.

Task: new files Raconte/Capture/StructureMarker.swift and Raconte/Capture/MarkerLog.swift
(exact API surfaces in the plan), plus SegmentLayout.markerLogFileName and
SegmentLayout.markerLogURL(captureDirectory:). MarkerLog mirrors LiveTranscriptStore's
semantics exactly: O_APPEND, lineEncoder() (NEVER the pretty-printed encoder()),
nextSeq = max(lastSeq+1, completeLines), torn-tail termination both across reopens and
in-process, unreadable-existing-log throws rather than renumbering, three-answer
MarkerLogSource. StructureMarker: hand-written init(from:) AND encode(to:) — seq/frame/
kind strict, voice lenient, unknown kind preserved via .unknown(String), voice key
omitted when nil. No completeness/tail-loss API: tail loss is undetectable here by
design — say so in the doc comment.

TDD, in this order:
1. Write RaconteTests/MarkerLogTests.swift with every test named in the plan's Step 2.
2. Add skeletal types so it compiles (append/open throw notOpen, parse returns empty),
   run `xcodegen generate` then
   `xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' test -only-testing:RaconteTests/MarkerLogTests`
   and CAPTURE the failing output.
3. Implement to green, then run the FULL suite
   (`… -scheme Raconte -destination 'platform=macOS' test`).
4. Run the three mutation checks in the plan (torn-tail block deleted; encoder() swap;
   unknown-kind collapsed) — each must produce failures — and revert each.

Swift 6 strict concurrency. Do not modify LiveTranscriptStore.swift or any
Transcription/ file. Do not commit. Report: diff, red output, green output, the three
mutation results.
```

---

## Step 3 — coordinator `markVoice` / `markParagraph` + `lastError` path

### Files

**Edit: `Raconte/Capture/CaptureCoordinator.swift`** — one new
`// MARK: Structure markers (T6 §14)` section.

New state (beside the observable block, lines 54-95, and the private wiring):

```swift
/// Most recent voice marker's id, nil when none written. The UI voice toggle binds this.
private(set) var currentVoice: String?
/// Successful marker appends this capture — the haptic trigger (plan §0.3.4).
private(set) var markerCount = 0

private var markerLog: MarkerLogWriter?
/// Latched when the log could not be opened (mirrors TranscriptionSession.loggingBroken).
private var markerLoggingBroken = false
```

New API, all `@MainActor` (the class already is):

```swift
/// The frame-0 "bn" opener (owner decision 4): a multi-voice capture opens in bigNico,
/// written as an ordinary marker at frame 0 so "what voice is this span" has one rule.
/// Called by the screen model when a multi-voice capture reaches .recording.
func markOpeningVoice()

/// Raw tap: current clock frame, voice marker. No-op outside .recording or with no
/// frame clock (design §7 — disabled outright, never frame-0 spam).
func markVoice(_ voice: String)

/// Raw tap: current clock frame, paragraph marker. Independent of the voice toggle
/// (owner decision 7) — same guards.
func markParagraph()
```

Shared implementation:

```swift
private func appendMarker(kind: StructureMarker.Kind, voice: String?, atFrame frame: Int64) {
    guard phase == .recording,
          currentFrameClock != nil,          // design §7: no clock → markers disabled
          !markerLoggingBroken,
          let captureID = activeCaptureID else { return }
    do {
        let writer = try openMarkerLogIfNeeded(captureID: captureID)
        try writer.append(StructureMarker(seq: 0, frame: frame, kind: kind, voice: voice))
        if case .voice = kind { currentVoice = voice }
        markerCount += 1
    } catch {
        // Recording is never interrupted for a marker (design §7); it fails loudly.
        lastError = "Couldn't save a marker"
        if markerLog == nil { markerLoggingBroken = true }   // the open itself failed
    }
}

/// Lazy: transcript/ must not exist until a marker actually lands (rev 2 rule 10 /
/// the T3 zero-byte-log lesson — an eager open makes a mis-tap undeletable).
private func openMarkerLogIfNeeded(captureID: String) throws -> MarkerLogWriter {
    if let markerLog { return markerLog }
    let directory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot,
                                                   captureID: captureID)
    let writer = MarkerLogWriter(captureDirectory: directory)
    try writer.open()
    markerLog = writer
    return writer
}
```

`markOpeningVoice()` calls
`appendMarker(kind: .voice, voice: StructureMarker.Voice.bigNico, atFrame: 0)` — the
literal 0, never the clock. `markVoice(_:)` / `markParagraph()` read
`currentFrameClock?.currentFrame` (via a `guard let frame = currentCaptureFrame`) and
pass it through.

Teardown — in `resetCaptureWiring()` (lines 624-634):

```swift
try? markerLog?.close()
markerLog = nil
markerLoggingBroken = false
currentVoice = nil
```

(`markerCount` may stay — the coordinator is single-capture and respawned — but reset it
anyway for symmetry.)

### Tests — write first

**Edit: `RaconteTests/CaptureCoordinatorTests.swift`** — new section
`// MARK: T6 §14 step 3 — structure markers`, reusing the existing fixtures. Read
markers back with `MarkerLogReader.load(captureDirectory:)` composed from the test's
captures root + `coordinator.activeCaptureID` (capture it while recording — it nils on
teardown).

- `testMarkParagraphWritesTheRawTapFrame` — `record()`, `feed(frames: 750)`,
  `markParagraph()` → one `.paragraph` marker, `frame == 750`, no `voice` value.
- `testMarkVoiceWritesTheMarkerAndPublishesCurrentVoice` — `markVoice("ln")` → marker
  `voice == "ln"`, `coordinator.currentVoice == "ln"`.
- `testMarkOpeningVoiceWritesLiteralFrameZero` — `feed(frames: 750)` **first**, then
  `markOpeningVoice()` → `frame == 0`, `voice == "bn"`. (The feed-first ordering *is*
  the mutation check: an implementation that reads the clock fails at 750.)
- `testMarkerSeqsAreMonotonicAcrossKinds` — opener, paragraph, voice → seqs 0,1,2.
- `testNoMarksMeansNoTranscriptDirectory` — record, feed, `done()` → the capture
  directory contains no `transcript/`. (The lazy-open lesson, at the call site.)
- `testFirstMarkCreatesTheLogLazily` — `transcript/` absent before the first
  `markParagraph()`, present with `markers.jsonl` after.
- `testMarksOutsideRecordingAreIgnored` — `markParagraph()` before `record()` and again
  after `done()` → no file, no crash, `markerCount == 0`.
- `testMarkerFramesSurviveInterruptionResume` — feed 750, interrupt, resume, feed 250,
  `markParagraph()` → `frame == 1000`. (Step 1's clock pinned at the marker level.)
- `testOpenFailureSetsLastErrorAndRecordingContinues` — before the first mark, create a
  plain **file** named `transcript` inside the capture directory (so
  `createDirectory` inside `open()` fails without chmod/root caveats);
  `markParagraph()` → `lastError != nil`, `phase == .recording` still, `feed` still
  counts, `done()` still reaches `.captured`.
- `testOpenFailureLatchesFurtherMarks` — after the failure above, a second
  `markParagraph()` neither crashes nor resets `lastError` to a success state, and
  `markerCount == 0`.
- `testMarkerCountIncrementsPerSuccessfulAppend` — three marks → 3 (the haptic seam).

### Red/green evidence

Red: add the three public methods as empty no-ops plus the stored properties, run

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' test -only-testing:RaconteTests/CaptureCoordinatorTests
```

paste the failures (at minimum `testMarkParagraphWritesTheRawTapFrame`,
`testMarkOpeningVoiceWritesLiteralFrameZero`, `testFirstMarkCreatesTheLogLazily` must be
seen red). Implement to green; full suite; commit
`capture: coordinator markVoice/markParagraph, lazy marker log, loud failure (T6 §14 step 3)`.

### Subagent prompt — step 3

```
You are implementing step 3 of docs/plans/2026-08-05-structure-markers-implementation-plan.md
in the raconte repo. Read the plan's §0 + Step 3 and the design doc's §3 (CaptureCoordinator
component), §7 (failure modes), and appendix. Steps 1 and 2 are already on this branch:
FrameClockSink/currentCaptureFrame and StructureMarker/MarkerLogWriter/MarkerLogReader
exist — read Raconte/Capture/FrameClockSink.swift, Raconte/Capture/StructureMarker.swift,
Raconte/Capture/MarkerLog.swift before starting.

Task: add to Raconte/Capture/CaptureCoordinator.swift exactly the state, API, and helper
shown in the plan's Step 3 (markOpeningVoice / markVoice / markParagraph / appendMarker /
openMarkerLogIfNeeded, currentVoice, markerCount, markerLog, markerLoggingBroken), plus
teardown in resetCaptureWiring(). Non-negotiable behaviors: markers hang off the
coordinator, NOT TranscriptionSession; the log opens lazily at first append, never
earlier; markOpeningVoice writes literal frame 0 with voice "bn"; append failure sets
lastError and never touches the recording; open failure latches; no capture-time undo —
do not add any removal API; guards are phase == .recording AND currentFrameClock != nil.

TDD, in this order:
1. Add the twelve tests named in the plan's Step 3 as a new MARK section in
   RaconteTests/CaptureCoordinatorTests.swift, reusing that file's FakeSession/
   FakeRecorder/makeCoordinator/waitUntil fixtures.
2. Add no-op method stubs + properties so it compiles; run `xcodegen generate` then
   `xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' test -only-testing:RaconteTests/CaptureCoordinatorTests`
   and CAPTURE the red output.
3. Implement to green; then the FULL suite
   (`… -scheme Raconte -destination 'platform=macOS' test`) — every pre-existing
   coordinator test must still pass.

Note: capture activeCaptureID into a local while the capture is live — resetCaptureWiring
nils it before you can read markers back after done(). Do not commit. Report: diff, red
output, green output.
```

---

## Step 4 — `multiVoice` on the sidecar + per-journal durable carry-over

### Files

**Edit: `Raconte/Library/EntryMetadata.swift`**

- New field `var multiVoice: Bool` (declared beside `detectionRan`, line ~87), memberwise
  init gains `multiVoice: Bool = false`.
- `CodingKeys` (lines 146-149): add `multiVoice`.
- `init(from:)` (lines 165-...): lenient additive decode, matching the `detectedDate`
  idiom: `multiVoice = (try? container.decodeIfPresent(Bool.self, forKey: .multiVoice)) ?? false`.
- `encode(to:)` (lines 209-223): encode **only when true** —
  `if multiVoice { try container.encode(true, forKey: .multiVoice) }` — so a default
  sidecar stays literally `{}` and `isDefault` keeps working unchanged (it is an
  `Equatable` compare against `.defaults`).

**Edit: `Raconte/Library/EntryListItem.swift`** — computed passthrough beside
`journalID`/`originalDate` (lines 97-127): `var multiVoice: Bool { metadata.multiVoice }`.

**Edit: `Raconte/Library/LibraryScreenModel.swift`** — beside `dateRange(forJournal:)`
(lines 158-160):

```swift
/// Durable per-journal multi-voice carry-over (design decision 5): the journal's most
/// recently captured entry decides. Deliberately AUTO-ENABLING — the recorded
/// divergence from the backdate rule (design §2): a wrong voice attribute is visible
/// and editable in T7; a wrong backdate is a quiet data error.
func lastMultiVoice(forJournal journalID: String) -> Bool {
    Self.mostRecentlyCaptured(allEntries.filter { $0.journalID == journalID }, limit: 1)
        .first?.multiVoice ?? false
}
```

**Edit: `Raconte/Capture/UI/CaptureView.swift`** (`CaptureScreenModel`):

New state beside `carriedBackdates` (line ~88), plus a computed read (plan §0.3.6 —
derived, not imperatively refreshed, so the async launch rescan can't race it):

```swift
/// In-session explicit choices, keyed by journal id — consulted before the disk value
/// so a toggle set on an entry-less journal survives a switch-and-back (plan §0.3.6).
private var multiVoiceOverrides: [String: Bool] = [:]

/// Carry-over (design decision 5): the explicit in-session choice for the selected
/// journal, else the journal's most recent entry on disk. Computed through
/// `library.allEntries`, so the toggle re-renders when the launch rescan lands.
var multiVoiceEnabled: Bool {
    guard let journalID = selectedJournalID else { return false }
    return multiVoiceOverrides[journalID] ?? library.lastMultiVoice(forJournal: journalID)
}

func setMultiVoiceEnabled(_ enabled: Bool) {
    guard let journalID = selectedJournalID else { return }
    multiVoiceOverrides[journalID] = enabled
}
```

Call sites:
- `selectJournal(_:)` (line 279) and `createJournal(name:)` (line 288): **no change** —
  the computed property re-derives per journal by construction. (Contrast with
  `resolveBackdateForJournalChange()`, which exists because backdate state is stored.)
- `handlePhase()` (line 246), in the existing `.recording` arm: snapshot
  `let multiVoice = multiVoiceEnabled` and (a) extend the
  `enqueueEntryMetadataWrite` closure to set `metadata.multiVoice = multiVoice`,
  (b) `if multiVoice { coordinator.markOpeningVoice() }`. The snapshot matters twice
  over: the closure runs later on a serialized Task chain, and the computed value
  could shift under it if a rescan lands mid-capture.
- `enqueueEntryMetadataWrite(for:clearingBackdateIfDisabled:)` (lines 534-555): thread
  the snapshot through (add a parameter or capture it — follow the existing
  `journalID` capture pattern).

### Tests — write first

**Edit the file owning `EntryMetadata` Codable tests** (locate it — expected
`RaconteTests/EntryMetadataStoreTests.swift`; if decode tests live elsewhere, follow
them):
- `testMultiVoiceAbsentDecodesFalse`
- `testMultiVoiceTrueRoundTrips`
- `testMultiVoiceFalseIsOmittedFromTheSidecar` — encode defaults → bytes are `{}`
  (or at least contain no `multiVoice` key).
- `testMultiVoiceGarbageDecodesFalse` — `{"multiVoice":"yes"}` → false, no throw.

**New: `RaconteTests/MultiVoiceCarryOverTests.swift`** —
`@MainActor final class MultiVoiceCarryOverTests: XCTestCase`. Two fixture layers:
in-memory model tests mirror `BackdateCarryOverTests.swift` (fakes at its lines 5-22,
`makeModel()` at 41-46); disk-backed tests build real capture directories with
`entry.json` sidecars under a temp root the way the existing `LibraryScanner` /
`LibraryScreenModel` tests do (mirror their fixture helpers), then `await rescan()`.

- `testMultiVoiceAutoEnablesFromTheJournalsMostRecentEntry` — journal A's latest entry
  has `multiVoice: true`; a **freshly constructed** model over the same root, after
  `await rescan()`, reads `multiVoiceEnabled == true` with no user action. Put the
  divergence note in a comment: this deliberately inverts
  `BackdateCarryOverTests.testCarryOverNeverAutoEnablesTheToggle`.
- `testCarryOverDoesNotCrossJournals` — A latest true, B latest false (or no entries) →
  switching to B disables.
- `testCarryOverSurvivesJournalSwitchAndBack` — journal with **no entries**: toggle on,
  switch away, switch back → still on (the override map).
- `testCarryOverIsDurableAcrossRelaunch` — write sidecars, build a *second* model over
  the same root → enabled matches disk.
- `testMostRecentEntryDecidesWhenEntriesDisagree` — older true + newer false → off
  (ordering via `mostRecentlyCaptured`: `capturedAt` desc).
- `testRecordingWritesMultiVoiceToTheSidecar` — toggle on, record via fakes, await the
  metadata chain → `entry.json` has `multiVoice: true`; toggle off → key absent.
- `testMultiVoiceCaptureOpensWithFrameZeroBigNico` — toggle on, record →
  `markers.jsonl` holds `{seq:0, frame:0, kind:voice, voice:"bn"}`; toggle off, record
  → no `transcript/` at all.

### Red/green evidence

Red: add the `multiVoice` field with decode/encode wired but leave the carry-over API as
stubs (`multiVoiceEnabled` computed returning false, `lastMultiVoice` returning false),
run

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' test -only-testing:RaconteTests/MultiVoiceCarryOverTests -only-testing:RaconteTests/EntryMetadataStoreTests
```

paste the red (the metadata Codable tests may already be green at this point — the
carry-over and recording tests are the required red). Implement to green.

Mutation check (then revert): in `init(from:)`, decode `multiVoice` strictly
(`try container.decode`) → `testMultiVoiceAbsentDecodesFalse` must fail — proving the
lenient path is load-bearing, i.e. every pre-feature sidecar on both devices still reads.

Full suite green (pre-existing `BackdateCarryOverTests` untouched and passing), commit:
`library+capture: multiVoice sidecar field, per-journal durable carry-over (T6 §14 step 4)`.

### Subagent prompt — step 4

```
You are implementing step 4 of docs/plans/2026-08-05-structure-markers-implementation-plan.md
in the raconte repo. Read the plan's §0 + Step 4, the design doc's §2 decisions 4-5 and
its divergence note, and these precedents in source: the backdate carry-over block in
Raconte/Capture/UI/CaptureView.swift (carriedBackdates, setBackdateEnabled,
resolveBackdateForJournalChange, rememberBackdate), EntryMetadata's hand-written
init(from:)/encode(to:) in Raconte/Library/EntryMetadata.swift, and
RaconteTests/BackdateCarryOverTests.swift.

Task, exactly as specified in the plan: (1) EntryMetadata.multiVoice — lenient decode
((try? decodeIfPresent) ?? false), encode-only-when-true so defaults stay `{}`;
(2) EntryListItem.multiVoice passthrough; (3) LibraryScreenModel.lastMultiVoice(forJournal:)
off allEntries via mostRecentlyCaptured; (4) CaptureScreenModel: multiVoiceOverrides map,
setMultiVoiceEnabled(_:), and multiVoiceEnabled as a COMPUTED property
(override ?? library.lastMultiVoice) — no stored toggle state, no imperative refresh, no
onAppear hook; the computed read through library.allEntries is what makes carry-over
survive relaunch and not race the async launch rescan (plan §0.3.6); (5) handlePhase's
.recording arm snapshots the computed value into a local, writes it through
enqueueEntryMetadataWrite's closure, and calls coordinator.markOpeningVoice() when
enabled. Carry-over AUTO-ENABLES by design — this is the recorded divergence from the
backdate rule; do not "fix" it.

TDD, in this order:
1. Write the four EntryMetadata Codable tests (in the file that owns its decode tests)
   and RaconteTests/MultiVoiceCarryOverTests.swift with the seven tests named in the
   plan, mirroring BackdateCarryOverTests' fakes for model tests and the existing
   scanner-test fixtures for disk-backed ones.
2. Stub the carry-over API, `xcodegen generate`, run
   `xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' test -only-testing:RaconteTests/MultiVoiceCarryOverTests -only-testing:RaconteTests/EntryMetadataStoreTests`
   and CAPTURE the red output.
3. Implement to green, then the FULL suite — BackdateCarryOverTests and every
   EntryMetadata/scanner test must still pass.
4. Mutation check (then revert): make the multiVoice decode strict — 
   testMultiVoiceAbsentDecodesFalse must fail.

Do not commit. Report: diff, red output, green output, mutation result.
```

---

## Step 5 — `CaptureView` controls

### Files

**New: `Raconte/Capture/UI/MarkerControls.swift`** — the pure, testable half (mirrors
`RecordControlModel.make(phase:canResume:)`, `RecordButton.swift:36-73`):

```swift
/// Pure phase+toggle → marker-control state. Exhaustive over CaptureState so a new
/// phase breaks the build here rather than silently hiding the controls.
struct MarkerControlsModel: Equatable {
    var showsVoiceControl: Bool
    var showsParagraphControl: Bool
    /// Taps land only in .recording (design §5); shown-but-disabled through
    /// interrupted/resuming so the layout doesn't jump during an interruption.
    var isEnabled: Bool

    static func make(phase: CaptureState, multiVoice: Bool) -> MarkerControlsModel
}
```

Rules: `.recording`/`.interrupted`/`.resuming` → `showsParagraphControl = true` always
(owner decision 7), `showsVoiceControl = multiVoice`, `isEnabled = (phase == .recording)`;
every other phase → nothing shown. Exhaustive `switch`, no `default`.

**Edit: `Raconte/Capture/UI/CaptureView.swift`**

1. Setup area — a `MultiVoiceField` view beside `JournalHeaderView` / `BackdateField`
   (body lines 600-601), following `BackdateField`'s shape (lines 846-889):
   `Toggle("Two voices", …)` bound to
   `model.multiVoiceEnabled` via `model.setMultiVoiceEnabled(_:)`,
   `.accessibilityIdentifier("capture.multiVoiceToggle")`,
   `.environment(\.colorScheme, .dark)` with the standard comment (copy the wording at
   lines 863-866), `.disabled(model.coordinator.phase != .idle)` (plan §0.3.5:
   pre-record only).
2. Recording controls — in the `VStack(spacing: 28)` near `RecordButton`
   (lines 623-645), driven by
   `let markers = MarkerControlsModel.make(phase: …, multiVoice: model.multiVoiceEnabled)`:
   an `HStack` of
   - voice switch (shown when `markers.showsVoiceControl`): a `Button` labelled with the
     active voice — `"BN"` when `coordinator.currentVoice != "ln"` (nil ⇒ the capture
     opened in bn), `"LN"` otherwise — whose action marks the *other* voice:
     `coordinator.markVoice(coordinator.currentVoice == StructureMarker.Voice.littleNico
     ? StructureMarker.Voice.bigNico : StructureMarker.Voice.littleNico)`.
     `.accessibilityIdentifier("capture.voiceSwitch")`.
   - paragraph button (shown when `markers.showsParagraphControl`): label "¶ Paragraph",
     action `coordinator.markParagraph()`,
     `.accessibilityIdentifier("capture.paragraph")`.
   Both: `.disabled(!markers.isEnabled)`, `.environment(\.colorScheme, .dark)` + the
   standard comment, thumb-reach sizing (`.buttonStyle(.bordered)`,
   `.controlSize(.large)` — match the Done button's visual weight).
3. Haptics — on the HStack, the **condition variant** (plan §0.3.4):

   ```swift
   .sensoryFeedback(.impact, trigger: model.coordinator.markerCount) { old, new in
       new > old   // fires per recorded marker; never on the teardown reset to 0
   }
   ```

   Pure SwiftUI, available on both platforms at the 26.0 deployment targets, no
   `#if os(iOS)` needed. A bare `trigger:` would also fire when `markerCount` drops to
   0 at capture teardown / coordinator respawn — a phantom buzz on Done.
4. Failure state — none to add: a failed append sets `coordinator.lastError`, already
   rendered red at lines 640-645.

### Tests — write first

**New: `RaconteTests/MarkerControlsModelTests.swift`** (pure, exhaustive):
- `testNothingShownBeforeRecording` — `.idle`, `.preparing` → both hidden.
- `testVoiceAndParagraphShownWhileRecordingWithMultiVoiceOn`
- `testParagraphShownWhileRecordingEvenWithMultiVoiceOff` — owner decision 7 pinned.
- `testVoiceControlHiddenWhenMultiVoiceOff` — all recording-family phases.
- `testControlsShownButDisabledWhileInterruptedAndResuming`
- `testNothingShownAfterCapture` — `.stopping`, `.captured`, `.finalizing`, `.complete`.

**Edit: `RaconteUITests/CaptureUITests.swift`** — the design §8 UI test:

- `testVoiceControlsFollowTheMultiVoiceToggle` — launch with the harness env;
  activate `capture.multiVoiceToggle`; tap `capture.record`; assert
  `capture.voiceSwitch` and `capture.paragraph` exist; tap `capture.done`; wait for
  idle. Then toggle `capture.multiVoiceToggle` **off** (carry-over will have auto-armed
  it from the just-recorded entry — the explicit off-toggle is part of what's being
  tested); tap record again; assert `capture.voiceSwitch` does NOT exist while
  `capture.paragraph` does; done. Use the file's `activate(_:)` and `waitUntil`
  helpers (lines 24-59). The harness needs no changes: the coordinator builds its own
  frame clock (plan §0.3.2) and `SyntheticRecorder` feeds real chunks.

### Red/green evidence

Red: write `MarkerControlsModelTests` against a stub `make` returning all-false, run

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' test -only-testing:RaconteTests/MarkerControlsModelTests
```

paste the red; implement to green. The UI test cannot run red-first meaningfully against
missing identifiers (it would fail on element lookup either way); its evidence is the
green run on the simulator:

```
xcodebuild -project Raconte.xcodeproj -scheme RaconteUI -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:RaconteUITests/CaptureUITests/testVoiceControlsFollowTheMultiVoiceToggle
```

then the full `RaconteUI` suite (all pre-existing UI tests must stay green — the new
controls must not perturb `capture.record`/`capture.done` layout queries), then the full
unit suite. Commit:
`capture UI: Two-voices toggle, voice switch + paragraph controls, haptic (T6 §14 step 5)`.

### Subagent prompt — step 5

```
You are implementing step 5 of docs/plans/2026-08-05-structure-markers-implementation-plan.md
in the raconte repo. Read the plan's §0 + Step 5 and the design doc's §5 (UI) and §7.
Precedents to read in source first: RecordControlModel in
Raconte/Capture/UI/RecordButton.swift (the pure phase→control pattern you are
mirroring), BackdateField in Raconte/Capture/UI/CaptureView.swift lines ~846-889 (the
setup-area toggle shape AND the .environment(\.colorScheme, .dark) rule — copy its
comment wording), and RaconteUITests/CaptureUITests.swift (harness, helpers,
identifier conventions).

Task: (1) new Raconte/Capture/UI/MarkerControls.swift with MarkerControlsModel.make
(exhaustive switch, rules in the plan); (2) CaptureView additions — "Two voices" toggle
(id capture.multiVoiceToggle, disabled unless .idle, dark-scheme-pinned) in the setup
area, and the recording-time voice switch (id capture.voiceSwitch, label BN/LN off
coordinator.currentVoice) + paragraph button (id capture.paragraph), dark-scheme-pinned,
disabled unless .recording, with the sensoryFeedback CONDITION variant firing only when
markerCount increases (the exact modifier is in the plan — a bare trigger buzzes on the
teardown reset); (3) UI test
testVoiceControlsFollowTheMultiVoiceToggle per the plan — note carry-over auto-arms the
toggle after the first multi-voice recording, so the second half of the test explicitly
toggles it off.

TDD: write RaconteTests/MarkerControlsModelTests.swift (six tests named in the plan)
against a stub make() first; `xcodegen generate`; run
`xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' test -only-testing:RaconteTests/MarkerControlsModelTests`
and CAPTURE the red. Implement to green. Then run the UI test on the simulator:
`xcodebuild -project Raconte.xcodeproj -scheme RaconteUI -destination 'platform=iOS Simulator,name=iPhone 17' test`
(full RaconteUI suite — pre-existing UI tests must stay green), and finally the full
unit suite. Do not commit. Report: diff, red output, both green outputs.
```

---

## Step 6 — `MarkerSnapping` (pure)

### Files

**New: `Raconte/Capture/MarkerSnapping.swift`**

```swift
/// Snaps raw marker frames onto inter-word gaps in a committed transcript (design §6).
/// Pure: no I/O, no actor, no clock. The raw frame is NEVER mutated — a better
/// snapping rule later re-derives better boundaries from untouched data (owner
/// decision 2). Consumed by T7 promotion and re-applied by T8 retranscription.
enum MarkerSnapping {

    /// ±window around the raw tap frame. One named constant; a guess until a real
    /// page is read (design §10) — tune here, nowhere else.
    static let snapWindowSeconds: Double = 1.5

    static func windowFrames(sampleRate: Double) -> Int64
    // Int64((snapWindowSeconds * sampleRate).rounded())

    /// A span of transcribed speech on the capture-frame axis.
    struct SpokenInterval: Equatable, Sendable {
        var start: Int64
        var end: Int64
    }

    struct SnappedMarker: Equatable, Sendable {
        /// The stored marker, raw frame intact.
        var marker: StructureMarker
        var snappedFrame: Int64
        /// §6 rule 4: nothing usable in the window — raw frame kept; T7 surfaces it.
        var approximate: Bool
    }

    /// Interval extraction with the untimed-run rule (design §6): a record whose runs
    /// are all timed contributes one interval per run; a record containing ANY untimed
    /// run contributes its record-level frameRange as a single interval (conservative —
    /// no interior gaps invented from partial data). Output is sorted and merged.
    static func intervals(fromCommitted committed: [TranscriptResult]) -> [SpokenInterval]

    /// §6 rules, in order, per marker (details plan §0.3.7):
    /// 0. Raw frame outside every interval → already in a gap: keep it, exact.
    /// 1. Collect inter-interval gaps intersecting [frame−w, frame+w].
    /// 2. Pick the largest by intersection length; ties → nearest the raw frame.
    ///    Snapped frame = midpoint of the intersection.
    /// 3. No gap, but an interval boundary in the window → nearest boundary.
    /// 4. Nothing in the window → raw frame, approximate.
    /// Output order matches input order; markers of every kind (including .unknown)
    /// pass through — snapping is kind-agnostic.
    static func snap(markers: [StructureMarker],
                     intervals: [SpokenInterval],
                     windowFrames: Int64) -> [SnappedMarker]
}
```

Callers (T7) get `committed` from the existing disk path:
`LiveTranscriptReader.load(captureDirectory:)` → `.records` →
`LiveTranscriptReader.consolidate(_:)` → `.committed` (map 3 §9 — the seam exists today;
`EntryTranscriptLoader.load` walks it). Markers come from
`MarkerLogReader.load(captureDirectory:)`, whose `.unreadable` answer means **assign no
voice attributes** — never assume single-voice (design §7). Nothing in this step wires
those; this step is the pure function only.

### Tests — write first

**New: `RaconteTests/MarkerSnappingTests.swift`** — all fixtures are literal frame
numbers at 48 kHz (`windowFrames(sampleRate: 48_000) == 72_000`); a `result(_:)` helper
builds `TranscriptResult`s with timed/untimed runs.

Design §8's named cases:
- `testMarkerInsideSpeechSnapsToTheLargestGapInWindow`
- `testEqualGapsResolveToTheNearestOne`
- `testNoGapInWindowSnapsToNearestRunBoundary`
- `testNothingInWindowKeepsRawFrameAndFlagsApproximate` — tap inside one long run.
- `testUntimedRunFallsBackToRecordLevelRange` — a record with one untimed run yields
  the record range; a gap its timed siblings implied does NOT attract the snap.
- `testMarkerBeforeTheFirstRunKeepsRawFrame` — rule 0; includes the frame-0 opener.
- `testMarkerAfterTheLastRunKeepsRawFrame` — rule 0.

Plan additions:
- `testMarkerAlreadyInAnInterRunGapKeepsRawFrame` — rule 0 between runs, not approximate.
- `testAllRunsTimedUsesPerRunGaps` — intra-record gaps between timed runs are candidates.
- `testOverlappingIntervalsAreMergedBeforeGapsAreComputed`
- `testSnapNeverLandsFurtherThanTheWindowFromTheRawFrame` — a huge gap clipping the
  window edge: snapped frame stays within ±windowFrames (the intersection-midpoint
  rule pinned).
- `testRawFrameIsNeverMutated` — `snapped.marker == markers` input, byte-for-byte.
- `testWindowConstantConvertsToFrames` — `windowFrames(sampleRate: 48_000) == 72_000`,
  `windowFrames(sampleRate: 16_000) == 24_000`.
- `testUnknownKindMarkersPassThroughSnapping` — kind-agnostic.
- `testEmptyTranscriptSnapsNothingButReturnsEveryMarker` — no intervals → every marker
  rule-0 exact at its raw frame (T8's "markers outlive any transcript": with *no*
  intervals every frame is outside them). Note: design §7's "no transcript → promotion
  assigns nothing" is T7's read-layer behavior, not this function's — this function is
  total.

### Red/green evidence

Red: stub `intervals` returning `[]` and `snap` returning raw/approximate for
everything, run

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' test -only-testing:RaconteTests/MarkerSnappingTests
```

paste the red. Implement to green.

Mutation checks (each must fail its named test; revert after):
1. "largest gap" → "first gap found" → `testMarkerInsideSpeechSnapsToTheLargestGapInWindow`.
2. Drop the tie rule (keep whichever came first) → `testEqualGapsResolveToTheNearestOne`.
3. Snap to full-gap midpoint instead of intersection midpoint →
   `testSnapNeverLandsFurtherThanTheWindowFromTheRawFrame`.
4. Treat an untimed run as `[0, 0]` instead of falling back to the record range →
   `testUntimedRunFallsBackToRecordLevelRange`.

Full suite green; commit:
`capture: MarkerSnapping — pure gap-snap of raw marker frames (T6 §14 step 6)`.

### Subagent prompt — step 6

```
You are implementing step 6 of docs/plans/2026-08-05-structure-markers-implementation-plan.md
in the raconte repo. Read the plan's §0.3.7 + Step 6 and the design doc's §6 (snapping
rules) and §7 (failure modes). Types you consume, read first: StructureMarker
(Raconte/Capture/StructureMarker.swift), TranscriptResult
(Raconte/Transcription/TranscriptionEngine.swift:15-62) and TranscriptRun
(Raconte/Transcription/TranscriptRecord.swift:39-55 — per-run captureFrameStart/End are
OPTIONAL: Apple documents runs need carry no time range; that is what the record-level
fallback exists for).

Task: new file Raconte/Capture/MarkerSnapping.swift, exact API in the plan
(snapWindowSeconds = 1.5 as the single named constant; windowFrames(sampleRate:);
SpokenInterval; SnappedMarker; intervals(fromCommitted:); snap(markers:intervals:windowFrames:)).
Pure functions only — no I/O, no actor, no clock, no import beyond Foundation. The raw
marker frame is never mutated; snapping output is a separate snappedFrame. Rules 0-4 and
the intersection-midpoint/tie details are spelled out in the plan — follow them exactly.

TDD: write RaconteTests/MarkerSnappingTests.swift with all fifteen tests named in the
plan's Step 6 FIRST, against stubs (intervals → [], snap → raw/approximate);
`xcodegen generate`; run
`xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' test -only-testing:RaconteTests/MarkerSnappingTests`
and CAPTURE the red. Implement to green; run the FULL suite; then run the four mutation
checks in the plan (each must fail its named test) and revert them.

Do not commit. Report: diff, red output, green output, four mutation results.
```

---

## Step 7 — deferred to T7 (recorded, not built)

Nothing in this plan renders or edits the voice attribute. What T7 inherits:

- `MarkerLogReader.load(captureDirectory:)` — and its three answers. `.unreadable` ⇒
  promotion assigns **no** voice attributes; never assume single-voice from a failed
  read (design §7, the `journals.json` lesson).
- `MarkerSnapping` + the `approximate` flag to surface, and mis-tap editing (there is
  deliberately no capture-time undo — owner decision 6; T7 must handle mis-taps
  regardless).
- `EntryMetadata.multiVoice` / `EntryListItem.multiVoice` for rendering decisions;
  voice rendering itself (typeface instinct: print vs cursive) is T7's call (design §10).
- T8 retranscription re-applies markers to the new transcript via the same pure snap —
  markers outlive any given transcript by construction.

## Verification checklist for the first machine with Xcode

1. `git fetch && git checkout <build branch> && xcodegen generate`.
2. Confirm the map baseline: this plan's line numbers assume `1f2a44b5`; if main has
   moved, re-check the four seams (tee construction at `CaptureCoordinator.swift:364`,
   `resetCaptureWiring`, `handlePhase`'s `.recording` arm, `EntryMetadata.init(from:)`)
   before trusting any edit anchor.
3. Run the full unit suite once *before* step 1 to establish the baseline count
   (632 expected as of `1f2a44b5`).
4. Execute steps 1→6, each as a subagent build with the prompt above, parent diff
   review before each commit, red output demanded every time.
5. After step 5, run the full `RaconteUI` simulator suite, not just the new test.
6. Device pass (owner, phone): record a real two-voice page — the ±1.5 s window
   (design §10) gets tuned from that recording, in `MarkerSnapping.snapWindowSeconds`
   only.
