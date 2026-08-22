# CLAUDE.md

Session-by-session history lives in [docs/devlog.md](docs/devlog.md). This file carries only the latest session, project intent, and conventions.

## Session 2026-08-21→22 (laptop — #79 + #80 BUILT on `m4/sync`; OPUS GATE BLOCKED on a reproduced data-loss defect, fixed; 1555 → 1606 unit / 43 → 45 UI)

Ran `docs/plans/2026-08-21-journal-order-and-delete-plan.md` to completion in one sitting,
subagent-driven (Sonnet implementers + Sonnet task reviews, Opus gate + Opus fix wave).
Branch `m4/sync` `082e30e9..c592752c`, **12 commits, PUSHED**. Both trees clean;
`stash@{0}` (inert fetch-debounce scaffolding) untouched. **Not merged to main — and the
owner smoke has not been run.**

- **Owner ruled all three Phase-B questions as recommended:** delete EMPTY journals only
  (zero entries **including trashed** — a trashed entry restored into a deleted journal is
  the orphan hazard); the affordance is a destructive editor row behind a confirmation
  dialog, **visible-but-disabled with an explanatory footnote** when refused, not a swipe;
  and the offline-peer resurrection race is **accepted and documented, not fixed** (no
  deletion tombstones).
- **Phase A (#79) — clean at the gate, first time on this branch.** New
  `Array<Journal>.displayOrdered` (createdAt asc, id tiebreak) applied at every listing
  surface; `Place.swift`'s "registry order (locked)" doc comment superseded. Registry
  storage stays insertion-ordered on purpose — **presentation sorts, storage does not**;
  `journals.json` is never sorted. The capture picker's bootstrap-once copy became a
  model-side `libraryDidRescan()` observer (never a view hook, per the nav redesign).
- **A2's review caught the #67 guard shipping UNPINNED**, and the mechanism is worth
  keeping: `JournalSelection.resolve` returns `.existing(storedID)` whenever the id is
  still in the registry, so neither headline test (neither deletes the selected journal)
  could tell the guard from its absence. The guard's real job is suppressing
  `resolveBackdateForJournalChange()` — which unconditionally sets `backdateDate = Date()`
  — on irrelevant background rescans. Same no-op-visit-clobbers-live-state shape as the
  m4/sync merge gate's F1. Now pinned by a backdate-unchanged test, mutation-verified.
- **Phase B (#80) in three layers.** `JournalStore.deleteJournal` (registry remove, cover
  cleanup, guards for unknown-id and last-remaining-journal) with the **emptiness rule in
  `LibraryScreenModel`, because the store cannot see entries**; sync propagation both ways
  (`noteLocalDelete` → the previously zero-caller `enqueueDeletes`; inbound deletion ingest
  handling **journal record names ONLY**, entry/artifact deletions still ignored under m4
  Task 11); and the editor row + dialog.
- **THE GATE EARNED ITS SEAT AGAIN — verdict BLOCKED, 1 Critical + 4 Important.**
  **Critical, reproduced on the committed tree at every delay from `Task.yield()` to 3 ms:
  `LibraryScreenModel.rescan()`'s superseded-scan guard made a DISCARDED scan
  indistinguishable from a published one**, so the destructive callers read stale
  `allEntries` and a journal holding a 48,000-frame capture was deleted both locally and by
  inbound sync. This was the **second** failure of the same rule — B1 had already been sent
  back in review for reading a stale scan, and this defeated that very fix. Fixed properly:
  `rescan()` now returns whether it published, `rescanUntilFresh(attempts:)` requires a won
  scan, and **both destructive callers REFUSE when freshness cannot be proven**. The
  refusal surfaces honestly ("Couldn't delete this journal"); it cannot read as success.
- **The other four, all Phase B:** the headline "must never orphan entries" test was
  **vacuous** (single-journal fixture let the last-journal guard mask the mutation — the
  SIXTH vacuous fixture on this plan); an entry with an **unreadable `entry.json` scanned
  as `journalID == nil`** and so could not block deletion of its own journal (the recurring
  three-answers mistake, on a destructive path — now any `.metadataUnreadable` row blocks);
  a **filed-but-not-yet-durable capture** did not block deletion (traced and confirmed
  reachable — `.recording` is published before `beginRecording`, and `EntryMetadataStore.write`
  creates its own directory, so `entry.json` names the journal before any frames exist);
  and a refused inbound deletion's **corrective re-push silently failed** against archived
  system fields for a server-deleted record, with `SyncPlanner.reconcile` never retrying.
- **The re-review invented its own mutations and both were caught** — `rescanUntilFresh`
  falling through to `true` after exhausting attempts ("the bounded retry wearing a hat"),
  and disabling only the ledger-clearing half of the re-push fix. It also traced every
  destructive caller: none reaches a decision without a proven-fresh scan.
- **`continueAfterFailure` defaults to `true`** — settled by measurement twice. One report
  explained a missing mutation failure by claiming the opposite; a plausible
  framework-sounding excuse for absent failures is itself a finding. (In memory.)
- **The background-suite stall hit its 11th victim**, in a dispatch that carried both the
  warning and the mechanism. **Wording cannot prevent it — budget one controller nudge per
  long-suite task.** Root cause is now understood: the `RaconteUI` suite exceeds the Bash
  tool's **hard 10-minute cap** (600000 ms is the maximum the tool accepts), so a single
  invocation is killed mid-run; the fix is splitting with `-only-testing`, not
  backgrounding. (In memory.)
- Tooling: superpowers' `task-brief` script only matches `Task <number>` headings, so this
  plan's `Task A1`/`B2` style needed briefs awk'd out by hand; `review-package` is fine.
  The plan file lives on `main` and is **absent from the m4 worktree** — pass subagents the
  main-checkout absolute path.
- **Two owner-facing consequences of the fail-safe design:** one corrupt `entry.json` now
  blocks **all** journal deletion with no in-app repair route, and a mis-tapped zero-frame
  capture blocks its journal until the next launch's recovery pass. Narrower than it
  sounds — `EntryMetadataStore.read` returns `.defaults` for an *absent* sidecar and throws
  only for a corrupt one — but it is a real usability cost the owner has not yet seen.
- A gate-fix agent **posted a comment to issue #80** documenting the accepted resurrection
  race (owner ruling 3). Outward-facing; flagged and accepted after the fact.

**Next steps:**
1. **Owner smoke — nothing has been run on a device.** Build both (macOS via ditto to
   `~/Desktop/Raconte-m4sync.app` + dylib-UUID check; iPhone via wireless `devicectl`, the
   usual tunnel-open retry). Test: delete an empty test journal on one device and watch it
   vanish on the other; confirm the journal lists now match everywhere; confirm a journal
   holding an entry shows the disabled row + footnote. **Nothing CloudKit-side has been
   verified by any test** — owner smoke is the only evidence a delete lands on a peer.
2. **Decide the two fail-safe costs above** — whether a corrupt sidecar blocking all
   deletion needs a repair route before this ships.
3. **`m4/sync` → main** is now 12 further commits ahead; also **resume the m4 SDD loop at
   Task 6** (entry + finalize artifacts push) — read the m4 ledger first
   (`/Users/nico/src/raconte-m4/.superpowers/sdd/2026-08-17-m4-sync-implementation-plan/progress.md`).
   Decide the Task-0 stash at Task 12.
4. **#68** (macOS cover picker sheet empty) — still the only cover path on the Mac.
5. **Owner smoke item never run:** Mac — type a new journal name in the editor, ⌘2 without
   clicking away, reopen (write-through discipline; macOS UI tests impossible here).
6. **Repo visibility raised by the owner and left open:** the audit's finding (no secrets,
   no journal content ever committed) still holds, but CLAUDE.md is now a detailed public
   narrative. Flip with `gh repo edit nicolovejoy/raconte --visibility private` if wanted.
