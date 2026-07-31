# CLAUDE.md

## Status 2026-07-30 (overnight autonomous session)

Landed overnight (all pushed to main):
- Issue #4 CLOSED: flaky interruption test root-caused (test read the manifest between
  sidecar close and manifest write — `send()` publishes phase before disk effects land);
  test now polls the on-disk manifest, stress-verified ×200.
- Issue #5 FIXED, pending 30s device verification: route loss now auto-resumes onto the
  current default input (fresh engine, pinned to the capture's canonical format; tap
  resamples if the new device's rate differs). `mediaServicesReset` now surfaces Resume.
- Smoke automation: doc tests 7/20/21/22 at the model/encoder layer; NEW `RaconteUITests`
  (scheme `RaconteUI`, iOS simulator) drives real UI flows — record→finalize,
  kill→recover-banner, idle relaunch, repeated cycles — via a DEBUG synthetic sine
  recorder (`Capture/Debug/UITestSupport.swift`, env `RACONTE_UITEST_ID`). No mic, no
  TCC. CI runs them in a new sim step. macOS UI testing needs interactive
  automation-mode permission → deliberately simulator-only.

Run log: `docs/m1-smoke-log.md` (next manual run: 10). Owner-accepted caveat: small
audible hiccup at backgrounding edges (issue #2).

## M2 design landed 2026-07-30

`docs/plans/2026-07-30-m2-transcription-design.md` — live transcript via
SpeechAnalyzer/SpeechTranscriber. Written from SDK recon against Xcode 26.6, a map of the
M1 sources, and issue #1; then reviewed by adversarial subagents against both the SDK and
the code, which broke two rev-1 decisions (rewritten in rev 2) and surfaced three live M1
bugs, now filed.

Governing rule: transcription is derived and may fail at any moment. It never sends events
into `CaptureMachine` (M2 doesn't touch it), it's a second consumer of the same PCM chunks,
and retranscription from `final/recording.m4a` — not the live pass — is the correctness
guarantee. Transcript time = capture-frame time = position in the m4a, so live and
re-derived results are directly comparable.

Open issues: #1 background awareness and **#9** interruption `endedAt` (both folded into
M2 T8), #2 gap-honest capture (low, explicitly *not* an M2 blocker), **#10** replaying
`live.jsonl` doesn't reproduce the live view, **#11** the reader can't tell an absent log
from an unreadable one. #10 and #11 are design questions, not slips — settle both before
T6. Closed: #5 route loss (smoke run 10), #6 scrubbing (smoke run 11), #7 and #8 in T2.5.

## Landed 2026-07-30 (execution session)

Plan of record for both: `docs/plans/2026-07-30-next-tasks.md`.

- **Issue #6 — playback scrubbing.** `PlaybackSeek` (pure frame math, walks cumulative
  `frameCount` not sidecar `startFrameOffset`), `SegmentPlayer.seek(toFrame:)` with
  range-limited mapped segment loads + a generation guard on the completion callback,
  `CapturePlayback.seek/beginScrubbing/endScrubbing` over both paths, and
  `PlaybackProgressLine` as a `Slider` that seeks on drag end only. m4a path has a UI test;
  raw-segment path is new manual smoke test 25. Not yet closed on GitHub — needs that
  manual pass.
- **M2 T1.** `TeeSink` (stateless, checked-`Sendable`) + `BoundedPCMSink` with a coalescing
  drop ledger over `FrameRange`; both `recorder.start` sites install the same tee (the
  resume site is covered by a mutation-verified regression test); `activeCaptureID` /
  `activeFormat` published; `SecondarySinkFactory` threaded through the composition root
  and supplied as a no-op by the UI-test harness. `TranscriptionEngine` /
  `TranscriptResult` declared, no implementations.
- **M2 T2** (2026-07-31). `TranscriptConsolidator` (pure: volatile never promoted to
  committed, empty-volatile revokes its range, out-of-order arrivals ordered by frame)
  and `TranscriptionSession` (actor: converter runs, discontinuity → fresh run +
  recorded `skippedRanges`, ordered shutdown with a bounded finalize falling through to
  `abandon()`), driven by a scripted fake engine. 224 unit tests green.
  Two design amendments, both forced by measurement and written back into the design
  doc: `prepare` returns the analysis format as an `AudioFormatDescriptor`
  (`AVAudioFormat` is not `Sendable`, and the converter lives in the session), and §2's
  `emittedInRun` clock is replaced by stamping straight off `StampedChunk.startFrame`
  — the converter's output wanders ~90 ms against its input before catching up, so an
  emitted-frame accumulator would re-prime at every discontinuity. `primeMethod = .none`,
  without which the converter silently swallows frames.
- **M2 T2.5** (2026-07-31). Both data-loss bugs fixed and mutation-verified.
  **#8**: `CaptureSnapshot.holdsIrreplaceableArtifacts` (m4a, m4a.part, or a non-empty
  `transcript/`) filters every `.deleteCaptureDirectory` decision into a new
  `.quarantineCaptureDirectory` — a *no-op on disk*, so it is idempotent by doing
  nothing and the recording never moves out from under the UI. Filtering once after
  the decision rather than guarding three delete sites is deliberate.
  `SegmentLayout.transcriptDirectory` is declared here, ahead of T3, so the guard
  exists before the writer does. **#7**: `writeCapturedManifest` now carries
  `schemaVersion`/`needsAttention`/`lastError`/`retryCount`/`finalizeAttempts`, with a
  `Mirror`-based field-count tripwire that fails when `Manifest` gains a field nobody
  carried over. 238 unit tests + 5 UI tests green.
