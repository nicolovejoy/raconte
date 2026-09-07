# CLAUDE.md

Session-by-session history lives in [docs/devlog.md](docs/devlog.md). This file carries only the latest session, project intent, and conventions.

## Session 2026-09-06/07 (laptop — overnight SDD run #2: 13 tasks, four PRs open, unit CI green)

Reviewed the week, took four rulings from the owner before he left (slate = Phase 1
hardening + export; #2 held; full-fidelity export with a folder picker; the M4 reinstall
gate has NEVER been run), wrote `docs/plans/2026-09-06-overnight-hardening-export-plan.md`
and ran it via SDD: four worktrees from `main` `2a1b4fbd`, two implementers at a time on
disjoint branches, Sonnet for implementers and task reviewers, Opus for the four
whole-branch reviews, one fix wave + one scoped re-review per branch. Owner merges in
order **#150 → #152 → #153 → #151**, "Update branch" between each.

- **PR #150** `feat/sync-land-or-park` — Closes #85, #91. Durable `sync/parked.json`;
  every refusal in six ingest functions parks with a distinct reason and a clean ingest
  unparks (three reviewers walked every early `return`); new engine verb
  `refetch(recordNames:)` (chunked at 100, same `acceptRemote` path) run by
  `retryParked` on launch (all names) and foreground (attempts < 10), gone-from-server
  unparks loudly; `UnknownItemResend.plan` resends a NOT_FOUND child with its Entry in
  the same event; `IngestDropReason` deleted as dead code. **Fixes FUTURE losses only**
  — earlier drops were never parked. Unit **2124** (CI matched).
- **PR #152** `feat/81-unreadable-entry-repair` — Closes #81. `StagedRemover.quarantine`
  renames `captures/<id>/` into `<container>/quarantine/<ULID>-<id>/` (not backup-excluded,
  invisible to sync and to `purge()`); Trash screen "Unreadable entries" section with a
  confirmed Quarantine action; destination logged at `.notice`. Recovery by hand is
  macOS-only (iOS container is not browsable). A resync re-creates the capture from the
  healthy server sidecar, by design. Unit 2088, UI **63** (+1 `TrashRepairUITests`).
- **PR #153** `feat/small-debt-2026-09-06` — Closes #71; #67 items 2, 3, 4 (commented,
  not closed). Out-of-span glyph + detail sentence, flagged never blocked;
  `PlaceRouting.reroute` keeps a pushed **entry** when a journals pull removes the
  current journal (routing rule proven; the SwiftUI path-survival half is unverified and
  unreachable from a UI test); `journalDateLines` once per rescan; `CaptureLiveBadge` is
  the only `.elapsed` reader; `formatDuration` → `RecFormat.clock` (rounding became
  truncation). Unit 2101.
- **PR #151** `feat/archive-export` — the v1 export. About → Archive → Export archive…
  → folder picker → byte-copy package with a derived `transcript.md`, sha256 for every
  file, manifest written last, `.part` staging; `ArchiveVerifier` reads it back from its
  own `revisions/` (with the C1 dedupe rule); `docs/export-format.md` incl. a
  `jq | shasum -c` recipe; user-selected-files entitlement in all three files. Unit 2117.
  New issues: #154 Verify archive… row, #155 `CaptureView.statusRow` per-tick
  re-evaluation, #156 parked count on Debug/About.

Process: 13 tasks, 8 task-level fix rounds, 4 branch fix waves, zero breaker trips, no
rate-limit hit. One stall (Task 9: a foreground UI run past the Bash tool's 120 s default
auto-backgrounded — new memory). One reviewer false positive (a fallback granted in the
dispatch, invisible to the reviewer — new memory). One plan-authored test turned
tautological by its own task's refactor, caught only at the Opus branch review — new
memory. **The UI CI jobs on all four PRs were still running at handoff (~37 min each,
queued behind one another); unit CI matched the local counts exactly on #150/#151/#152.**
Worktrees under `.worktrees/` are left in place until the PRs merge.

