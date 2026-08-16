> **Archived — shipped.** Scratch task list from the M1/M2 era (#6 scrubbing, M2 T1); superseded by the M2 and M3 builds.

# Next two tasks — scrubbing (#6) and M2 T1

Planned 2026-07-30 by subagents reading the real sources. Both are ready to execute cold:
everything needed is here, no session memory required. Line numbers verified against HEAD
at the time of writing (`8103e5f` + the cue/timestamp commit) — re-grep names if they drift.

---

## Stale line numbers in the M2 design doc

`docs/plans/2026-07-30-m2-transcription-design.md` was written before `8103e5f` (startCue).
Verified mapping for the citations that matter:

| design doc | actual HEAD | what |
|---|---|---|
| `:85` | `:88` | `private var pendingCaptureID` |
| `:86` | `:89` | `private var currentFormat` |
| `:89` | `:92` | `private var currentForwarder` |
| `:158` | `:163` | `send(.record(captureID:))` |
| `:292` | `:301` | `let forwarder = PCMForwarder()` — the one construction site |
| `:353` / `:363` | `:362` / `:372` | resume guard / resume `recorder.start` |
| `:416` | `:425` | `enqueueFinalize` in `completeCapture()` |
| `:447` | `:456` | pump's `for await item in forwarder.stream` |
| `:462` / `:466` | `:471` / `:475` | `flushPump()` / `finishPump()` |
| `:512-519` | `:521-528` | `resetCaptureWiring()` |
| `:608-642` | `:617-651` | `PCMForwarder` |

`CaptureView.swift`: `CaptureScreenModel` is `:44-186`, `init` `:63-82`, `live()` `:86-102`,
`spawn` closure `:70-79`, `finishCurrentCapture()` `:152-159`. `UITestSupport.swift:10-21`
is unchanged.

---

# Task A — playback scrubbing (issue #6)

Goal: drag a handle to any point in a finished recording; see position / total.

## Ground truth

Two playback paths, chosen by `PlayableSourceSelector.select` (`CapturePlayback.swift:21-29`):

- **m4a path** — `AVAudioPlayer` (`CapturePlayback.swift:157-161`). `currentTime` is
  settable, so **seek is one line.** Don't overbuild it.
- **raw path** — `SegmentPlayer` = `AVAudioEngine` + `AVAudioPlayerNode` with whole-file
  buffers scheduled in index order (`SegmentPlayer.swift:74-92`). **No seek exists.**

Position plumbing: `CapturePlayback` is `@Observable` (`:68-73`); a `Task` polls every 50 ms
while playing (`:173-181`) and writes `currentTime` in `tick()` (`:183-202`). Ticker created
in `play()` (`:119`), cancelled in `pause()`/`stop()` (`:127`, `:136`).
`PlaybackProgressLine` (`UI/PlaybackProgressLine.swift:10-20`) is a read-only `ProgressView`,
used by `FinishedRow` (`CaptureView.swift:325-327`) and `RecoveryBanner` (`:44-46`), rendered
only once `playback != nil` — i.e. after the first Play tap.

`AVAudioPlayerNode.scheduleSegment` needs an `AVAudioFile`; segments are headerless flat
Float32 read by hand (`SegmentPlayer.loadBuffer`, `:95-109`). So seeking the raw path means
`scheduleBuffer` with a partially-loaded buffer: find the segment containing the target
frame, load only `[offset..<frameCount]` of it, then schedule later segments whole.

## Steps

**A1 — pure seek math.** New `Raconte/Capture/PlaybackSeek.swift`, styled after
`SegmentLayout.swift:3-6` (pure enum of statics):

```swift
struct SegmentSeekPlan: Equatable, Sendable { var position: Int; var frameOffsetInSegment: Int }
enum PlaybackSeek {
    static func plan(frameCounts: [Int], globalFrame: Int) -> SegmentSeekPlan?
    static func clampFrame(_ f: Int, totalFrames: Int) -> Int
    static func frame(forSeconds: Double, sampleRate: Double) -> Int
}
```

**Walk cumulative `frameCount`, never `startFrameOffset`.** `rawSegments` takes
`startFrameOffset` from the sidecar (`CapturePlayback.swift:43`) and the planner tolerates
gaps in that chain, but `SegmentPlayer.totalFrames` (`:27`) and the rendered audio are the
concatenation of `frameCount`s. Using `startFrameOffset` desyncs the playhead wherever a gap
exists. `position` is the index *into the ordered array*, not `segment.index`.

Tests (`RaconteTests/PlaybackSeekTests.swift`): frame 0; mid-segment; exact boundary → next
segment offset 0; last frame; `>= total` → nil; empty array → nil; zero-frame segments
skipped so boundaries don't drift; seconds→frames rounding. CI-testable, commit alone.

**A2 — `SegmentPlayer.seek(toFrame:)`.**

1. Range-limited loader beside `loadBuffer` (`:95`):
   `loadBuffer(url:format:frameOffset:frameCount:)` via `FileHandle` seek or
   `Data(contentsOf:options:.mappedIfSafe)` + subrange. Byte math through
   `DirectorySnapshot.bytesPerFrame(format)` (`DirectorySnapshot.swift:84-94`), not a
   hardcoded 4. Refactor `loadBuffer` to call it with offset 0.
2. Add `private var seekBaseFrame = 0` and `private var generation = 0`.
3. Rewrite `restart()` (`:74`) as `schedule(fromFrame:)`; `restart()` = `schedule(fromFrame: 0)`.
4. `seek(toFrame:)`: clamp → capture `wasPlaying = node.isPlaying` → `generation &+= 1` →
   `node.stop()` → `seekBaseFrame = target` → `didFinish = false` →
   `schedule(fromFrame: target)` → `scheduled = true` → if `wasPlaying` restart engine + play.
5. **Generation guard on the completion callback** (`:83-86`). `node.stop()` fires pending
   `.dataPlayedBack` handlers, so without `guard gen == self.generation else { return }` the
   first seek instantly sets `didFinish = true` and the UI snaps to the end. This is the
   most likely bug in the whole feature.
6. `currentTime` (`:41-46`): add `seekBaseFrame`; return `Double(seekBaseFrame)/sampleRate`
   in the guard-else instead of `0`, so a seek-while-paused reads back correctly.
7. `stop()` (`:65`) resets `seekBaseFrame = 0` and bumps `generation`.
8. Expose `var currentFrame: Int` and `func seek(toFrame:)`; seconds live in `CapturePlayback`.

Testable without hardware: the partial loader (write a known ramp `.pcm`, assert
`frameLength` and samples at the offset) and that seek leaves `didFinish == false` with
`currentTime ≈ target` while stopped.

**A3 — one position abstraction on `CapturePlayback`.** Do **not** add a protocol —
`CapturePlayback` already *is* the path-agnostic surface and already switches on `source` in
three places (`:110-117`, `:154-168`, `:184-201`). A protocol would need a retroactive
`@MainActor` conformance on `AVAudioPlayer` for one settable property. Extend instead:

```swift
func seek(to time: TimeInterval)
func beginScrubbing()
func endScrubbing(at time: TimeInterval)
private(set) var isScrubbing: Bool
```

- `seek` switches: m4a → `m4aPlayer?.currentTime = t`; raw → `segmentPlayer?.seek(toFrame:)`;
  `.none` → no-op. **Always set `self.currentTime = t` synchronously** or the slider snaps
  back to the stale value on drag end.
- `beginScrubbing` must route through the existing `pause()` (`:122-128`) so the ticker is
  cancelled. Do not invent "paused but `isPlaying == true`": `tick()`'s m4a branch reads
  `!player.isPlaying` as end-of-file and slams `currentTime = duration` (`:188-191`).
- `endScrubbing` resuming must call `play()`, not `m4aPlayer?.play()`, so
  `ensurePlaybackSession()` (`:143-150`) still runs on iOS — otherwise the cold-launch
  inaudible bug returns.
- Belt-and-braces `guard !isScrubbing` at the top of `tick()`.

Tests: extend `CapturePlaybackTests.swift`, reusing the real-encode fixture at `:129-151`.
Seek without ever calling `play()`; assert `currentTime` and the underlying player agree.
Clamp tests (`-5` → 0, `999` → duration). A raw-segments seek test over `.pcm` fixtures.

**A4 — scrubber UI.** Turn `PlaybackProgressLine` into the scrubber (keep the name; both
call sites keep working). Use **`Slider(value:in:onEditingChanged:)`**, not a custom
`DragGesture`: one implementation for both platforms, `onEditingChanged` is exactly the
begin/end signal needed to suspend the ticker and to avoid re-seeking the raw path on every
drag delta (each raw seek re-reads and re-schedules every remaining segment), plus free
`.adjustable` a11y and `XCUIElement.adjust(toNormalizedSliderPosition:)` for UI tests.

```swift
@State private var scrubValue: Double?
Slider(value: Binding(get: { scrubValue ?? min(playback.currentTime, playback.duration) },
                      set: { scrubValue = $0 }),
       in: 0...max(playback.duration, 0.01),
       onEditingChanged: { editing in
           if editing { playback.beginScrubbing() }
           else { playback.endScrubbing(at: scrubValue ?? playback.currentTime); scrubValue = nil }
       })
```

- Range must use `playback.duration` (decoded, `:160`), **not** `recording.durationSeconds`
  (manifest frames, `CaptureView.swift:172-175`) — AAC priming makes them differ by up to
  the 0.5 s tolerance asserted at `CapturePlaybackTests.swift:150`, and the handle couldn't
  reach the end.
- Never write `playback.currentTime` from the binding's `set` (that's a mutation during view
  update on an `@Observable`); only from `endScrubbing`.
