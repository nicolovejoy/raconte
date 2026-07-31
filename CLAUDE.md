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

Open issues: #1 background awareness (folded into M2 T8), #2 gap-honest capture (low, now
explicitly *not* an M2 blocker), **#7** recovery drops manifest fields, **#8** corrupt
manifest deletes a finalized m4a (blocks M2 T3), **#9** interruption `endedAt` never
written. #5 verified fixed on the mini (smoke run 10). #6 scrubbing implemented — see below.

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

**Next (owner + next session):**
1. Manual: new smoke test 25 — scrub a *recovered* (un-finalized) recording on device, then
   close issue #6. The finalized-m4a scrub is already covered by
   `CaptureUITests.testScrubbingAFinishedEntryMovesThePosition`.
2. Sweep leftovers: `interrupted`/`resuming` kill-gates need a FaceTime call from a
   second device (Siri won't engage while the app holds the mic) — or fold into the
   eventual iPhone pass.
3. M2 T2 (§9 of the design doc), then T2.5 — which fixes #8 and #7 before anything writes
   into the capture tree. T4 is the first task needing the mini or the iPhone.
4. Reserve the CloudKit container `iCloud.org.pianohouseproject.raconte` on the portal.
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
