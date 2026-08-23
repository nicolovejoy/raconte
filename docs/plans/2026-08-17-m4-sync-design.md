# M4 — device sync via CloudKit (design, 2026-08-17)

Owner-approved design for syncing the archive across devices (phone, mini, laptop).
Sections 1–3 were approved live in conversation; sections 4–6 follow directly from
prior rulings and the persistence inventory. Supersedes the CloudKit sketch in
`2026-07-29-data-model-and-migration.md` §2 (written against a GRDB schema that was
never built — the real store is file-based); carries its semantic rulings forward.
The T6 design's §9 (sync tensions + sizing) is incorporated and its open item 7
(cascade delete vs quarantine) is resolved here (§5).

## 0. Goal, acceptance, owner rulings

**Goal (owner, 2026-08-16): full replica + restore.** Every device holds everything,
audio included. Acceptance test: delete the app from a device, reinstall, and the
full archive reconstructs from iCloud. Freshness: eventual (minutes) is fine; audio
rides any network, cellular included.

Owner rulings from this design pass:

1. **Conflicts on `entry.json`: last-writer-wins per field** — a backdate set on the
   phone and a journal move on the Mac both survive.
2. **Approach A — record-per-artifact** (vs. entry-bundle records; iCloud Drive
   container sync rejected: no conflict control, and file eviction is exactly the
   damage `head.json`'s `sizesStillMatch` check exists to catch).
3. **Pause/edit-then-continue (2026-08-17):** #26 pause (one m4a, interruption
   machinery) is wanted and is independent of M4. Editing stays strictly
   post-capture. Cross-device mid-capture sync is ruled out: **entries sync only
   once finalized.** The record model keeps the multi-recording door open
   structurally (AudioAsset is its own record, 1..n capable) but nothing multi-
   recording is built.

## 1. What syncs, what doesn't

From the persistence inventory (every claim verified against code 2026-08-16):

Syncs — human-authored or irreplaceable:
- `final/recording.m4a` — write-once, ~600 KB/min (AAC-LC 80 kbps mono).
- `entry.json` — journalID, originalDate, trashedAt, multiVoice, detection fields.
- `transcript/canonical-<n>.json` — create-once revisions; ~725 KB per 30-min
  revision, ~1.4 MB/hour → **bodies must travel as CKAssets** (T6 §9 math).
- `transcript/markers.jsonl` — capture taps + Mark-voices corrections.
- `transcript/live.jsonl` — write-once at promotion; the machine's raw hearing
  (run-level confidences don't survive into spans; T8's diff source). Restore
  without it would be quietly lossy.
- `manifest.json` — as a verbatim snapshot at finalize (historical facts:
  interruption log, verified-at, transcript coverage — not re-derivable).
- `journals.json` — names + voice labels exist nowhere else.
- `journals/<id>/cover.jpg` — not derivable locally.

Never syncs — each per an existing code/doc ruling:
- `transcript/head.json` (documented disposable cache; rebuilt locally),
- `transcript/draft.json` (device-local editor buffer),
- `entry-log.jsonl` (explicitly local-only forensic; gains `.sync`-cause rows when
  sync edits metadata — the enum case already exists in `EntryLog.swift:23`),
