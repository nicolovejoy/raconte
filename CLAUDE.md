# CLAUDE.md

Session-by-session history lives in [docs/devlog.md](docs/devlog.md). This file carries only the latest session, project intent, and conventions.

## Session 2026-08-30 (laptop — PR #119 merged; record flow + Discard + About tutorial, PR #124 open)

**PR #119 merged** (#117 closed). Then the record-flow build shipped via SDD from
`docs/plans/2026-08-29-record-flow.md`, 8 tasks, **PR #124 open and unmerged — merging is
Nico's.** https://github.com/nicolovejoy/raconte/pull/124

**Owner rulings this session:** (1) record-flow **option 1** — the library's floating button
and Home's "New entry" now START recording on arrival (`CaptureScreenModel.beginCapture(inJournal:)`),
instead of preselecting + routing to capture's idle screen; (2) discard semantics **trash,
not hard delete** — a mis-tap goes to Trash, restorable 30 days, same rule `delete(_:)`
refuses to except; (3) About gains a short "what this is / how it works" for a first-time
TestFlight user (Lori) — copy is written to be rewritten.

**`Discard` stops through the ORDINARY `done()` path** and lets the capture finalize
normally — the m4a is verified and promoted exactly as for a kept reading, nothing is left
half-written — then the entry is trashed. Supporting change: `bootstrap()` is now
**await-once** (a stored `Task`), so a caller arriving from the library waits for the
launch-recovery scan instead of racing it.

**The finding worth remembering: never infer WHICH capture an intent refers to from
`finalizeQueue`.** The plan trashed every id in it; fix round 1 narrowed that to `.last`
(matching `buildReceipt`); the final fix wave PROVED both wrong, 3/3 runs — on a launch that
healed an orphaned capture, an early drain makes `transcribed == [recoveredID]`, so a discard
trashed the RECOVERED reading and kept the mis-tap. `discardCurrentCapture()` now snapshots
`coordinator.activeCaptureID` at arm time and trashes THAT id. Removes the dependency on
#122's race and made the regression test landable (it had been blocked all branch).
Also fixed: an armed discard could survive a dropped `done()` (no `(.resuming, .done)` row in
`CaptureMachine`) and trash a later, longer reading; the Discard button rendered 12pt on
macOS, under the 16pt floor, because it used a raw font instead of `captureLabel`.

**Process note: the reviews caught more defects in the PLAN than in the implementations** —
three test specs that could not fail (two at pre-flight, one caught by an implementer that
instrumented the code rather than shrugging), plus two wrong implementations the plan
mandated. Unit 2032 green; `NavigationUITests` 14/14; `AboutUITests` needed a `swipeUp` once
the tutorial pushed the diagnostics below the fold (CI caught it — Task 8 only ran
`NavigationUITests`).

**Owner smoke is PARTIALLY DONE and must be resumed.** Step 1 (floating button arrives
already recording) PASSED. Step 2 (Discard) FAILED and was fixed: *"the transcription stays,
though not in the journal is it visible."* `CaptureView.transcriptRegion` rendered on "is
there text" alone and never asked `CaptureLayoutModel.showsLiveTranscript`. The transcription
session deliberately holds the finished text after a stop, and a fresh coordinator does not
clear it — it belongs to the session. On the ordinary path the receipt covers that region, so
nobody ever saw the stale text; discard nils the receipt and uncovered it, stranding the
words of a recording that no longer exists on the landing screen. That is the #53-era defect
`showsLiveTranscript` exists to prevent; the view was simply not asking. Fixed in `8edb3db3`
(one condition). **Latent since the receipt landed — not introduced by this branch.**

**No automated test pins that fix.** The simulator does not reliably produce transcription
text, so a UI test asserting "no transcript after discard" would very likely pass without
ever having had text to leave behind — vacuous, which this plan hit three times already.
Decide after the re-smoke: file the coverage gap, or find a seam that makes it real.

**Next steps:**
1. **Resume owner smoke** on `~/Desktop/Raconte.app` — REBUILT after the fix, debug dylib
   UUID `5E1BAC32` (the failed pass was `FE06F091`; quit the old app first). Re-run step 2,
   then steps 3-7, from the bottom of `docs/plans/2026-08-29-record-flow.md`. Step 6 is the
   known swallowed-tap gap: if it reads as broken rather than merely slow, fix it instead of
   filing it. Step 7 is the About copy — read it as Lori would; it is meant to be rewritten.
2. **Merge PR #124** once CI is green and the smoke passes (Nico). CI was in flight on
   `8edb3db3` at handoff; earlier runs on this branch show `cancelled` because each push
   supersedes the last, not because anything failed.