- **M2 T3** (2026-07-31). `TranscriptRecord`/`TranscriptRun`/`TranscriptTimeStamp` (§3's
  on-disk shape), `LiveTranscriptWriter`/`Reader` (append-only JSONL, torn tail dropped,
  `O_APPEND`), `TranscriptRef` on the manifest with no `schemaVersion` bump,
  `SegmentLayout` transcript paths, `DirectorySnapshot` transcript stats. Two bugs caught
  by its own tests: the shared encoder is `.prettyPrinted` (would have torn every record
  in half — added `lineEncoder()`), and `O_APPEND` fused the first record after a torn
  tail onto it, losing both.
- **Two adversarial review passes** (2026-07-31), which found real defects in *already
  committed* T2 code. Worst: `finalizedWithinBound` raced inside a `withTaskGroup`, which
  awaits every child before returning, so the bound was decorative against an
  uncancellable finalize — 5.2 s measured against a 100 ms bound, and the fake's
  `Task.sleep` stall made it invisible. Also: `finish()` cancelled the results drain
  before finalize's tail arrived; `start()`'s two suspension points let a concurrent
  `finish()` be overwritten back into `.running`; unusable chunks weren't recorded as
  skips (so `skippedRanges` claimed full coverage while the analyzer saw nothing); and the
  converter's delay line was dropped unrecorded at every discontinuity. 262 unit + 5 UI
  tests green.

## Rev 3 decisions landed 2026-07-31 (#10, #11 settled)

Four owner decisions, all implemented and mutation-verified; 285 unit tests green. Written
up in full as **§11 of the M2 design doc** — read that, not this summary.

- **A real defect in shipped T2 code**: Apple documents that a module need not reissue a
  final result over a range it finalizes *through*, so committing only on
  `isVolatile == false` loses every phrase recognized correctly on the first try. The live
  screen looks right the whole time, which is what hid it. Fix: `finalizedThroughFrame`
  carried through the seam, `TranscriptConsolidator.promote(through:)`.
- **#10**: replay = fold the log back through `TranscriptConsolidator`
  (`LiveTranscriptReader.consolidate`). `apply` now *returns* what must be logged — final
  results including empty ones (the deletions) plus promotions. Rejected encoding
  tombstones in the format: two implementations of the same rules stop agreeing.
- **#11**: `.absent` / `.unreadable` / `.present` are three answers, and the bare
  `[TranscriptRecord]` convenience is gone. It was also a *writer* bug — `open()` resumed
  `nextSeq` from the same swallowed read, so an unreadable log got colliding seq numbers;
  it now throws. Tail loss is detected against `TranscriptRef.committedRecords`, since
  `seq` structurally cannot (the old doc comment claimed it could).
- **Decoder hazard**: verified that Swift's synthesized decoder *ignores property
  defaults* — so adding a field would have silently erased every log rather than erroring.
  Hand-written `init(from:)`: additive fields lenient, identity fields strict. No version
  field (nothing to migrate yet). Free only because no `live.jsonl` exists on any device.
