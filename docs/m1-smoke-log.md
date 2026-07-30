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

Next run: 6 — discriminating test for the run-5 artifact: record ~20s, swipe to
the app switcher at ~5s, keep talking from outside the app for ~10s, return,
stop normally (no kill), play back. Clean mid-background audio with jitter only
at the transition = confirms transition-only artifact. Silent background span =
background capture itself is degraded and run 3's pass needs a re-listen.
