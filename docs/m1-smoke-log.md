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

9. 2026-07-29 — iPad kill-at-every-transition sweep (home-screen launch):
   - preparing PASS, recording (first entry) PASS — clean idle, no banner.
   - recording w/ rotated segments (swipe-kill at ~25s; rotation isn't
     gateable — doc corrected): PASS, recovered ~0:25.
   - stopping PASS, captured PASS — recovered banner + auto-finalize.
   - finalizing PASS with corrected expectation: gate lands post-commit → no
     banner, silent re-finalize into the list (doc corrected).
   - interrupted / resuming gates NOT RUN: Siri won't engage while the app
     holds the mic (voice or top-button), so no solo interruption source on
     iPad. Needs a FaceTime call from a second device, or fold into the
     iPhone pass.
   Harness fixes this run: "Kill now" is SIGKILL (fatalError paused under
   Xcode's debugger and looked dead); run the sweep from a home-screen launch,
   not an Xcode run session.

10. 2026-07-30 — Mac mini, doc test 31 (input-device switch mid-recording) —
   PASS on the issue this test tracks. Counted 1→12 over ~12s, switched input
   device in System Settings → Sound partway through. Both halves present;
   #5 (total post-switch loss) confirmed fixed by db1ac02 and CLOSED.
   Residual, tracked in #9: ~4s of audio lost across the switch (playback runs
   "six" → "eleven") and the splice is *smooth*, not silent — the timeline
   compresses rather than preserving the gap. Same failure family as #2 but at
   the segment boundary rather than within a segment. The gap length is already
   derivable from existing sidecar `startHostTime` + `frameCount`; nothing
   consumes it, and `contiguousPrefix` reads the run as gapless because
   `startFrameOffset` is cumulative-by-construction.

11. 2026-07-31 — Mac mini, doc test 25 (scrub a recovered, un-finalized
   recording) — PASS. Recorded ~30s counting aloud, `killall -9` mid-recording,
   relaunched to the recovery banner, played, dragged to mid-track, then back
   toward the start. Audio resumed from the handle both times, elapsed label
   tracked the handle, and playback crossed segment boundaries without a gap.
   This was the last thing gating issue #6 — the finalized-m4a path is already
   covered by `CaptureUITests.testScrubbingAFinishedEntryMovesThePosition` — so
   **#6 CLOSED**. Test recording deleted afterward by the owner.

12. 2026-08-02 — **iPhone 17 Pro, first pass ever on a phone.** Device
   registration cleared, built and installed from the mini. Three checks:
   - First launch + permission: **PASS.** Only the microphone prompt appeared —
     **no speech-recognition prompt.** So iOS does *not* require
     `NSSpeechRecognitionUsageDescription` for on-device `SpeechAnalyzer`. The
     key is still absent from `project.yml`; design §6 wants it defensively, but
     it is not a first-launch crash and never was.
   - ~15 s recording with live transcript: **PASS.** Text appeared on screen
     while speaking, owner rated accuracy good, audio "perfect" on playback.
     This is the first confirmation that M2's capture→convert→analyze→log chain
     works on iOS at all, not just on macOS.
   - Denied-permission path: NOT RUN (owner declined; the sink-abandon leak it
     exercises stays unverified).

   **Observed: the live transcript appeared to stop a few words early** when
   stopping immediately after speaking. **Root-caused the same session as a
   display bug — no words were ever lost**, and fixed.

   `LiveTranscriptionCoordinator.finish(captureID:)` removed the run from `runs`
   and cleared `activeCaptureID` *before* `await run.finish()`. But
   `run.finish()` awaits the pump, and the pump's tail is exactly what publishes
   the analyzer's finalized text into `displayText` — a capture's last phrase is
   produced *during* shutdown, not before it. So the panel unhooked from its
   data source the instant stop began, and the finalize tail was written to
   `live.jsonl` while rendering nowhere. Fix: unhook after the await, plus hold
   the completed text in `lastCompletedText` until the next capture begins, so
   the panel no longer blanks the moment an entry lands.

   Owner called this correctly from the symptom alone ("it just switched
   interface before it was done"). Worth recording that the first two theories
   from the code side — the 5 s `finalizeBound` against a previously measured
   5.2 s finalize, and a volatile trailing phrase never finalizing — were both
   wrong, and the expensive on-device container pull they implied was
   unnecessary.

   **Re-verified same session on a rebuilt phone install: PASS.** The final
   words appear and stay up. One observation worth more than the pass itself:
   the on-screen text was *wrong* at the moment of stop and **auto-corrected
   afterwards**. That is the consolidator promoting volatile text to committed
   during shutdown, and it settles a question the code alone could not — the
   analyzer's corrections arrive *during* finalize, not before it. Which is
   also why the old ordering hid so much: it unhooked the view at exactly the
   moment the transcript was still improving.

   Also landed this run: **a build timestamp at the bottom of the capture
   screen** (`BuildInfo`, executable mtime, rendered in `America/Los_Angeles`
   regardless of the device's zone). A wireless `devicectl` install gives the
   tester no visible evidence of which build they are holding; that question
   came up mid-pass and could only be answered from build-tool output on the
   mini. Verified in the field the same session. The technique — wireless
   install plus the stamp — was written to the `musicforge-raconte` handoff
   channel, since MusicForge ships a SwiftUI app to the same devices.

Next run: 13 — interrupted/resuming gates (doc tests 13 + 14) via a FaceTime
call from a second device. Now best run on the iPhone rather than the iPad,
since the phone is live and Siri/calls work there natively. Also still open on
the phone: background suspension (§7), the ~2-instance limit, asset download on
a device without models, battery/thermal, and the denied-permission path.
