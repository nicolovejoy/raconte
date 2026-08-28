# Sync investigation — state at 2026-08-26 pm (paused for a reboot)

Written mid-investigation so the next session starts from evidence, not memory.
Companion evidence: `~/Documents/raconte-evidence/raconte-sync-2026-08-26-2048.logarchive`
(253 MB, copied out of /tmp so a reboot cannot take it). Read it with:

```
/usr/bin/log show --archive ~/Documents/raconte-evidence/raconte-sync-2026-08-26-2048.logarchive \
  --predicate 'processImagePath CONTAINS "Raconte"' --info --debug --style compact
```

Always `/usr/bin/log` — a zsh function in the profile shadows bare `log`.

## SETTLED: the image bug is fixed

The `Image` record type was absent from BOTH CloudKit schemas. Created it by hand in
Development (8 fields, names verified against `SyncRecordBuilders.swift`), deployed to
Production. Photos taken on the iPhone now appear on the laptop — verified end to end by
the owner. No code change was needed; the queued saves flushed themselves.

Three other additive changes rode along in that deploy. We never captured what they were.
`Schema -> History` in the CloudKit Console still has the diff. Worth knowing, because if
one of them was Journal's `span`, then journal edits were ALSO being rejected in Production
and issues #94/#91 may be describing symptoms of this same missing-schema cause.

Rule going forward: any new CK record type or field needs a schema deploy BEFORE the
TestFlight build that writes it.

## OPEN PROBLEM 1: inbound records are being discarded (#85)

The iPhone's own log, two launches spanning 20:48:26-20:51:32 (three minutes), ordinary
TestFlight use, no pathological trigger:

```
25 x sync: fetched AudioAsset record missing its file or sha256 - ignored
20 x sync: fetched Revision record missing body/sha256/entryRef - ignored
 5 x sync: fetched LiveLog record missing its file or sha256 - ignored
```

50 inbound records dropped. CKSyncEngine never redelivers a consumed record, so each one is
permanent loss on that device. Guards: `SyncIngest.swift:1648-1651` (AudioAsset), `:1690`
(LiveLog), `:1748` (Revision).

