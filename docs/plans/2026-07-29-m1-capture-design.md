# Milestone 1 — Indestructible local capture (design)

Date: 2026-07-29. Scope: capture only. NO transcription, NO sync, NO journals/folders.
Target: SwiftUI universal app (iOS 26 + macOS 26), multiplatform target, not Catalyst.
Env: Xcode 26.6, Swift 6.3.3. M1 has no iOS-26-only dependency (SpeechAnalyzer is M2).

Source root assumed `Recountly/`. Capture code under `Recountly/Capture/`. Names below are
proposals; adjust freely at scaffold time.

Verified against local SDK headers (2026-07-29):
- `AVAudioSession` is `API_UNAVAILABLE(macos)`. `AVAudioSessionInterruptionNotification`,
  `AVAudioSessionRouteChangeNotification`, `AVAudioSessionMediaServicesWereResetNotification`
  are all iOS-only.
- `AVAudioEngine` exists on both iOS and macOS.
- `AVAudioApplication` (record-permission API) is iOS 17+ / macOS 14+ — the modern
  replacement for `AVAudioSession.requestRecordPermission`.

Design invariant (the spine, from the rebuild plan): **audio on disk is ground truth.**
Every rule below optimizes for "the bytes the user spoke are already durably on disk," never
for a clean in-memory buffer. A force-kill must never cost more than one un-flushed tap
buffer (≤ one `bufferDuration`, target ≤ 200 ms).

---

## 1. On-disk format + directory layout

### Directory layout

Everything lives under Application Support (backed up, not purgeable), not Caches.

```
<AppSupport>/Recountly/
  captures/
    <captureID>/                         # captureID = ULID minted at preparing→recording
      manifest.json                      # capture-level journal (state machine record)
      manifest.json.part                 # transient during atomic manifest write
      segments/
        000000.pcm                       # finalized segment, monotonically numbered
        000000.json                      # sidecar checkpoint for 000000.pcm
        000001.pcm
        000001.json
        ...
        000042.pcm.part                  # segment currently being written (the live tail)
      final/
        recording.m4a                    # written by finalization worker (AAC-LC)
        recording.m4a.part               # transient during finalize
  recovered/                             # optional: nothing here in M1; reserved
```

- `captureID`: ULID (lexicographically sortable, time-prefixed). One directory per capture.
- Segment index: zero-padded 6-digit decimal, gap-free, monotonic. Padding keeps `readdir`
  order == chronological order.

### Segment format

Raw interleaved PCM, exactly the tap's output format, no container, no header. Header info
lives in the sidecar so a truncated `.pcm` is still fully decodable up to its last whole
frame. Chosen format (see §4): **Float32, mono, 48 kHz, non-interleaved single channel** —
i.e. deinterleaved to one channel before write, so the file is a flat `Float32` stream.

- Segment rotation: close current segment and open the next when EITHER
  `segmentDurationSeconds ≥ 20` (target; configurable 15–30) OR bytes ≥ a cap (~8 MB) —
  whichever first. Rotation is the natural checkpoint cadence.
- Write path is append-only. The live segment is `NNNNNN.pcm.part`. On rotation it is
  fsync'd then atomically renamed to `NNNNNN.pcm` and its sidecar `NNNNNN.json` is written.

### Sidecar checkpoint (`NNNNNN.json`)

One per finalized segment, written *after* the `.pcm` is fsync'd + renamed. Small, JSON.

```json
{
  "captureID": "01J...",
  "index": 42,
  "format": { "sampleRate": 48000, "channels": 1, "commonFormat": "pcmFormatFloat32",
              "interleaved": false, "bytesPerFrame": 4 },
  "frameCount": 960000,
  "startFrameOffset": 40320000,     // cumulative frames before this segment
  "startHostTime": 1490283.402,     // engine time of first frame (seconds, monotonic)
  "wallClockStart": "2026-07-29T15:00:00.123Z",
  "sha256Prefix": "1a2b3c4d",       // first 8 hex of sha256(pcm bytes); integrity, not crypto
  "closedReason": "rotation",       // rotation | stop | interruption | appTermination
  "byteCount": 3840000
}
```

`startFrameOffset` + `frameCount` give exact cumulative duration without reading any PCM.
`sha256Prefix` is cheap tamper/corruption detection, not security.