**Next steps:**
1. **Merge #150 → #152 → #153 → #151** after confirming each PR's UI job is green (`gh pr
   checks N`; expected UI 62 / 63 / 62 / 62) and hitting **Update branch** before each.
   The four branches have disjoint file sets, so conflicts are not expected; the
   update-branch CI run is the proof.
2. **Device smoke, build 15 first** (unchanged from the last handoff), then a **Mac smoke
   of the merged main** as build 16: export to an external volume and verify; corrupt one
   `entry.json` → Trash shows the section → quarantine → journal deletes; span a journal
   → glyph and sentence; record past the sidebar clock. Self-contained steps are in each
   PR body.
3. **M4 acceptance gate, never run** — with a synced Mac: quit, move
   `~/Library/Application Support/Raconte` aside (never delete), relaunch, let sync settle,
   export with #151's action, verify, compare counts with the iPhone. Only after this
   passes does any recountly teardown get scheduled (the backup at
   `~/recountly-export-2026-09-06/` stands).
4. Owner questions still open from the roadmap review: re-transcribe migrated audio or
   carry the web transcript; #133 v1 or v2. #50 needs its own design pass (head.json
   fingerprint) — deliberately not built. #2 held.

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

**Signing changed with M4 (2026-08-17) — the old bare macOS commands no longer work.**
The app now carries `com.apple.developer.icloud-*` entitlements, which are *restricted*:
macOS refuses to ad-hoc-sign a binary that has them (`"Raconte" has entitlements that
require signing with a development certificate`). Two macOS recipes, and it matters which:

Test (macOS) — ad-hoc signs against `Raconte-nocloud.entitlements`, the shipping list
minus the three sync keys. **Keeps the sandbox, which is not optional**: `RaconteTests`
runs with the real app as its test host, so an unsandboxed run makes `AppContainer.root()`
the owner's real `~/Library/Application Support/Raconte` rather than a container — the
launching app would scan and sweep his actual archive. Never `CODE_SIGNING_ALLOWED=NO`
here. (`EntitlementsParityTests` pins the override against the generated file, so adding
a capability to project.yml and forgetting the override fails loudly.)

📋 **COPY THE BELOW**:

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS=Raconte/Raconte-nocloud.entitlements test
```