7. Nico's calls: delete merged remote branch `feat/journal-editing`; backlog #67 (10 items),
   #73-78, #71, #70 (decoder half), #66, #63, unified-editor #60/#59,
   #29/#50/#51/#54/#55/#18/#35/#47/#46/#44, TestFlight.

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
- **When `m4/sync` merges**, the macOS `test` command above will need
  `CODE_SIGN_ENTITLEMENTS=Raconte/Raconte-nocloud.entitlements` added, and must NEVER
  gain `CODE_SIGNING_ALLOWED=NO` — that flag unsandboxes the app-hosted test runner
  onto the real iCloud-entitled data path rather than a stripped test one. Until that
  merge, the plain commands above work as written on `main`.

## Working style

- Plan → implement → review via subagents, one milestone task at a time (task breakdown
  lives in the M1 design doc). Test-first for the pure core (state machine, recovery
  planner, segment math) — hardware behind protocols.
- Docs: plain and terse. No grandiose prose.
- Signing: team `8UK463WB83` (in project.yml) is a **paid** Apple
  Developer Program membership — the same team MusicForge ships under. Nothing is gated on
  enrollment: TestFlight, CloudKit containers, push and Live Activities are all available
  now. (Verified 2026-07-31 from the on-disk profiles: App Store distribution profiles and
  year-long expiries, neither of which a free personal team can produce.)