### Manifest (`manifest.json`) — capture-level journal

Single source of truth for capture identity + state. See §2 for the state field. Written
atomically on every state transition and on segment rotation (segment count/duration update).

```json
{
  "captureID": "01J...",
  "schemaVersion": 1,
  "createdAt": "2026-07-29T15:00:00.000Z",
  "state": "recording",
  "stateSeq": 7,                       // monotonic; disambiguates concurrent recoveries
  "stateUpdatedAt": "2026-07-29T15:03:22.100Z",
  "format": { "sampleRate": 48000, "channels": 1, "commonFormat": "pcmFormatFloat32",
              "interleaved": false },
  "segmentCount": 43,                  // count of finalized segments known to manifest
  "lastKnownFrameOffset": 41280000,    // cumulative frames as of last manifest write
  "interruptions": [                   // append-only log
    { "kind": "call", "beganAt": "...", "endedAt": "...", "resumed": true }
  ],
  "final": { "path": "final/recording.m4a", "verifiedAt": null, "durationFrames": null }
}
```

### Atomicity protocol

Two atomic primitives, used everywhere:

- **Atomic file replace**: write `X.part`, `write()`, `fsync(fd)`, `close`, `rename(X.part, X)`.
  POSIX `rename` within a volume is atomic. Then `fsync` the *directory* fd so the rename
  itself is durable (otherwise a crash can lose the rename even though data is on disk).
  Wrap as `AtomicFile.replace(at:writing:)`.
- **Append-with-flush** for the live `.pcm.part`: open once with `O_APPEND`; per tap buffer
  `write()` then periodically `fsync` (every rotation boundary always; optionally every N
  buffers). No rename until rotation.

### What survives a kill at each instant

- Kill while writing a tap buffer to `NNNNNN.pcm.part`: file has all whole frames written by
  the last `write()`; at most one in-flight buffer (≤ bufferDuration) is lost. The `.part`
  has no sidecar yet — recovery reconstructs frameCount from file size / bytesPerFrame and
  truncates any trailing partial frame.
- Kill between segment `write()` and rotation fsync: same as above; `.part` intact to last
  write.
- Kill during rotation (after data fsync, before/after rename, before sidecar): recovery sees
  either `NNNNNN.pcm.part` (rename not durable) or `NNNNNN.pcm` without `NNNNNN.json` (sidecar
  not yet written). Both handled: reconstruct sidecar from file. No data loss.
- Kill during manifest write: `manifest.json.part` may exist; `manifest.json` is either the
  old-but-valid version or the new one (atomic rename). Recovery reads `manifest.json`, deletes
  any stray `.part`. Manifest can lag reality (fewer segments than exist on disk) — recovery
  trusts the *filesystem* for segment set, manifest only for `captureID`/`state`/`format`.
- Kill during finalize: `final/recording.m4a.part` discarded; raw segments still present
  (never deleted pre-verification) → re-finalize.

Rule: **manifest is advisory for segment content; the segments directory is authoritative.**
Manifest is authoritative only for identity, format, and last-persisted state.

---

## 2. Capture state machine

Pure value type `CaptureState` + pure `CaptureMachine` reducer (see §6). The machine emits
`Effect`s (start engine, open segment, write manifest, …) executed by the imperative host;
the reducer itself touches no hardware and no disk.

### States

| State | Meaning | Audio flowing? |
|---|---|---|
| `idle` | no active capture | no |
| `preparing` | permission + session + engine configured, not yet tapping | no |
| `recording` | tap installed, segments rotating | yes |
| `interrupted` | audio yanked by system (call/route/reset); engine stopped, files intact | no |
| `resuming` | reacquiring session/engine after interruption | no |
| `stopping` | user tapped Done; draining final tail | winding down |
| `captured` | all raw segments closed + sidecar'd; audio complete on disk | no |
| `finalizing` | worker encoding AAC-LC | no |
| `complete` | AAC verified, raw segments deleted | no |

`captured` is the durability commit point: from here, the recording is safe regardless of
what happens to finalization. `complete` is a cleanup milestone, not a safety one.

### Transition table

Persist column = what is written (atomically) BEFORE the effect is considered committed.
`stateSeq` increments on every manifest write.