- Identifiers follow `<surface>.<element>`: add `var idPrefix: String = "finished"` to
  `PlaybackProgressLine` (it already takes a defaulted `tint`, `:8`), pass `"recovery"` from
  `RecoveryBanner.swift:45`. Emit `"\(idPrefix).scrubber"`, `.position`, `.total`.
- **Do not reuse `finished.duration`** for the total: `CaptureUITests.swift:36-38` counts
  rows by that identifier, so a second element with it breaks three existing tests.
- Optional: render the scrubber before the first Play tap by extracting `ensurePlayback()`
  from `toggle()` (`:346-350`) and calling it from `onEditingChanged(true)`. If fiddly, ship
  play-first and file a follow-up — the drag is the ask.

**A5 — UI test + manual.** Add to `RaconteUITests/CaptureUITests.swift`: record ~3 s over
the synthetic recorder → play → `app.sliders["finished.scrubber"].adjust(toNormalizedSliderPosition: 0.5)`
→ assert `finished.position` reads about half of `finished.total`. **Assert on the label,
not audibility** — `SegmentPlayer.play()` swallows engine-start failures (`:55-58`) and a
headless sim may have no route. Because `endScrubbing` writes `currentTime` synchronously,
the label assertion holds with no audio at all.

That covers the m4a path only. The raw path is unreachable from UI tests (`bootstrap` drains
the finalize queue at launch, `CaptureView.swift:120`), so raw-path scrubbing is manual —
add it to the smoke doc.

