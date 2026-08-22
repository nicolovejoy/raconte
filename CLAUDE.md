# CLAUDE.md

Session-by-session history lives in [docs/devlog.md](docs/devlog.md). This file carries only the latest session, project intent, and conventions.

## Session 2026-08-22 (laptop — m4 SDD Tasks 6–11 + 3 ruled wiring tasks BUILT AND REVIEWED; Empty Trash + #82 shipped; CLAUDE.md slimmed; 1606 → 1750 unit)

Marathon session: /readup → roadmap discussion → continuous SDD on `m4/sync` (Sonnet
implementers + Sonnet reviews per the standing cost ruling; every task adversarially
reviewed, every Important fixed and re-reviewed). Branch `m4/sync` `c592752c..6fcd73b6`,
**~20 commits, PUSHED**. Main carries the CLAUDE.md restructure (`e6ad36f8`). Both trees
clean; `stash@{0}` untouched. **Not merged to main; Task 12 + final review + Gate B remain.**

- **Owner rulings landed this session:** corrupt-sidecar deletion block ACCEPTED as
  fail-safe default (tracked as **#81** for a repair route); zero-frame mis-tap blocking a
  journal ruled NOT acceptable → **#82 filed AND BUILT** (on-demand recovery for
  provably-worthless, provably-inactive blockers — planner's own decision is the safety
  valve, owned-decision switch with no `default:`, parked-continuation race pin);
  CLAUDE.md slimmed to an operating manual (history → `docs/devlog.md`, `e6ad36f8`);
  repo STAYS PUBLIC (advice: flipping private bills macOS CI minutes at 10×);
  merged `feat/journal-editing` deleted local + origin.
- **Empty Trash shipped** (owner asked mid-smoke: emptying one-at-a-time was blocking
  test 2): toolbar button on the Trash screen, confirm dialog with count, loops the
  per-entry guard (sidecar re-read per item), one purge + one rescan, honest partial-failure
  alert. Review-approved; the review exposed that the brief's named mutation adversary was
  structurally impossible — adjudicated as a brief defect, and the guard's restore-race
  branch got its own mutation-verified pin (`abffce0b`).
- **Owner smoke, partial:** journal ordering (#79) PASS on both devices. Tests 2–5 (Empty
  Trash, cross-device empty-journal delete, disabled row + footnote, picker freshness,
  mis-tap delete) NOT yet run — devices carry builds at `9280adaf` (Mac dylib `08DF35AC`
  at `~/Desktop/Raconte-m4sync.app`, phone `37E561B0`), which include Empty Trash + #82
  but NOT Tasks 6–11. Build fresh at branch head before the next smoke.
- **m4 SDD Tasks 6–11 all complete** (ledger authoritative:
  `/Users/nico/src/raconte-m4/.superpowers/sdd/2026-08-17-m4-sync-implementation-plan/progress.md`):
  T6 entry+finalize record builders/hooks; T7 assemble-then-commit ingest; T8 per-field
  entry LWW merge (shared `LWWResolve`, clean approve); T9 revision sync (2 fix rounds);
  T10 marker streams (clean approve); T11 purge→CK delete + delete ingest via StagedRemover.
  **Suite 1606 → 1750 unit, green throughout.**
- **THREE PLAN DEFECTS ruled and fixed mid-loop, all the same class** (design names a
  chokepoint no task's file list assigns — now in memory as
  plan-preflight-sweep-design-chokepoints): `recordToPush` never wired for
  entry/audio/liveLog (builders+ingest+merge all existed, nothing pushed — wired as a ruled
  task with single-read discipline and scanner-shared digests); the marker-append
  `noteLocalChange` chokepoint (setSpan precedent: an edit must not wait for a
  reconciliation scan); and T7's pending buffer assumed CloudKit redelivery that does not
  exist.
- **The session's recurring catch, now in memory as inbound-sync-must-land-or-park:
  CKSyncEngine NEVER redelivers a consumed record**, so any ingest path that
  refuses-and-returns is permanent silent loss. Caught three times: T7's in-memory pending
  buffer (pieces split across a launch boundary stuck forever → durable staging with
  at-arrival sha + rehydration), T9's trashed-capture revision refusal (restore never
  recovered the edit → parks via pending-revisions.json, resolved at rehydration:
  restored→ingest, still-trashed→parked, purged→discard per §5 delete-wins), and T11's
  design review. Companion rule: **any parked-state writeback after an await reconciles
  against a fresh disk read** (`reconcileParkedWriteback`/`mergeIntoParked`) — the actor is
  reentrant during suspension (T5 C1's class, re-caught in T9 round 2).
- **T11's Important:** the deleted entry's OWN queued save rested on unverified engine
  dedup — now explicitly withdrawn on both paths and the pre-start buffer dedupes
  save-then-delete. Entries have NO corrective re-push (deleted is deleted — the journal
  corrective re-push stays journal-specific per the #80 owner ruling).
- **Review-accepted deviations worth knowing:** the Revision record gained `entryRef` (the
  design's schema table had no captureID field and the record name carries only the ULID);
  design §2's stated marker record name `<captureID>.m.<deviceID>` is actually
  `m.<captureID>.<deviceID>` on the wire (pre-existing doc drift, fix on next doc touch).
- **Process:** 1 background-suite stall (12th) + 2 machine-sleep kills (lid-close defeats
  `caffeinate -ims`), each recovered by a single verified-state resume; one implementer
  self-caught a `git checkout --` that discarded work mid-task and redid it — the reviewer
  independently confirmed nothing half-restored. `continueAfterFailure = false` verified in
  new UI test classes. CI's docs-only red on main (8/21) did not recur — next run green.

**Next steps:**
1. **Resume the m4 SDD loop at Task 12** (debug status screen; decide `stash@{0}` — the
   inert fetch-debounce scaffolding — per the plan). Read the ledger FIRST; its RESUME
   POINT block carries the accumulated **Gate B agenda** (entries end-to-end from the
   composition root on real devices; second-CK-delete-no-op is only fake-verified; T8's
   missing Mirror field-count tripwire for EntryMetadata/RemoteEntryFields — triage
   must-fix-before-merge; M1 engine conflict routing still unfakeable; refuse-vs-park sweep).
2. **Final whole-branch review (Opus) + Gate B acceptance** (delete-app-reinstall-
   reconstructs) — point the final reviewer at every deferred-minor/parked ledger line.
3. **Fresh smoke builds at branch head** (both devices; ditto + dylib-UUID check; wireless
   devicectl) — first builds where entries can actually sync device-to-device. Owner smoke:
   the pending tests 2–5 (Empty Trash both devices; delete an empty journal cross-device;
   disabled row + footnote; picker freshness; mis-tap → immediate journal delete per #82)
   PLUS the first-ever entry sync check (record on phone → entry appears on laptop).
4. **`m4/sync` → main after Gate B + smoke.** CLAUDE.md will conflict (this file was
   restructured on main; the branch's Commands section supersedes — graft it onto the slim
   structure).
5. Nico's calls: #81 repair route timing; backlog #67 (10 items), #73–78 (cheap Sonnet
   batch post-merge), #70 decoder half, #68 (macOS cover picker — still the only Mac cover
   path), #66, #63, unified-editor #60/#59, TestFlight (flip aps-environment first).

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