This CONTRADICTS #85's current body, which says "observed only under a pathological trigger
... this is hardening, not a live data-loss path." Evidence posted as a comment on #85
(issue #85 comment, 2026-08-26). The issue's priority should be re-read in that light.

**Blocking gap:** those log lines carry no record name, so we cannot tell whether launch 2
re-dropped the same records launch 1 dropped (nothing permanently lost yet, repair window
open) or 30 different ones (50 records gone). That single missing identifier is what stopped
this investigation. Fix it first — split the compound guard, log the record name and which
of the three sub-causes fired. Small change, prerequisite for measuring any real fix.

Also unresolved: a genuinely assetless server record and a CKAsset whose download failed
produce the IDENTICAL log line. Those are different bugs with different fixes.

## OPEN PROBLEM 2: pending saves frozen on both devices

iPhone 10, iPad 106. Neither moves. On the iPad the count was unchanged across a full minute
inside one launch, which rules out the "removed then re-enqueued by reconcile" churn theory
(that would dip during a send).

`pendingSaveCount` reads live from `CKSyncEngine.State` (`CloudEngineControl.swift:423-433`),
so it is authoritative, not stale bookkeeping.

**Last finding before the pause — this is the live thread.** CKSyncEngine's own logging
(subsystem `com.apple.cloudkit`, which the archive captures) shows sends ARE being attempted
and ARE failing:

```
20:48:27.339 E  Raconte [com.apple.cloudkit:Engine] failed sending changes for context:
               Error Domain=CKErrorDomain Code=2 UserInfo={CKPartialErrors=<private>}
20:48:27.793 E  Raconte [com.apple.cloudkit:Engine] immediate sync failed with error: ... Code=2
```

Code 2 is `CKErrorPartialFailure`. So the earlier read of "no send is being attempted" was
wrong — sends happen, and the server rejects records within them.

**The inference worth chasing next:** our own `handleFailedSaves` logged NOTHING for these
failures. Walking `SaveFailureDisposition`, the only paths that log nothing are
`.mergeConflict` and a `.recreate` whose `resolveUnknownItem` succeeded. `.recreate` means
`unknownItem` — a record replayed as an UPDATE against a server copy that does not exist.
That is exactly the archived-dev-era-system-fields failure mode (#90, and the
`cloudkit-stale-metadata-across-environments` memory): resend, fail, resend, forever, with a
constant pending count. It fits every observation. It is NOT yet confirmed.

**To confirm:** `CKPartialErrors` is redacted as `<private>`. Getting the per-record errors
requires installing Apple's CloudKit logging configuration profile on the device to
unredact, or adding our own log line in `handleFailedSaves` for the `.mergeConflict` and
`.recreate` paths (which are currently the only silent ones) and shipping a build.

## Suggested next actions

1. Add record names + sub-cause to the three `SyncIngest` ingest-drop log lines (#85).
2. Add a log line to the two silent `handleFailedSaves` paths. Together with 1, one
   TestFlight build makes both open problems diagnosable instead of guessable.
3. Capture `Schema -> History` from the Console for the three unidentified deployed changes.
4. Re-read #94 and #91 against all of the above — they may be symptoms, not causes.

## Untouched session goals

- #89 (About page) is shipped, device-verified, and is what diagnosed the image bug. It is a
  single-ask issue, not a consolidated one. Ready to close; the owner had not answered yet.
- #101 entry paging is fully planned and still waiting for a Sonnet session to execute
  `docs/plans/2026-08-26-101-entry-paging-plan.md` via SDD.
- #86 looks like the parent of #101 and may want closing as superseded.

## RESOLVED 2026-08-27: both open problems are one bug — root cause found via build 9

Build 9 (named drop lines + disposition logging, `IngestDropReason`) made the loop
legible in one capture (`~/Documents/raconte-evidence/raconte-sync-2026-08-27-build9-take2.logarchive`):
exactly 10 distinct records — 5 AudioAsset, 4 Revision, 1 LiveLog, matching the iPhone's
frozen "Pending saves 10" by name — each cycling `save rejected — serverRecordChanged`
paired with `dropped — asset has no fileURL — asset download failed`, three rounds in
one session.

The loop: reconcile enqueues records the server already has → every push is rejected
`serverRecordChanged` (NOT `unknownItem` — the `.recreate` theory above is refuted) →
`.mergeConflict` runs the server copy through `acceptRemote`, which archives the
server's change tag and then drops the copy (a push-error `serverRecord` never has its
assets downloaded, so `fileURL` is nil) → the defect: `audioRecord`/`liveLogRecord`/
`revisionRecord`/`imageRecord` take no `base:` (unlike journal/entry/markerStream), so
`recordToPush` mints a fresh record with no system fields and the archived tag is never
used → next push is another "create" of an existing record, rejected identically,
forever.

Reframes:
- **No data loss.** The "50/80 inbound records discarded" were the same ~10 records'
  asset-less conflict copies, dropped once per send round. The content is local — this
  device is the pusher. #85's severity drops back to its original assessment.
- The iPad's 106 pending is almost certainly the same loop, bigger stuck set.

Fix (agreed direction, next session, ship as build 10): **short-circuit** — on
`serverRecordChanged` for a write-once type, compare local sha256 to the server copy's
`sha256` field (present without asset download); match → write the upload ledger, remove
the pending save, done; mismatch → log loudly (a real conflict write-once records must
not have). Base-threading through the four child builders remains the fallback if some
record ever legitimately needs a re-push.

**Implemented, `fix/sync-write-once-conflict`, build 10.** Settle rule: sha256 match →
ledger credited with the local digest, pending save retired, no re-upload. Divergent
rule: loud error logged, pending save retired without a ledger entry so reconcile
resurfaces the record every launch rather than looping silently. Device verification
(iPhone 10→0, iPad 106→0 pending saves) still pending — TestFlight build 10.