| # | From | Event | To | Effect | Persist (manifest/segment) |
|---|---|---|---|---|---|
| 1 | idle | user taps Record | preparing | request perm, configure session+engine | create dir; manifest{state:preparing} |
| 2 | preparing | ready | recording | install tap, open seg 0 `.part` | manifest{state:recording} then open seg |
| 3 | preparing | perm denied / config fail | idle | tear down; surface error | delete empty capture dir |
| 4 | recording | rotation tick | recording | close seg N (fsync+rename+sidecar), open N+1 | sidecar N; manifest{segmentCount, frameOffset} |
| 5 | recording | AVAudioSession interruption began (iOS) | interrupted | stop engine, close live seg (reason=interruption) | sidecar; manifest{state:interrupted, +interruption log entry} |
| 6 | recording | route change "old device unavailable" | interrupted | same as 5 | same as 5 |
| 7 | recording | media services reset (iOS) | interrupted | discard engine; close live seg | same as 5 |
| 8 | interrupted | interruption ended (.shouldResume) OR user taps Resume | resuming | rebuild session+engine | manifest{state:resuming} |
| 9 | resuming | engine restarted OK | recording | install tap, open next seg | manifest{state:recording}; open seg |
| 10 | resuming | reacquire fails (retry budget left) | interrupted | backoff, stay recoverable | manifest{state:interrupted, retryCount++} |
| 11 | resuming | reacquire fails (budget exhausted) | captured | give up live; treat what we have as complete | manifest{state:captured} |
| 12 | recording | user taps Done | stopping | keep tap ~FLUSH window, then remove | manifest{state:stopping} |
| 13 | stopping | tail drained | captured | close final seg (reason=stop); stop engine; release session | sidecar; manifest{state:captured, segmentCount final} |
| 14 | interrupted | user taps Done | captured | close nothing new (already closed at 5); stop | manifest{state:captured} |
| 15 | captured | worker picks up | finalizing | encode AAC-LC to `.part` | manifest{state:finalizing} |
| 16 | finalizing | encode+verify OK | complete | rename `.m4a.part`→`.m4a`; delete raw segs | manifest{state:complete, final.verifiedAt}; then delete segments/ |
| 17 | finalizing | encode/verify fail (budget left) | captured | discard `.part`; requeue | manifest{state:captured, finalizeAttempts++} |
| 18 | finalizing | fail (budget exhausted) | captured | keep raw forever; flag needsAttention | manifest{state:captured, needsAttention:true} |
| 19 | recording/stopping | disk-full write error | interrupted | stop tap; surface "storage full"; DON'T delete | manifest{state:interrupted, lastError:diskFull} |
| 20 | any non-idle | app terminating (last-gasp) | (unchanged) | best-effort fsync live seg + manifest | manifest{stateUpdatedAt}; no state change |

Notes:
- Interruptions and route changes are **normal states (5–11)**, never errors. The only true
  error edges are 3 (permission), 18 (persistent encode failure), 19 (disk full).
- `stopping` keeps the tap alive for a short flush window (≈ 300 ms, tunable — this is the
  native analogue of the web app's FLUSH_MS, but here it only guards a tap buffer, not a
  network commit) so the last spoken tail lands before the tap is removed.
- macOS: rows 5/6/7/8 (interruption/route/reset) don't exist as AVAudioSession events. macOS
  equivalents come from `AVAudioEngineConfigurationChangeNotification` (device change) →
  treat as transition 6/8 pair. See §4.

### How state is journaled for force-kill recovery at any transition

- **One writer.** All disk mutations funnel through a serial actor `SegmentStore` (single
  `DispatchQueue`/actor). No concurrent manifest writers → `stateSeq` is a true total order.
- **Write-ahead ordering.** For a transition, the manifest reflecting the *new* state is
  written (atomically) BEFORE the effect that the new state authorizes, EXCEPT where doing so
  would claim data not yet durable. Concretely:
  - Opening a new segment: manifest first (harmless if the segment never gets data — recovery
    ignores empty/absent segments).
  - Marking `complete` + deleting raw segments: manifest `complete` is written and dir-fsync'd
    BEFORE any `unlink` of raw segments. If killed mid-delete, recovery sees `complete` +
    verified `.m4a` and finishes the delete idempotently.
