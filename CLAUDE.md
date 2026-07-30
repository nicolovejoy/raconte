# CLAUDE.md

## Status 2026-07-29: Milestone 1 CODE-COMPLETE — needs on-device smoke

All 11 M1 tasks (T1–T11 in the capture design doc) implemented via parallel subagent
waves in one evening, plus an adversarial review pass (all 6 findings fixed — notably:
zero allocation on the realtime tap path). **136 unit tests green** on macOS; iOS
Simulator builds green; CI green (`macos-26` runner). The migration export also ran:
verified open-format package at `~/Documents/recountly-export/2026-07-30/` (36 entries,
34 audio, 108 files hash-verified — done via the web repo's `export-open-package.mjs`).

**Next (owner + next session):**
1. **On-device paranoid smoke** — build to the owner's iPhone from Xcode, run
   `docs/m1-paranoid-tests.md` (28 tests; the DEBUG menu in the capture screen drives the
   kill-at-every-transition sweep). This is M1's real acceptance gate; everything so far
   is simulator/unit-level. Known unknowns flagged VERIFY in the design doc (§8) mostly
   need device runs to resolve.
2. Apple Developer Program enrollment ("soon" per owner) — needed for TestFlight/CloudKit
   (M4), not for device dev builds (personal team 8UK463WB83 already signs).
3. Then Milestone 2: live transcript (SpeechTranscriber) — design pass first, same
   subagent pipeline.

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

Milestone 1 smoke doc: `docs/m1-paranoid-tests.md` (28 on-device tests + macOS pass).

## Identity

- App name: **Raconte** (French, "tell!" — English *recount* comes from *raconter*)
- Bundle id: `org.recountly.raconte` (CloudKit container later: `iCloud.org.recountly.raconte`)
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

## Working style

- Plan → implement → review via subagents, one milestone task at a time (task breakdown
  lives in the M1 design doc). Test-first for the pure core (state machine, recovery
  planner, segment math) — hardware behind protocols.
- Docs: plain and terse. No grandiose prose.
- Signing: personal team `8UK463WB83` (already in project.yml) signs local + device dev
  builds. Paid Apple Developer Program pending (owner: "soon") — gates TestFlight/CloudKit.
