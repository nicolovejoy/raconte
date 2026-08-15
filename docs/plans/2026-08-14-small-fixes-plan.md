# Small-fixes batch plan — 2026-08-14

Branch `fix/aug14-batch`, worktree `/Users/nico/src/raconte-b5`, base `423d3fed`.
Closes #42, #58, #49, #48 on merge (close-commands go in the PR body ONLY, never in
commit subjects/bodies — this repo has closed an issue by accident from prose before).

## Global constraints

- Swift 6 strict concurrency; match surrounding code style and comment density.
- After ANY project.yml change: `xcodegen generate` before building.
- Build/test command (always explicit derivedDataPath, never pipe through `head`):
  `xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' -derivedDataPath .dd test CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO`
  Use `-only-testing:RaconteTests/<Class>` for targeted runs while iterating; run the
  full macOS unit suite once before your final commit of the task.
- Every new test needs red-first or mutation evidence: show the test failing when the
  behavior it pins is broken (mutate the production predicate or fixture), and state
  the mutation and its output in your report. A test that passes against a mutated
  implementation is vacuous — this repo has hit that 14 times; reviewers check for it.
- Commit per green step. Commit messages: plain description, NO "fixes #N"/"closes #N".
- iOS must still compile: `xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'generic/platform=iOS' -derivedDataPath .dd build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO` after UI changes.

## Task 1 — issue #42: five cheap test pins (test-only, plus one injectable seam)

Test-hygiene backlog from Gate B triage. Five pins, each cheap, all currently relying
on implementation inspection:

1. `allocationCollision` (second EEXIST in `TranscriptRevisionStore.append`) is
   untested; reachable under T9 sync. Pin via the existing `beforeWrite` seam.
2. `DeviceIdentity` tests write the real `UserDefaults.standard` domain (test
   pollution across runs) — pass a throwaway `UserDefaults(suiteName:)`; make the
   store's device id injectable if that is what a clean test requires (small
   production seam allowed).
3. F18 generative splice property uses an unseeded `SystemRandomNumberGenerator` —
   failures are unreproducible. Seed it (or log the seed on failure so a failure can
   be replayed). Prefer a fixed seed + a documented way to vary it.
4. `closeDraft` on a trashed capture is untested (§10's trash-composition row names
   draft *close*; the `guardWritable` guard exists, only `writeDraft` has the test).
   Pin that closeDraft on a trashed capture refuses.
5. F11 half-open boundary case untested: `[100,150]` vs adopted `[40,100]` must NOT
   degrade. Also fix the comment at `TranscriptMergeTests.swift:328` which mislabels
   a 5-frame real overlap as a boundary case.

Each pin gets its own mutation evidence. Do not refactor unrelated tests.

## Task 2 — issue #58 (macOS dark-on-dark capture controls) + TestFlight orientations key

Part A (#58): On the capture screen in macOS **light mode**, these controls render
near-black on the pinned near-black background: the journal picker ("Recording
into"), the Backdate toggle, the Entry-date precision segmented control, and the
date field. The Two-voices toggle already carries the known fix
(`.environment(\.colorScheme, .dark)` — standing repo rule for system controls on
the pinned capture background) but these siblings evidently don't, or the pin
doesn't reach their popup/stepper internals on macOS. Sweep the capture screen:
every system control on the pinned near-black background must be legible in macOS
light mode. Prefer the colorScheme pin; where macOS control internals ignore it,
use semantic/explicit foreground colors. Verify by building macOS AND iOS; unit
tests only if a real testable seam exists (a shared modifier is one) — do not
invent view-inspection tests.

Part B (orientations): the App Store validation failure is
`UISupportedInterfaceOrientations` missing (the app declares no orientations).
In `project.yml` under the target's `info.properties` add:
- `UISupportedInterfaceOrientations: [UIInterfaceOrientationPortrait]`
- `UISupportedInterfaceOrientations~ipad: [UIInterfaceOrientationPortrait, UIInterfaceOrientationPortraitUpsideDown, UIInterfaceOrientationLandscapeLeft, UIInterfaceOrientationLandscapeRight]`
(Ruling: iPhone portrait-only; iPad all four to keep multitasking.) Then
`xcodegen generate` and prove the keys land: build for iOS and inspect the built
product's Info.plist (`plutil -p`) showing both keys. macOS is unaffected.

## Task 3 — issue #49 (backdate affordance disappears once set) + issue #48 (weekday on day-precision backdates)

Part A (#49), owner-ruled shape (option 1 from the issue): once a backdate is set,
the "Change backdate…" button (`EntryDetailView.swift:132` area,
`item.isBackdated ? "Change backdate…" : "Backdate this entry…"`) disappears
entirely. The displayed backdate itself becomes the edit affordance: tapping the
date opens the existing backdate sheet. Requirements:
- No backdate → the "Backdate this entry…" button exactly as today.
- Backdate set → no button; the rendered date is tappable and opens the same sheet;
  give it an accessibility label/hint (e.g. "Edit backdate") so VoiceOver users
  retain the route.
- The destructive "Remove backdate" action inside the sheet is untouched.
- The sticky rules stand: nothing becomes one-tap clearable.
Pin what is pinnable at model/view-state level (e.g. an affordance-visibility
function both ways); don't build UI-inspection tests for the tap itself.

Part B (#48), owner-ruled scope: show the day of the week ONLY for entries whose
backdate is `.day` precision. Never at `.year`/`.yearMonth` — `anchorDate`'s day-1
fill would fabricate an authoritative-looking, meaningless weekday (this is the
exact data-lie class `PartialDate` exists to prevent). No weekday for
non-backdated (capture-date-only) entries.
- Surfaces: library rows (abbreviated weekday, e.g. "Tue") and entry detail (full
  weekday name).
- Locale-aware: derive via the user's calendar/locale (e.g. `Date.FormatStyle`
  weekday, from `anchorDate` which is exact at `.day` precision) — no hardcoded
  English names.
- Pin the formatting both ways: day-precision backdate shows a weekday; yearMonth/
  year backdate and no-backdate show none. Keep fixture dates away from year
  boundaries (UTC/Pacific CI trap).
