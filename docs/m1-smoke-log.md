# M1 smoke run log

Sequential run numbers (Nico's numbering, continues across sessions). Doc test
numbers refer to `m1-paranoid-tests.md`.

Device: Nico's Big iPad unless noted.

1. 2026-07-29 — deploy + first record/playback (doc test 1) — PASS
2. 2026-07-29 — playback of finished entry (doc test 2) — PASS
3. 2026-07-29 — app switch mid-recording (doc test 5) — PASS. Spawned issue #1
   (background recording continues with no user-facing indication).
4. 2026-07-29 — force-quit mid-recording (doc test 6) — recovery PASS; playback
   silent. Root cause: cold-launch `.soloAmbient` session; fixed in `11e6dfa`
   (`CapturePlayback.ensurePlaybackSession`). Entry became audible after the fix.
5. 2026-07-29 — re-test doc test 6 after fix (7s recording) — PASS with caveat:
   jittery robotic cut-outs from ~4-5s (the swipe-out moment), then silence to
   the end. Same spot in raw playback AND the m4a → data on disk; storage chain
   verified byte-consistent. Diagnosis: OS dropped/muted mic buffers around the
   app-switcher transition; tap concatenates what arrives (time compression).
   Spawned issue #2 (gap-honest capture via AVAudioTime) and issue #3 (no
   playback position UI).

6. 2026-07-29 — swipe away + return mid-recording (run-5 discriminator) — PASS.
   Background audio captured; small audible hiccup at both transition edges
   (swipe-out and return). Owner: acceptable for M1, not perfect. Issue #2
   reopened as the down-the-road fix (gap-honest capture).

7. 2026-07-29 — iPad tests 25-27 — PASS per owner (kill sweep not yet run —
   harness needed explaining first). New observation: ~quarter-second "shkshks"
   artifact right at backgrounding (noted on issue #2; still accepted).

8. 2026-07-29 — macOS pass, semi-automated (Claude killed/relaunched/verified
   disk; owner clicked + spoke; eMeet Nova mic, 48k via HAL).
   - Doc test 28 (record/stop/playback): PASS.
   - Doc tests 29+30 (background + SIGKILL mid-recording, ~52s in the .part):
     PASS — recovery normalized, re-finalized, `complete` on disk.
   - Doc test 31 (input switch eMeet → iPhone Continuity mic): FAIL — no crash,
     but all post-switch audio lost, recording cut short at cut-over → issue #5.
   - **Major find**: live finalize never ran in-session — the UI drained
     `finalizeQueue` on the phase flipping to `captured`, which happens before
     the commit effects fill the queue; every m4a to date came from next-launch
     recovery, masked by the raw-segment playback fallback. Fixed
     (`handleFinalizeQueue` keyed off the queue) + 2 model-level regression
     tests (suite now 138).
   - Also landed: delete button on recording rows (owner request). Scrubbing →
     issue #6.

Next run: 9 — iPad kill-at-every-transition sweep via the Debug button.
iPhone full pass deferred by owner until iPad + Mac are solid.