- **Recovery is idempotent and filesystem-truth-based** (§3). Because the segments dir is
  authoritative for content and the manifest only for identity/state/format, a manifest that
  lags (kill before its write) never loses audio — recovery recomputes from files.
- Force-kill at literally any point resolves to one of: (a) a valid earlier state with all
  durable segments intact, or (b) `complete` with verified AAC. Never a state that claims
  audio that isn't on disk.

---

## 3. Recovery scan at launch

Runs on every launch, before the capture UI is interactive. Pure decision core
`RecoveryPlanner` (input: directory snapshot; output: `[RecoveryAction]`) + imperative
executor. No hardware.

### Inputs (gathered by a directory walk, no PCM decode)

For each `captures/<id>/`:
- manifest (parse; may be missing/corrupt → treat state as `unknown`)
- segment files: list of `NNNNNN.pcm`, `NNNNNN.pcm.part`, sidecars present/absent
- byte sizes (→ derivable frameCount = floor(bytes / bytesPerFrame))
- `final/recording.m4a` present? `.part` present?

### Per-capture decision table

| manifest.state | segments on disk | final.m4a | Action | User-facing |
|---|---|---|---|---|
| absent/corrupt | ≥1 non-empty | — | rebuild manifest from sidecars/files → `captured` | "Recovered recording: MM:SS" |
| absent/corrupt | none/empty | — | delete dir (nothing captured) | silent |
| preparing | none | — | delete dir | silent |
| recording / interrupted / resuming / stopping | ≥1 non-empty | — | normalize: close any `.pcm.part`, regenerate missing sidecars, set `captured` | "Recovered recording: MM:SS" |
| recording / … | none/empty | — | delete dir | silent |
| captured | ≥1 | absent | leave `captured`; enqueue finalize | "Recovered recording: MM:SS" (then finalizes) |
| finalizing | ≥1 | .part only | discard `.part`; set `captured`; requeue | "Recovered recording: MM:SS" |
| finalizing/complete | present | .m4a present | verify `.m4a` (§5); if OK → `complete`, delete raw; else → `captured`, requeue | if verify OK: appears as normal finished entry; else recovered |
| complete | may be deleted | .m4a present+verified | finish any half-done raw delete | silent (already an entry) |

"Non-empty segment" = frameCount ≥ some floor (e.g. ≥ 0.5 s total across the capture);
below the floor the capture is discarded as an accidental tap.

### `.pcm.part` normalization

1. `frames = floor(fileSize / bytesPerFrame)`; if `fileSize % bytesPerFrame != 0`, truncate
   the trailing partial frame (`ftruncate`).
2. fsync, rename `.pcm.part` → `.pcm`.
3. Write its sidecar (compute `startFrameOffset` from prior segments' cumulative frames;
   `closedReason: "appTermination"`).

### User-facing outcomes

- Exactly one banner per recovered capture: **"Recovered recording: 18m42s"** with Play +
  Keep/Delete (Keep is default; nothing auto-deletes a real recording).
- Multiple recovered captures → list them (rare: only if killed across multiple sessions
  without launching between).
- Duration string = `formatDuration(totalFrames / sampleRate)`.
- Recovery must complete fast (only stats + small JSON, no PCM decode) so it's synchronous
  before UI or a quick async with a spinner.

---

## 4. AVAudioSession / AVAudioEngine configuration

### iOS