- **Build order changed: T4 before the T3 wire-up.** T3 can't be finished without an
  engine (the factory could only return `nil`), and deferring also sidesteps the
  quarantine hazard — `open()` creates a zero-byte log, which flips
  `holdsIrreplaceableArtifacts`, so opening at factory time would make every mis-tap leave
  a permanently undeletable directory. Fix when wiring lands: open lazily at first append.

## M2 T4 + T3 wire-up landed 2026-07-31 — live transcription works on the mini

`SpeechAnalyzerEngine` (real `SpeechAnalyzer`/`SpeechTranscriber`) →
`LiveTranscriptionCoordinator` → `LiveTranscriptionRun` → `TranscriptionSession`, which
owns the log writer. Verified on the mini: a 9.1 s recording transcribed accurately,
full coverage, `committedRecords` matching the file, no orphan `transcript/` dirs.

Facts measured, not assumed (probe: `RaconteTests/SpeechAvailabilityProbe`):
`bestAvailableAudioFormat` is **1 ch 16 kHz Int16 interleaved** — the capture path is
Float32 48 kHz, so the converter does a sample-*format* change too. The descriptor
round-trip survives it. `AssetInventory.status` reports `.supported` with nine `en_*`
locales installed and a real format returned, so **status tracks this app's reservation,
not whether the bytes exist** — the asset gate keys off `bestAvailableAudioFormat != nil`
and treats status as advisory.

Three defects the device pass found, all fixed, none reachable from CI:
- **Overlapping `AnalyzerInput` killed the session 0.7 s into a 6.2 s recording.** The
  converter emits lumpily, so stamping every output buffer with its input chunk's start
  frame declares spans that overlap what the analyzer already accepted → `audioDisordered`
  on the *results* stream → session dead, every later chunk silently ignored. Fix: stamp
  a run's **first** buffer only, `nil` after (the SDK's "immediately after the previous
  buffer"). Gaps stay expressible because a discontinuity opens a new run. Pinned by
  `AnalyzerInputOrderingTests`, which measures the overlap directly.
- **`coverageFrames` lied.** `ingest` returned silently when not running, so a dead
  session's audio counted as covered — the ref claimed a complete transcript for 11 % of a
  recording. Now recorded as skipped.
- **`TranscriptRef` was never written**: read from `activeCaptureID`, which
  `resetCaptureWiring()` nils first. Now keyed off the finalize queue.

**Next (owner + next session):**
1. Transcript ends at 7.80 s of a 9.1 s recording — trailing silence, or a tail that never
   finalized? First thing to check; it is the one unexplained observation from the pass.
2. iPhone pass. Everything iOS-only is still unverified: TCC behaviour, the ~2-instance
   limit (macOS has none), background suspension (§7), asset download on a device without
   models, battery/thermal. iPhone 15 needs a cable.
3. `DictationTranscriber` fallback (§6.1) is not wired — unavailable reports `noModel`.
4. Carry-ins still open from design §11.7: the secondary-sink abandon hook (four
   coordinator paths drop the sink with no notification, leaking a live analyzer), and
   recovery synthesizing a `completedAt: nil` ref for a killed capture.
5. Reserve the CloudKit container `iCloud.org.pianohouseproject.raconte` on the portal.
   Container ids are permanent and unreclaimable; costs nothing to hold, and M4 needs it.

One architectural note from T10: `CaptureMachine` has no `captured→idle` edge, so the UI
mints a fresh CaptureCoordinator per capture (single-capture coordinators by design). If
M2 wants a long-lived coordinator, that's a deliberate machine change, not a bug fix.

## What Raconte is

Native SwiftUI universal app (iOS 26 + macOS 26) for private, single-user spoken-word
journaling. Full rebuild of the frozen web app at github.com/nicolovejoy/recountly
(recountly.org). **Audio is ground truth; the transcript is a derived, replaceable
interpretation** — that principle drives every design choice.

Plan of record: `docs/native-rebuild-plan.md` (architecture, milestones, migration,
web teardown). Detailed designs in `docs/plans/`:
- `2026-07-29-m1-capture-design.md` — Milestone 1: indestructible capture (segment
  format, state machine, recovery scan, task breakdown)
- `2026-07-29-data-model-and-migration.md` — GRDB schema, CloudKit mapping, export
  package spec, Neon migration
- `2026-07-29-apple-sdk-recon.md` — SDK availability verified against installed Xcode

