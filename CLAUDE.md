# CLAUDE.md

Session-by-session history lives in [docs/devlog.md](docs/devlog.md). This file carries only the latest session, project intent, and conventions.

## Session 2026-08-29 pm (laptop — TestFlight build 12 shipped; CI cost fixed; two redesign gaps filed)

**Build 12 is on TestFlight, both platforms** (`EXPORT SUCCEEDED` for iOS and macOS),
carrying the whole UX set (#112/#113/#114/#115). 2009 unit / 57 UI green on that tree —
the UI suite ran as four `-only-testing` splits (13+16+13+15), since even six classes
blows the Bash 10-minute cap. PR #116 merged: the version bump, plus two fixes found
along the way.

**CI cost, found from a $273 GitHub billing alarm.** raconte is a PUBLIC repo, so Actions
on standard runners is 100% discounted and *nothing was actually charged* — the panel
shows gross metered usage next to a matching discount. But it was $251.91 of gross usage
in August: 222 runs, each spawning TWO `macos-26` runners for ~30 min. **93 of 180 main
runs were docs-only commits** (devlog, handoff, plan docs), cold-building Xcode twice to
prove a markdown file didn't break the app — over half the spend. Added `paths-ignore`
on `docs/**` and `**/*.md` to both triggers. Safe because main has no branch protection
and no rulesets (verified); with a required check, a path-filtered skip sits "expected"
forever and blocks docs-only PRs — the workflow comment records the skipped-inner-job
alternative. Also: the unit job is only ~2 min; the iOS-simulator UI job is essentially
the entire bill.

**Owner device smoke on build 12: Home looks right, nav bar and capture screen still look
like the old app.** Diagnosed by grepping the token layer — exactly four files consume
ink & paper tokens (`HomeView`, `EntryDetailView`, `EntryInfoSheet`, `JournalPickerSheet`);
`LibraryView`, `SidebarView`, `ContentView`, `CaptureView` use zero. Two distinct causes,
now filed:
- **#117** — the library + sidebar restyle was the *other half of PR 3* (`ux-redesign-design.md`
  specified "journal picker **+ library**"); PR #114 shipped only the picker sheet and the
  rest was never filed. Straight unfinished work; the issue carries the full spec.
- **#118** — the capture re-skin was PR 4, consciously replaced when #108 became the Home
  bookshelf, and never re-planned. Needs a *design* pass, not a build: the old mocks assumed
  capture was the landing screen, so the idle state, the demoted-controls pull-up, and the
  recovery banners are all moot. Only the recording-state design plausibly survives.

Doc fix: `docs/testflight-deploy.md` told you to bump `CFBundleVersion` in
`Raconte/Info.plist`, which XcodeGen GENERATES — the exact trap that reset the build
number 2→1 on 2026-08-24. Now points at `project.yml`.

**Next steps:**
1. **Invite Lori** (internal tester, all devices): invite email sent 2026-08-29; when her
   Apple Account email arrives → ASC Users and Access → Customer Support role → TestFlight
   Internal group, automatic distribution on. Build 12 is already up and waiting.
   Fresh-install path: bootstrap mints a default "Journal", so her Home starts with one
   coverless card.
2. **Finish build-12 smoke.** Home shelf with real covers confirmed good on device. Still
   unverified: **the dark recovery-banner card on paper** — force-quit mid-capture, relaunch,
   check it's legible in BOTH light and dark mode (dark-on-dark is the known trap).
3. **#117 — library + sidebar restyle.** The dropped half of PR 3; spec is in the issue.
   This is the visible seam the owner noticed, and the cheapest of the two to close.
4. **#118 — capture screen.** Needs a short design pass first (what is capture now that
   it isn't the front door?), not a straight build.
5. **Home follow-ups** (parked at #115's final review, listed in the PR body): gate
   recovery-banner Play on live capture phase (mirror `CaptureSidebarRow.isLive`);
   spine-tap UI test (4-journal seed); last spine row draws a trailing hairline;
   deleted-journal fallback `.capture` → maybe `.home`.
6. Remaining sync hardening, demoted: #91 (reconcile-on-foreground), #85 (park inbound
   asset failures). Capture Schema → History for the three unidentified deployed changes.

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