3. **#118 — capture screen design pass** (what is capture now that it isn't the front door,
   and now that arriving there means you are already recording?).
4. **Invite Lori**: when her Apple Account email arrives → ASC Users and Access → Customer
   Support role → TestFlight Internal group. Next TestFlight build should include #119+#124.
5. **New issues from this branch:** #122 (phase flips before `enqueueFinalize`, so a finish
   can drain a stale queue and strand the real capture — the branch no longer depends on it),
   #123 (a disk-full inside the ~300ms stop flush can resurrect a capture with its discard
   still armed). Both fail in the keep-the-audio direction.
6. **Parked polish** (unchanged from last session): NeutralCoverTile non-square overload +
   migrate `HomeView.faceOutCover`; `EntryMonthGroup.id` salt; cache the month formatter;
   "Add Cover" pill routes to editor not picker. Plus sync hardening #91/#85, dark
   recovery-banner smoke still unverified.

## Session 2026-08-29 late (laptop — #117 shipped: library + sidebar restyle, PR #119 open)

**#117 built end-to-end via SDD resume** of `docs/plans/2026-08-29-ux-redesign-implementation.md`
(its Tasks 11–12 — the half PR #114 dropped; the old ledger proved Tasks 1–10 shipped, and
Tasks 13–15 stay superseded by #118). **PR #119 is open against main, unmerged — merging is
Nico's.** https://github.com/nicolovejoy/raconte/pull/119. Library: 190-pt cover band
(3-stop scrim), 56-pt entry-own-image thumbs, month sub-headers, floating 60-pt record
button (`library.record`, wired via existing `CaptureScreenModel.selectJournal` +
`router.select(.capture)`). Sidebar rows: cover thumbs + `inkSecondary` subtitles.
`NeutralCoverTile` extracted from the picker as the one shared coverless tile;
`JournalHeaderCard` deleted. 2017 unit green; Navigation 11/11, ImageCapture 3/3,
JournalEditor 10/10, EntryPaging 3/3.

**Final whole-branch review (opus) caught a real bug the task reviews missed**: month
headers fabricated "January" for `.year`-precision backdates (the `anchorDate` month-fill
trap, one file over from `weekdayText`'s own refusal). Fixed: nil-month groups render no
header. Also fixed from review: stronger band scrim, bottom `safeAreaInset` so the
floating button can't hide the last row.

**Owner smoke on the branch build drove three more fixes** (all on PR #119): the macOS
Choose Journal sheet was an unsized clipped card → `minWidth 400/minHeight 460`; imageless
entry thumbs showed a mic glyph → plain quiet tile; coverless journal tiles' `book.closed`
read as "a paper-towel dispenser" → serif first-letter monogram (`NeutralCoverTile.monogramText`,
unit-pinned). Trap re-learned: a NEW test file silently doesn't run until `xcodegen generate`
— the suite reported green at the old count first.

**Owner smoke also surfaced a flow gap, undecided**: browsing a journal doesn't follow you
to capture, and the floating record button lands on capture's idle screen where the
"Last entry" card reads as noise. Three options were laid out; owner hasn't picked.
Recommendation on file: option 1 — the journal page's record button *starts recording
immediately* (what the design doc's "starting capture into that journal" says), sidebar
navigation keeps its own current journal; anything fancier belongs in #118's redesign.
Filed down-the-road: #120 (choose the cover slice the band shows), #121 (crop tool at
image capture).

**Next steps:**
1. **Merge PR #119** once CI is green (Nico). The owner smoke passed on the final build.
2. **Record-flow build (good first task for an opus agent):** confirm option 1 with the
   owner, then: floating `library.record` starts recording on arrival (today it only
   preselects + routes); check the Home "New entry" button for the same idle-screen
   detour. The three options and the owner's complaints are in this section above.
3. **#118 — capture screen design pass** (what is capture now that it isn't the front
   door?). The record-flow decision feeds this.
4. **Invite Lori** (unchanged): when her Apple Account email arrives → ASC Users and
   Access → Customer Support role → TestFlight Internal group. Build 12 is up; next
   TestFlight build should include #119.
5. **Parked polish** (post-#119, from reviews): NeutralCoverTile non-square overload +
   migrate `HomeView.faceOutCover`; JournalPickerSheet coverless tile → monogram is done
   but its `cover(for:)` still hand-rolls on main until #119 merges; `EntryMonthGroup.id`
   salt against duplicate keys; cache the month formatter; "Add Cover" pill routes to
   editor not picker (disclosed deviation). Plus prior parked: Home follow-ups (#115 PR
   body), sync hardening #91/#85, dark recovery-banner smoke still unverified.

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
nothing. Needs the iCloud capability enabled on the App ID.

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