Milestone 1 smoke doc: `docs/m1-paranoid-tests.md` (full iPhone pass + iPad and macOS
delta passes, 32 tests total).

## Identity

- App name: **Raconte** (French, "tell!" — English *recount* comes from *raconter*)
- Bundle id: `org.pianohouseproject.raconte` (CloudKit container later:
  `iCloud.org.pianohouseproject.raconte`). `pianohouseproject.org` is the owner's
  public-facing namespace for all his work — publisher, not product. Changed 2026-07-31
  from `org.recountly.raconte`, which was product-under-product; nothing had shipped.
- Repo: github.com/nicolovejoy/raconte
- Single user (the owner). No accounts, no server. iCloud identity only (Milestone 4).

## Stack

- SwiftUI multiplatform target (NOT Catalyst), Swift 6 strict concurrency.
- Capture: AVAudioSession (iOS) / AVAudioEngine tap, append-only PCM segments on disk.
- Transcription (M2): on-device SpeechAnalyzer/SpeechTranscriber (iOS 26 API).
- Storage (M3): GRDB/SQLite + FTS5. Files in the app container.
- Sync (M4): CKSyncEngine → CloudKit private DB, custom zone.
- Xcode project is GENERATED — `project.yml` (XcodeGen) is the source of truth;
  `*.xcodeproj` is gitignored. After clone or project.yml edit: `xcodegen generate`.

## Commands

- `xcodegen generate` — (re)create Raconte.xcodeproj from project.yml
- Build (macOS): `xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' build`
- Test (macOS): `xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' test`
- iOS simulator: same with `-destination 'platform=iOS Simulator,name=iPhone 17'` (check `xcrun simctl list devices` for available names)
- UI tests (simulator only — macOS needs interactive automation permission):
  `xcodebuild -project Raconte.xcodeproj -scheme RaconteUI -destination 'platform=iOS Simulator,name=iPhone 17' test`

## Working style

- Plan → implement → review via subagents, one milestone task at a time (task breakdown
  lives in the M1 design doc). Test-first for the pure core (state machine, recovery
  planner, segment math) — hardware behind protocols.
- Docs: plain and terse. No grandiose prose.
- Signing: team `8UK463WB83` ("Nicholas Lovejoy", in project.yml) is a **paid** Apple
  Developer Program membership — the same team MusicForge ships under. Nothing is gated on
  enrollment: TestFlight, CloudKit containers, push and Live Activities are all available
  now. (Verified 2026-07-31 from the on-disk profiles: App Store distribution profiles and
  year-long expiries, neither of which a free personal team can produce.)

<!-- SHARED-CONVENTIONS:BEGIN v=d5e16e653242 — auto-managed, do not edit here; source: prompt-lab/workflow/claude-md-shared.md (edit + re-sync) -->
## Shared conventions

<!-- These are Nico's cross-repo output rules. They're materialized into each repo's
CLAUDE.md so every agent (local, cloud, third-party) sees them as plain text. Source
of truth: prompt-lab/workflow/claude-md-shared.md — edit there and re-sync, never here. -->

- **Clickable URLs.** When pointing at any web destination (dashboard, repo, PR, deploy, settings, docs, localhost), print the full bare URL — `https://example.com` or `http://localhost:8080` — on its own, never just the page's name and never a markdown `[label](url)` link. Nico's terminal auto-linkifies raw `https://` text, so a bare URL is one-click and stays copyable.

- **Number your questions.** Any time you ask Nico more than one question, present them as a numbered list (1., 2., 3.) so he can answer by number with no ambiguity. A single standalone question needs no number.

- **Self-contained smoke-test instructions.** When you ask Nico to manually test or verify an app or website, assume zero carried-over context — he should never scroll back or recall a URL/path/credential from earlier. Always include: the exact URL (full `https://…` or `http://localhost:…`, restated even if mentioned above), the precise steps in order, and what a pass vs. fail looks like. Repetition here is a feature, not clutter.

- **No marker before a copy-paste command block.** Nico's terminal renders markdown bullets (`-`, `*`, `•`) as `●`, which breaks paste into zsh. The line directly above a fenced command block must be a plain-text label ending in a colon — never a bullet, dash, asterisk, or number. For loud copy targets, lead the label with `📋` + bold `COPY THE BELOW`, then a colon, then the block.
<!-- SHARED-CONVENTIONS:END -->
