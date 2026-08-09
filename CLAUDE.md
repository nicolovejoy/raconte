# CLAUDE.md

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
   `0CE992E2-8065-5FAB-A2E2-064D9712A522`, hardware UDID `00008150-000D244C3663401C`) —
   *not* an iPhone 15. Its name was inherited from a restore, and a stale `iPhone16,1`
   record with a near-identical name still shows as `unavailable`. Identify by
   productType or UDID, never by name. Note it needs Developer Mode confirmed **after**
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
- Signing: team `8UK463WB83` ("Nicholas Lovejoy", in project.yml) is a **paid** Apple
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