- **UI tests reach places through `openPlace(app, "sidebar.…")` in
  `RaconteUITests/UITestNavigation.swift`.** Never hard-code a navigation tap in a test
  class — `openPlace` already handles the iPhone-collapsed-vs-Mac/iPad-both-columns
  difference (back-button vs. straight tap) in one place.
- **Nothing that must happen while a capture is running may hang off a view's
  lifecycle.** `CaptureView` is no longer permanently mounted (nav redesign) — it can
  be navigated away from at any time. Anything that must keep working regardless
  (phase dispatch, the idle-timer hold, receipt reconciliation) lives on
  `CaptureScreenModel` itself, driven by the model's own observation of its state,
  never by `.onAppear`/`.onDisappear`/`.onChange` on a view.
- **`ContentView.swift` is rewritten by both `nav/split-view` and `m4/sync`** and the
  two will conflict on merge — expected and accepted (nav design §10); whichever
  branch merges second resolves the conflict by hand.
- **Never put an `Image` in a macOS `Menu` label.** On macOS a `Menu`'s label discards
  SwiftUI's sizing of a resizable `Image` and paints it at intrinsic size — a 768×1024
  cover photo laid out at 768×1024 *points*, covering the whole screen and pushing the
  rest of the label off-window (#69). Proven by a six-variant harness: no in-place
  clamp and no `.menuStyle` fixes it — the image has to leave the label entirely. A
  `Button` label is fine; the image only breaks inside a `Menu`.
- **A `JournalSpan`/date-range endpoint is a unit, not an instant.** `PartialDate` is
  `Comparable` by `anchorDate`, which fills absent components with the FIRST — "2001"
  anchors to 1 Jan 2001. A naive `start <= d && d <= end` comparison against raw
  `PartialDate`s therefore excludes most of the range it claims to cover. Expand each
  endpoint to its precision's unit before comparing: `start` to the earliest instant of
  its unit, `end` to an EXCLUSIVE upper bound (the first instant of the unit right after
  `end`'s), and test `date >= lowerBound && date < exclusiveUpperBound`. Subtracting a
  fixed second to fake an inclusive bound under-covers the final second of the unit —
  build the exclusive bound from `calendar.dateInterval(of:for:).end` untouched instead.
- **An offscreen `Form` `Section` FOOTER is absent from the accessibility tree until it is
  scrolled into view** — so a UI test asserting on an explanatory footnote below the fold
  finds nothing and fails for the wrong reason. Reveal it with a directional `swipeUp()`
  before querying (a directional scroll, not a fixed distance, so it survives other device
  sizes). Discovered 2026-08-21 on the journal editor's disabled-delete footnote.
- **The `RaconteUI` suite exceeds the Bash tool's HARD 10-minute cap** (600000 ms is the
  maximum the tool accepts), so a single whole-suite invocation is killed mid-run and reads
  exactly like a hang. Split it into two or more FOREGROUND `-only-testing:` invocations by
  test class and reconcile the counts against the baseline. Do **not** background it — a
  subagent never receives the completion notification, which is the single most common
  stall on this project (11 instances). The unit suite still fits inside the cap.
- **A `.sheet` attached to a `Form`'s `Section` silently never presents, on iOS 26** —
  observed, mechanism unconfirmed. Attach `.sheet`/`.fullScreenCover` to the screen's
  outer view (the `Form` itself, or above it), never to a `Section` or other child.
- **`.tap()` on a `Toggle` inside a `Form`/`List` hits the row's merged label+switch
  accessibility frame at its CENTRE, which for a full-width row is the label, not the
  switch — the tap silently never flips it.** Real finger taps work fine; this is an
  XCUITest-harness gap. Tap near the trailing edge instead, e.g.
  `coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5))` — re-tune the offset
  per row width if a wider layout (iPad) is ever covered.
- **A pushed screen that can be popped without warning must write through on commit,
  never hold a Done-button-shaped batch of unsaved edits.**
  `PlaceRouting.detailPath(afterSelecting:from:path:)` always returns `[]`, so any
  sidebar click (and on the Mac, ⌘1-4) pops the top of `detailPath` with zero chance for
  that screen to intervene. The pattern (`JournalEditorView`, matching `BackdateField`):
  commit each field twice, redundantly — on losing focus (the ordinary case), and again
  in `onDisappear` via an **unstructured `Task {}`, never `.task`** (SwiftUI cancels
  `.task` on disappear, defeating the whole point of the safety net).

**UI design rules (owner, 2026-08-02):**
- The capture screen pins a near-black background; any system control placed on it must
  pin `.environment(\.colorScheme, .dark)` — ambient-scheme bubbles render dark-on-dark
  in light mode (bit us once).
- Prefer semantic colors over `Color(white:)` literals anywhere the background isn't
  pinned.
- Backdates are sticky: editable with explicit overrides, never clearable by one tap.
  Owner wants metadata edits auditable eventually (fold into T6 revision design).

<!-- SHARED-CONVENTIONS:BEGIN v=e5fb79b2ef4d — auto-managed, do not edit here; source: prompt-lab/workflow/claude-md-shared.md (edit + re-sync) -->
## Shared conventions

<!-- These are Nico's cross-repo output rules. They're materialized into each repo's
CLAUDE.md so every agent (local, cloud, third-party) sees them as plain text. Source
of truth: prompt-lab/workflow/claude-md-shared.md — edit there and re-sync, never here. -->

- **Clickable URLs.** When pointing at any web destination (dashboard, repo, PR, deploy, settings, docs, localhost), print the full bare URL — `https://example.com` or `http://localhost:8080` — on its own, never just the page's name and never a markdown `[label](url)` link. Nico's terminal auto-linkifies raw `https://` text, so a bare URL is one-click and stays copyable.

- **Number your questions.** Any time you ask Nico more than one question, present them as a numbered list (1., 2., 3.) so he can answer by number with no ambiguity. A single standalone question needs no number.

- **Self-contained smoke-test instructions.** When you ask Nico to manually test or verify an app or website, assume zero carried-over context — he should never scroll back or recall a URL/path/credential from earlier. Always include: the exact URL (full `https://…` or `http://localhost:…`, restated even if mentioned above), the precise steps in order, and what a pass vs. fail looks like. Repetition here is a feature, not clutter.

- **UTC at rest, Pacific on display.** Timestamps are stored in UTC, always. A *calendar day* shown to a human is `America/Los_Angeles` — Nico's day, and the clock the work actually happened on. The two rules that follow are the ones that get broken: never form a date bucket with `new Date(…).toISOString().slice(0,10)` (that is UTC, so every chart axis and "today" silently rolls over at 5pm Pacific — it put a phantom tomorrow bar on the Prompt Lab dashboard), and never bucket UTC-stamped rows with a bare `date(col)` in SQL. Use `Intl.DateTimeFormat('en-CA', { timeZone: 'America/Los_Angeles' })` in JS and an explicit zone in SQL/Python. Storage in local time is also wrong — it can't be migrated across a DST boundary without loss.

- **No marker before a copy-paste command block.** Nico's terminal renders markdown bullets (`-`, `*`, `•`) as `●`, which breaks paste into zsh. The line directly above a fenced command block must be a plain-text label ending in a colon — never a bullet, dash, asterisk, or number. For loud copy targets, lead the label with `📋` + bold `COPY THE BELOW`, then a colon, then the block.
<!-- SHARED-CONVENTIONS:END -->