Owner-smoke app build (macOS) — real automatic signing, so the app actually carries the
iCloud entitlement. **This is the only macOS build that can sync.** An app built with the
nocloud override launches and behaves normally but `SyncCoordinator.live()` returns nil
(it reads the signature's entitlement), so a sync smoke against it silently tests
nothing. Needs the iCloud capability enabled on the App ID. Bump `CFBundleVersion` and
append `docs/builds.md` first — About shows `build N: <date>` (#141).

📋 **COPY THE BELOW**:

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' \
  -derivedDataPath /tmp/raconte-smoke -allowProvisioningUpdates build
```

Hand the result over with `ditto`, never bare `cp -R`, and verify identity with
`dwarfdump --uuid` on `Raconte.debug.dylib` — see the DerivedData/stale-build traps above.

- iOS compile check: `xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'generic/platform=iOS' CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build`
- iOS simulator: `-destination 'platform=iOS Simulator,name=iPhone 17'` (check `xcrun simctl list devices` for available names). Simulator builds need **no** entitlements override — they don't validate restricted entitlements against a profile.
- UI tests (simulator only — macOS needs interactive automation permission):
  `xcodebuild -project Raconte.xcodeproj -scheme RaconteUI -destination 'platform=iOS Simulator,name=iPhone 17' test`

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
- **A UI test that scrolls to reach a row must scroll UNTIL IT FINDS IT, never a fixed
  number of swipes.** The rule above (directional, not a fixed distance) survives a change
  of device; it does not survive a row being ADDED above the assertion, which silently
  pushes the target back below the fold. That is exactly how #118 §7 broke
  `AboutUITests` — one row into About's App section moved three assertions out of reach of
  its single `swipeUp()`. The durable form is `AboutUITests.revealRow(_:_:)`: swipe, check,
  repeat to a bound, since swipes past the end of a list are no-ops. Call such helpers in
  top-to-bottom document order — the scroll only goes down, so a row checked after a lower
  one may already have left the tree off the top.
- **A straggler grep scoped to the target you changed misses the rest of the repo.** #118's
  Task 5 grepped `RaconteUITests` for deleted identifiers and found zero; `Place.swift`,
  `LibraryView.swift` and `HomeView.swift` still named them in comments, and one comment
  cited a test the same PR deleted. Grep `Raconte RaconteTests RaconteUITests` — all three —
  for every deleted symbol, identifier and test name, and drive present-tense hits to zero.
- **`git checkout <branch>` fails when that branch is checked out in a worktree, and a
  chained `&&` command carries on with whatever was already checked out.** The owner's
  measurement build silently ran on `main`. Build from the worktree directory instead, or
  verify the built dylib carries a string only the branch has (`strings … | grep`).
- **`Logger(...).info` lines are not persisted to disk by default** — `log show` returns
  nothing even with `--info` once the process has moved on. Use `.notice` for anything the
  owner will read back after the fact.
- **A phrase grep misses prose that wrapped across a line.** #118 §7 listed three stale
  doc comments; there were FOUR. `JournalHeaderView`'s copy read `permanently-\n  mounted`,
  so every grep for the phrase found three and silently missed `RecordControlsRow`. When
  auditing COMMENTS rather than code, grep a short distinctive fragment that cannot wrap
  (one word, e.g. `permanently`), then count the hits to zero — a phrase match is evidence
  of nothing.
- **A cloud session cannot build or test this project.** Claude Code on the web runs a
  Linux container with NO Swift toolchain — no `xcodebuild`, no `xcodegen`, no `swiftc` —
  so an unattended cloud task cannot run either suite, and CI on the macOS runners is its
  only verification. Write cloud-task prompts that expect this: end at an open PR and let
  CI judge it. What a cloud session CAN still check locally is real: brace/paren balance,
  that a removed accessibility identifier is referenced nowhere, and `git merge-tree` for
  conflicts against a moved main.
- **"Verify the executed test count CHANGED" has an exception: an assertion added to an
  EXISTING test does not move it.** #118 §7 added the `about.buildStamp` assertion inside
  `testAboutScreenShowsVersionEnvironmentAndSyncRows`; UI stayed 61 → 61, correctly. The
  honest verification there is that the count matches the same-day baseline on main (so
  nothing was skipped) and that the run is green with `continueAfterFailure = false` — a
  missing row would have failed the test, not lowered the count.
- **Take the test-count baseline from the latest main CI run, never from a commit
  message or a PR body.** Those numbers go stale the moment anything merges. PR #127
  predicted "2006 against a baseline of 2009" from #116's commit message, which two
  merges (#119, #124) had already overtaken — the real baseline was 2032 and the real
  result 2029. The delta was right and the absolutes were nonsense, which is the
  dangerous shape: it looks like verification. Read `Executed N tests` out of the job
  log of main's most recent CODE-carrying run (docs-only pushes skip CI, so "most
  recent run" is not always the most recent commit). Main after #126+#127: **2029 unit
  (1 skipped), 61 UI**.
- **Two PRs branched from the same base can both be green and still merge into a red
  main.** #126 and #127 both had base `1ea4fe8` and merged 52 seconds apart, so neither
  one's CI ever saw the other's changes; the first run to test the combination was
  main's own, after both were already in. It came out green — the file sets were
  disjoint — but that was luck, not process. When two PRs are open at once: merge one,
  wait for main to go green, then hit **Update branch** on the second before merging it,
  which forces its CI to test the actual combination. Cheap, and it turns "probably
  fine" into evidence.
- **The build stamp lives in About, not on the capture screen** (#118 §7, merged in
  https://github.com/nicolovejoy/raconte/pull/126). Read it at sidebar → About → App →
  `Build`; it is a different fact from the `Version` row beside it, which is the same on
  every install of one build submission. `dwarfdump --uuid` remains the only build identity
  worth quoting when the two disagree.
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
