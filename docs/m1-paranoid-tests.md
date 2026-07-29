# Milestone 1 paranoid test checklist — indestructible capture

Manual test protocol for M1 scope only: record button, AVAudioEngine writing append-only
audio segments to disk, persistent capture state machine (idle→preparing→recording→
interrupted→resuming→stopping→captured→finalizing→complete), launch-time recovery scan,
background AAC finalize, playback. **No transcription, no sync, no folders in this
milestone** — don't test for them.

Run on a **physical iPhone** (simulator can't fake calls/Bluetooth/lock-screen realistically).
A shorter macOS pass is at the bottom. Each test is self-contained — no state carried from
the previous test unless its setup line says so. Tests marked **(2 devices)** need a second
phone to place a call; tests marked **(2 people)** need someone else's Bluetooth device or
help triggering an alarm from another room.

Before starting: fully charge the phone or keep it plugged in — several tests take 60+
minutes real time. Have Settings open in the background switcher for the permission tests.

## 1. Baseline

1. **Cold start, first recording.**
   Setup: fresh install, mic permission not yet granted.
   Steps: open app → tap record → grant mic permission when prompted → speak for 10s →
   stop.
   PASS = recording starts after permission grant, a finalized file exists, playback plays
   back the 10s of speech.
   FAIL = permission prompt doesn't appear, recording silently fails, or file is 0 bytes /
   missing.

2. **Immediate playback.**
   Setup: continue from test 1, or record a fresh 15s clip and stop normally.
   Steps: from the finished recording, tap play.
   PASS = audio plays start to finish, duration shown matches actual speech length.
   FAIL = playback fails, truncated, or duration is wrong/zero.

## 2. Lock screen & backgrounding

3. **Lock screen mid-recording, short (<1 min).**
   Setup: none.
   Steps: tap record → speak → after ~20s press the lock button → wait 30s with the phone
   locked → unlock → stop the recording.
   PASS = app shows "recording" state throughout (check via Dynamic Island / lock screen if
   present, or unlock and see elapsed time kept counting), finalized file contains audio
   from before AND after the lock, no gap or truncation at the lock boundary.
   FAIL = recording pauses/stops on lock, audio has a silent gap, or elapsed time resets.

4. **Lock screen mid-recording, long (>10 min).**
   Setup: none. Allow ~12 minutes wall-clock for this test.
   Steps: tap record → speak a few words → lock the phone → leave locked for 10+ minutes →
   unlock → speak again → stop.
   PASS = finalized recording duration is ~10+ minutes, both the start and end speech are
   audible, iOS did not kill the app in the background (check: no "Recovered recording"
   banner needed — this should finalize as a normal Stop, not a crash recovery).
   FAIL = app was suspended/killed by iOS (recording ends early, or launch shows a recovery
   banner instead of a clean stop), or audio is truncated.

5. **App switch (not locked).**
   Setup: none.
   Steps: tap record → speak → swipe up to the app switcher (don't force-quit) → sit on
   the home screen 15s → switch back into the app → stop.
   PASS = recording continued while backgrounded, no gap in audio, elapsed timer correct
   on return.
   FAIL = recording paused/stopped on background, or state shown on return is wrong.

## 3. App lifecycle / force-quit

6. **Force-quit mid-recording, then relaunch.**
   Setup: none.
   Steps: tap record → speak for ~30s → swipe up to app switcher → swipe the app card away
   (force-quit) → relaunch the app from the home screen.
   PASS = on relaunch the app runs its recovery scan and shows something like "Recovered
   recording: 0m3Xs" (duration close to what was spoken before the kill); the recovered
   audio file plays back the spoken words with no corruption.
   FAIL = no recovery banner appears (silent data loss), recovered file is empty/corrupt,
   or app crashes on relaunch.

7. **Force-quit during idle (no active recording).**
   Setup: app has at least one previously finalized recording; nothing is currently
   recording.
   Steps: force-quit the app (swipe away in app switcher) → relaunch.
   PASS = app opens straight to idle state, no spurious "recovered" banner, prior
   recordings still list/play correctly.
   FAIL = false-positive recovery banner, or prior recordings are lost/corrupted.

8. **Kill during "stopping" state.**
   Setup: none. This tests the narrow window between tapping Stop and the app finishing the
   stop transition.
   Steps: tap record → speak → tap Stop → **within roughly 1 second of tapping Stop**,
   force-quit the app (swipe away in app switcher) before you see any "saved/done" UI →
   relaunch.
   PASS = recovery scan on relaunch finds the recording and finalizes it (banner or the
   recording simply appears in the list, playable, matching what was spoken) — no data
   loss even though the kill landed mid-transition.
   FAIL = the recording is missing entirely, or the app hangs/crashes on relaunch.

9. **Kill during "finalizing" state.**
   Setup: none. Finalize (raw segments → AAC) runs in the background after Stop; this
   targets killing the app while that conversion is in flight.
   Steps: tap record → speak for at least 60s (longer recordings give the finalize step
   more time to still be running) → tap Stop → immediately force-quit the app before the UI
   shows the recording as finished/playable → relaunch.
   PASS = on relaunch the recording either finishes finalizing automatically or the
   recovery scan re-finalizes it from the kept raw segments; final result plays back full
   audio with correct duration, no truncation at the point of the kill.
   FAIL = recording is missing, playback is truncated, or the app has to be told to retry
   with no automatic recovery.

## 4. Audio route changes

10. **Headphone pull mid-recording.**
    Setup: start recording while wired or Bluetooth headphones are connected and audio is
    routing through them (or just plug in wired headphones first).
    Steps: tap record → speak → physically unplug/disconnect the headphones mid-recording →
    keep speaking → stop.
    PASS = recording continues uninterrupted through the route change (mic input unaffected
    by output route switching to speaker), no gap or restart in the audio.
    FAIL = recording stops, restarts, or has a gap at the moment of disconnect.

11. **Bluetooth connect mid-recording. (2 people or spare BT device)**
    Setup: have a Bluetooth headset/speaker paired but not connected before starting.
    Steps: tap record → speak → connect the Bluetooth device mid-recording → keep
    speaking → stop.
    PASS = recording is continuous across the route change; audio captured before and
    after the connect is all present and in order.
    FAIL = gap, duplicate segment, or recording stops on the route change.

12. **Bluetooth disconnect mid-recording. (2 people or spare BT device)**
    Setup: start recording with a Bluetooth device already connected and routing audio.
    Steps: tap record → speak → turn off/walk away from the Bluetooth device mid-recording
    (forcing a route change back to built-in) → keep speaking → stop.
    PASS = same as above — continuous audio, no gap at the disconnect boundary.
    FAIL = gap, stop, or crash at the disconnect.

## 5. Interruptions

13. **Incoming call, accepted. (2 devices)**
    Setup: have a second phone ready to call the test device.
    Steps: tap record → speak → have the second phone call the test device → answer the
    call → talk briefly → hang up → return to the app → stop.
    PASS = app transitions to "interrupted" during the call (this is a normal state per
    design, not an error) and to "resuming"/"recording" after hang-up; the audio before the
    call and after returning are both present in the finalized file (audio during the call
    itself is expected to be missing/silent — that's correct, not a bug).
    FAIL = the app treats the interruption as a crash/error, loses the pre-call audio, or
    fails to resume recording after the call ends.

14. **Incoming call, declined. (2 devices)**
    Setup: same as above.
    Steps: tap record → speak → have the second phone call the test device → decline the
    call immediately → confirm the app is still recording → stop.
    PASS = brief interruption state then straight back to recording with no user action
    needed beyond declining; audio continuous other than the momentary interruption.
    FAIL = recording doesn't resume automatically, or requires the user to manually tap
    record again.

15. **Siri interruption.**
    Setup: none (Siri must be enabled, "Hey Siri" or side-button trigger).
    Steps: tap record → speak → invoke Siri ("Hey Siri, what time is it?") → let Siri
    respond and dismiss → confirm still recording → stop.
    PASS = same as call interruption — recording pauses/interrupts cleanly and resumes,
    audio before and after intact.
    FAIL = recording stops permanently, or app crashes when Siri takes audio focus.

16. **Alarm or timer firing mid-recording.**
    Setup: set a Clock timer or alarm to fire ~1 minute from now, with sound.
    Steps: tap record → speak → let the timer/alarm fire and play its sound → dismiss it →
    confirm still recording → stop.
    PASS = recording is unaffected or briefly interrupted-then-resumed automatically; no
    audio loss beyond the interruption window itself.
    FAIL = recording stops and doesn't resume, or the alarm audio contaminates/corrupts the
    recorded file.

## 6. System conditions

17. **Airplane mode toggle mid-recording.**
    Setup: none.
    Steps: tap record → speak → enable Airplane Mode (Control Center) mid-recording → keep
    speaking → disable Airplane Mode → stop.
    PASS = no effect on recording — audio capture doesn't depend on network/radio state;
    file is continuous.
    FAIL = recording stops or glitches when radios toggle (would indicate an unwanted
    coupling to network state — this milestone has no network path).

18. **Low Power Mode mid-recording.**
    Setup: none.
    Steps: tap record → speak → enable Low Power Mode (Settings or Control Center)
    mid-recording → keep speaking for at least a minute → stop.
    PASS = recording continues normally; no throttling artifacts, drops, or engine
    restarts.
    FAIL = recording stutters, drops segments, or stops when Low Power Mode engages.

19. **Disk nearly full.**
    Setup: fill device storage to within ~50–100MB of the device's reported free space
    (copy large files via Files app / Photos, or use a storage-filler tool) before
    starting.
    Steps: with storage nearly exhausted, tap record → speak for at least 30s → stop.
    PASS = the app either records successfully (if space allows) or fails **visibly and
    gracefully** (clear low-storage message, no silent data loss of what was already
    captured to disk before space ran out) — partial segments already written to disk
    before the failure must still be recoverable via the recovery scan.
    FAIL = app crashes, hangs indefinitely, or silently produces a corrupt/empty file with
    no error shown.
    Cleanup: free the disk space back up after this test.

## 7. Duration & timing edge cases

20. **Recording across midnight.**
    Setup: schedule this for a real run spanning local midnight, or set the device clock to
    23:58 (Settings → General → Date & Time → disable Set Automatically → set time) before
    starting. Remember to re-enable automatic date/time after.
    Steps: tap record → speak → let the recording run past midnight (real or set clock) →
    speak again after midnight → stop.
    PASS = single continuous recording, no split into two entries, no crash or corruption
    at the day boundary, timestamps/duration are sane.
    FAIL = recording splits, duration math is wrong (e.g. negative or wraps to 0), or app
    crashes at the boundary.
    Cleanup: restore automatic date & time in Settings before continuing other tests.

21. **Very long recording (60+ minutes).**
    Setup: keep the phone plugged in. Allow over an hour of wall-clock time.
    Steps: tap record → speak occasionally throughout → let it run 60+ minutes uninterrupted
    → stop.
    PASS = finalized file plays back full duration (60+ min) with no gaps, segment
    rotation (the ~15–30s on-disk segments) is invisible to the user, finalize to AAC
    completes without excessive delay or crash on a file this size.
    FAIL = app crashes/is killed before you can stop it, memory grows unbounded, playback
    of the finished file is truncated or has gaps at segment boundaries.

22. **Rapid start/stop cycles.**
    Setup: none.
    Steps: tap record → immediately (within 1s) tap stop → repeat this record/stop cycle
    10 times in a row, back to back, with minimal pause between cycles.
    PASS = all 10 recordings are created as separate finalized entries, each playable, no
    crash, no entries merged/dropped, no leftover "stuck recording" state after the last
    cycle.
    FAIL = app crashes, some cycles produce no entry, entries are merged together, or the
    app gets stuck in a non-idle state after the last stop.

## 8. Permissions & recovery

23. **Mic permission revoked mid-app-life via Settings.**
    Setup: app already has mic permission granted; app is currently open and idle (not
    recording).
    Steps: background the app (don't force-quit) → go to Settings → Privacy & Security →
    Microphone → turn the app's mic access off → return to the app → tap record.
    PASS = app detects the revoked permission and shows a clear message / re-prompts,
    rather than silently failing; no crash.
    FAIL = app crashes, hangs, or shows a "recording" UI while capturing nothing/silence
    with no indication of the problem.

24. **Device restart with an interrupted recording pending recovery.**
    Setup: none.
    Steps: tap record → speak for ~30s → force-quit the app (swipe away) → restart the
    phone entirely (hold power + volume to power off, then power back on) → after restart,
    open the app.
    PASS = launch runs the recovery scan and surfaces the interrupted recording (e.g.
    "Recovered recording: 0m3Xs"), file plays back the spoken audio correctly.
    FAIL = no recovery banner, recording is lost, or app crashes on the post-restart
    launch.

## macOS (shorter pass)

Universal app — same capture code path, verify it isn't silently broken on the desktop
target. No lock-screen equivalent; focus is app lifecycle and route changes.

25. **Basic record/stop/playback on Mac.**
    Setup: none.
    Steps: open the Mac app → grant mic permission if prompted → record 15s of speech →
    stop → play back.
    PASS = same as iPhone test 1 — clean recording, correct duration, plays back.
    FAIL = permission prompt missing, recording fails, or playback broken.

26. **App backgrounded (Mission Control / Cmd+Tab away) mid-recording.**
    Setup: none.
    Steps: start recording → Cmd+Tab to another app, or click elsewhere on the desktop →
    leave it backgrounded 30s → switch back → stop.
    PASS = recording continuous, no gap, matches iPhone test 5 expectations.
    FAIL = recording pauses or drops when losing focus.

27. **Quit and relaunch mid-recording (Mac equivalent of force-quit).**
    Setup: none.
    Steps: start recording → speak ~20s → force-quit via Cmd+Option+Esc (Force Quit
    dialog) → relaunch the app.
    PASS = recovery scan on relaunch finds and finalizes the recording, matching iPhone
    test 6.
    FAIL = no recovery, or corrupted/missing file.

28. **Audio device change mid-recording (e.g. built-in mic → USB/Bluetooth mic).**
    Setup: have an alternate input device available (USB mic, AirPods, etc.).
    Steps: start recording on the built-in mic → speak → switch input device in System
    Settings → Sound (or via the menu bar) mid-recording → keep speaking → stop.
    PASS = recording continues across the device switch without crashing; a gap or brief
    interruption at the switch point is acceptable, but no crash and no total data loss —
    audio before and after the switch is both present.
    FAIL = app crashes on device switch, or all audio after the switch is lost.