## Sharp edges

1. Stale completion callbacks (`SegmentPlayer.swift:83-86`) — the generation guard above.
2. Node clock resets on `stop()` (`:43-45` reads `sampleTime` raw) — hence `seekBaseFrame`.
3. `currentTime` returns 0 when nothing renders (`:44`) — seek-while-paused reads back 0.
4. `play()` re-schedules from zero if `didFinish || !scheduled` (`:52`) — seek must leave
   `scheduled == true`, `didFinish == false`.
5. Whole-file loads: `loadBuffer` does `Data(contentsOf:)` per segment (`:96`) and
   `restart()` loads *every* segment up front (`:78-90`). A 45-min capture is ~500 MB
   resident. Use `.mappedIfSafe` / range reads; only seek on drag *end*.
6. `restart()` silently skips unreadable/empty segments (`:79-80`) while `totalFrames` sums
   all declared counts (`:27`) — filter once at init and derive both from the same set.
7. `tick()`'s end-of-file heuristic (`CapturePlayback.swift:188-191`) fights any scrub that
   leaves the ticker running.
8. `finished.duration` identifier collision (above).
9. Two different totals (manifest frames vs decoded duration).
10. `loadBuffer` hardcodes Float stride and `floatChannelData[0]` (`:98-107`) though
    `commonFormat` maps four cases (`:111-118`) — keep the assumption, centralize byte math.
11. `ensurePlaybackSession()` only runs from `play()` (`:143-150`).

---

# Task B — M2 T1: TeeSink + coordinator seams

Scope per design §9: `TeeSink`, a tee stored property with teardown, published
`activeCaptureID` / `activeFormat`, factories threaded through the composition root. **No
transcriber.** T1 ends with a no-op second branch.

## The one thing that must not be missed