Session (`AVAudioSession.sharedInstance()`):
- Category `.playAndRecord` (needed so playback of recovered/finished audio works in the same
  session; and `.record` alone can't mix playback).
- Mode `.spokenAudio` (tuned for voice; VERIFY vs `.measurement` — `.measurement` disables
  input processing/AGC which is arguably better for archival ground truth. Leaning
  `.spokenAudio` for M1; revisit).
- Options: `[.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]`. (Bluetooth HFP input
  is low quality; we still accept it since the user may want it — segment format is fixed
  regardless, we resample from the tap's actual format.)
- `setActive(true)` in `preparing`; `setActive(false, options: .notifyOthersOnDeactivation)`
  in `captured`.
- `setPreferredIOBufferDuration(~0.02–0.1s)` — VERIFY the system honors it; treat as a hint.

Background audio: `UIBackgroundModes` = `["audio"]` in Info.plist. This keeps the engine
running when the screen locks / app backgrounds *while actively recording*. Mic capture in
the background requires an active recording session with this mode; iOS shows the orange mic
indicator. VERIFY current iOS 26 behavior — Apple has historically allowed background mic
only with the audio background mode + active session; confirm no additional entitlement is
required beyond the Info.plist key.

Permission: `AVAudioApplication.requestRecordPermission(completionHandler:)` (iOS 17+),
`NSMicrophoneUsageDescription` in Info.plist.

Notification handling (iOS-only, all confirmed iOS-only in headers):
- `AVAudioSessionInterruptionNotification`:
  - `.began` → transition 5 (→ interrupted). Read `AVAudioSessionInterruptionTypeKey`.
  - `.ended` → if `AVAudioSessionInterruptionOptionKey` contains `.shouldResume` → transition
    8 (→ resuming) automatically; else stay `interrupted`, show Resume button.
- `AVAudioSessionRouteChangeNotification`: if `AVAudioSessionRouteChangeReasonKey` ==
  `.oldDeviceUnavailable` (headphone/BT pull) → transition 6 (→ interrupted). Other reasons
  (new device available, category change) → keep recording, just re-read the tap format if
  the engine restarts.
- `AVAudioSessionMediaServicesWereResetNotification`: audio server died → transition 7; must
  fully rebuild session + engine + tap from scratch (all AVAudio objects are invalid).

### AVAudioEngine + tap (both platforms)

- `engine.inputNode`, `installTap(onBus: 0, bufferSize: 4096, format: inputFormat)` where
  `inputFormat = inputNode.outputFormat(forBus: 0)` (never hardcode — hardware format varies,
  BT is often 16 kHz/8 kHz).
- Tap closure runs on a realtime-ish thread: it must NOT block. It converts to the canonical
  segment format via a preallocated `AVAudioConverter` (input hardware format → Float32/mono/
  48 kHz) and hands the resulting bytes to `SegmentStore` via a lock-free ring/`DispatchQueue`
  async. **No disk I/O on the tap thread.**
- Canonical segment format chosen as Float32/mono/48k (see §1). Rationale: lossless
  intermediate; downmix-to-mono at capture (journaling is voice); 48k is a safe superset that
  AAC-LC finalize downsamples if desired. VERIFY whether to keep hardware sampleRate instead
  of forcing 48k — resampling on the tap thread costs CPU; alternative is store hardware rate
  in the sidecar and resample only at finalize. **Leaning: store at hardware rate, resample at
  finalize** (cheaper capture, sidecar already records the rate). Decide at implementation.
- Mic level meter: compute RMS/peak from the same buffer for the UI (no extra tap).

### macOS differences (no AVAudioSession)

`AVAudioSession` is `API_UNAVAILABLE(macos)` — confirmed in headers. On macOS:
- **No session category/mode/options, no setActive, no background-mode entitlement.** A
  foreground/background Mac app can record whenever it holds mic permission; there is no
  session to interrupt.
- Permission: `AVCaptureDevice.requestAccess(for: .audio)` (or `AVAudioApplication` which is
  `macos(14.0)+`), `NSMicrophoneUsageDescription`. Add the **Audio Input** entitlement
  (`com.apple.security.device.audio-input`) for the sandbox.
- Interruptions/route changes: there is no `AVAudioSessionInterruptionNotification`. The
  macOS analogue is `AVAudioEngineConfigurationChangeNotification` (posted when the input
  device changes / is unplugged) → map to transition 6 (→ interrupted) then 8/9 (rebuild +
  resume) once a device is available. Device-gone-with-no-replacement stays `interrupted`.
- The engine + tap code is identical.

### Keeping the capture core shared

Platform-specific glue behind a protocol:

```swift
protocol AudioSessionController {         // Capture/Platform/AudioSessionController.swift
    func activate() async throws
    func deactivate()
    var events: AsyncStream<SessionEvent> { get }   // .interrupted/.resumeAvailable/.routeLost/.reset
}
```

- `IOSAudioSessionController` (iOS): wraps AVAudioSession + the three notifications.
- `MacAudioSessionController` (macOS): no-op activate/deactivate; emits `.routeLost`/resume
  from `AVAudioEngineConfigurationChangeNotification`.

Everything above the protocol — `CaptureMachine`, `SegmentStore`, `RecoveryPlanner`, the
engine/tap driver (`AudioEngineRecorder`, which is itself cross-platform) — is shared. The
machine consumes `SessionEvent`s identically on both platforms; only the source differs.

---

## 5. Finalization worker

`FinalizerWorker` (actor) drains a queue of `captured` captures. One at a time, low priority,
resumable across launches (state lives in the manifest, §2 rows 15–18).

### Encode approach — pick: **AVAssetWriter** with an AAC-LC `AVAssetWriterInput`.

One line: AVAssetWriter directly produces the finished `.m4a` container with correct duration
metadata and handles PCM→AAC-LC in one path, whereas AVAudioConverter only yields raw AAC
packets that then need separate muxing — AssetWriter is fewer moving parts for "PCM frames in,
playable .m4a out." (VERIFY: feed PCM by wrapping each segment's frames in `CMSampleBuffer`s
via `AVAssetWriterInput` + `requestMediaDataWhenReady`; settings:
`AVFormatIDKey: kAudioFormatMPEG4AAC`, mono, sampleRate 44100 or 48000, `AVEncoderBitRateKey`
~80_000. Confirm CMSampleBuffer construction from a flat Float32 PCM buffer.)

### Encode steps

1. Read segments in index order (streaming, don't load all into RAM).
2. For each segment: read PCM, wrap into `CMSampleBuffer`(s), append to the AAC input.
   Concatenation of the ordered segments == the full recording (segments are contiguous;
   `startFrameOffset` chain validated first — any gap → flag `needsAttention`, still encode
   what's contiguous).
3. Finish writing → `final/recording.m4a.part`.

### Verification step (before deleting any raw segment)

1. `.m4a.part` exists and byte size > 0.
2. Open with `AVAudioFile`/`AVURLAsset`; assert decodable.
3. `abs(decodedDurationFrames/rate − rawTotalFrames/rate) < tolerance` (e.g. < 0.5 s; AAC
   priming/padding makes it non-exact — VERIFY tolerance empirically).
4. On pass: atomic rename `.m4a.part` → `.m4a`, write manifest `complete` + `verifiedAt`,
   dir-fsync, THEN `unlink` raw `segments/`. On fail: discard `.part`, requeue (row 17) or
   flag after budget (row 18).

### When raw segments are deleted

Only after transition 16: manifest is `complete` AND `.m4a` verified AND durably renamed.
Never before. A capture stuck at `captured`/`needsAttention` keeps its raw PCM forever — the
raw segments are themselves a valid, playable recording (via a concatenating `AVAudioPlayer`
feed or by decoding sequentially), so the user never loses audio to a finalize bug.

Playback (M1): finished entries play the `.m4a`; recovered-but-not-finalized entries play by
streaming the ordered raw segments (a small `SegmentPlayer` that schedules buffers on an
`AVAudioPlayerNode`). Both behind a `CapturePlayback` protocol.

---

## 6. Testability

### What's pure / injectable

- `CaptureMachine`: `(CaptureState, Event) -> (CaptureState, [Effect])`. No I/O, no time, no
  hardware. Time/ULID injected. **100% unit-testable.**
- `RecoveryPlanner`: `(DirectorySnapshot) -> [RecoveryAction]`. `DirectorySnapshot` is a plain
  struct (list of captures, each with manifest?, segment file stats, final file stat). No FS
  access in the planner — the executor gathers the snapshot. **100% unit-testable.**
- `SegmentStore`: file layout logic (paths, padding, sidecar (de)serialization, cumulative
  frame math, `.part` truncation math) split into a pure `SegmentLayout` + a thin FS actor.
  Pure parts unit-tested; the FS actor tested against a temp dir.
- `AtomicFile`, sidecar/manifest Codable round-trips: pure, unit-tested.
- Format/duration formatting (`formatDuration`): pure.

Hardware (`AVAudioEngine`, `AVAudioSession`, `AVAssetWriter`) sits behind protocols
(`AudioEngineRecorder`, `AudioSessionController`, `AudioEncoder`) with fake implementations
that feed synthetic PCM buffers, so the *driver* wiring can be tested without a mic. The
encode itself is validated on-device / in a round-trip integration test.

### Unit-test suite (XCTest, no hardware)

`CaptureMachineTests`:
- every row 1–20 transition produces expected next state + effects
- interruption during recording closes live segment before state flips
- resuming retry budget: N fails → stays interrupted, N+1 → captured (row 10/11)
- Done during interrupted goes straight to captured (row 14), no new segment
- disk-full during recording → interrupted, no data-claiming (row 19)
- `stateSeq` strictly increases across every transition
- illegal events are no-ops (e.g. rotation tick while `idle`)

`RecoveryPlannerTests` (one per §3 decision row):
- corrupt manifest + real segments → rebuild→captured, correct duration
- `.pcm.part` present → normalize action emitted with correct truncated frameCount
- preparing + no segments → delete
- finalizing + `.part` only → discard + requeue
- complete + verified m4a + half-deleted segments → finish delete
- sub-floor total duration → discard
- multiple captures → multiple independent actions

`SegmentLayoutTests`:
- 6-digit padding, gap-free ordering, chronological == readdir order
- cumulative `startFrameOffset` chain across N segments
- `.part` truncation math (fileSize not multiple of bytesPerFrame)
- sidecar Codable round-trip; manifest Codable round-trip + schemaVersion

`AtomicFileTests` (temp dir):
- replace leaves either old or new, never partial
- interrupted-write simulation (write `.part`, don't rename) → original intact

`SegmentStoreTests` (temp dir):
- append buffers → rotate → correct files + sidecars on disk
- kill-simulation: stop mid-`.part`, run recovery, assert playable frame total

`FinalizerTests` (fake encoder):
- ordered segment feed → encoder receives frames in order, contiguous
- gap in `startFrameOffset` → `needsAttention`, encodes contiguous prefix
- verify-fail path requeues; verify-pass deletes raw

`AudioEncoderRoundTripTests` (real AVAssetWriter, no mic — synthetic sine PCM):
- PCM sine → AAC-LC `.m4a` → decode → duration within tolerance, non-silent. (May run only on
  device/sim; marked as an integration test.)

### On-device paranoid manual tests (M1 smoke doc)

Each: start a recording, perform the action, confirm (a) no crash, (b) recovery banner or
continued recording as expected, (c) played-back audio contains everything spoken up to the
event. Record wall-clock spoken content ("one… two… three…") to verify no gap.

1. Lock screen mid-recording → keep speaking → unlock. Audio continuous (background mode).
2. Switch to another app → return. Continuous.
3. Pull wired headphones (route `.oldDeviceUnavailable`) → interrupted → Resume → continues.
4. Bluetooth: connect AirPods mid-recording; disconnect mid-recording. Interrupt/resume clean.
5. Incoming call, **accept** → interrupted for call duration → after hangup, `.shouldResume`
   → auto-resume → continues.
6. Incoming call, **decline** → brief interruption → resume.
7. Force-quit (swipe up) mid-recording → relaunch → "Recovered recording: MM:SS", plays all
   spoken up to ~last 200 ms.
8. Force-quit during Done/finalize → relaunch → recovered, finalizes on next launch.
9. Kill at each transition (use a debug menu that pauses in each state): preparing, recording,
   first rotation, interrupted, resuming, stopping, captured, finalizing → relaunch → correct
   recovery per §3.
10. Disk full (fill storage, or a debug cap) → "storage full", state interrupted, existing
    audio intact and playable.
11. Airplane mode on throughout → no effect (fully offline; proves no network in capture path).
12. macOS: unplug/switch input device mid-recording (config-change) → interrupted → resume on
    new device. Sleep the Mac mid-recording → wake → recovered/continuous.
13. Long-run: 45+ min recording → many segments → finalize → single correct-duration `.m4a`.

---

## 7. Task breakdown (implementer-subagent sized)

Ordered; each is independently reviewable. "Done-when" is the acceptance gate.

**T1 — Layout + Codable models + AtomicFile (pure).**
Files: `Capture/SegmentLayout.swift`, `Capture/Models/{Manifest,SegmentSidecar,CaptureState}.swift`,
`Capture/AtomicFile.swift`. Done-when: `SegmentLayoutTests`, `AtomicFileTests`, Codable
round-trip tests green; no AV imports.

**T2 — CaptureMachine (pure reducer).**
Files: `Capture/CaptureMachine.swift`, `Capture/Effect.swift`, `Capture/Event.swift`.
Done-when: `CaptureMachineTests` cover all 20 rows + stateSeq monotonicity + illegal-event
no-ops; no I/O.

**T3 — SegmentStore actor (FS I/O over T1).**
Files: `Capture/SegmentStore.swift`. Done-when: append→rotate→sidecar verified in a temp dir;
manifest atomic-write; kill-sim (stop mid-part) leaves recoverable files; `SegmentStoreTests`
green.

**T4 — RecoveryPlanner (pure) + executor.**
Files: `Capture/RecoveryPlanner.swift`, `Capture/RecoveryExecutor.swift`,
`Capture/DirectorySnapshot.swift`. Done-when: every §3 row has a passing `RecoveryPlannerTests`
case; executor applies actions idempotently against a temp dir.

**T5 — AudioSessionController protocol + platform impls.**
Files: `Capture/Platform/AudioSessionController.swift`, `IOSAudioSessionController.swift`,
`MacAudioSessionController.swift`, Info.plist keys (`UIBackgroundModes`,
`NSMicrophoneUsageDescription`), macOS entitlement. Done-when: iOS emits interrupted/resume/
routeLost/reset from the three notifications; macOS emits from config-change; compiles for
both platforms; permission request wired. (Manual verify on device.)

**T6 — AudioEngineRecorder (engine + tap + converter).**
Files: `Capture/AudioEngineRecorder.swift`. Done-when: installs tap at hardware format, feeds
PCM to a sink protocol, computes RMS for meter, never does disk I/O on tap thread; driven by a
fake sink in tests; real capture verified on device.

**T7 — CaptureCoordinator (wires machine + store + session + recorder).**
Files: `Capture/CaptureCoordinator.swift`. Done-when: executes machine effects; runs recovery
at launch; end-to-end record→Done→captured produces correct segments+manifest on a device/sim.

**T8 — FinalizerWorker (AVAssetWriter encode + verify).**
Files: `Capture/FinalizerWorker.swift`, `Capture/AudioEncoder.swift` (protocol + AssetWriter
impl). Done-when: `FinalizerTests` (fake encoder) + `AudioEncoderRoundTripTests` green; raw
segments deleted only post-verify; requeue/needsAttention paths covered.

**T9 — Playback (m4a + raw-segment fallback).**
Files: `Capture/CapturePlayback.swift`, `Capture/SegmentPlayer.swift`. Done-when: plays a
finished `.m4a` and an un-finalized segment set; duration correct.

**T10 — Capture SwiftUI screen + recovery banner.**
Files: `Capture/UI/CaptureView.swift`, `RecordButton.swift`, `RecStatusLine.swift`,
`MicMeter.swift`, `RecoveryBanner.swift`. Done-when: record/pause(interrupt)/resume/Done
reflect machine state; live timer + meter; "Recovered recording: MM:SS" banner with
Play/Keep/Delete; builds iOS + macOS.

**T11 — Debug transition-pause harness + smoke doc.**
Files: `Capture/Debug/TransitionBreakpoints.swift` (DEBUG-only), `docs/smoke-checklist-m1.md`.
Done-when: a debug toggle can halt/kill at each state for test 9; smoke doc enumerates §6
manual tests with pass/fail criteria.

Dependency order: T1→T2 parallel with T5/T6; T3 needs T1; T4 needs T1; T7 needs T2/T3/T5/T6;
T8 needs T1/T3; T9 needs T1/T8; T10 needs T7/T9; T11 last.

---

## Open questions / VERIFY list

1. iOS 26 background-mic: confirm `UIBackgroundModes:["audio"]` + active `.playAndRecord`
   session is still sufficient with no extra entitlement.
2. Canonical capture format: store at hardware sample rate (resample at finalize) vs force
   48k mono at tap. Leaning hardware-rate.
3. `.spokenAudio` vs `.measurement` mode (input processing on/off for archival fidelity).
4. AVAssetWriter CMSampleBuffer construction from flat Float32 PCM; exact AAC settings.
5. AAC priming/padding duration tolerance for the verification check.
6. `setPreferredIOBufferDuration` honored value on iOS 26 devices.
7. macOS: is `AVAudioEngineConfigurationChangeNotification` sufficient for all device-loss
   cases, or is a `CoreAudio` device-listener also needed?
