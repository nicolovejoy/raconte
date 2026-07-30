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
5. 2026-07-29 — re-test doc test 6 after fix — PASS with caveat: audio garbled
   near the end, most content captured. Under investigation (write path can only
   truncate by construction; suspects: real handling noise during the swipes, or
   a playback/finalize issue not yet identified).

Next run: 6.