`grep -n 'PCMForwarder()\|recorder.start(sink' Raconte/Capture/CaptureCoordinator.swift`:

- `:301` — the only construction site, in `configureAndStart`
- `:304` — initial start, `matching: nil`
- `:372` — **resume start, `matching: format`, passing `forwarder` explicitly**

Install the tee at `:301-304` and leave `:372` alone and the second branch **silently dies
at the first interruption/route-loss resume**, with every disk test still green. Both start
sites must pass the tee, and there must be a regression test that proves it.

**Always build the tee, even with one branch.** A conditional creates two sink identities to
keep in sync across two start sites — exactly the bug above. One always-present tee makes
the shipping path the tested path. Cost: one loop over a 1-element array on the audio thread,
against the `Data` allocation already at `AudioEngineRecorder.swift:215`.

## B1 — `TeeSink` + `FrameRange`

New top-level `Raconte/Capture/TeeSink.swift`:

```swift
final class TeeSink: PCMSink {          // checked Sendable — see below
    let branches: [any PCMSink]
    init(branches: [any PCMSink]) { self.branches = branches }
    nonisolated func receive(_ chunk: PCMChunk) {
        for branch in branches { branch.receive(chunk) }
    }
}
```

- **Does not need `@unchecked Sendable`.** Its only stored property is
  `let branches: [any PCMSink]`, and `PCMSink` refines `Sendable` (`PCMSink.swift:21`), so a
  final class with only immutable Sendable storage satisfies checked `Sendable`. Contrast
  `PCMForwarder` (`:617`) and `LevelBox` (`:657`), which are `@unchecked` because they guard
  mutable state with `NSLock`. **Never add state to `TeeSink`** — a counter flips it to
  `@unchecked` plus a lock on the real-time thread for every capture. Say so in the comment.
- Must be top-level in its own file, not nested in the `@MainActor` coordinator — same
  reason `EngineRecording` is top-level (`CaptureCoordinator.swift:28-29`).
- `receive` may do nothing but iterate and forward, disk branch first. No lock, no
  allocation, no `Task {}`. `PCMChunk.data` is `Data` (COW), so fanning to N branches costs
  N retains.
- **"Disk branch first" is load-bearing, not cosmetic.** The tee runs on the caller's
  thread, so nothing preempts a slow branch — isolation comes purely from ordering: chunk N
  is on the pump's stream before the slow branch is entered. Document that.
- `PCMSink.receive` is **non-throwing** (`PCMSink.swift:22`), so design §8's "throwing
  branch" test doesn't exist as written. Implement it as an *internally-failing* branch that
  absorbs its error and no-ops.

New `Raconte/Capture/Models/FrameRange.swift` (no such type exists today); T3 reuses it for
`TranscriptRef.skippedRanges`:

```swift
struct FrameRange: Codable, Sendable, Equatable { var start: Int64; var end: Int64 }  // [start, end)
```

## B2 — `BoundedPCMSink` + drop ledger

Drops belong in the **branch**, not the tee: `PCMChunk` carries no frame offset, so a tee
counter can't label drops it didn't cause, and tee state costs a lock on the hot path.

The tee delivers every chunk to every branch unconditionally, so a branch that advances its
cursor by `chunk.frameCount` **on entry** has exactly the sidecar capture-frame axis —
including for chunks it then drops. That's what makes the gap expressible.

```swift
struct StampedChunk: Sendable { let chunk: PCMChunk; let startFrame: Int64 }

final class BoundedPCMSink: PCMSink, @unchecked Sendable {
    let stream: AsyncStream<StampedChunk>
    // continuation; NSLock; cursor: Int64; dropped: [FrameRange]; dropCount: Int
    // init(capacity:) uses AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(capacity))
    nonisolated func receive(_ chunk: PCMChunk) {
        // lock: start = cursor; cursor += frameCount; unlock
        // switch continuation.yield(StampedChunk(chunk:startFrame:))
        //   .enqueued -> done;  .dropped/.terminated -> recordDrop(FrameRange(start, start+frames))
    }
}
```

**Use `.bufferingOldest`, not `.bufferingNewest`.** With `bufferingOldest`, `.dropped`
returns the element just yielded, so the recorded range is the current chunk's — no eviction
bookkeeping. `bufferingNewest` evicts the *oldest*, punching a hole mid-stream and forcing
two converter restarts per burst in T2.

