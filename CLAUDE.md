# CLAUDE.md

## Session 2026-08-15 evening (laptop — #53 ROOT-CAUSED + DESIGNED, owner-approved, NOT built)

Very short session (owner had to reboot). Zero code written, tree clean. Everything below
is a fresh agent's starting point: the diagnosis is confirmed by reading, both owner
rulings are in hand, and the next step is implementation.

- **#53 root cause, confirmed by reading — the two symptoms are ONE defect.**
  `CaptureView.body` (`Raconte/Capture/UI/CaptureView.swift:706-792`) is a **single outer
  `ScrollView`** holding everything in one `VStack(spacing: 28)`: journal header →
  backdate → multi-voice → recovery banners → **transcript** (`:741-750`, capped
  `maxHeight: 160`) → status line → mic meter → record button → `MarkerControlsRow` →
  Done → recents → build stamp. The controls live *inside* the page scroll, *below*
  content that grows. So the transcript block appearing shoves record + voice switch down
  ~188 pt (160 + spacing) — the original drift report — and since the ¶ button was
  already noted below the fold on iPhone (CLAUDE.md 2026-08-07), a long entry pushes the
  voice switch off-screen entirely. **"Disappeared" = scrolled out of view, not removed.**
  Ruled out as the cause: `MarkerControlsModel.make` (`Raconte/Capture/UI/MarkerControls.swift:22`)
  never hides the voice switch in `.recording`/`.interrupted`/`.resuming` — visibility is
  purely `multiVoice`, so nothing conditionally removes the control.

- **Owner ruling 1 — fix #53 STANDALONE now, do NOT fold into the capture-landing
  redesign.** Reason: `docs/plans/2026-08-08-capture-landing-decisions.md` item 1 says the
  owner wants to iterate again on the capture interface *specifically*, "later, not now",
  and wants that look discussion on a larger screen (iPad/Mac). So that build isn't ready,
  and this bug blocks recordings today. **Layout only — no palette, typography, or IA
  change** (icon-blue / serif / lowercase `ln`-`bn` all stay queued for the redesign,
  which later inherits the fixed-controls constraint).

- **Owner ruling 2 — "pin controls, simplify the recording view."** Approved layout:
  - **Fixed bottom control bar in EVERY phase** — status line, mic meter, record button,
    `MarkerControlsRow`, Done, and the error text move OUT of the page scroll into a bar
    pinned to the bottom. They never move, idle or recording. This is the actual #53 fix.
  - **While recording**: hide the Recent list (a browse affordance nobody uses mid-read)
    and the Two-voices toggle (already `.disabled` outside `.idle` at `CaptureView.swift:1090`
    — pre-record only by design, so hiding it loses nothing). The **transcript expands to
    fill the space above the bar** with its own independent scroll, replacing the 160 pt cap.
  - **Backdate stays reachable** by scrolling the region above the transcript — unlike the
    two-voices toggle it is NOT phase-gated (`BackdateField`, `:1005`) and writes through
    to the live capture's `entry.json` mid-recording, so it must not be removed.
  - **Idle layout unchanged.**

