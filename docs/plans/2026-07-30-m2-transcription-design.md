# Milestone 2 — Live transcript + reconciliation (design)

Status: design, not implemented. Written 2026-07-30 against Xcode 26.6 (17F113),
iPhoneOS26.5 / MacOSX26.5 SDKs. Rev 2 — rev 1 was reviewed against the SDK and against the
M1 sources; two of its decisions broke and are replaced here (§2 timestamps, §3 durability),
and three live M1 bugs it surfaced are filed as issues #7/#8/#9.

**Line numbers in this document predate commit `8103e5f` (startCue) and are stale by ~3–9
lines in `CaptureCoordinator.swift` and ~25 in `CaptureView.swift`.** Type and function
names are correct; grep for those rather than trusting a line. `docs/plans/2026-07-30-next-tasks.md`
carries a verified mapping.

Prior art being deliberately *not* repeated: the frozen web app (`~/src/recountly`) stored
one flat `transcript text` column per entry, treated the transcript as authoritative and
audio as best-effort, had no timings, no revisions, and no way to re-transcribe — its
`PATCH` route had no `transcript` field at all, so nothing could ever repair a bad
transcript. Every one of its long-running bugs (#23/#52/#54/#69) followed from that.
Raconte inverts the polarity.

---

## 0. The governing rule for this milestone

**Transcription is derived. It may fail, lag, or be abandoned at any moment without
affecting the capture.**

Three consequences the rest of this document obeys:

1. The transcriber **never sends events into `CaptureMachine`.** No new states, events, or
   effects. M2 leaves `CaptureMachine.swift` untouched. A transcriber that throws, stalls,
   or is never started must be invisible to the recording path.
2. The transcriber is a **second consumer of the same PCM chunks**, not a stage in the write
   path. It can never delay, reorder, or drop a chunk on its way to disk.
3. **Post-hoc retranscription from `final/recording.m4a` is the correctness guarantee; live
   transcription is a latency optimization.** Anything the live pass misses — crash, missing
   model, unsupported locale, backgrounding, the iOS two-instance limit — is recoverable by
   re-deriving from audio. That is what makes best-effort live transcription safe.

---

## 1. SDK facts this design rests on

Verified in
`iPhoneOS26.5.sdk/…/Speech.framework/Modules/Speech.swiftmodule/arm64e-apple-ios.swiftinterface`
and the macOS counterpart. The two differ only in the module-flags line — every declaration
is identical, so there is no platform divergence in this API.

- `SpeechAnalyzer` is a `final public actor`; `SpeechTranscriber` a class conforming to
  `SpeechModule`. All `@available(macOS 26.0, iOS 26.0, *)`. Swift-only overlay; no ObjC
  headers. Deployment targets are already 26.0 on both platforms, so no availability gating.
- Audio goes in as an `AsyncSequence<AnalyzerInput>`, where
  `AnalyzerInput(buffer: AVAudioPCMBuffer, bufferStartTime: CMTime?)`.
- **The analyzer does not convert audio.** Buffers must already be in a format from
  `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:considering:)`, which returns
  `nil` while assets are missing. Wrong format throws `SFSpeechError.Code.unexpectedAudioFormat`;
  non-monotonic timestamps throw `.audioDisordered`; resource exhaustion throws
  `.insufficientResources`.
- **Gaps are expressed by `bufferStartTime`, and only by it.** From the `SpeechAnalyzer`
  docs: "To skip past part of an audio stream, omit the buffers you want to skip from the
  input sequence… pass the later buffer's time-code within the audio stream as the
  `bufferStartTime` parameter of the later `AnalyzerInput`." A `nil` `bufferStartTime` means
  "immediately after the previous buffer." This is load-bearing for §2.
- Results: `SpeechTranscriber.results` is `some Sendable & AsyncSequence<Result, any Error>`.
  `Result` carries `range: CMTimeRange`, `resultsFinalizationTime: CMTime`,
  `text: AttributedString`, `alternatives: [AttributedString]`, with `isFinal` ≡
  `resultsFinalizationTime >= range.end`.
- **A volatile result is not guaranteed to be reissued as final** — "there is no guarantee
  that this result will be reissued with this property set to `true`." Finalization must be
  driven by `resultsFinalizationTime`, which finalizes *all* prior results whose range
  predates it. Never wait for a matching final per range.
- An empty `text` inside the volatile range **revokes** prior results for that range.
- Timing and confidence are `AttributedString` run attributes:
  `AttributeScopes.SpeechAttributes.TimeRangeAttribute` (`Value = CMTimeRange`) and
  `.ConfidenceAttribute` (`Value = Double`), gated on `ResultAttributeOption.audioTimeRange`
  / `.transcriptionConfidence`. The docs say "the associated transcription text" — they do
  **not** document run granularity as per-word. Word-level granularity is a VERIFY item, not
  a fact (§10.7).
- `SpeechTranscriber(locale:transcriptionOptions:reportingOptions:attributeOptions:)` — all
  four arguments required, all `Set<…>`. Presets:
  `timeIndexedProgressiveTranscription` = volatile + fast + audioTimeRange. **No preset
  enables `.transcriptionConfidence`**, and `.etiquetteReplacements` is the only
  `TranscriptionOption` case.
- `SpeechAnalyzer.Options(priority:modelRetention:)` with `.whileInUse / .lingering /
  .processLifetime`. `SpeechModels.endRetention()` is the counterpart to `.lingering`.
- `prepareToAnalyze(in:)` / `prepareToAnalyze(in:withProgressReadyHandler:)` does model
  setup up front "to reduce or eliminate delays in analyzing the first audio input."
- **Finishing the input sequence does not finish the session.**
  `finalizeAndFinishThroughEndOfInput()` "waits until the input sequence has terminated" —
  so the `AsyncStream` continuation must be finished *first* or it never returns.
  `cancelAndFinishNow()` is the abandon path.
- Assets: `AssetInventory.status(forModules:)` → `reserve(locale:)` (optional; auto-reserved)
  → `assetInstallationRequest(supporting:)?.downloadAndInstall()`, progress via a Foundation
  `Progress`. **Reservations are a limited, throwing resource**:
  `maximumReservedLocales` varies by device, exceeding it throws
  (`.tooManyAssetLocalesAllocated`, `.assetLocaleNotAllocated`,
  `.cannotAllocateUnsupportedLocale`), and `release(reservedLocale:)` must be called when a
  locale is no longer needed. Assets persist across launches and are shared between apps.
- **iOS caps concurrent analyzer instances at roughly two; macOS has no limit.** The limit is
  on instances allocated "to clients", so it is not purely self-inflicted. `SpeechAnalyzer.init`
  is non-throwing — the error surfaces at `start` / `analyzeSequence` / `setModules`.
- `SpeechDetector` is a VAD module that only functions alongside a transcriber.
  `DictationTranscriber` is the fallback where `SpeechTranscriber.isAvailable` is false or
  the locale is unsupported.
- Locale matching goes through `supportedLocale(equivalentTo:)`, not
  `supportedLocales.contains(_:)` — equivalent locales are not `==`.
- Swift 6 (`SWIFT_STRICT_CONCURRENCY: complete`) is not a problem: `AVAudioFormat`,
  `AVAudioConverter`, `AVAudioFile`, `AVAudioTime` are all `NS_SWIFT_SENDABLE`.
  `AVAudioPCMBuffer` is not, which is why `AnalyzerInput` is `@unchecked Sendable` — see the
  trap in §2.

Not knowable from headers, carried to §10: whether a fully on-device `SpeechAnalyzer` trips
the speech-recognition TCC gate (the new API has **no** authorization call anywhere; only
legacy `SFSpeechRecognizer.requestAuthorization` mentions
`NSSpeechRecognitionUsageDescription`), and whether the sandboxed macOS build needs
`com.apple.security.network.client` for `downloadAndInstall()`.

Noted so nobody copies it: Apple's own `SpeechAnalyzer` doc example uses
`preset: .offlineTranscription`, which **does not exist** in the shipped `Preset` type.

---

## 2. Where the audio forks, and what time it is

### The fork

Today there is one `PCMSink` and one consumer: `AudioEngineRecorder.start` takes a single
sink (`AudioEngineRecorder.swift:43`); `CaptureCoordinator` constructs one `PCMForwarder`
(`CaptureCoordinator.swift:292`). `TapProcessor` carries an explicit contract that no second
caller of `process(_:)` may be added (`AudioEngineRecorder.swift:115-122`).

**Decision: fork at the sink, not at the tap.** Add `TeeSink: PCMSink` fanning each
`PCMChunk` out to an ordered list, disk branch first.

Rejected: forking inside `TapProcessor` (adds work on the real-time thread, violates the
single-caller contract, and — decisively — bypasses `FakeRecorder` and the DEBUG
`SyntheticRecorder`, which produce chunks at the sink, so every mic-free harness would stop
covering the transcriber); a second consumer on `PCMForwarder.stream` (single-consumer, one
pump task at `CaptureCoordinator.swift:447` — a second consumer steals chunks rather than
duplicating them); subscribing off `SegmentStore` (couples transcription to disk I/O,
which §0 forbids). Note the tee is *not* an extra copy: `PCMChunk.data` is `Data`
(`PCMSink.swift:10`) — copy-on-write and immutable, so a branch costs a retain.

Wiring, concretely — this is more surgery than "pass a different sink":

- There is only **one** sink construction site, but **two** `recorder.start` sites. The
  resume path reuses the same forwarder object but passes it explicitly
  (`rebuildAndReacquire`: `guard let forwarder = currentForwarder`, then
  `recorder.start(sink: forwarder, …)`). A tee installed at the construction site does
  **not** carry across resume for free — the resume start site must pass the tee too, or
  the second branch silently dies at the first interruption with every disk test still
  green. This is the highest-risk line in T1 and it needs its own regression test.
- `currentForwarder` is typed `PCMForwarder?` (`:89`) and the coordinator uses
  `PCMForwarder`-specific API — `.stream` (`:447`), `.flush()` (`:462`), `.finish()` (`:466`),
  `.resumeBarrier` (`:454`). So the tee is a **new** stored property holding
  `TeeSink(branches: [forwarder, transcriptionSink])`, with the disk code untouched, and
  teardown added to `resetCaptureWiring()` (`:512-519`).
- `flushPump()`'s ordered barrier covers the disk branch only. **`coverageFrames` therefore
  cannot be read synchronously at `captured`** — it is whatever the transcription branch has
  ingested, read after its own drain (§4).

The transcription branch is non-blocking in the same sense `PCMForwarder` is: at most a
`continuation.yield`. It owns a bounded buffer and **drops on overflow, counting drops and
recording the dropped frame range**. Back-pressure never reaches the tap; a degraded live
transcript is repaired by retranscription.

### The clock

**Decision: `bufferStartTime` is derived from the capture-frame offset — the same axis the
segment sidecars use — never from an output-frame accumulator, and never from `AVAudioTime`.**

Rev 1 proposed counting frames the converter had emitted. That is wrong and it is the
mistake this section exists to prevent: an emitted-frame counter is *contiguous by
construction*, so it cannot express a gap. After any dropped chunk (overflow) or any
suspended stretch (§7 backgrounding), every subsequent timestamp would be early by exactly
the omitted duration and the transcript timeline would silently compress against the audio —
the same class of bug as issue #2 on the capture side. It would also be information-free:
a contiguous counter says nothing `nil` doesn't already say.

The scheme instead:

1. Maintain `ingestedCaptureFrames`, incremented by `chunk.frameCount` for **every** chunk
   the tee delivers, including ones the transcription branch drops or skips. This is the
   same quantity the sidecar `startFrameOffset` chain accumulates, so it is exactly the
   position in `final/recording.m4a`.
2. Rebuild an `AVAudioPCMBuffer` in the canonical format from `chunk.data`, then convert to
   `bestAvailableAudioFormat` with an `AVAudioConverter`. Conversion is near-certain —
   capture is Float32 mono at the *hardware* rate, typically 48 kHz.
3. Stamp `bufferStartTime = CMTime(value: runStartCaptureFrame + emittedInRun, timescale:
   canonicalSampleRate) - primingOffset`, where `emittedInRun` is scaled to canonical frames.
4. **On any discontinuity — an overflow drop, a background suspension, a resume — finish the
   current converter, start a fresh one, and open a new run at the true capture-frame
   offset.** The jump is then honest and the analyzer accounts for the skipped audio, per the
   SDK rule quoted in §1.

Monotonicity within a run is by construction, so `.audioDisordered` cannot occur; across
runs it holds because capture-frame offsets only increase. `primingOffset` is the converter's
constant latency; measure it once and assert it in a test rather than assuming zero (§10.6).

**Unifying consequence, worth stating plainly:** the transcript timeline *is* the capture-frame
timeline *is* the position in the finalized m4a. Live results and retranscription results are
therefore directly comparable without a mapping table. Wall-clock is a separate axis and is
not the transcript's business — that is issue #2's concern, not this milestone's (§7).

`PCMChunk.sampleRate` is invariant for the life of a capture: resume pins `matching: format`
(`CaptureCoordinator.swift:363` → `AudioEngineRecorder.swift:51-54`) and the tap resamples
(`:188-201`), so the emitted rate is always `outputFormat.sampleRate` (`:218`). The
transcription branch may rely on that and must not pretend to test a rate change it can
never observe.

**Trap:** `AnalyzerInput` is `@unchecked Sendable`, so the compiler will *not* stop an
implementer from handing the analyzer actor a reused scratch buffer — which is exactly the
house style on the disk path (`AudioEngineRecorder.swift:137,179-180`). **Allocate a fresh
`AVAudioPCMBuffer` per chunk in the transcription branch.** A reused one is a silent data
race with no diagnostic.

---

## 3. Where the transcript lives on disk

Constraint from M1: **`segments/` is deleted wholesale on finalize**
(`FinalizerWorker.swift:163`) and by `finishRawDelete` (`RecoveryExecutor.swift:60-62`).
`final/` survives. Nothing under `segments/` may hold a transcript.

```
captures/<captureID>/
  manifest.json
  segments/…                (deleted on finalize, as today)
  final/recording.m4a       (as today)
  transcript/
    live.jsonl              append-only; committed results only
    canonical-<n>.json      addressable revisions; n increments, never rewritten
```

`live.jsonl` is append-only. **Durability matches the audio path rather than exceeding it**:
`SegmentStore.append` does a plain `writeAll` with no fsync (`SegmentStore.swift:122-129`);
fsync happens at segment close (`:233`). The transcript writer does the same — buffered
appends, fsync at the same commit boundaries (segment close, capture end). A torn trailing
line is expected after a force-kill and is discarded on read; every complete prior line is
valid. No `.part` dance, because there is no rewrite. (Rev 1 said fsync-per-record: stricter
than the audio it describes, a synchronous barrier at speaking cadence, and self-defeating —
it would have made the torn-line case it planned for nearly unreachable.)

`canonical-<n>.json` goes through the existing `AtomicFile.replace`. Revisions are
append-only files in M2 and move into GRDB in M3 (`native-rebuild-plan.md:33`).

One record per committed (finalized) result:

```json
{ "seq": 12,
  "text": "…",
  "captureFrameStart": 1440000,
  "captureFrameEnd":   1483200,
  "analyzerStart": {"value": 480000, "timescale": 16000},
  "analyzerEnd":   {"value": 512000, "timescale": 16000},
  "runs": [ {"text":"hello","captureFrameStart":…,"captureFrameEnd":…,"confidence":0.93} ],
  "generator": "SpeechTranscriber",
  "locale": "en_US" }
```

Capture-frame fields are the durable, cross-revision truth. **`analyzerStart`/`analyzerEnd`
are revision-local and must not be compared across revisions** — `bestAvailableAudioFormat`
is asset- and device-dependent and can change after a model update, so a later
retranscription may run at a different rate entirely.

`runs` is the flattened `AttributedString` run attributes; it feeds the M3
`transcript_segments` table (`2026-07-29-data-model-and-migration.md:114`) and later
scrubbing (issue #6). It is not literally a superset of that table — `entryId` and
`revisionId` are assigned at M3 import time, since M2 has no entry concept and no database.

**Volatile results are never written to disk.** They exist only as a published property on
the main actor for the UI — the "volatile hypothesis (UI-only)" layer of
`native-rebuild-plan.md:25-28`.

### Manifest changes

```swift
struct TranscriptRef: Codable, Sendable, Equatable {
    var generator: String        // "SpeechTranscriber" | "DictationTranscriber"
    var locale: String
    var coverageFrames: Int64    // capture frames actually ingested by the transcriber
    var skippedRanges: [FrameRange]  // drops + suspensions, in capture frames
    var committedRecords: Int
    var completedAt: Date?       // nil while live / abandoned
    var latestRevision: Int?
}
var transcript: TranscriptRef?
```

`coverageFrames` + `skippedRanges` against `lastKnownFrameOffset` is the honest measure of
completeness and is what triggers a retranscription offer. Because the pump barrier does not
cover the transcription branch (§2), it is written after that branch drains, not at
`captured`.

**No `schemaVersion` bump.** `TranscriptRef` is optional, so v1 manifests decode under M2
code and vice versa. There is zero version handling anywhere in the codebase — a grep for
`schemaVersion` finds only the declaration (`Models/Manifest.swift:80`), the init default,
and two test assertions. A bump would break `SegmentLayoutTests.swift:163,169` and, worse,
`RecoveryExecutor.writeCapturedManifest` constructs `Manifest(...)` without passing it
(`RecoveryExecutor.swift:117-127`), so recovery would silently rewrite every pre-M2 manifest
as v2 with no migration step. Bump when there is something to migrate.

**Trap, must not be missed:** `writeCapturedManifest` reconstructs the manifest field-by-field
and carries over only `createdAt`, `interruptions`, and `final`. Any new field not added
there is **silently dropped on every crash-recovery path**. `transcript` must be added, with
a regression test — and the same test should cover `needsAttention`, `lastError`,
`retryCount`, `finalizeAttempts`, which are already being dropped today (issue #7).

`DirectorySnapshot`'s per-capture gather (`DirectorySnapshot.swift:126-171`, called from
`gather` at `:109-121`) reads only `manifest.json`, sidecars, and file sizes; extend it to
stat `transcript/` so recovery can distinguish complete / partial / absent. It must still
never parse PCM. `SegmentLayout` (`SegmentLayout.swift:59-101`) gains the `transcript/` path
builders — every path in the codebase goes through it.

**Blocked on issue #8:** `RecoveryPlanner` returns `.deleteCaptureDirectory` when the
manifest is missing *or corrupt* and no segment data remains (`RecoveryPlanner.swift:104-105`),
and the executor removes the whole tree (`RecoveryExecutor.swift:39-41`). For a *finalized*
capture `segments/` is already gone, so one corrupt manifest byte destroys
`final/recording.m4a`. That is a pre-existing M1 hazard; M2 doubles its blast radius by
putting the transcript in the same tree. Fix — never delete a capture directory containing
`final/` or `transcript/` — lands before T3.

---

## 4. The transcription session

New types, outside the capture state machine:

```swift
protocol TranscriptionEngine: Sendable {          // SpeechAnalyzer hides behind this
    func prepare(format: AVAudioFormat) async throws
    func start() async throws
    func ingest(_ input: AnalyzerInput) async
    func finishInput() async                       // terminate the input sequence
    func finalizeAndFinish() async throws          // only valid after finishInput()
    func abandon() async                           // -> cancelAndFinishNow()
    var results: AsyncThrowingStream<TranscriptResult, Error> { get }
}

actor TranscriptionSession {   // owns engine, converter, frame accounting, jsonl writer
}
```

`finishInput()` is separate and mandatory: `finalizeAndFinishThroughEndOfInput()` **waits for
the input sequence to terminate**, and finishing the `AsyncStream` continuation does not by
itself finish the session. Calling finalize without first finishing the stream hangs until
the bounded wait expires — on every single capture. `abandon()` exists because after that
bound the only correct call is `cancelAndFinishNow()`.

Session state, deliberately *not* a `CaptureMachine` phase:
`idle → preparing → running → finishing → done`, plus terminal `failed(Error)` and
`unavailable(Reason)`. Every failure is absorbing: stop ingesting, write what exists, leave
`TranscriptRef.completedAt == nil`, surface a non-blocking "transcript incomplete —
re-derive?" affordance. It never propagates.

Configuration:

- `SpeechTranscriber(locale:, transcriptionOptions: [], reportingOptions: [.volatileResults],
  attributeOptions: [.audioTimeRange, .transcriptionConfidence])`. That is *not* simply
  "`timeIndexedProgressiveTranscription` minus `.fastResults`" — no preset enables
  `.transcriptionConfidence`. Dropping `.fastResults` is a deliberate accuracy-over-latency
  call for a journaling app; the volatile stream already gives immediate feedback. Because
  this differs from any preset in two dimensions, the §10.5 A/B must vary one at a time.
- `SpeechAnalyzer.Options(priority: .utility, modelRetention: .whileInUse)`. `.lingering`
  (paired with `SpeechModels.endRetention()`) is worth measuring for back-to-back captures,
  but `.whileInUse` is the conservative default for occasional single-user use.
- Call `prepareToAnalyze(in:)` at capture start to avoid first-result latency.
- One module, so consolidation keys off `resultsFinalizationTime` and we ignore
  `analyzer.volatileRange` / `volatileRangeChangedHandler`. Those exist to combine *multiple*
  modules' volatile ranges; with one transcriber they add nothing. Stated so the choice is
  explicit rather than an oversight.
- No `SpeechDetector` in the first cut. Revisit if the battery measurement (§10.4) demands it.

### Ownership — the part rev 1 hand-waved

The claim "keyed to the captureID, held by a longer-lived owner" needs code that does not
exist. A longer-lived owner *does* exist — `CaptureScreenModel` (`CaptureView.swift:21-55`),
which already owns the finalizer across coordinator re-spawns (`:129`). But it cannot key
anything to a captureID today: the ID is minted **inside** the coordinator
(`CaptureCoordinator.swift:158`) into `private var pendingCaptureID` (`:85`), the format is
`private var currentFormat` (`:86`), and the sink is built inline (`:292`). The only ID the
owner ever sees is `finalizeQueue`, appended at `completeCapture()` (`:416`) — after the
capture is over, useless for a live session.

So T1/T2 include a small, explicit coordinator API change (no machine change):

- publish `activeCaptureID: String?` and `activeFormat: AudioFormatDescriptor?`;
- accept an injected secondary-sink factory, threaded through `CaptureScreenModel`'s `spawn`
  closure (`CaptureView.swift:44-52`) and through `live()` (`:59-74`) and the DEBUG
  `uiTestHarness()` (`UITestSupport.swift:10-21`);
- tear the tee down in `resetCaptureWiring()` (`:512-519`), leaving the session itself alive
  in the owner so it can drain after the coordinator is replaced.

Shutdown ordering matters and is not free: `finishCurrentCapture()`
(`CaptureView.swift:124-131`) runs encode → verify → `removeItem(segments/)` →
`coordinator = spawn()` with no window for a transcript flush. The transcript drain
(`finishInput()` → `finalizeAndFinish()` → bounded 5 s wait → else `abandon()`) runs
concurrently with finalize and writes `TranscriptRef` when it completes. It must not gate
finalize — losing the tail costs a re-derive, not the words. This is precisely the failure
recountly spent issue #69 on (`done-flush.ts`, an 8 s wait with an interim fallback); here it
is uninteresting by construction.

---

## 5. Retranscription from audio

`SpeechAnalyzer` has a file path:
`init(inputAudioFile:modules:options:analysisContext:finishAfterFile:volatileRangeChangedHandler:)`
and `analyzeSequence(from: AVAudioFile)`. After finalize, `final/recording.m4a` is complete
and verified, so retranscription is a pure function of it — and because the transcript
timeline is the capture-frame timeline (§2), its output is directly comparable to the live
pass.

Triggers:

1. Automatic when `coverageFrames` + `skippedRanges` show a material gap (proposal: >2 % or
   >2 s missing), or the live pass ended `failed` / `unavailable`.
2. Manual, always available on a finished entry.
3. Locale change — which must `release(reservedLocale:)` the old locale, since reservations
   are capped by `maximumReservedLocales` and exceeding it throws.

Each run writes a **new** `canonical-<n>.json`. Provenance per revision: `lastGeneratedAt`
and `lastUserEditedAt`. **Retranscription never silently replaces user-edited text** — where
they conflict it produces a diff for the owner to accept.

On iOS, respect the ~two-instance limit: retranscription must not start while a live capture
holds an analyzer, and it must handle `insufficientResources` thrown at `start` (not at
`init`, which cannot throw) since another process may hold instances too. Queue it behind
the finalize queue — which means `FinalizerWorker`'s `queue: [String]`
(`FinalizerWorker.swift:54`) grows a second job kind, or a sibling worker with the same
shape. That is real work, not a clause (T6).

---

## 6. Model assets and availability

1. `SpeechTranscriber.isAvailable`; if false → `DictationTranscriber`; if that is also
   unavailable → `unavailable(.noEngine)`, and the app still records perfectly. Nothing about
   M1 regresses.
2. Resolve locale via `supportedLocale(equivalentTo: Locale.current)`. If it returns a
   near-equivalent (different region), show a picker rather than silently accepting "colour"
   for "color".
3. `AssetInventory.status(forModules:)`; if not `.installed`, request installation and
   surface the `Progress`. `assetInstallationRequest(supporting:)` auto-reserves and **throws
   if that would exceed `maximumReservedLocales`** — handle it, and `release(reservedLocale:)`
   on locale change. No documented size API exists; `Progress.totalUnitCount` may or may not
   carry bytes — probe once in T4 before writing UI copy (§10.8), and until then say
   "downloading", not "downloading 240 MB".
4. Cache nothing about installation state: assets are shared system-wide and can be removed
   out from under us. Re-check `status` at each capture start.

`bestAvailableAudioFormat` returning `nil` is the runtime signal that assets are not ready —
treat as `unavailable(.assetsMissing)` and skip the live pass rather than starting a session
that will throw.

Info.plist: add `NSSpeechRecognitionUsageDescription` **defensively** (currently absent —
`project.yml` has only `NSMicrophoneUsageDescription`). The new API exposes no authorization
call, so it may be unnecessary; it costs nothing and its absence crashes the legacy API.
Confirm empirically in T4.

---

## 7. Issue #1 — background awareness, folded in

State today, verified: **no lifecycle handling exists at all.** `RaconteApp.swift:1-10` is a
bare `WindowGroup`; a grep for `scenePhase`, `didEnterBackground`, `ActivityKit`,
`UNUserNotification` across the target returns nothing relevant. Recording survives
backgrounding purely because of `UIBackgroundModes: [audio]` (`project.yml:45`), and the only
indicator is the system mic dot. Issue #1 calls that "probably not enough."

M2 raises the stakes: a live transcriber running unattended burns meaningfully more power
than a tap writing PCM.

**Decision: suspend live transcription while backgrounded; keep recording.** The backgrounded
stretch is recorded as a `skippedRange` and re-derived from audio afterwards at zero cost to
correctness. This removes the battery objection entirely, and is only sound because §2's
timestamps can express the gap and §0.3 makes the live pass optional. It needs the
scene-phase hook issue #1 needs anyway.

Awareness surfaces, in build order:

1. **Scene-phase plumbing + honest elapsed** — small, cross-platform, unblocks the rest. The
   elapsed clock is already wall-clock derived (`CaptureCoordinator.swift:488`), so it reads
   correctly on return.
2. **Live Activity, iOS only.** `ActivityKit` is `@available(macOS, unavailable)` on every
   declaration, so it can never be the Mac answer. Requires a **new WidgetKit extension
   target** (`ActivityConfiguration` only lives in a widget extension) plus
   `NSSupportsLiveActivities`. No push needed — the app is already alive under the audio
   background mode, so local `activity.update` suffices. Check
   `ActivityAuthorizationInfo().areActivitiesEnabled`. **The embed must be scoped to iOS in
   `project.yml`**, or the macOS build of this single multiplatform target will try to embed
   an iOS-only extension.
3. **`MenuBarExtra` on macOS** (`@available(macOS 13.0, *)`, `@available(iOS, unavailable)`):
   red dot + elapsed + stop.

Rejected: a local notification (a second permission prompt in a single-user app for strictly
less information than a Live Activity) and an auto-stop timeout (collides head-on with doc
test 4, which asserts a 10+ minute backgrounded recording must survive and finalize normally
— `m1-paranoid-tests.md:58-66`; any cap must be far above that and must stop-and-keep).

### Relationship to issue #2 — weaker than rev 1 claimed

Rev 1 made issue #2 a prerequisite. It isn't. A tap buffer dropped before `PCMChunk` is
removed from **both** branches identically, so the transcript↔capture-frame↔m4a mapping is
unaffected; only the wall-clock↔audio mapping skews. T1–T3 have no dependency on it, and it
is sequenced as ordinary parallel work rather than a blocker.

The larger and genuinely relevant gap problem is **issue #9**: interruption gaps are
unrecorded on disk. `SegmentStore` accumulates `cumulativeFrameOffset += frames`
(`SegmentStore.swift:259`) and `resumeRecording()` (`:155-159`) opens the next segment with
no gap accounting, while `InterruptionLogEntry.endedAt` / `.resumed` are **never written** —
`markInterrupted` is the only writer and passes `nil` for both (`SegmentStore.swift:146-147`).
So a 30 s phone call is invisible on disk. That does not break this design (transcript time is
audio time, which is legitimately gap-compressed), but it does mean nothing can reconstruct
real elapsed time, and it should be fixed while §7's scene-phase work is in the same code.

---

## 8. Testability

The existing harnesses cover the transcriber for free, given the fork is at the sink (§2):
`FakeRecorder.feed` pushes into the injected sink (`CaptureCoordinatorTests.swift:49,55-59`)
and so does the DEBUG `SyntheticRecorder` (`UITestSupport.swift:59`). CI already runs both
schemes (`.github/workflows/ci.yml`).

**Missing seam, must be added:** the UI-test composition root injects only
`makeSession` / `makeRecorder` / `encoder` (`UITestSupport.swift:16-21`). A fake
`TranscriptionEngine` needs a parameter on `CaptureScreenModel.init`
(`CaptureView.swift:38-55`) threaded through `live()` (`:59-74`) — same change as the
secondary-sink factory in §4, so do them together in T1.

Unit (CI, no hardware, no models):

- `TeeSink`: fan-out order; a throwing or slow branch cannot stall the disk branch; drops
  counted and their frame ranges recorded.
- Frame accounting: `ingestedCaptureFrames` advances on dropped chunks too; a discontinuity
  produces a new converter run with a jumped `bufferStartTime`; monotonicity across drops,
  suspensions, and resume; the constant `primingOffset` asserted (§10.6). Do **not** write a
  sample-rate-change test — resume pins the format, so the transcription branch can never
  observe one.
- Consolidation, against a scripted `TranscriptionEngine` fake: promotion driven by
  `resultsFinalizationTime`; a volatile result **never** reissued as final; an empty-text
  volatile result **revoking** a prior range; out-of-order arrivals. These are the SDK's
  documented sharp edges and all are reachable with a fake.
- Shutdown ordering: `finalizeAndFinish()` without a prior `finishInput()` must be a test
  failure, not a hang; the 5 s bound falls through to `abandon()`.
- `live.jsonl`: append-only, torn trailing line discarded, replay is deterministic.
- Manifest round-trip **including `writeCapturedManifest` carry-over** for `transcript` plus
  the four fields already being dropped (issue #7).
- Recovery: capture killed mid-transcription with a partial `live.jsonl` normalizes to
  `captured` with `completedAt == nil` and a retranscription flag; a capture directory
  holding `final/` or `transcript/` is never deleted (issue #8).

UI (simulator, `RaconteUI`): record → live text appears → finalize → transcript persists →
relaunch shows it, over the fake engine. The synthetic 440 Hz sine produces no words, which
is fine — the fake supplies the text.

**Not automatable, explicitly:** anything against the real `SpeechAnalyzer`. CI runners have
no model assets, so `bestAvailableAudioFormat` returns `nil` there. Real-engine verification
is device smoke only; say so in the smoke doc rather than implying coverage.

New smoke tests: speak → words appear live; kill mid-transcription → relaunch shows a partial
transcript, re-derive completes it; airplane mode with assets installed → still transcribes;
airplane mode without assets → records fine, transcription unavailable, no crash; background
2 min → recording intact, transcript re-derived over the gap; unsupported-locale path;
locale change twice → no reservation exhaustion.

---

## 9. Task breakdown (implementer-subagent sized)

- **T1** — `TeeSink`; new stored property + teardown in `resetCaptureWiring`; coordinator
  publishes `activeCaptureID` / `activeFormat`; secondary-sink and transcription-engine
  factories threaded through `CaptureScreenModel.spawn` / `live()` / `uiTestHarness()`. No
  transcriber yet. Test: the disk path is bit-identical with a no-op second branch.
- **T2** — `TranscriptionEngine` protocol + scripted fake + `TranscriptionSession` actor:
  converter runs, capture-frame accounting, discontinuity handling, shutdown ordering. No
  real SDK. All of §8's consolidation tests land here.
- **T2.5** — Issue #8 first (never delete a capture directory holding `final/` or
  `transcript/`) and issue #7 (`writeCapturedManifest` field carry-over). Both are live M1
  bugs; T3 writes into the tree they endanger.
- **T3** — `live.jsonl` writer/reader, `TranscriptRef` on the manifest (no `schemaVersion`
  bump), `SegmentLayout` paths, `DirectorySnapshot` extension, recovery-planner cases.
- **T4** — Real `SpeechAnalyzer` / `SpeechTranscriber` behind `TranscriptionEngine`;
  `AssetInventory` install flow with reservation limits and `release`; availability and
  locale resolution; `prepareToAnalyze`. First device run — settles the TCC and
  network-entitlement VERIFY items.
- **T5** — Live transcript UI: volatile ghost text visually distinct from committed text,
  committed text stable under revocation. (recountly's uncontrolled-`<textarea>` trick is a
  web workaround with no SwiftUI analogue — do not port it.)
- **T6** — `canonical-<n>.json` writer and its post-finalize hook (nothing owns this today —
  `FinalizerWorker` has no transcript concept); retranscription from `final/recording.m4a`;
  the coverage-gap trigger; a second job kind in the finalize queue so iOS respects the
  two-instance limit.
- **T7** — Editable canonical transcript with `lastUserEditedAt` / `lastGeneratedAt`
  provenance and the retranscription diff.
- **T8** — Issue #1: scene-phase plumbing, suspend-transcription-while-backgrounded, then the
  Live Activity target (iOS, embed scoped to iOS) and `MenuBarExtra` (macOS). Fix issue #9
  (`InterruptionLogEntry.endedAt`) here, same code.

Parallel, not a blocker: issue #2 (honor the tap's `AVAudioTime`, insert silence on
discontinuity) — needed for honest wall-clock, not for transcript↔audio alignment.

T1–T3 are pure-core and testable on CI. T4 is the first that needs the mini or the iPhone.

---

## 10. Open questions / VERIFY list

1. Does a fully on-device `SpeechAnalyzer` require `NSSpeechRecognitionUsageDescription`
   and/or trip a TCC prompt? No authorization API exists; unverifiable from headers.
   **Test on device in T4.**
2. Does the sandboxed macOS build need `com.apple.security.network.client` for
   `downloadAndInstall()`, or is the download brokered by a system daemon? **Test on the mini
   in T4.**
3. Model asset size and cold-device download time — no API exposes it.
4. Battery/thermal cost of live transcription over a 30-minute capture. Decides whether
   `SpeechDetector` VAD gating is needed and whether `.lingering` retention is worth it.
5. Does subtracting `.fastResults` produce latency the owner notices? A/B on device, varying
   one option at a time (the chosen config differs from every preset in two dimensions).
6. The converter `primingOffset` for the 48 kHz → analyzer-format path — measure once and
   assert it, rather than assuming zero.
7. **Is `TimeRangeAttribute` run granularity actually per-word?** The docs say only "the
   associated transcription text." §3's `runs` schema and issue #6 scrubbing both assume
   word-level. Check in T4 before the schema is depended on.
8. Does `AssetInstallationRequest.progress.totalUnitCount` carry bytes? One probe in T4
   decides the download UI copy.
9. `AnalysisContext.contextualStrings` is documented only for `DictationTranscriber` (cap:
   100 phrases across all tags). Whether `SpeechTranscriber` ignores it is an inference, not
   a documented fact — irrelevant to M2, relevant if biasing is ever wanted.
10. The ~50 entries migrating from Neon in M3 arrive as flat text with **no time offsets**,
    and 23 are paper-archive imports whose audio may not exist. Decide whether they get an
    explicit "unlinked provenance" class rather than being forced into the segment/timing
    model. Flagged now because the transcript schema is being set now; the migration is M3.