`recordDrop` coalesces with the last range when contiguous. Hold the lock for a few
instructions only; the T2 drain side must never hold it across an `await`.

Tests: `capacity + K` chunks with no drain → `dropCount == K`, **one coalesced**
`FrameRange`, `ingestedFrames == (capacity+K)*F`. Then drain, feed more, assert the next
`StampedChunk.startFrame` jumped by the dropped amount — the gap is expressed, not
compressed. Two separated bursts → two non-contiguous ranges.

## B3 — coordinator wiring

Add after `:92`:

```swift
/// Fan-out installed on the tap: disk branch first, then any injected secondary. Always
/// present during a capture, even with one branch, so both `recorder.start` sites pass
/// the same object.
private var currentTee: TeeSink?
```

`currentForwarder: PCMForwarder?` **stays as-is** — `.stream` (`:456`), `.flush()` (`:471`),
`.finish()` (`:475`), `.resumeBarrier` (`:463`) all keep working untouched. That's the
"disk code untouched" property that makes the bit-identity test meaningful.
`beginRecording`'s guard (`:320-321`) must keep using `currentForwarder`, not the tee —
`startPump` (`:453`) needs `PCMForwarder.stream`.

- `configureAndStart` (`:289-317`): build `forwarder`, call
  `makeSecondarySink?(captureID)`, build `TeeSink(branches: [forwarder] + secondary)`, pass
  the tee to `recorder.start` at `:304`. Assign `currentTee` at `:313-315` alongside the
  other two, after the start and format guards pass.
- `rebuildAndReacquire` (`:358-376`): guard on `currentTee` at `:362`, pass the tee at `:372`.
  Safe to drop `currentForwarder` from that guard — all three are set and cleared together.
- `resetCaptureWiring()` (`:521-528`): add `currentTee = nil`.

Publish the IDs by **renaming** the private stored properties into the observable block
(`:52-64`) — grep confirms zero external references:

| property | set at | cleared at |
|---|---|---|
| `activeCaptureID` | `:242`, `case .record(let id)` in `realize` — after `phase` publishes `.preparing`, before any disk exists | `resetCaptureWiring()` `:526` |
| `activeFormat` | `:315`, after the `captureFormatDescriptor` guard, just before `send(.engineReady)` | `resetCaptureWiring()` `:525` |

Update the other use sites: `:320-321`, `:362`, `:425`.

**`activeFormat` is never re-set on resume** — `:372` pins `matching: format` and the tap
resamples (`AudioEngineRecorder.swift:188-201`), so emitted `PCMChunk.sampleRate` is
invariant. That's the invariant design §2 depends on; don't add a re-set.

## B4 — factory threading (match the `startCue` pattern)

Trailing optional param with `= nil` on both inits, stored `private let`, captured by
`spawn`, supplied only from `live()`. Every existing call site keeps compiling.

`CaptureCoordinator.swift`, beside `StoreFactory` (`:44`):

```swift
/// Builds an optional second `PCMSink` branch, fanned alongside the disk branch by
/// `TeeSink`. `@MainActor` (not `@Sendable`) so the owner can retain the product — the
/// transcription session outlives the coordinator (design §4). The format is NOT a
/// parameter: it is unknown until `recorder.start` returns. Read `activeFormat`.
typealias SecondarySinkFactory = @MainActor (_ captureID: String) -> (any PCMSink)?
```

Then: property after `startCue` (`:83`), init param after `startCue:` (`:113`), assignment
after `self.startCue = startCue` (`:123`). `CaptureScreenModel.init` (`:63-82`) takes it
after `startCue:` (`:67`); `spawn` (`:70-79`) captures and forwards it. `live()` unchanged
in T1 — T4 supplies the real arguments. `uiTestHarness()` (`UITestSupport.swift:16-20`) gets
`makeSecondarySink: { _ in NoOpPCMSink() }`, one line, so the simulator suite drives
record→finalize→relaunch with a two-branch tee over `SyntheticRecorder`.

Judgment call, `TranscriptionEngine` in T1: declare the protocol only (design §4), no
implementations, no consumers, in `Raconte/Transcription/TranscriptionEngine.swift`, plus
`TranscriptResult`. It forces `import Speech` under strict concurrency in the smallest
commit and churns the composition-root signature once. Escape hatch: if `import Speech`
fights strict concurrency, drop it to T2 — 8 call sites, all defaulted. Don't ship an empty
placeholder.