- `segments/`, `*.part`, `trash-pending/`, DEBUG `analysis-input.wav`,
- UserDefaults `currentJournalID` and `raconte.deviceID` (both documented
  per-device; `CurrentJournal`'s comments already anticipate sync).

Free ride: the per-journal "Two voices" carry-over is derived from the journal's
latest entry's `entry.json`, so it syncs as a side effect — intended per the
comment at `EntryMetadata.swift:89-97`.

## 2. Record schema

One custom zone `RaconteZone`, private database, container
`iCloud.org.pianohouseproject.raconte`. Children reference their Entry with
`.deleteSelf` action so a purge cascades server-side.

```
Journal            recordName = journal ULID          mutable
  name             String        LWW per field
  createdAt        Date
  voiceLabels      String (JSON) LWW per field
  cover            CKAsset       LWW (replaced on new pick)

Entry              recordName = capture ULID          mutable
  journalID        String?       LWW per field   (plain id, not a CKReference —
  originalDate     String?       LWW per field    a dangling id degrades safely,
  trashedAt        Date?         LWW per field    same as CurrentJournal today)
  multiVoice       Bool          LWW per field
  detectedDate     String?       write-once (origin device only)
  detectionRan     Bool          write-once latch
  manifestSnapshot String (JSON) the finalized manifest, verbatim
  capturedAt       Date          ordering without downloading children

AudioAsset         recordName = <captureID>.a0        immutable, write-once
  file             CKAsset       recording.m4a
  sha256, bytes, frameCount, sampleRate      (verify-on-ingest)

Revision           recordName = revision ULID (its id, NEVER the file number)
  body             CKAsset       the canonical-N.json bytes, verbatim
  sha256, bytes                              immutable, write-once

LiveLog            recordName = <captureID>.live      immutable, write-once
  file             CKAsset       live.jsonl at promotion time

MarkerStream       recordName = m.<captureID>.<deviceID>
  content          String        that device's marker lines (JSONL);
                                 single-writer by construction → grows
                                 monotonically; whole-field replace is safe
```

Load-bearing choices:

1. **Revision identity is the ULID, never the file number** (T6 §9 ruling). Ingest
   writes a synced-in revision at the receiving device's next free `canonical-N`
   slot via `createExclusively`, bytes unchanged. File numberings may differ across
   devices forever; the chain doesn't care — parents are named by id.
2. **Revision bodies as verbatim assets.** §9's two format economies (~20% smaller)
   are an independent on-disk-format optimization, not a sync blocker; sync
   benefits automatically if they ship.
3. **`manifestSnapshot`** exists because a receiving device must materialize a
   `manifest.json` the recovery scanner reads as *settled*, and the manifest holds
   history nothing can re-derive. Uploaded at finalize (after `recordTranscriptRef`);
   rare post-capture rewrites re-upload whole-field LWW.
4. **Marker records gain one additive field `at` (ISO timestamp).** "Later seq
   wins" is single-writer; cross-device corrections order by `at`, tie-broken by
   deviceID. `retractsSeq` stays scoped to its own stream. Old builds' decoders
   ignore unknown keys — backward compatible.
5. **Per-field LWW stamps live in `entry.json`** under an additive `modified` map
   (field → ISO timestamp), written by `EntryMetadataStore.update` at the moment of
   change. An untouched entry still encodes as `{}`. `journals.json` grows the same
   additive per-journal `modified` map.
6. **Entries sync only once finalized** (m4a verified, promotion attempted).
   In-flight/interrupted captures are device-local until recovered.

## 3. Change tracking + engine wiring

A new **`SyncCoordinator` actor owns a `CKSyncEngine`**. The engine owns cursors,
tokens, retry/backoff, and the zone subscription — we never hand-roll change
tokens. Repo idiom holds: decision logic in a pure testable core (`SyncPlan`:
file-tree state + bookkeeping → record operations); the actor is the thin IO shell.

**All bookkeeping lives in `<App Support>/Raconte/sync/`** — a sibling of
`captures/`. Contents: engine state serialization, archived CKRecord system fields
per record, and an uploaded-ledger (record id → sha256/bytes last uploaded). The
whole directory is disposable cache. **Nothing sync-related is ever written inside
a capture directory** — any file under `transcript/` flips
`holdsIrreplaceableArtifacts` and makes a mis-tap undeletable
(`DirectorySnapshot.swift:90-93`).

**Local changes reach the engine via hooks at the six existing write chokepoints**
(all already actor-funneled):
- `EntryMetadataStore.update` → enqueue Entry
- `TranscriptRevisionStore.append` → enqueue Revision (fires once per revision)
- `MarkerLogWriter` / `MarkerCorrectionWriter` append → enqueue own MarkerStream
- `JournalStore` save → enqueue Journal
- `JournalCoverStore.write/delete` → enqueue Journal (cover field)
- finalize completion (m4a verified + promotion) → enqueue Entry + AudioAsset + LiveLog

**Belt and braces: a launch reconciliation scan** — walk the tree, compare against
the uploaded-ledger, enqueue anything a crash dropped between "file written" and
"change enqueued". This is also the initial upload path: on first enable the
ledger is empty, so the scan enqueues the whole existing archive.

Sync triggers: engine-scheduled after local enqueues; fetch on launch, foreground,
and silent push.

## 4. Conflict mechanics

- **Immutables can't conflict.** AudioAsset / Revision / LiveLog are create-once
  with content-derived identity; ingest verifies sha256 regardless.
- **Concurrent transcript edits need no merge — the chain is the resolution.**
  Two offline edits mint two revisions sharing a parent; after sync both exist
  everywhere; "current" is computed (newest human revision) so every device agrees;
  the other edit is visible in history as a fork, one revert away. CloudKit never
  sees a conflict because nothing was mutated.
- **Entry/Journal fields: per-field LWW on `modified` stamps.** Push conflict:
  merge server record field-by-field (newer stamp wins), resave. Fetched remote
  change: merge into `entry.json` by the same rule, **written through
  `EntryMetadataStore.update`** (keeps the resurrect-staged-capture guard and the
  `.sync` audit cause), and through `JournalStore` for journals. Stamps are wall
  clocks; same-field edits within clock skew resolve arbitrarily but
  deterministically (tie-break deviceID) — acceptable for a single user, and the
  entry-log records what happened.
- **Marker streams: structurally conflict-free** (one writer per record). All
  merging is read-side and deterministic: union all streams; corrections ordered
  by `at`, tie-break deviceID; later wins at the same boundary; `retractsSeq`
  resolves within its own stream only.
- **Trash vs. restore = `trashedAt` field LWW.**

## 5. Trash, purge, deletes (resolves T6 §9 item 7)

- **Soft trash is a synced field**, never a CloudKit delete (2026-07-29 ruling).
- **Permanent deletion (30-day sweep or Delete Now):** locally exactly as today
  (`TrashSweeper` → `StagedRemover.stage` one-way rename → purge), plus enqueue a
  CKRecord delete of the Entry; children cascade via `.deleteSelf` references.
- **A sync-in delete (`deletedRecordZoneChanges` for an Entry) routes through
  `StagedRemover.stage` + purge — never `RecoveryExecutor`, never raw
  `removeItem`.** The staged rename is the app's one-way door and is atomic;
  recovery's delete path is forbidden because quarantine semantics
  (`holdsIrreplaceableArtifacts`) would refuse or, worse, be bypassed.
- Both devices sweeping independently at ~30 days is fine: CK-deleting an absent
  record and staging an absent directory are both no-ops.
- Edge: a delete arrives while local unsynced work exists for that entry (e.g. an
  offline-minted revision). Rule: **the delete wins** — the entry sat in trash 30
  days and trashed entries refuse edits anyway; pending uploads for a deleted
  entry are dropped from the queue.
- Journals have no delete (deliberate, `JournalStore.swift:77-78`) — no journal
  tombstones needed.

## 6. Ingest on a receiving device

- **New entries: assemble-then-commit.** Materialize the complete capture
  directory under `sync/staging/<captureID>/` (manifest.json from
  `manifestSnapshot`, entry.json, `final/recording.m4a`, transcript files), verify
  every sha256, then `rename(2)` into `captures/<captureID>/`. The recovery
  scanner and library only ever see complete directories — mirrors the `.part` →
  rename convention. Minimum commit set: manifest + entry.json + m4a; transcript
  artifacts may land in the same assembly when already fetched.
- **Incremental updates to existing entries** go through the stores' own
  primitives, never raw file writes (standing branch rule): Entry field merges via
  `EntryMetadataStore`, revisions via a `TranscriptRevisionStore` ingest API that
  allocates the next free local `n` (`createExclusively`, `.allocationCollision`
  retry as shipped), foreign marker streams materialized as
  `markers-<deviceID>.jsonl` beside `markers.jsonl`, journals merged by id via
  `JournalStore`, covers via `JournalCoverStore`.
- **`head.json` is rebuilt locally** after revision ingest (the existing
  `persistHead` path; its `fileSizes` integrity check already anticipates cloud
  damage).
- Read-side changes: the marker read path merges multiple streams (§4);
  attribution and rendering are downstream of that merge and unchanged otherwise.

## 7. Format changes (all additive, old builds unaffected)

1. `StructureMarker` gains optional `at` (ISO timestamp), stamped on every new
   append (capture taps and corrections). Old records without `at` sort before
   stamped ones within their stream; single-stream entries behave exactly as today.
2. `EntryMetadata` gains optional `modified: [String: Date]` (field → last-set
   stamp), written on every `update`. Absent for untouched entries (`{}` preserved).
3. `JournalRegistry` entries gain the same optional `modified` map.
4. New sibling files `transcript/markers-<deviceID>.jsonl` (foreign streams,
   written only by ingest). NOTE: these live under `transcript/` deliberately —
   they are precious voice attribution and *should* trip
   `holdsIrreplaceableArtifacts`.

## 8. Entitlements, environments, rollout

Entitlements/project.yml additions (currently zero iCloud footprint):
`com.apple.developer.icloud-container-identifiers` =
[`iCloud.org.pianohouseproject.raconte`] (container already reserved),
`com.apple.developer.icloud-services` = [CloudKit], `aps-environment`, and
`remote-notification` in `UIBackgroundModes` (iOS). macOS sandbox keeps existing
entitlements and adds the same iCloud keys + network client if not present.

CloudKit **development environment** first; record types materialize from first
writes; deploy schema to production before any TestFlight build.

Sync is enabled whenever an iCloud account is available; never blocks or delays
capture (capture writes never wait on sync). Account missing / quota exceeded /
network errors surface on the Debug screen first (status line: last push, last
fetch, pending counts, last error); user-facing surfacing is a later polish pass.

Build order (each phase independently smokeable; the mini — empty by design — is
the receiving smoke device):
1. Entitlements + `sync/` bookkeeping + `SyncCoordinator`/engine skeleton +
   **Journal sync** end-to-end (smallest real proof: rename a journal on the
   phone, see it on the mini).
2. **Entry + finalize artifacts** (Entry record, AudioAsset, LiveLog,
   manifestSnapshot; assemble-then-commit ingest). Mini starts receiving entries.
3. **Revisions + marker streams** (+ `at` stamps, `modified` stamps, multi-stream
   read merge, head rebuild).
4. **Trash/purge + delete ingest** (staged-removal routing).
5. **Acceptance:** delete the app from the mini, reinstall, archive reconstructs.

## 9. Explicitly not building (M4)

- Sync of in-flight captures, cross-device mid-capture anything.
- Shared/public databases, sharing UI, multi-user anything.
- Selective sync / audio-on-Wi-Fi-only policies (owner ruled any-network).
- Conflict UI (per-field LWW + the chain's fork visibility cover it).
- Migration of the 36 frozen recountly.org entries (M5, after sync verifies).
- The §9 revision-format economies (independent optimization).

## 10. As-built deviations (M4 T12, 2026-08-22)

Rulings and implementation drifted from this design in five ways over Tasks 1–12.
None change the model above; recorded here so the doc stays trustworthy.

1. **The Revision record carries an `entryRef` field.** §2's schema table has no
   captureID column for `Revision` — the record's own name (`recordName = revision
   ULID`) carries only the revision's id, never the capture it belongs to. `entryRef`
   (the same shared cascade field every child record carries, `.deleteSelf`) does
   double duty here: it is both the delete cascade AND the only way ingest recovers
   which capture a fetched Revision record belongs to.
2. **The MarkerStream record name on the wire is `m.<captureID>.<deviceID>`**, not
   `<captureID>.m.<deviceID>` as originally written above in §2 (now corrected in
   place) — pre-existing doc drift from `SyncRecordName.swift`'s actual encoding,
   caught and fixed on this touch.
3. **Inbound ingest is land-or-park, never refuse-and-return.** `CKSyncEngine` never
   redelivers a record it has already handed to this device, so any ingest path that
   declines an inbound record and simply returns loses it permanently. Two concrete
   consequences beyond what §6 describes:
   - A new entry's pieces (manifest, `entry.json`, the m4a, transcript artifacts) are
     staged durably under `sync/staging/<captureID>/` with a `pending.json` sidecar
     the instant each piece decodes, sha-verified at arrival — not held only in
     memory. A launch boundary crossing mid-assembly cannot lose them.
   - A revision or marker stream arriving for a capture that is currently trashed
     locally cannot be ingested (the store refuses writes to a trashed capture), so
     it parks instead, in `sync/staging/<captureID>/pending-revisions.json` (and the
     marker-stream equivalent) rather than being dropped.
   - Rehydration runs at every launch (`SyncCoordinator.live`, after the stores are
     attached) and resolves each parked item: **restored → ingest** it now,
     **still trashed → stay parked**, **purged → discard** (this last case is §5's
     "the delete wins" applied to inbound work that arrived too late to matter).
4. **Fetch-on-launch and fetch-on-foreground are the coordinator's own responsibility**
   (§3's stated trigger list), wired in Task 12: `SyncCoordinator.launch()` ends with
   a fetch kick, and `foregrounded()` (called from `RaconteApp`'s `scenePhase`
   watcher) covers the scene returning to `.active`. No task before T12 owned this
   wiring, so it had silently dropped out of the plan text despite being mandated
   here; only silent push remains unbuilt (no APNs receipt path exists in this app).
5. **Entry deletion has no corrective re-push; that exists for journals only** (#80,
   owner ruling) — an entry that reaches the server as deleted stays deleted, with no
   retry path if the delete itself fails to land. **Trashing an entry is NOT a
   deletion for push purposes**: `trashedAt` is an ordinary per-field LWW-merged
   value on `entry.json` like any other metadata field, so a trashed entry keeps
   pushing normally (including the trash flag) — only a PERMANENT delete (30-day
   sweep or Delete Now) routes through the no-corrective-re-push CK-delete path §5
   describes.