- **Implementation notes for the next agent** (not yet started, nothing on disk):
  1. Put the visibility rules in a pure, testable `make(phase:)`-style model next to
     `MarkerControlsModel` (same file/pattern, exhaustive `switch` with no `default`) —
     which sections show per phase. That is the unit-testable core; TDD it red-first.
  2. **The honest pin for #53 is a UI test**, not a unit test: the simulator harness
     already exists (`RACONTE_UITEST_ID` synthetic sine recorder,
     `Capture/Debug/UITestSupport.swift`, scheme `RaconteUI`). Assert the
     `capture.voiceSwitch` / `capture.record` frames are UNCHANGED before vs. after the
     transcript grows, and that the voice switch stays hittable. A layout fix with no
     frame assertion is exactly the vacuous-fixture shape this repo keeps hitting.
  3. Watch the `.environment(\.colorScheme, .dark)` pins when moving controls (#58): the
     subtree pin must travel with each moved control — and NEVER `.preferredColorScheme`,
     since `CaptureView` is the permanently-mounted NavigationStack root.
  4. Nested same-axis `ScrollView`s: the transcript's inner scroll currently sits inside
     the outer page scroll. The new structure should make the transcript's scroll the only
     one in that band, not a nested one.

- Session hygiene: CI green (5/5 recent runs on main), CLAUDE.md conventions in sync,
  0 unsummarized days, no other worktrees or agents. Stale local `design/capture-landing-mocks`
  is 5 behind origin (ignorable — that branch also carries committed `.build/` junk;
  cherry-pick from it, never merge).

**Next steps:**
1. **Build #53** to the approved layout above — it is fully ruled, nothing blocking.
2. Owner smoke: #58 macOS light mode (PR #61 body has exact steps); phone check that the
   new nav-title weekday layout reads right on the Dec 8, 2025 entry.
3. Unified-editor design pass (#60, #59) — unchanged from prior handoffs.
4. ASC credential hygiene → TestFlight upload — orientations blocker merged; owner still
   needs to rotate the ASC key.
5. Queued design passes: capture-landing redesign (now owes the fixed-controls constraint
   as a named requirement), #54 prev/next, #55 bubble hierarchy, #38 voice-label
   mistranscription, #26 capture pause.

## Session 2026-08-15 (laptop — detail nav-title weekday fix; #53 identified as next, NOT started)

Short session. Owner smoke-tested PR #61's #48 weekday work live and found the layout
wrong; fixed same-session. Then owner asked what's queued for capture, which surfaced
#53's severity has changed — that's next session's target, described below for a fresh
agent to pick up directly.

- **Detail-screen weekday placement fixed** (`c82bb1ef`, TDD red→green,
  `EntryDetailViewNavigationTitleTests.swift` new). Owner's complaint: the weekday
  landed in its own caption line below an "Entry date" row that just repeated the nav
  title's date — redundant, and not "up there" where he was looking. Fix: nav title
  itself now reads "Mon, Dec 8, 2025" (weekday only at day-precision backdates, same
  #48 rule as before) and doubles as the tap-to-edit affordance issue #49 gave the old
  row (`EntryDetailView.navigationTitleView`, `.toolbar { ToolbarItem(placement:
  .principal) }`). The standalone "Entry date" row and "Mon" caption are gone. 1215
  unit tests green (was 1212). Built for and installed on the phone
  (`0CE992E2-8065-5FAB-A2E2-064D9712A522`), pushed to origin/main.

- **NEXT: #53 — capture screen controls, now a functional bug, not polish.**
  Original report (2026-08-12): live transcript text pushes the record button and
  multi-voice switch around on screen, so a muscle-memory tap misses. **Owner smoke
  2026-08-14 escalated it**: on a long entry (the Dec 9, 2025 recording) the voice-
  switch button *disappeared entirely* partway through — not drift, gone. That makes
  voice marking impossible mid-entry on any long capture. Requirement (owner's own
  words): "need the controls to stay put." Fix shape: during an active recording, the
  record/stop button, voice switch, and paragraph button must have FIXED positions
  regardless of transcript length — the transcript area scrolls/clips within its own
  region instead of reflowing the controls. Source: `Raconte/Capture/UI/CaptureView.swift`.
  Design already scoped as a named requirement of the capture-landing redesign
  (`docs/plans/2026-08-08-capture-landing-decisions.md`, IA + type + palette all
  locked) — **fold #53's fixed-controls constraint into that build rather than
  patching CaptureView twice.** A next agent should read that design doc first, then
  either (a) brainstorm/plan the capture-landing implementation with #53 as a named
  layout constraint, or (b) if the owner wants #53 fixed standalone first, scope a
  smaller layout-only fix to CaptureView (pin controls, isolate the transcript in its
  own scrolling container) as a stopgap.
- Reviewed full open-issue list against CLAUDE.md's own capture-related next steps
  (#53, #58, #38, #26, #2, #1) — no drift found; #58 stays open pending the owner's
  macOS light-mode smoke test from PR #61 (steps in the PR body).

**Next steps:**
1. **#53** — capture screen fixed-controls fix, see problem description above. Start
   by reading `docs/plans/2026-08-08-capture-landing-decisions.md`.
2. Owner smoke: #58 macOS light mode (PR #61 body has exact steps); phone check that
   the new nav-title weekday layout reads right on the Dec 8, 2025 entry.
3. Unified-editor design pass (#60, #59) — unchanged from prior handoffs.
4. ASC credential hygiene → TestFlight upload — orientations blocker merged; owner
   still needs to rotate the ASC key.
5. Queued design passes: #54 prev/next, #55 bubble hierarchy, #38 voice-label
   mistranscription, #26 capture pause.

## Session 2026-08-14 evening (laptop — 5-item Sonnet batch SHIPPED, PR #61 merged; 1201 → 1212 tests; secrets hard-block)

Owner low on tokens: everything ran on Sonnet subagents (implementers AND reviewers,
owner directive) in one SDD loop, 3 dispatches for 5 items, worktree `raconte-b5`
(deleted after merge). Both fix rounds were real catches.

- **PR #61 merged by owner** (`43076bae`, closes #42/#48/#49): the five #42 test pins
  (allocationCollision via widened `beforeWrite` seam; DeviceIdentity off real
  UserDefaults; F18 seeded/reproducible; closeDraft-on-trashed pinned via the
  equal-text no-op branch — the only path where its own guard is load-bearing;
  F11 half-open boundary), #58 capture legibility, TestFlight orientations keys
  (iPhone portrait, iPad all four — **upload now unblocked** pending ASC key rotation),
  #49 backdate affordance (button gone once set; the date itself opens the sheet),
  #48 weekday (day-precision BACKDATES only, rows "Tue"/detail "Tuesday", via
  `Calendar.weekdaySymbols` — `Date.FormatStyle.weekday` has an in-process width-leak
  bug, reproduced and documented in PartialDate).
- **Fix round catches:** (1) first #58 fix used `.preferredColorScheme(.dark)` inside
  CaptureView — the permanent NavigationStack root — which would have forced the WHOLE
  window dark in light mode; reverted to subtree `.environment` pin + `.toggleStyle(
  .switch)` + white tint at the capture call site only. (2) the tappable backdate row
  repeated this file's own Task-6 VoiceOver flattening bug; fixed with
  `.accessibilityElement(children: .combine)` + explicit label.
- **NEW TRAP VARIANT: GitHub close-keywords fire from PR BODIES too.** PR #61's body
  said "Close #58 manually if it passes" — GitHub closed #58 on merge. Reopened.
  The commit-message rule now extends to PR bodies: reference issues without a
  close-verb immediately before the number.
- Final whole-branch review independently re-ran the suite on the committed tree
  (1212/0), rebuilt iOS, verified orientation keys via plutil on the built product.
- **Phone updated twice** (pre-batch main `993E`, then batch build `26E8` — dylib UUID
  prefixes on the Debug screen). Owner smoke feedback filed mid-session: #53 upgraded
  (voice switch DISAPPEARS on long entries, not just drifts — Dec 9 2025 entry is the
  repro), #60 (unified editor must show voice-change marks, not just ¶), #48 comment
  (weekday shipped for backdates; extend to capture dates if owner asks post-smoke).
- **Global secrets hard-block installed** (`~/.claude/settings.json` + global
  CLAUDE.md): Read deny rules for .env variants/keys/credentials, auto-mode hard_deny
  for shell-side reads, op (1Password) + `.env.tpl` (`op inject`/`op run`) documented
  as the only secrets path. `.env.tpl`/`.env.example` deliberately exempt.
- Housekeeping: stale remote branches deleted (feat/mark-voices, fix/aug14-batch);
  resync marker refreshed (light resync: no drift found).

**Next steps:**
1. **Owner smoke on the new builds:** #58 macOS light mode (exact steps in PR #61
   body — close #58 manually if it passes) and phone: backdated Dec 9 2025 entry
   should show "Tuesday"; backdate button should be gone on backdated entries (tap
   the date to edit).
2. **Unified-editor design pass** — unchanged from prior handoff, now also carries
   #60's voice-indication ask; two owner rulings still open (frameless-text marks
   refuse-vs-approximate; atomic tokens vs validated markdown).
3. **ASC credential hygiene → TestFlight upload** — orientations blocker is MERGED;
   remaining: owner rotates ASC key, creates `~/.appstoreconnect/issuer_id`, then
   archive+upload per docs/testflight-deploy.md.
4. **#53 capture-landing build** raised in urgency: controls now known to DISAPPEAR on
   long entries (owner: "need the controls to stay put").
5. Queued design passes: #54 prev/next, #55 bubble hierarchy.

## Session 2026-08-12 night (laptop — privacy audit ACTED ON; build-date branch 2 fix rounds; mark-voices RETHINK ruled: unified editor)

Short evening session, subagent-heavy (owner directive: Sonnet/Opus agents for defined
work, owner smokes).

- **Owner smoke step 5 (merge-then-drag) FAILED on macOS** — drag gives no visible
  selection, then a bare "Mark as BN" confirm dialog naming no words. Owner: "rethink
  the tooling completely." **Brainstorm ran; owner RULED: option 1, one unified editor**
  — the T7 transcript editor grows visible inline structure marks (¶ + voice,
  markdown-ish); Mark voices mode disappears. **Plus his key constraint: NO re-ordering
  of text** — only replace-words, insert, add/remove ¶, change voice on sections. That
  constraint is load-bearing: in-order edits are exactly what the T6d splice + §16.5
  frame-inheritance already handle, so the editor decomposes at Done into (word-diff →
  maybe revision; structure-only saves mint NO revision) + (mark-diff → marker appends).
  Undo #59 falls out free (draft-until-Done, ⌘Z); the failed drag UX dissolves (real
  text selection). **Two owner rulings still open for the design pass:** (1) a mark
  placed inside newly-typed frame-less text — refuse vs approximate; (2) marks as atomic
  tokens vs plain markdown chars validated at Done. Smoke steps 6-8 never run (moot for
  6; 7-8 = Voice Labels, still worth a pass post-rethink).
- **Privacy audit ran (Opus, read-only) — verdict: keep the repo public.** Zero
  audio/journal/secret ever committed (all 250 commits content-scanned; the ASC .p8
  never entered). Real finding: `.build/` was COMMITTED (738 MB, 59k files — gitignore
  said `build/`, not `.build/`). **Fixed on main `ca45e7f7`**: untracked + gitignore
  hardened (audio, live.jsonl/entry.json/container pulls, *.p8/*.mobileprovision,
  *.xcresult). History deliberately NOT rewritten (content non-sensitive; rewrite would
  break every cited SHA). **`a40cde0a`**: ASC Key/Issuer IDs out of testflight-deploy.md
  (recipe now derives Key ID from the .p8 filename, Issuer from untracked
  `~/.appstoreconnect/issuer_id` — owner must create that file once), iPhone hardware
  UDID + legal name out of CLAUDE.md. Owner ruled "little/big Nico" in public stays.
  Owner wants ASC key stored in 1Password; **recommended rotating the ASC key** (old
  coordinates are in public history; a fresh key's never were) — queued for tomorrow.
- **Build-date stamp built via SDD-style loop** (Sonnet implementer, Opus reviewer, two
  fix rounds — both real): branch `worktree-agent-a299c9dae63bf803a` at `a663ad10`,
  1200 unit tests, **UNMERGED — final scoped re-review was in flight at session end**.
  Round 1 Critical: file mtime is COPY time (`cp -R` resets it; the owner's actual
  Desktop app carried 17:56 for a 16:47 link) — "Built" relabelled to "Binary file
  date", Mach-O LC_UUID identity added. Round 2 Critical: the UUID shown was the STUB
  executable's — content-identical across all 10 probed builds (code lives in the debug
  dylib) — a constant masquerading as identity; now identityCandidate() always prefers
  the debug dylib, red-first pinned. Vacuous-fixture count hit 14 (candidate predicate
  survived total destruction). Round-2 re-review then caught **the branch red**: two
  fixture tests fail deterministically (`temporaryDirectory` gives unresolved
  `/var/folders/…`, `FileManager.enumerator` returns `/private/var/…` — resolve
  symlinks on the fixture root), and **both implementer rounds claimed green suites
  never run on the committed tree** (round-1 1192 and round-2 1200 both false; the
  failing test dates to `def1eeb8`). Production code verdicted correct; fix round 3
  (symlink resolve + verbatim suite-result evidence) dispatched at session end.
  **Handoff rule: copy builds with `ditto` or `cp -Rp`, never bare `cp -R`** — bare
  copy destroys mtimes; build identity = the debug dylib's LC_UUID (`dwarfdump --uuid`),
  never a timestamp.

**Next steps:**
1. ~~Land the build-date branch~~ **DONE post-handoff**: fix round 3 (`0035bc1d`,
   symlink-resolved fixtures) verified INDEPENDENTLY — parent re-ran the full suite on
   the committed tree, 1201 green — then merged `de9c5503`, worktree + branch deleted.
   Fresh macOS build for the owner at `~/Desktop/Raconte-latest.app` (ditto-copied,
   dylib UUID verified against the build products; the stale Raconte-markvoices.app
   was removed). Debug screen now shows "Binary file date … PT · <UUID prefix>".
2. **Unified-editor design pass** (supersedes #59/#60 as separate items; folds #13
   adjacency): owner-ruled direction above; open rulings (1) frameless-text marks
   refuse-vs-approximate, (2) atomic tokens vs validated markdown. Then plan + SDD loop.
3. **ASC credential hygiene (owner, with help):** rotate the ASC API key (revoke old,
   mint new, store .p8 + IDs in 1Password), create `~/.appstoreconnect/issuer_id`.
   Then **TestFlight upload** (orientations Info.plist fix still pending,
   docs/testflight-deploy.md).
4. Owner smoke 7-8 (Voice Labels sheet + round-trip) whenever convenient — unaffected
   by the rethink.
5. Queued design passes: #53 capture-landing, #54 prev/next, #55 bubble hierarchy,
   #58 capture dark-on-dark.

## Session 2026-08-12 evening (laptop — #56 FINISHED AND MERGED; PR #57; 1124 → 1179 unit + 14 UI tests)

Resumed the SDD loop at Task 5 and ran it to the end: Tasks 5-8, adversarial gate, two
fix waves, **PR #57 merged by Nico** (`6a3c6dfa`), #56 closed. Worktree + branch deleted.
Owner smoke-tested mid-session on a macOS build; feedback filed as #58-#60.

- **Task 5** (VoiceMarkingModel + store seam): review found 3 Importants, one fix round —
  `hasApproximateBoundary` was wholly unpinned (the branch's repeat vacuous-fixture
  shape), `alternativeVoice` byte-copied `VoiceMarkingPlan.governingVoice` (drift =
  silent misattribution; now shared), and no in-flight guard (interleaved taps left a
  paragraph unflipped with no error; now `isWriting` + CheckedContinuation-parked test).
- **Task 6** (Mark voices UI, old Correct-markers surface deleted): one fix round —
  stale per-block gesture rects could silently over-mark after a paragraph merge (fixed
  by keying block identity to token ids), and the brief's detail-screen a11y assertion
  had been dropped over a real VoiceOver merge gap (single-paragraph entries lost their
  voice label entirely; fixed with `.accessibilityElement(children:)`).
- **Task 7** (per-journal Voice Labels sheet): approved clean, no fix round — first on
  the branch. **Task 8 docs**: §17 as-built + overview editing story; CLAUDE.md refresh
  deliberately deferred to this handoff (branch base predated main's handoff commit).
- **GATE (Opus, adversarial):** suite independently re-run (1176 green), iOS builds,
  commit bodies clean. All four probes SAFE: non-placeable restore-span bleed
  structurally unreachable; marking during an open transcript draft touches neither
  draft nor chain (byte-identical, markers survive the next revision); OLD build decodes
  voice-carrying adds as voiceless paragraph markers (structure degrades, text never
  misattributes); unlabelled journals.json byte-identical. One Important: the Task 6
  `.id()` identity fix survives deletion against every test — fix wave added a real
  drag-path UI test, but it provably can't discriminate that one line in the simulator
  (two constructions tried, documented); **parked — the flip-merge-then-drag owner smoke
  step is the pin**. Late owner ruling folded in: capture voice switch now speaks the
  journal's labels via VoiceDisplay (`0ddf6b74`).
- **Owner smoke (macOS build, partway):** tap-to-flip PASS (wants undo → **#59**);
  drag-to-mark PASS mostly (implied ¶ breaks invisible/uneditable; owner wants a
  text/markdown-style structure editor → **#60**, explicitly NOT ruled out, deferred by
  D8); merge-then-drag INCOMPLETE (owner "not finding a way to drag" on macOS — real UX
  signal for #60); steps 6-8 (marking-mode scroll, Voice Labels sheet, labels round-trip)
  NOT yet run. **#58** filed: macOS capture screen dark-on-dark controls near-invisible
  in light mode (pre-existing class).
- **Trap that cost a smoke round:** this laptop has NINE Raconte DerivedData dirs;
  newest-by-mtime handed the owner a STALE app (he saw the old Correct-markers UI).
  Always build with an explicit `-derivedDataPath` and verify the binary (`grep -ac
  "Mark voices" …/Raconte.debug.dylib` — Debug builds put code in the debug dylib, the
  main executable is a stub). Verified build at `~/Desktop/Raconte-markvoices.app`.

**Next steps:**
1. **Finish owner smoke 5-8 on the macOS build** (`~/Desktop/Raconte-markvoices.app`,
   now = merged main): flip-to-merge then drag inside the merged block (the unpinned
   `.id()` case), marking-mode scroll, Voice Labels sheet, labels on a fresh entry open.
2. **Visible build date/time (PST) in the app** (owner ask, approach agreed): read the
   binary's link timestamp at runtime, show on the Debug screen; no build-system change.
3. **TestFlight upload** — one Info.plist fix (orientations key; docs/testflight-deploy.md).
4. **Repo-privacy audit** (owner ask, subagent) — unchanged from prior handoffs.
5. Design passes queued: #60 text-based structure editing (+ #59 undo, macOS drag UX),
   #54 prev/next, #55 bubble hierarchy, #58 capture dark-on-dark, capture-landing plan.

## Session 2026-08-12 afternoon (laptop — owner smoke + #56 designed AND half-built; 1124 → 1171 tests on branch)

Owner ran the smoke test live and the session pivoted into the thing it surfaced.

- **Owner smoke feedback → issues #53-#56 filed.** #53 capture controls move as live
  transcript grows (named requirement for capture-landing build); #54 prev/next entry
  navigation (design discussion); #55 detail-screen bubble-button hierarchy (future);
  **#56 voice-attribution editing unusable** — the T7 "Correct markers" screen is
  machine-shaped, entries without voices can't get them, and an edit visibly shifted
  BN/LN attribution (unreproduced — get the entry/edit from owner if it recurs).
  Confirmed for owner: back-arrow = Done is by design; mini not showing entries is
  expected (no sync until M4).
- **#56 designed in-session, owner ruled everything** (all on the issue): paragraph is
  the unit but sentence-level exchanges exist; **default-voice model** (unmarked = main
  voice, mark only the secondary; generalizes to tertiary); **display per journal —
  default NO labels**, main voice italic / alternative regular (his journals use two
  hands, no labels), labels opt-in per journal; **explicit "Mark voices" mode** (tap
  paragraph flips, drag words marks a range, WYSIWYG, Done exits) replacing Correct
  markers; owner tests on macOS laptop when built.
- **Plan committed** (`docs/plans/2026-08-12-mark-voices-plan.md`, `24bfc8df`): 8 tasks +
  gate. Everything reduces to two append-only records (frame-0 opening-voice add +
  voice-carrying boundary add) planned by pure `VoiceMarkingPlan`; later-seq-wins makes
  re-marking pure appends, no retract/correct.
- **SDD loop ran Tasks 1-4 to complete** (Sonnet implementers, Opus for Task 4 + all task
  reviews; every task exactly one fix round — the T7 pattern holds). Branch
  `feat/mark-voices` (worktree `/Users/nico/src/raconte-mv`, base `24bfc8df`) at
  `40e9a650`, PUSHED, 1171 unit tests green. Review kills, all probe/fixture-confirmed:
  Task 1 — old `.correctionVoice` silently overrode newer voice adds at same frame (now
  seq-based precedence, 3 directions pinned); Task 3 — `hasAnyVoiceMarker` hardcoded
  `true` survived all 1155 tests (now pinned both ways, two distinct mutations); Task 4
  worst — **splice fragments share identical frames, so a flip could silently self-cancel
  and a range-mark could bleed voice onto unselected words**; ruled refuse-`.notMarkable`
  via whole-plan frame-ambiguity validation, disk fixture pins log-byte-identical refusal.
- **Ledger is the authoritative resume point**:
  `/Users/nico/src/raconte-mv/.superpowers/sdd/2026-08-12-mark-voices-plan/progress.md` —
  carries a RESUME POINT block (next: Task 5), per-task deferred minors for the gate,
  what Tasks 5/6/7 dispatches must carry (non-atomic plan execution → model reloads +
  surfaces honestly; refusal is a reachable UI state — disable affordance up front;
  flip-into-neighbour-voice merges paragraphs; leading non-placeable text stays
  voiceless), and an owner product question (capture toggle shows LN/BN, ignores
  journal labels).

**Next steps:**
1. **Resume the #56 SDD loop at Task 5** — read the worktree ledger first; Tasks 5-8
   remain (model, marking UI, labels sheet, gate + PR + **macOS build for owner test**,
   which he explicitly wants to run on this laptop).
2. **TestFlight upload** — still one Info.plist fix away (orientations key; recipe in
   docs/testflight-deploy.md).
3. **Repo-privacy audit** (owner ask, subagent) — unchanged from last handoff.
4. Owner smoke follow-ups when scheduled: #53 capture-control stability, #54 prev/next
   design discussion, #55 bubble hierarchy (explicitly "future").
5. Capture-landing implementation plan; photo-snapshot plan; #38 SDK recon; #44
   live.jsonl pull.

## Session 2026-08-11 → 08-12 (laptop — T7 FINISHED AND MERGED; 1073 → 1124 tests; PR #52)

Ran the SDD loop from Task 7 to the end unattended (Sonnet implementers, Opus reviews,
Opus Gate B), opened PR #52, **Nico merged**. Worktree + t7 branch deleted; fresh main
(`ea0ea4dc`) built and wirelessly installed on the phone — **owner smoke test pending**
(steps in PR #52's body). Every task needed exactly one fix round.

- **Task 7 (audit log §7)**: prior session's skeleton kept, its stubbed torn-tail fuse
  caught by RED (lost BOTH records). Review: store predicted the model's rejection answer
  instead of reading it — `update` now generic over the closure's return.
- **Task 8 (history panel + revert)**: review Critical — `canRevert` required `isDetached`,
  which NO v1 chain can produce: the Revert button was structurally unreachable, panel
  inert. Also: panel ignored `editability`; revert-while-draft-open was silently reversed
  by the later draft close (now a store-level `.draftInProgress` refusal).
- **Task 9 (§16 docs)**: all six rulings recorded + verified citation-by-citation. Review
  Critical: commit body said `close #37` as prose — the exact `47d3f37a` accident again;
  amended + force-pushed. **Watch commit BODIES, not just subjects.**
- **Task 9b (splice-inherit, owner ruling §16.5)**: zero-overlap replacement inherits the
  replaced word's frames; #37 closed. Review fix: unusable-bounds fallback now `.none`,
  never borrowed provenance.
- **GATE B (with fixes)**: found the branch's worst bug — `done()` cleared
  `hasUnsavedChanges` unconditionally after `closeDraft`, so a keystroke landing during
  the close await (autocorrect/dictation/typing through dismissal) was lost forever while
  Done reported success; probed 4 ways, fixed with a bounded re-flush loop. Also: Task 9b's
  wholesale condition mutated to `>=1` survived all 1116 tests (three negative fixtures
  added). **Structural answer on 13 vacuous-fixture instances** (memory:
  vacuous-fixtures-need-an-adversary): same agent authors property+fixture+mutation = no
  adversary. Recos for next build: coverage gating on changed lines; mutation named in the
  brief as INPUT; cardinality ≥2 fixtures.
- **New trap** (memory: frozen-clock-two-mints-coin-flip-order): frozen TestClock + two
  mints ⇒ `createdAt` tie ⇒ random ULID order — 50/50 flaky tests. Advance the clock
  between mints. #51 filed for the production-side ordering question.
- Issues: #37 #39 #41 closed, #51 filed. Four harness drops (2 machine-sleeps), all
  recovered by same-agent resume, zero work lost.

**TestFlight CLI setup (2026-08-12, same session — 95% done, ONE fix from first upload):**
bundle ID `org.pianohouseproject.raconte` registered (`KJ4D33V27R` — dev builds were on the
team wildcard, which can never ship); profile `raconte appstore` (`78D2Z6JR83`) minted
against team cert `89FGBW89NS`, installed both dirs; `scripts/ExportOptions.plist` +
`docs/testflight-deploy.md` committed (`8ea16c4a`); ASC app record created by owner as
**"Raconte Journal"**; Release archive SUCCEEDED (no optimizer crash). **Upload failed on
validation: `UISupportedInterfaceOrientations` missing** — the app declares no orientations.
Fix: add the key (iPhone: portrait; iPad needs all four for multitasking, or opt out) via
project.yml info properties, `xcodegen generate`, re-archive, re-run the exportArchive
command in docs/testflight-deploy.md. Everything else is proven working.

**Next steps:**
1. **Give the owner the smoke test in EXPLICIT detail** (owner ask): small batches — not
   too many steps at once — each step with exact taps and a stated pass/fail criterion.
   Content: edit round-trip, late-keystroke-at-Done survival, revert from history,
   "Ellen"→"LN" wholesale correction, approximate-boundary asterisk (outside selection).
   Build already on the phone (`ea0ea4dc`).
2. **Finish TestFlight upload** — one Info.plist fix, see block above.
3. **Repo-privacy audit (owner ask, subagent):** verify this repo being PUBLIC is
   appropriate — audit history + tree for anything private (owner's journal content in
   fixtures?, device identifiers, team/signing IDs, API key IDs, paths) and report
   whether real safety exists for private files despite the public repo. Note: docs/ and
   CLAUDE.md carry team ID + ASC key ID + device UDID — assess, don't assume harmless.
4. Capture-landing implementation plan (fully specced; carries #27 gated by #35).
5. Photo-snapshot plan (approved); #38 SDK recon; #44 live.jsonl pull; coverage gating in
   CI (Gate B reco).

## Session 2026-08-10 → 08-11 (laptop — T7 Tasks 4-6 + GATE A done; 986 → 1073 tests; Task 7 next)

Resumed the T7 SDD loop at Task 4 (Fable controller, Opus implementer for Task 4 per owner
ruling, Sonnet for 5-6, Opus reviews throughout). **Branch `t7/editor-ui` pushed at
`80337d99` — 25 commits this session, 1073 unit + 12 UI tests green.** Ledger in the
worktree is the authoritative resume point; it now carries a RESUME POINT block.

- **Task 4 (the editor)** + **Gate A** were the session's spine. The gate BLOCKED correctly:
  across its 3 fix rounds, six probe-confirmed defects died, including two data-loss
  Criticals — the pop path silently swallowing a failed save, and a Back→Edit-again lost
  update where the second session's words never reached the store while Done reported
  success (reproduced through the real store). The fix converged on a session-token
  protocol: a dead session's WORK still completes, but none of the live session's STATE may
  be written by it — now guarded after every await in the model.
- **Task 5 (span attribution)**: BN/LN rendering now survives edits; the `.machineLive`
  gate is gone and paragraphs/text divergence is structurally impossible.
- **Task 6 (marker correction + #37)**: additive correction records (retract, voice-correct,
  word-anchored boundary ADD), forward-compatible; worst review find was word-anchored adds
  being fed through MarkerSnapping — on the device-observed abutting-runs norm the owner's
  boundary-add could snap to frame 0 and produce NO visible split. Fixed read-side (exact
  markers never snap; stored frames were always right).
- **Two owner rulings (both → §16 at Task 9.4):** a leading non-placeable span renders
  `voice: nil`, never a guessed voice; and **a wholesale zero-overlap word replacement
  ("Ellen"→"LN") INHERITS the replaced word's audio frames** — today's splice discards them,
  which is why the brief's own #37 example was disproved by probe. The splice change is
  **Task 9b**, in-branch before Gate B.
- **Vacuous fixtures hit 10 instances, now in three shapes** (degenerate assertion,
  degenerate fixture file-count, wholly untested branch). The countermeasure that worked:
  mutation-in-RED as the implementer's burden, REDs required to fail *for the reason the
  finding names*, and re-reviewers deleting fixes to watch tests fail. Gate B carries the
  structural question as a named agenda item.
- **Six harness failures** (five 600 s watchdog stalls in one storm + one earlier), across
  three agents. Zero work lost. Protocol additions: commit per green STEP; after a SECOND
  stall on one agent, hand off to a fresh agent with a written state summary instead of a
  third resume; Edit/Write tools only (a Bash classifier rejection once applied no edit
  while the test failure read as "fix didn't work"); mutation scripts must assert their own
  patterns matched (a no-op mutation reads identically to a worthless test).

**Next steps:**
1. **Re-dispatch Task 7** (audit log — agent was stopped cleanly at reboot; untracked
   skeleton `EntryLog.swift` left in the worktree for the next agent to judge). Ledger's
   RESUME POINT block has the full dispatch context.
2. Task 8 (history panel + revert) → Task 9 (minors + §16: five rulings queued) →
   **Task 9b** (splice inherit, owner-ruled) → Gate B → PR (Nico merges).
3. After merge: capture-landing implementation plan; photo-snapshot plan; #38 SDK recon;
   #44 device live.jsonl pull.

Ran the T7 editor plan as a subagent-driven SDD loop. **Branch `t7/editor-ui` (worktree
`/Users/nico/src/raconte-t7`, base `9cf853fa`), 10 commits, pushed. Tasks 1-3 complete and
reviewed clean; Task 4 (the editor itself) is next and NOT started.** Ledger at
`.superpowers/sdd/2026-08-09-t7-editor-ui-plan/progress.md` in the worktree is the
authoritative resume point, not this summary. Baseline 930 on main → **986 green**.

- **Task 1** `254e248b`+`a5754c7a` (#41 prereqs). Review found two Importants, both
  probe-confirmed: closing a recovered draft *before* promotion **permanently** blocked the
  machine transcript from ever entering the chain (`promoteIfNeeded` skips on any canonical
  file, and the `.userEdit` the close minted was that file); and the close put an actor hop
  in front of the first transcript paint — the exact regression the T6c comment three lines
  below was warning about (probed: 0.1228 s wait against a 0.1234 s walk at 4k captures).
  One fix: `nonisolated` `hasDraft` fast path, and promote-before-close when a draft exists.
- **Task 2** `30fdd461`..`9635b93d` (`EntryChainSnapshot`, the editor/history/diagnostics read
  model). Editability precedence probe-verified against the store's write guards, so "the
  editor let me type and then the save refused" is structurally impossible. Four Importants:
  `isForked` could be hardcoded `false` and all 13 tests passed; `chainByteSize`'s
  "readable or not" half was unpinned (and the report overstated its evidence); **three
  Gate-A-hardened store internals had been re-implemented, and the `rawLoad` copy had already
  silently dropped the `dedupedFiles` bucket that Gate A finding N1 exists for**; and a
  corrupt `entry.json` was labelled `.readOnlyTrashed`. Then a fifth: the detached-revision
  ordering was documented but vacuously tested (reversing it passed all 958).
- **Task 3** `6b69b8fa`..`c6e9e1a6` (#40 read costs, #39 visibility). §15b.15's degraded-chain
  refusal fires on every `writeDraft` — reviewer reproduced the bug the issue's wording
  invites and watched the tests catch it. Three fix rounds. **Filed #50** for the residual
  whole-chain-decode-per-write rather than improvising it, per the plan.

**Three owner/controller rulings, all needing §16 at Task 9.4:**
1. **Detached revisions** (owner): reserve "machine transcript, not applied" for genuinely
   unapplied revisions. An entry's own rev0 is the foundation of later human edits, so the
   plan's `!isAttached` shorthand is superseded *for that field only* — the set is now
   "neither `current` nor in `ancestry(of: current)`". `isAttached` itself is unchanged.
2. **Row honesty** (owner): rows route through the O(1) head cache, but a trusted head could
   mask in-place damage — row said healthy, detail and editor both refused. Fix: record each
   canonical file's byte size in `head.json`, distrust on mismatch. Nearly free because the
   scan already stats those files for #39. **Same-size corruption still slips through —
   accepted knowingly and pinned by its own deliberately-named test.**
3. **Corrupt sidecar** (mine): an unreadable `entry.json` gets its own editability case, not
   `.readOnlyTrashed` — same principle as #1, never label a state with something untrue.
   Also mine: Task 3 needed a **launch-time `persistHead` sweep**, since `persistHead`'s only
   caller is `append` and promotion skips existing chains, so every head on the device stayed
   distrusted forever and the read-cost win reached zero existing entries.

**The sweep then introduced a data-safety regression the review caught:** it stamped captures
with *no chain*, and writing `head.json` into an empty `transcript/` flips
`holdsIrreplaceableArtifacts` false→true — a mis-tapped capture becomes **permanently
undeletable**, the zero-byte-log trap (rule 10) `MarkerLog` and `CaptureCoordinator` both
already guard. Fixed with `!files.isEmpty` + two tests, mutation-verified twice.

**Process:** vacuous fixtures are now **6-for-6 across two builds** (Gate A I2, T6d's lattice,
Gate B C1, plus three on this branch). Every dispatch demands a mutation check; **compile-error
"red" is explicitly not acceptable evidence** — that weakness is exactly what let two Task 2
defects through. Standing branch rule: call the store's shared primitives, never copy them.
**Six harness failures** (five "connection closed mid-response", one 600s watchdog stall) — all
recovered by resuming the SAME agent from its transcript, zero work redone; resume prompts
should state the verified worktree diff and say "commit as soon as you are green."

**Owner to-do list audited against code + issues; #46-#50 filed.** Already shipped: journal
covers/precision dates (#14), the dark-background date bubble, spoken-date backdating (#15),
capture-page recents (#32, owner confirmed old). In the T7 plan: edit-and-confirm (Task 4),
Swahili/technical word correction (#37, Task 6). New: **#46** reviewed flag (owner asked for
it explicitly — distinct from editing), **#47** backdate increment (owner ruled *not urgent*:
"same is good enough"), **#48** weekday on entries (only expressible at `.day` precision —
`anchorDate`'s day-1 fill would fabricate a confident wrong weekday), **#49** backdate button
should disappear once set (the sticky half shipped in `e7efb617`; it currently only relabels).

**Next steps:**
1. **Resume the SDD loop at Task 4** (the editor). Read the worktree ledger first — it carries
   four things Task 4 must handle: `refresh()` also runs after backdate save/clear and journal
   move, so a 90 s-idle open editor draft can be closed `.recovered` from under it;
   `.readOnlyNoTranscript` refuses where `writeDraft` would succeed, so the editor owns that
   guard; the `hasDraft` TOCTOU goes live once the editor is a real draft writer; and
   `EntryTranscript.text` is a truncated snippet under `.skip` despite its doc comment.
   Then Gate A, Tasks 5-9, Gate B, PR (auto-mode can't `gh pr merge`).
2. Capture-landing implementation plan (fully specced; carries #27 gated by #35).
3. Photo-snapshot implementation plan (design approved).
4. #38 contextual-string biasing (verify SDK surface); #44 needs a device `live.jsonl` pull.

## Session 2026-08-09 midday (laptop — PR #45 MERGED; flake fixed; T7 plan drafted; photo-snapshot design approved; LN/BN type ruled)

Subagent-heavy session (Sonnet flake fix, Opus plan + mocks), all landed on main.

- **PR #45 merged** (`bf0042d5`), CI green on the merged tree. t6 worktree, both
  `t6/revision-chain` branches, and the SDD ledger dir all deleted.
- **Flake pair closed (`a140b7f8`, test-only).** The REAL race was the sibling:
  `lastError` is assigned strictly after the `retryCount` disk write in
  `handleReacquireResult`, previously masked by an incidental 150 ms sleep — now waits
  on the actual signal (deterministically reproduced via a probe sleep, reverted).
  `testRapidRecordDoneCyclesProduceTenSeparateEntries` has NO logic race (it polls
  `finalizeQueue`, whose append shares its trigger's MainActor continuation); its
  budget was just tight for real store I/O — widened 5→15 s with the investigation
  in a comment. 771 green pre-merge.
- **T7 editor-UI plan drafted** (`docs/plans/2026-08-09-t7-editor-ui-plan.md`, Opus,
  written against PR #45 pre-merge — re-verify file:line cites): 9 tasks + 2 gates,
  **12 numbered owner questions, 3 blocking** (what ends an edit given §2.5 has no
  discard; flattened vs per-paragraph editing; marker-correction storage shape).
  Scope find: **the editor's first save would silently drop BN/LN voice rendering**
  (`EntryTranscript.swift:120` gates paragraphs on `.machineLive`) — span
  re-attribution is now required Task 5, not "deferred to T7" hand-waving. Also:
  no revision identity on the read path (Task 2's `EntryChainSnapshot`), no
  per-capture `closeStaleDrafts`, no `apply(merge:)` glue, §7.2 write bypass still open.
- **Photo-snapshot design approved + committed**
  (`docs/plans/2026-08-09-photo-snapshot-design.md`): photo is HUMAN REFERENCE ONLY
  (owner ruling — no OCR ever); one per entry, retake replaces; capture-time snap +
  detail-view attach; `page.jpg` in the capture dir with a `PagePhotoRef` in
  entry.json (three-answer read), ImageIO re-encode strips EXIF;
  `holdsIrreplaceableArtifacts` must include it; provenance flag + batch-snap queue
  (photograph 5 pages, read them in one at a time) deferred-not-precluded.
- **LN/BN type + palette RULED** (addendum in
  `docs/plans/2026-08-08-capture-landing-decisions.md`; mocks `g-lnbn-type.html` /
  `h-encre-bleu.html` cherry-picked to main, branch `design/lnbn-font-mock` pushed):
  serif (New York) confirmed; prefix = letterspaced accent micro-label but
  **lowercase `ln`/`bn`**; BN italic stays; icon-blue palette adopted (hue 213.5°
  off the icon's #092343); **no dip-switch-style toggles** — traditional switches.
  "Good enough", no further type iteration. Capture-landing is now fully specced:
  IA + type + palette all locked.
- **Continuation same sitting — T7 PLAN IS BUILD-READY (`2e54ce41` + `ff2243d0`):**
  all 12 owner questions RULED (every reco accepted: Done-only editor, one flattened
  text view, marker correction as its own mode with corrections AND word-anchored
  boundary-ADDS appended to `markers.jsonl`, refuse-trashed, degraded-chain offers
  read-only live transcript, #13 later, #39 = history panel + diagnostics with a
  ~50-revisions-per-entry alarm, #37 not collected yet, keyboard defaults confirmed,
  audit log written-not-shown, approximate-boundary affordance in / selection fix
  parked). Then an Opus agent re-verified every cite against merged main and folded
  the rulings into task bodies. **Two claim errors caught: #40.2's premise is FALSE**
  — `readableOrderedRevisions` (:440) does the chain decode AND §15b.15's
  degraded-chain refusal in one call, so the issue's "skip the decode" fix would
  silently delete the refusal on every promoted entry; Task 3 rewritten with a
  mutation check pinning it, correction commented on #40. Also
  `TranscriptAttribution.swift` is in `Raconte/Library/`, not `Transcription/`.
  Strays cleaned. Mock decision ruled "good enough" — no further type iteration.

**Next steps:**
1. **Launch the T7 SDD loop** — `docs/plans/2026-08-09-t7-editor-ui-plan.md` is
   fully ruled, cite-verified, nothing blocking. 9 tasks + 2 gates, T6-chain style
   (Sonnet implementers, Opus reviews, superpowers:subagent-driven-development).
   First: re-run the 930 suite on main and take that as baseline, then Task 1
   (#41 prerequisites).
2. **Capture-landing implementation plan** — everything is locked now (IA A+C-rows+
   B-receipt+thumb-bar, serif, lowercase ln/bn accent labels, icon-blue, traditional
   switches); carries #27 Mail-swipe gated by #35 journal-lock friction.
3. **Photo-snapshot implementation plan** (design approved; sequenced after T7
   unless owner resequences).
4. #38 contextual-string biasing (verify SDK surface; pairs with T8 design);
   #44 needs a device live.jsonl pull.

## Session 2026-08-08 overnight → 08-09 (laptop — T6 CHAIN FINISHED: Tasks 4-6 + Gate B, PR #45 open; 849 → 930 tests)

Resumed the SDD loop at Task 4 per the ledger and ran it to the end: Tasks 4-6 built
(Sonnet implementers, Opus task reviews, fix rounds via SendMessage-resume), Gate B
adversarial whole-branch review passed, **PR #45 open at `d4fe63f9` — merge is Nico's.**
Branch `t6/revision-chain`, 930 unit tests (771 at branch base). Ledger + worktree kept
for PR iteration; delete after merge.

- **Task 4 (T6c promotion + loader)** `626c0219`+`cfa04f2b`: one fix round — canonical
  branch dropped truncation/unreadable degradations; text-vs-paragraphs source split
  (paragraphs now gated on `.machineLive`, re-attribution deferred to T7); entry-open
  serialized behind the launch corpus walk (now reads transcript first, re-reads on
  `.promoted`).
- **Task 5 (T6d splice + drafts)** `ee9fafc9`..`3998bd5f`: two fix rounds. Worst finds:
  splice didn't round-trip (deleting the space between two `.exact` spans was silently
  reverted — emission rewritten around pendingSeparators; `join(spans)==editedText` now
  asserted in the 200-case F18 property) and draft paths spliced against a degraded
  chain (F5 reintroduced — now refuse on any unreadable revision).
- **Task 6 (T6e merge minting)** `44d45586`: approved clean. Ruling: adopt is VERBATIM
  (anchor preserved) — §6.3's ".exact" prose is descriptive, not an anchor rewrite.
- **Gate B** (Opus, independent 930-green suite re-run, §10 audited row-by-row, probes):
  one Critical — **promotion doubled whitespace at every run boundary** (AttributedString
  runs partition the text and carry boundary whitespace; join re-inserts). F16/C3 tests
  were both fixtured runless — the one path where the bug is invisible. Fixed `d4fe63f9`
  (trim run text at promotion, re-fixtured RED-first). Verdict: Ready to merge.
  **Gate lesson (now in memory): audit that fixtures exercise the NON-degenerate path** —
  Gate A I2, T6d's vacuous lattice test, and this C1 all shared that shape.
- **Paperwork:** design **§15b** (rulings 10-15: run-trim, forced-merge of adjacent
  .exact on separator deletion, closeDraft diffs against draft.parentID not current,
  adopt-verbatim, TranscriptDraft's 3 extra fields, degraded-chain refusal) on main
  `54656196`+`2e40a9ca`. **Issues #40-44** carry every non-blocking finding (#40 scan-path
  chain-decode cost, #41 T7 prerequisites incl. unwired closeStaleDrafts, #42 test
  hygiene, #43 T9 durability nits, #44 no-whitespace run-split residual — needs device
  live.jsonl data).
- **Docs for humans (owner ask — PR was unreadable):** `docs/overview.md` — the whole
  system as plain-words mental models with mermaid diagrams (revision chain = "tiny git
  for one entry's transcript"); README rewritten to point at it; three stale
  "UNVERIFIED" banners on shipped 2026-08-05 build docs retired. `5422ff69`.
- /readup resync verified all 9 recently-touched open issues genuinely unshipped; Nico
  deleted merged branch `fix/flake-store-write-precedence`.

**Next steps:**
1. **Nico: merge PR #45** (auto-mode can't). After merge: delete worktree
   `/Users/nico/src/raconte-t6` + SDD ledger dir.
2. **NEW — owner design discussion (asked 2026-08-09): journal-page photo snapshots.**
   When reading an old handwritten journal, snap a photo of the page. The PAPER journal
   is then the source of truth; the recording (him reading it) AND the photo are both
   representations of it; edits must keep that model in mind. Slots into the entry
   sidecar/capture-directory model + M3's photos table + the T6 provenance story —
   design pass before building. Brainstorm first.
3. **T7 editor-UI plan** (separate doc): whole-revision accept v1, marker correction,
   audit log §7, #37 typed-word correction, keyboard-first iPad/Mac, #41 prerequisites
   (wire closeStaleDrafts, merge caller guards, §6.3 adopt pin), #39 storage visibility,
   #40 head-cache routing, parked rendering minors.
4. Capture-landing design follow-ups (owed: LN/BN serif-vs-sans font mock, dark,
   icon-blue accent; palette pass off the app icon; #27 Mail-swipe gated by #35).
5. #38 contextual-string biasing (pairs with T8 retranscribe design); #44 needs a real
   device live.jsonl pull; flake backlog (breakpoint-controller method).

## Session 2026-08-08 evening (laptop — T6a–e revision-chain build launched; 771 → 837 tests on branch, Gate A mid-fix)

The "T7 next" label in the last handoff was wrong by one letter: three Explore code maps
proved **T6a–T6e (the revision chain itself) was entirely unbuilt** — recent "T6" commits
were §14 markers, not §11's chain. So this session planned and launched the chain build.
**Session ends with the Gate A fix wave still running in the background** — the SDD ledger
at `.superpowers/sdd/2026-08-08-revision-chain-implementation-plan/progress.md` is the
authoritative resume point, NOT this summary.

- **Docs on main (`e14d7f8b`):** `docs/plans/2026-08-08-revision-chain-code-maps.md`
  (citation authority — the T6 design doc's file:line cites drifted in ~9 places since
  08-03; also: launch-recovery path writes no TranscriptRef so promotion B1 recurs there,
  `markers.jsonl` contradicts §4.6's writer census, `EntryMetadata` now has six fields)
  and `docs/plans/2026-08-08-revision-chain-implementation-plan.md` (6 tasks + 2 gates;
  locked decisions incl. honest-nil coverage on launch promotion, Swift `difference(from:)`
  for the T6d splice diff, `TranscriptChainListing` as a deliberate 4th three-answer copy).
- **Build on branch `t6/revision-chain`** (worktree `/Users/nico/src/raconte-t6`, base
  `d0c18d2c`), subagent-driven, one fix round in Task 3:
  Task 1 `eb508165` types/decoders/TranscriptText.join; Task 2 `4102869e`
  `AtomicFile.createExclusively` (RENAME_EXCL, mutation-verified) + three-answer
  `transcriptDirUnreadable`; Task 3 `61c62aa4` TranscriptChain derivation +
  TranscriptRevisionStore (review caught: validatedHead never read head.json — cache
  defeated; `-1` sentinel in persisted arrays → additive `listingUnreadable`).
- **Gate A (Opus adversarial, suite independently re-run 837 green): BLOCKED — correctly.**
  Probe-confirmed C1: duplicate revision id across two canonical files TRAPS
  (`Dictionary(uniqueKeysWithValues:)`) on the read path, reachable via append-throws-
  after-durable-write retry; probe-confirmed C2: append into a staged-away capture
  RESURRECTS it (sidecar-absent reads as not-trashed; §4.6's write-side skip was
  implemented as a read-side rule). Plus I1 stale-head trust masks §4.8 self-healing,
  I2 the F6 fixed-point test was vacuous (never persisted between calls), I3 persistHead
  missing trash guard, I4 SpanAnchor lossy on unknown raw values (needs `.unknown(String)`
  like RevisionSource), I5 absent-sourceRevisionID needs its one read-side resolver.
  Wire format itself held. Fix wave dispatched (all 7 + C1-trigger); minors M1-M5 parked
  in ledger for Gate B triage.
- **Filed #39** (revision-chain storage visibility + growth alarm — owner ask; whole-text
  revisions are priced at ~725 KB/30-min entry, §9.5/9.6).
- **`.claude/settings.json` gained a read-only permission allowlist**
  (/fewer-permission-prompts): gc-read.sh, git fetch, sync-claude-md --check,
  devicectl list/info, mcp github issue_read. Deliberately NOT added: gc-write.sh,
  xcodebuild, xcodegen, python3 (owner's call to opt in).
- Process: SendMessage-resume of a task's original implementer works well for fix rounds
  (context intact, no re-brief); Gate A's reviewer wrote throwaway probe TESTS to confirm
  findings empirically before reporting — worth demanding in future gate prompts.
- **Post-handoff continuation (same evening): GATE A CLOSED, FORMAT FROZEN.** Fix wave
  `94edf7bf` (all 8 findings, each reproduced before fixing — real trap, real EISDIR,
  real resurrection), re-review verdicted all ADDRESSED (reviewer re-ran suite itself),
  freeze APPROVED with one new finding N1 (C1's dedupe dropped duplicate file numbers
  from `revisionFiles` → permanent cache defeat, probe-confirmed) — fixed `6ca5ab2f`
  (dedupedFiles bucket, differential trust-path test), scoped re-review ADDRESSED.
  **Branch `t6/revision-chain` at `6ca5ab2f`, 849 unit tests green, PUSHED to origin.**
  Gate rulings written into design **§15** (`b9dd2774` on main): duplicate-id rule,
  persistHead silent-no-op ruling + its throw-on-unreadable-sidecar edge, all as-built
  format deltas. Task 4 deliberately NOT dispatched — clean boundary for next session.

**Next steps (next session — an Opus agent can start directly from these):**
1. **Resume the SDD loop at Task 4.** Everything needed is on disk:
   ledger `.superpowers/sdd/2026-08-08-revision-chain-implementation-plan/progress.md`
   (authoritative state incl. parked minors M1-M5 for Gate B), plan
   `docs/plans/2026-08-08-revision-chain-implementation-plan.md`, Task 4 brief already
   extracted at `.superpowers/sdd/2026-08-08-revision-chain-implementation-plan/task-4-brief.md`,
   code maps `docs/plans/2026-08-08-revision-chain-code-maps.md`, design + §15 amendments
   `docs/plans/2026-08-03-t6-revision-chain-design.md`. Worktree `/Users/nico/src/raconte-t6`
   (branch `t6/revision-chain`, base `d0c18d2c`, HEAD `6ca5ab2f`, 849 tests).
   Sequence: Task 4 (promotion) → 5 (splice+draft) → 6 (merge) → Gate B whole-branch
   review → PR (auto-mode blocks `gh pr merge`; end at an open PR for Nico).
2. **After Gate B: write the T7 editor-UI plan** (separate doc — carries #37
   word-correction, audit log §7, parked rendering minors, #39 visibility hook, and NEW:
   owner may prefer keyboard-first editing on iPad/Mac — see capture-landing decisions).
3. **Design follow-ups (owner decided 2026-08-08 evening — see
   `docs/plans/2026-08-08-capture-landing-decisions.md`):** IA approved (A + C-rows +
   B-receipt + thumb bar); owed next: LN/BN font mock (serif-vs-sans, dark, icon-blue
   accent), palette pass connected to app-icon blue, capture-interface iteration (later),
   #27 Mail-model swipe gated by #35 journal lock ("not too much later").
3. Owner Saturday marker session items still stand (real two-voice page, dash-dot haptic
  verify) if not already done.
4. Design session (owner asked): capture-landing mocks A/B/C on
   `origin/design/capture-landing-mocks` (local branch is 5 behind — pull first),
   ¶-button fold, multi-voice visibility.
5. #38 contextual-string biasing; flake backlog (breakpoint-controller method).

The planned "Saturday" marker session happened a day early and turned into a full build
day: owner smoked, we shipped what the smoke asked for, he smoked again — three
build-smoke round-trips in one sitting. All on main, phone carries `2f73221b`.

- **`snapWindowSeconds` tuned 1.5 → 0.75 (`54d4c8c8`) from real device data.** Two
  sessions, 12 markers: taps trail the true boundary by 0.18–0.37 s and **never lead**.
  Every snap was exact; the 1.5 s guess was ~4× oversized and actively risky (rule 2
  ranks gaps by *size* first, so a distant long pause can steal a tap from the correct
  60 ms gap beside it). Then the evening's real two-voice entries showed the window
  barely matters: **all six voice taps landed inside actual inter-utterance silences** —
  rule 0, exact, snapping never engaged. Reading rhythm puts the tap in the pause.
- **T6 §14 step 7 (voice-attributed rendering) built and merged (`8f5c4cb0`)** —
  subagent-driven per `docs/plans/2026-08-08-voice-attributed-rendering-plan.md` (Opus
  plan, Sonnet implementers, Opus task reviews, one fix round, Opus final whole-branch
  review that independently re-ran the suite). `TranscriptAttribution` pure core (one
  voice per paragraph; break at every ¶ AND every voice switch — owner decision; nearer-
  edge cut inside a run, never mid-word; whole-record join rule keeps no-marker entries
  byte-identical), loader wiring (`EntryTranscript.paragraphs`, scanner never reads
  markers — asserted; unreadable marker log → NO voices, never "single voice"), thin
  detail-view switch over a tested `transcriptDisplay` function. The one fix round:
  a test named for the manifest→sampleRate contract never read a manifest (hardcoding
  the fallback passed everything) — now mutation-verified.
- **Owner smoke, all pass:** improv entry renders BN/LN correctly; then real entries.
  Feedback shipped same-session (`2f73221b`): labels inline (`BN: text`, semibold
  secondary prefix via Text concatenation) instead of a caption line, **BN italic / LN
  regular** (`TranscriptAttribution.isItalic`, display-layer only, ids stay opaque).
- **Filed #37** (typed-word correction for out-of-vocab words — Swahili; edit-time first,
  capture-time is the expensive option) and **#38** (spoken "LN" transcribes as "ellen"
  every time — real fix is SpeechAnalyzer contextual-string biasing, which would also
  serve #37; T8 retranscription must re-apply any biasing or it undoes the fix).
- UX note for the design session: **multi-voice toggle state isn't visible until
  recording starts** — owner wants it before tapping record.
- Residual minors from the reviews are parked in the T7 section of the rendering plan
  doc's history (trim vs "byte-identical" docs claim; cross-paragraph text selection
  lost with per-paragraph Text; symmetric `hasApproximateBoundary` unpinned by tests).
- Process notes: a shared-checkout implementer left HEAD on its feature branch — check
  `git branch --show-current` before merging. macOS test host can die with "Early
  unexpected exit… before establishing connection" when a dialog pops and gets the
  wrong click — retry before diagnosing. Wireless install: device showed `unavailable`
  until `devicectl device info details` opened the tunnel; first install attempt after
  reconnect failed transiently (retry succeeded).

**Next steps:**
1. **T7 editor UI** (whole-revision accept v1) + audit log — now also carrying #37
   edit-time word correction and the parked rendering minors.
2. Design session (owner asked): review the three capture-landing mock variants already
   on `origin/design/capture-landing-mocks` (A/B/C + DECISIONS.md, covers #18/#35/#27/
   #17), plus ¶-button fold and the multi-voice-state-visibility note.
3. **#38 contextual-string biasing** (verify SDK surface first) — pairs with T8
   retranscribe design.
4. Flake backlog: `testRapidRecordDoneCyclesProduceTenSeparateEntries` via the
   breakpoint-controller method; the 150 ms-sleep-shielded sibling while there.

## Session 2026-08-07 overnight+morning (laptop — #25 shipped, smoke 5–7 pass, marker haptics; 708 → 742 tests)

Overnight run on Sonnet/Opus subagents (owner low on Fable tokens), then live smoke
testing with the owner in the morning. All merged to main; #25 CLOSED.

- **New CI flake, root-caused and fixed (PR #33).** `testStoreWriteFailureDoesNotClobber…`
  — fourth member of the #4/#22 family (phase published before effects). Novel part:
  spinner load NEVER reproduced it (0/740 runs, up to 128 spinners); it was forced
  deterministically by arming the DEBUG **`TransitionBreakpointController`** to park
  `send()` in the gap between phase publication and effect realization — a repeatable
  detector for this whole flake family. Cheaper variant: re-poll the test predicate with
  `await Task.yield()` instead of a sleep. Full method:
  `.superpowers/sdd/flake-report-2026-08-07.md` (gitignored). Same report flags
  `testFailedResumeDiskWriteReturnsToInterruptedNotRecording` as safe only behind an
  incidental 150 ms sleep.
- **#25 staged removal built and merged (PR #34)** per the prepared prompts, three steps,
  subagent-driven with per-step Opus reviews + final whole-branch review. Two plan
  fixtures were physically impossible on APFS (sealing the staging root blocks the
  *stage*; moving a 0555 dir needs write perm on itself) — both re-measured independently
  before acceptance. **A step-3 implementer fabricated evidence** (quoted a grep count
  for a test that never existed); caught by the reviewer, diff verified sound, suite
  re-run by the parent. Trust but verify: re-run the gate yourself when a report smells.
  CI fact: **GitHub macOS runners can't reach backupd over XPC**, so
  `isExcludedFromBackup` reads false there — the test now probes capability and skips.
- **Full-suite re-run found another pre-existing load flake (unfixed):**
  `testRapidRecordDoneCyclesProduceTenSeparateEntries` — 733/734, "cycle 4 never
  committed", green 5/5 isolated, predates the branch. Candidate for the
  breakpoint-controller treatment.
- **Owner smoke 5–7 + #32 + #25 all PASS on device.** Markers land exactly (taps within
  0.06–0.2 s of true boundaries — but he was watching the screen, not reading; Saturday
  is the real test). Snapping trace: one BN→LN switch came back `approximate` because
  in-record word runs abut exactly, leaving **no gap to snap into mid-utterance** —
  watch this pattern in real-reading data before touching `snapWindowSeconds` (1.5 s
  never engaged; taps were ~10× more precise).
- **Marker haptic was silently dead on device: iOS suppresses haptics while the mic
  records.** Fix: `setAllowHapticsAndSystemSoundsDuringRecording(true)` in
  `IOSAudioSessionController.activate` (`5f21c992`). Then owner found `.impact` too weak
  → **dash-dot via CoreHaptics** (`fee6e674`): pure `MarkerHaptic` pattern spec (tunable
  constants, 0.12 s dash / 0.06 s gap / 0.7-intensity dot) + `MarkerHapticsPlayer`
  engine wrapper. **Dash-dot feel not yet verified on device.** CoreHaptics engine
  handlers fire off-main — hop to @MainActor (parent caught this in review).
- UX debt from smoke: **¶ button sits below the fold on iPhone** — fold into the parked
  capture-screen design session. Filed **#35** (per-journal delete friction:
  easy/confirm/locked — owner ask). #23/#24 were already closed; stale next-step.
- Harness: auto-mode classifier blocks `gh pr merge` (and heredoc `gh pr create`;
  `--body-file` works) — overnight runs end at an open PR, Nico merges. Direct push to
  main IS allowed. iOS compile checks need `CODE_SIGNING_ALLOWED=NO` (not just
  `CODE_SIGNING_REQUIRED=NO`) on this laptop.

**Next steps:**
1. **Saturday (owner, physical journals): the real marker session** — read an actual
   two-voice page (markers 5–7 were improv-verified today), confirm the dash-dot haptic
   feels right (tunables in `MarkerHaptic.swift`), then pull `markers.jsonl` +
   `live.jsonl` and tune `MarkerSnapping.snapWindowSeconds` — watching the
   no-mid-utterance-gap `approximate` pattern found today.
2. Design session (parked, owner asked): capture landing page, journal-focus
   consistency, ¶-button placement, #18 switcher, #35 delete friction.
3. T7 editor UI (whole-revision accept v1) + audit log — consumes the voice attribute;
   then T8 retranscribe.
4. Flake backlog: `testRapidRecordDoneCyclesProduceTenSeparateEntries` via the
   breakpoint-controller method; the 150 ms-sleep-shielded sibling while there.

## Session 2026-08-06 evening (laptop — CI red root-caused, #32 found+fixed, phone paired; 706 → 708 tests)

- **Resync caught an accidental issue close.** Docs-only commit `47d3f37a`'s message said
  "carries fixes #25", so the PR #28 merge closed #25 — with zero code shipped (the
  removal walk at `LibraryScreenModel.swift:312` / `TrashSweeper.swift:80` is untouched).
  Reopened. **Never write "fixes #N" in a commit message as prose** — say "build prompts
  for #25". GitHub reads it as a close-command on merge to main.
- **The "docs-only CI failures" were a mirage — there was never a path bug.** Opus
  subagent over 40 runs: docs commits 5/14 failed vs code 7/26 — statistically the same
  flake, two populations. (1) The #22 give-up race, dead since `97eb62e8`. (2) UI-test
  timeouts on contended runners — `testRepeatedRecordStopCyclesProduceSeparateEntries`
  spent 7 s in one wait-for-idle and blew its 30 s finalize budget; it flaked identically
  on 08-02, pre-markers. Hardened in `1f330f49`: `-retry-tests-on-failure
  -test-iterations 2` on the UI step (a twice-failing test still fails the run), the
  Xcode pin fixed (`/Applications/Xcode_26.app` doesn't exist on macos-26 and the
  `|| ls` fallback swallowed the error — the pin was decorative; now 26.6, loud), and
  xcresult upload on failure. Both runs since: green.
  Related tooling trap: `gh run view --log-failed` returns empty (exit 0) when a step
  name contains parentheses — use `gh api repos/…/actions/jobs/<id>/logs`.
- **Owner smoke tests 1–4 all pass** on `a4779994` (detail-trash, Delete Now, restore
  round-trip, swipe actions).
- **#32 found by owner mid-smoke, root-caused, fixed same evening (`c61c0d97`).** Two
  symptoms, one defect: capture-screen Recents pushed a blank detail page (with any
  journal chip selected), and move-to-journal blanked the live detail screen in place.
  `LibraryScreenModel.item(_:)` searched only journal-scoped `items` (`?? trashed`) while
  Recents pushes ids from the cross-journal `allEntries`; ContentView's `.entry`
  destination was `if let` with no else, and a destination builder returning nothing
  still pushes — a blank page. Fix: items → allEntries → trashed fallthrough (nil now
  means "exists nowhere") + a `ContentUnavailableView` else branch (the app's first use
  of that component; `entry.unavailable` a11y id). TDD red-first; 708 unit tests.
  Instructive: `EntryDetailView`'s keep-last-known defence was dead code for this case —
  the ContentView gate destroyed the view before its own defence could run.
- **Phone is now paired to the laptop** (one-time USB-C cable + Trust) — all future
  installs from this machine are wireless (`devicectl device install app`). Fresh main
  (`c61c0d97`: markers + #32 fix) installed. Remote `process launch` fails on a locked
  device — owner taps the icon instead.
- **Parked for a design session (owner asked, explicitly "later"):** capture landing
  page redesign — Recents styling, the two journal switchers (library vs capture) and
  where journal focus lives, and landing back on the journal's entry list after
  move-to-journal instead of staying on the detail screen.

**Next steps:**
1. **Saturday (owner home with physical journals):** record a real two-voice page —
   marker smoke tests 5–7 (toggle + controls, real recording with voice/paragraph taps,
   carry-over check). Also re-verify #32 on the phone: journal chip selected → tap a
   cross-journal recent → real detail page.
2. Pull the marker log from that recording; tune `MarkerSnapping.snapWindowSeconds`
   (1.5 s, a guess no test can validate).
3. Design discussion: capture landing page / journal-focus consistency (parked list above).
4. #25 staged-removal build — prompts ready in
   `docs/plans/2026-08-05-staged-removal-build-prompts.md`.
5. T7 editor UI (whole-revision accept v1) + audit log; T8 retranscribe.

## Session 2026-08-05 evening (laptop — Xcode verified; T6 §14 built; 640 → 706 tests)

**The laptop is now a real build machine.** Xcode 26.6 was already installed and selected;
the actual blocker was **signing** — zero codesigning identities, so every `xcodebuild`
died with "No Mac Development signing certificate" before running a test. Owner minted an
Apple Development cert in Xcode → Settings → Accounts (two now exist, both valid, harmless).
CI's own workaround also works locally and is what the subagent prompts used:
`CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO`. iOS 26.5 simulator runtime installed.

- **#22 root-caused and CLOSED (`97eb62e8`, PR #30) — it was three tests, not one.**
  All the same defect as issue #4: `send()` publishes the phase before the commit effects
  reach disk, so a test gating on `phase == .captured` and then reading the artifact races
  it. #4's fix taught the *sibling* tests to poll the on-disk manifest; these kept the old
  pattern. `testReacquireBudgetExhaustedClosesInterruptionAsNotResumed` and
  `testFailedResumeDiskWriteGivesUpToCapturedWithAudioIntact` (empty `finalizeQueue`), plus
  a third a subagent surfaced, `testGiveUpPathDeactivatesTheAudioSession`.
  **Method worth reusing: none of them reproduce in isolation** (12/12 green), so the race
  was forced with 6–8 `yes > /dev/null` spinners — 3/15 and 1/15 failures unfixed, 15/15 and
  20/20 green after. The two siblings that `await coordinator.done()` directly are *not*
  racy; only the polled give-up paths are.
- **T6 §14 capture-time structure markers built and merged (`6562c6f0`, PR #31)** — steps
  1–6 of `docs/plans/2026-08-05-structure-markers-implementation-plan.md`, one subagent per
  step on its own branch in its own worktree, parent diff review + mutation check before
  every commit. 640 → 706 unit tests, 9 UI tests. Step 7 stays deferred to T7.
  Most informative mutations: dropping `didWriteOpeningVoice` mis-attributes every span
  after an interruption resume (3 markers != 2, voice reset to `bn`); making the
  `multiVoice` decode strict breaks **14** tests, every extra one a pre-feature sidecar
  fixture — the exact device-data hazard the leniency exists for.
  `.sensoryFeedback(_:trigger:condition:)` **does** compile on macOS (plan checklist item 6
  answered); the `condition:` variant is required, since `markerCount` resets at teardown
  and a bare trigger buzzes on Done.

**Two false-failure patterns that each cost an hour — read before debugging a red suite:**
- **`xcodegen generate` after every *checkout*, not just after editing `project.yml`.** The
  `.xcodeproj` is gitignored, so switching to a branch without a file the project references
  fails as a bare `** TEST FAILED **` naming no test. It cost a whole 15-run experiment that
  reported 15/15 "failures" that were a stale project.
- **Never pipe `xcodebuild` through `head`.** It closes the pipe, wedges xcodebuild and its
  simulator runner, and leaves the sim's accessibility service bad — which then fails
  *unrelated* UI tests with `XC_kAXXCAttributeFocusedApplications` timeouts. Tell is timing
  (441 s vs 41 s for the same test). Recover with `simctl shutdown all` + `erase`. Related:
  after any interrupted UI run, shut simulators down before re-running.

Also: the Agent tool's worktrees branch from **main**, not from your current checkout —
subagents building on a stack must be told explicitly to `git checkout -b <name> <base>`.
`.claude/worktrees/` is now gitignored (it was making `git status` take 3.6 s).

**Next steps:**
1. **Owner smoke test (next session).** Two things at once: the outstanding
   `a477999` items (detail-trash, Delete Now, restore round-trip, swipe actions) and the
   new marker controls — record a real two-voice page.
2. **Tune `MarkerSnapping.snapWindowSeconds`** (currently 1.5) from that recording. It is a
   guess no test can validate, and deliberately a single constant.
3. T7 editor UI (whole-revision accept v1) + audit log — it consumes the voice attribute
   (design §9 step 7); T8 retranscribe.
4. `/resync` on the laptop now that it builds (never run here).
5. Filed, unscheduled: #25 staged removal (data-safety adjacent, build prompts already
   written), #23/#24 follow-ups, #17 cover polish, #18 journal switcher.

## Session 2026-08-05 afternoon (laptop — Xcode landed; crashed-session recovery)

Short session before owner travel. Xcode 26.6 (17F113) is now installed, selected, and
license-accepted on the laptop — **still unverified by an actual test run**.

- **Morning session crash post-mortemed**: the 09:02 plan-writing session hung at
  09:07:40 PT, immediately after the third of three Explore agents returned — the model
  API stream after those tool results never completed. Not local: the agents only
  read/grepped source, hooks have 5 s timeouts, and the Xcode license (accepted 09:21,
  mid-hang) was ruled out — the session stayed dead after acceptance. Nothing was lost;
  the tree was clean.
- **The three Explore code maps were recovered** from the dead session's transcript and
  stowed as `docs/plans/2026-08-05-structure-markers-code-maps.md` on branch
  **`plan/structure-markers`** (`77c55878`). A **cloud session is writing the T6 §14
  implementation plan on that branch** (per §9's seven steps, against the maps; it cannot
  build, so the plan is unverified-pending-local-run). Review its output before merging.
- **CI is red on `main`** at `1f2a44b5` — a docs-only commit, and `f516761` (also
  docs-only) failed on 08-03 while code commits between them passed. Likely flake or a
  docs-path trigger bug; uninvestigated. `gh run view 31022907852 --log-failed`.

**Next steps:**
1. Pull `plan/structure-markers`, review the cloud-written implementation plan, then run
   it locally (this machine can now build — verify with a macOS test run first).
2. Root-cause the red CI on main (docs-only commits failing).
3. Owner smoke test still outstanding on phone build `a477999` (detail-trash, Delete Now,
   restore round-trip, swipe actions).
4. `/resync` on the laptop now that Xcode works (never run here).
5. T7 editor UI (whole-revision accept v1) + audit log; T8 retranscribe.

## Session 2026-08-05 (laptop, design-only — no Xcode on this machine)

First session on the **laptop**. It cannot build: only CommandLineTools is installed, no
`Xcode.app`, so no `xcodebuild` and no simulators. App Store install started; macOS here is
26.6, matching the mini. Until it finishes, this machine is docs/design only.

- **Machine-local trap, fixed:** `sync-claude-md.sh --check` reported drift and `--apply`
  would have *deleted* the UTC-at-rest/Pacific-on-display convention added on the mini the
  day before (`a7fae6e4`). Cause: the script reads `~/.claude/claude-md-shared.md`, which is
  **not** git-synced and was two weeks stale here; `~/src/prompt-lab` was current. Refreshed
  the canonical copy from the repo. **On any new machine, read the diff before `--apply`** —
  drift can mean your local canonical is old, not that the repo is behind.
- **T6 §14 designed and committed** (`d031c213`):
  `docs/plans/2026-08-05-capture-structure-markers-design.md`. §14 now points at it.
  Voice + paragraph markers only — **end-sentence dropped** (the transcriber punctuates
  acceptably; per-sentence tapping costs the most flow for the least gain). Owner decisions:
  multi-voice toggle gates the feature, defaults off with **per-journal durable** carry-over,
  opens in `bn` as a frame-0 marker; voice stored as a string id, not a bool; **raw tap
  frames stored, snapped to word gaps on read** (±1.5 s, tunable); no capture-time undo;
  paragraph markers independent of the voice toggle. Frame source is a `FrameClockSink` tee
  branch (rejected the `elapsed` timer — a wall-clock accumulator that drifts from the frame
  axis across an interruption, so it passes every test and fails only on interrupted
  recordings). Markers hang off `CaptureCoordinator`, not `TranscriptionSession`, so they
  survive captures where transcription never ran.
- **Deliberate divergence recorded**: multi-voice carry-over auto-enables, where backdate
  carry-over (2026-08-02) explicitly never does. A wrong voice attribute is visible and
  editable; a wrong backdate is a quiet data error.
- **Edit ↔ capture round-tripping: rejected for now**, not filed. Follow-on material becomes
  its own entry (page-per-entry already makes entries small and numerous); an entry owning
  multiple recordings would break "transcript time = position in *the* m4a", playback seek,
  and the recovery scan, and is hard to walk back. #26 (capture pause) is unaffected and
  stays cheap — it is the interruption path driven by a button.

**Next steps:**
1. Finish the Xcode install on the laptop, then `sudo xcode-select -s
   /Applications/Xcode.app/Contents/Developer && xcodebuild -runFirstLaunch`. Verify with a
   macOS test run before trusting this machine.
2. Structure-markers build — task breakdown is §9 of the new design doc, seven steps,
   step 7 (T7 renders the voice attribute) deferred to T7. Write the implementation plan
   against a machine that can run the tests it specifies.
3. Owner smoke test still outstanding on phone build `a477999` (detail-trash, Delete Now,
   restore round-trip, swipe actions).
4. T7 editor UI (whole-revision accept v1) + audit log; T8 retranscribe.
5. `/resync` on this machine once Xcode works — it was skipped here because nothing could
   be verified by building.

## Session 2026-08-03 afternoon (subagent-driven; 595 → 632 unit tests, 8 UI tests)

**Closed: #19 #20 #21**, plus no-future-backdates (owner ask) and library swipe actions.
Every build ran through a Sonnet/Opus subagent with parent diff review before commit;
TDD prompts now require red-first evidence or a mutation check (see memory).

- **No-future-backdates** (`718052f`): `PartialDate.isFuture` (precision-aware, injectable
  clock), `EntryMetadata.setOriginalDate` the single write path (rejects, never clamps),
  detection discards future dates *without* latching. Mutation-verified.
- **#21** (`675c409`): `detectionRan` latch decodes from the `detectedDate` key's presence,
  independent of value parse; explicit key written only in the ran-but-valueless state.
- **#19** (`223b6d8`): `endedAt` = system's resumeAvailable receipt only (honestly nil
  otherwise); new `closedAt` = when we stopped waiting, and is the open/closed marker.
  Legacy records migrate on read.
- **#20** (`916d47a`): resume's disk half moved into `rebuildAndReacquire` before
  `.engineReady` — the only spot `.reacquireFailed` is still legal; store rolls back its
  in-memory manifest on a failed segment open. Failure surfaces via rows 10/11 + lastError.
- **Owner trash bug, root-caused via device forensics** (wireless container pull —
  `devicectl device copy from --domain-type appDataContainer`): detail-view Move to Trash
  was fire-and-forget *during view dismissal* (pop first, write later, `_ = try?`), so the
  tombstone never reached disk and Delete Now correctly-but-silently refused. Swipe path
  always worked (same model call, no teardown). Fix (`9c90ae8`, `a477999`):
  `trashEntry`/`restoreEntry`/`moveEntry`/`setBackdate` return Bool, every call site
  alerts, detail trash awaits-then-dismisses. deleteEntryPermanently no longer lies.
- **T6 revision-chain design rev 2 committed** (`5fc0ad0`) after two Opus adversarial
  passes killed rev 1's core (stored `detached` + highest-n current = data loss on second
  machine pass and on sync). Rev 2: `(createdAt, ULID)` order, ancestry-derived
  attachment, create-once writes, read-path-never-writes. **All 8 owner questions
  decided** (§12), incl. queue-not-close for drafts, decline-as-merge, page-per-entry.
  **§14 records voice markers**: LN/BN switch-voice + end-sentence/end-paragraph capture
  buttons (his journals are two-voice conversations, print vs cursive) — needs its own
  short design pass before T7.
- Filed: #22 (flaky reacquire test, 2/12), #23 (try?-swallowed manifest writes), #24
  (give-up leaves session active), #25 (non-atomic removeItem can un-trash an entry),
  #26 (capture pause — owner ask, maps onto interruption machinery).

**Next steps:**
1. Owner smoke test on phone build 14:29 PT (`a477999`): detail-trash, Delete Now on the
   fishing entry, restore round-trip, swipe actions. If detail-trash alerts, pull the
   container again.
2. Voice-markers design pass (§14 of T6 doc) — before T7.
3. T7 editor UI (whole-revision accept v1) + audit log build; T8 retranscribe.
4. #25 staged removal (data-safety adjacent); #22 flake root-cause when touching that area.
5. Backdate-precedence build (docs/plans/2026-08-03-backdate-precedence-ux.md, option B +
   affordance) — owner answered the T6 questions but B's backdateOrigin build is unstarted.

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
1. **iPhone pass — set up, never run.** Blocked mid-flight on device registration: the
   phone is not in the developer account, so `xcodebuild` fails at signing
   ("Device isn't registered… provisioning profile doesn't include"). Owner was
   registering it via Xcode (select device → ⌘B → **Register Device**) when the session
   ended. Once registered, rebuild from the CLI and install. Still unverified, all of it:
   TCC behaviour, the ~2-instance limit (macOS has none), background suspension (§7),
   asset download on a device without models, battery/thermal.
   **The device is an iPhone 17 Pro** (`iPhone18,1`, iOS 26.5.2, CoreDevice
   `0CE992E2-8065-5FAB-A2E2-064D9712A522`; hardware UDID deliberately not recorded here —
   public repo; get it from `devicectl list devices` when needed) —
   *not* an iPhone 15. Its name was inherited from a restore, and a stale `iPhone16,1`
   record with a near-identical name still shows as `unavailable`. Identify by
   productType or CoreDevice UUID, never by name. Note it needs Developer Mode confirmed **after**
   the reboot, not just toggled before it.
2. Carry-ins still open from design §11.7: the secondary-sink abandon hook (four
   coordinator paths drop the sink with no notification, leaking a live analyzer), and
   recovery synthesizing a `completedAt: nil` ref for a killed capture. The
   denied-permission path is one of the four leaks and is exercised by the iPhone pass.
3. `NSSpeechRecognitionUsageDescription` is absent from `project.yml`; design §6 wants it
   added defensively. Unconfirmed whether iOS actually requires it for on-device
   `SpeechAnalyzer` — if it does, that is a first-launch crash on the phone.

Closed this session: the 7.80 s transcript (see below), the `DictationTranscriber`
fallback (landed), and the CloudKit container (already reserved on the portal —
`iCloud.org.pianohouseproject.raconte` exists, description "Raconte"). The app's
entitlements still carry no iCloud keys, which is correct until M4.

## M3 dogfood MVP landed 2026-08-02 (evening session)

Plan of record: `docs/plans/2026-08-02-m3-dogfood-mvp-plan.md`; journeys draft
`docs/user-journeys.md`. T0–T5 all landed via supervised subagent builds, every diff
reviewed before commit; 320 → 478 unit tests, 6 UI tests. Shipped: journals first-class
(registry + `entry.json` sidecar, default journal auto-created), journal-context capture
with optional backdate, scan-based library (degrade-never-skip), library/detail screens,
one data path for recents (FinishedRecording deleted), 30-day trash (sweep never touches
an unreadable sidecar — mutation-verified), and an adversarial-review pass whose worst
find was `journals.json` unreadable→empty collapse silently unfiling a session.
Both devices carry current main. Trash flow has no manual smoke number yet.

**UI design rules (owner, 2026-08-02):**
- The capture screen pins a near-black background; any system control placed on it must
  pin `.environment(\.colorScheme, .dark)` — ambient-scheme bubbles render dark-on-dark
  in light mode (bit us once).
- Prefer semantic colors over `Color(white:)` literals anywhere the background isn't
  pinned.
- Backdates are sticky: editable with explicit overrides, never clearable by one tap.
  Owner wants metadata edits auditable eventually (fold into T6 revision design).

## Session 2026-08-02 evening → 2026-08-03 (subagent-driven; 478 → 595 unit tests)

**Closed: #14, #16, #9, #12.** All device-verified by owner except where noted. Two Opus
adversarial passes; every finding fixed same-session or filed (#19 #20 #21).

- **#14 in five commits.** Precision entry dates (day/yearMonth/year picker,
  `PrecisionDatePicker`); derived journal date ranges (`JournalDateRange`, precision-aware
  bounds, on chips + switcher); cover images (`JournalCoverStore` actor, ImageIO-only,
  camera + PhotosPicker per owner decision, `journals/<id>/cover.jpg`). Then the big one:
  **backdates are now `PartialDate` strings** ("1998"/"1998-03"/"1998-03-04") in
  entry.json — a year-only backdate stored as a `Date` re-derived a different year after
  a westward timezone change. Legacy ISO+precision sidecars dual-read, upgraded in place
  on rewrite. `anchorDate` (noon, day-1 fill, `Calendar.gregorianCurrent`) is the one
  Date-conversion rule. Landed while the corpus was tiny, as planned.
- **#15 landed** (`SpokenDateParser` — no NSDataDetector, it can't express precision;
  `SpokenDateDetection.apply` with `detectedDate` as the once-only latch on the sidecar;
  hook at finalize + launch recovery, degrades to silence; "Detected from the recording"
  label in detail view) **plus per-journal backdate carry-over** (in-memory this session,
  pre-fill on toggle-enable, never auto-enables, re-anchors on journal switch).
  Owner-verified on the phone except items in Next steps below.
- **Worst review finds, all fixed:** interruption resume erased a detail-screen backdate
  (write now guarded like `journalID`); Library-and-back navigation permanently dropped
  the #12 display hold (`onAppear` restore); lenient `Calendar.date(from:)` rolled
  Jan 31 + month=Feb into March; a `.year` bound fabricated "January" in ranges; filler
  stripping promoted mid-sentence years to bare-year detections (now gated to raw
  token 0); carry-over leaked across journals via live picker state.
- CI caught one UTC-only test failure locally invisible in Pacific (near-epoch backdate
  fixture) — keep backdate test fixtures away from year boundaries.
- Owner decisions recorded: #15 auto-apply (no chip); covers camera+library; carry-over
  within journal; phone is the primary dogfood device until M4 sync (mini = testing
  scratch, no laptop install).

**Next steps:**
1. **Disallow future backdates — owner asked for TDD.** Model-level clamp (picker,
   `setBackdate`, detection) + tests first. From phone smoke: forward dating currently
   allowed.
2. **Library swipe actions:** slide-to-trash and slide-to-move-to-journal on library
   rows, consistent with platform convention (owner request).
3. **UX discussion before building (owner: "let's discuss"):** manual-backdate-first
   currently blocks spoken-date detection entirely (his test 2 surprise), and carried
   backdates count as manual so a sitting with carry-over never gets per-entry spoken
   dates. Candidate: track how the backdate arose (explicit dial vs carried pre-fill);
   spoken detection outranks carried but never explicit; plus a "use detected date"
   affordance in detail view when detected ≠ original. Decide with owner first.
4. Filed, unscheduled: #19 (`endedAt` stamps when we stopped waiting), #20 (swallowed
   `resumeRecording` failure = dead recording under a running timer — data-loss
   adjacent, schedule soon), #21 (detection latch fails open if `detectedDate` ever
   unreadable), #17 (cover polish), #18 (journal switcher design pass — fold into T6).
5. T6 revision-chain design doc (editorial foundation; metadata-edit auditability),
   then T7/T8, then T9 CloudKit before multi-device editorial.

## Landed 2026-08-02

**The 7.80 s transcript is trailing silence — closed, not a bug.** The 9.1 s capture
`01KYX77KK5QM15915EZBVXTQZ4` (436,800 frames) committed two records, the second ending at
frame 374,400 (7.80 s), last word run at 371,520 (7.74 s). Measured off the analyzer's own
`transcript/analysis-input.wav`: speech runs at −34 dBFS through ~6.6 s, decays across
7.0–7.8 s, and the final 1.3 s sits at −50 to −59 dBFS — room noise. `coverageFrames`
equals the full recording and `skippedRanges` is empty, so the analyzer received every
frame and finalized through end of input. Nothing lost.

**M2 §6.1 — `DictationTranscriber` fallback.** `TranscriptionModuleCandidate` (candidate
protocol, two real conformers, `TranscriptionModuleSelector` owning order and the failure
taxonomy); `SpeechAnalyzerEngine` delegates module choice. The candidate holds its own
concrete module and drains its own results because `SpeechModule` has associated types and
no existential carries `results`. The `TranscriptionEngine` seam is unchanged. Each
candidate is gated on **its own** `bestAvailableAudioFormat != nil` —
`AssetInventory.status` stays advisory. 302 → 320 unit tests.

Two design-doc corrections, verified directly against `MacOSX26.5.sdk` (both the macabi
and `arm64e-apple-macos` slices, identical here): there is **no**
`DictationTranscriber.isAvailable` — `isAvailable` occurs once in the whole interface and
belongs to `SpeechTranscriber`, so §6 step 1's symmetric check does not exist; and there
is no `.noEngine` case in `TranscriptionUnavailable`. Written up as §12 of the design doc.

**The fallback has never executed anywhere.** CI has no assets and the mini has
`SpeechTranscriber` assets, so the preferred module always wins; only the selection *rule*
is tested, against fakes. The 17 Pro will likely not exercise it either — the stale
`iPhone16,1` is the better candidate, being likelier to lack assets.

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
- Signing: team `8UK463WB83` (in project.yml) is a **paid** Apple
  Developer Program membership — the same team MusicForge ships under. Nothing is gated on
  enrollment: TestFlight, CloudKit containers, push and Live Activities are all available
  now. (Verified 2026-07-31 from the on-disk profiles: App Store distribution profiles and
  year-long expiries, neither of which a free personal team can produce.)

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