## B5 — tests

**Bit-identity.** Run the identical capture script over two roots and compare. Harness edits
needed in `CaptureCoordinatorTests.swift`: `makeCoordinator` (`:89-105`) hardcodes `root`
(`:93`) and `mintCaptureID` (`:102`) — add `capturesRoot:` and `makeSecondarySink:` params;
`decodeManifest` (`:118-122`) / `decodeSidecar` (`:124-129`) need a `root:` param.
**`FakeRecorder.feed` writes all-zero `Data` (`:57`)**, so `sha256Prefix` is constant and
would pass vacuously — add a nonzero pattern.

Assert per segment: PCM bytes byte-equal across roots; sidecar `frameCount`,
`startFrameOffset`, `byteCount`, `sha256Prefix`, `closedReason`, `format` equal; manifest
`state`, `segmentCount`, `lastKnownFrameOffset` equal. **Don't compare encoded JSON** —
`createdAt`, `stateUpdatedAt`, `wallClockStart`, `startHostTime` are clock-derived.

Run the B side three ways: no-op branch, slow branch (~50 ms per `receive`), internally
failing branch. All three produce identical bytes. `FakeRecorder.feed` is synchronous so
this is deterministic, not timing-dependent.

`TeeSinkTests.swift`: fan-out order (disk branch's entry for chunk N precedes the second
branch's, for every N — the honest form of "can't stall the disk branch"); every branch sees
every chunk; a failing branch is invisible to the others; zero- and one-branch tees.

Coordinator-level: **tee survives resume** — extend
`testResumeContinuesSameCaptureGapFree` (`:187-216`) or
`testRouteLostAutoResumesOntoNewDevice` (`:220-249`) with a counting secondary; assert it got
both the pre-interruption 750 frames and the post-resume 250. Without the `:372` edit this
fails at 750. Also `activeCaptureID`/`activeFormat` lifecycle, and that the factory is called
once per capture and not at all on the permission-denied path (`:333-344` returns at `:290`).

## Steps and verification

Each independently committable and green alone. `xcodegen generate` is mandatory after any
step that adds a file (`project.yml:38,68` are directory globs, `*.xcodeproj` is gitignored).

1. **B1** `TeeSink` + `FrameRange` + `TeeSinkTests` — no coordinator changes.
2. **B2** `BoundedPCMSink` + drop ledger — still no coordinator changes.
3. **B3** coordinator wiring + published IDs + the bit-identity, resume-survival, and
   lifecycle tests.
4. **B4** composition-root threading; `uiTestHarness` no-op secondary; optional protocol file.

Build/test (from CLAUDE.md):

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' test
xcodebuild -project Raconte.xcodeproj -scheme RaconteUI -destination 'platform=iOS Simulator,name=iPhone 17' test
```

## Sharp edges

1. **`:372` is the whole ballgame** (above).
2. Design-doc line numbers are stale — use the table at the top of this file.
3. **The format isn't available when the sink is built.** `recorder.start` (`:304`) needs
   the sink; `captureFormatDescriptor` is only readable after it returns (`:309`). Factory
   gets the captureID only; the format arrives via `activeFormat`.
4. **`activeCaptureID` is nil by the time the finalize-queue observer runs.**
   `enqueueFinalize` (`:425`) and `resetCaptureWiring()` (`:428`) are in the same synchronous
   `completeCapture()` body, and the `.onChange` relay (`CaptureView.swift:268`) schedules a
   `Task`. An owner must latch the ID at the preparing→recording edge.
5. **Factory side effects leak on prepare-failure paths.** If `recorder.start` throws
   (`:305-308`) or the format is nil (`:309-312`), `configureAndStart` returns without
   assigning `currentTee` and a produced sink just deallocates. Harmless in T1; in T2 the
   factory starts an analyzer, so it will need explicit abandon. Note it in code now.
6. `TapProcessor`'s single-caller contract (`AudioEngineRecorder.swift:115-122`) still holds
   — the tee is downstream of `process(_:)`, but runs on the same RT thread with the same
   rules.
7. `SyntheticRecorder` calls the sink from a detached Task (`UITestSupport.swift:49-64`) and
   `FakeRecorder.feed` from the test's main actor (`:55-59`) — a `Task.sleep` branch will
   visibly slow the UI suite. Keep harness branches cheap.
