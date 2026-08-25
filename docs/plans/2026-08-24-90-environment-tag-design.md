# #90: Tag sync bookkeeping with the CloudKit environment; wipe on mismatch

2026-08-24. Design for issue #90. Companion evidence: build-4 smoke (devlog
2026-08-24) proved the phone's captures are fully healed on disk — the ~20 dev-era
entries stay off the iPad only because `ledger.json` says "uploaded" about pushes
that went to the **Development** CloudKit environment. Production never saw them,
and `SyncPlanner.reconcile` (ledger == scan → enqueue nothing) never retries.

## Problem

`sync/` bookkeeping (engine state, per-record system fields, upload ledger) carries
no record of which CloudKit environment wrote it. Crossing environments (dev-signed
build → TestFlight) leaves two failure shapes:

1. Archived system fields from dev replayed against prod → push as UPDATE against a
   record ID prod never held → `unknownItem`. The #94 self-heal recovers this — but
   only for records that get *enqueued*.
2. Ledger entries from dev claiming "uploaded" → reconcile never enqueues → the
   record never pushes, never fails, never heals. **This is the stranded-archive
   case, and no existing mechanism touches it.**

## Design

### 1. Environment detection (`CloudKitEnvironmentDetector`)

New file `Raconte/Sync/CloudKitEnvironment.swift`.

```swift
enum CloudKitEnvironment: String, Sendable { case development, production }
```

Detection reads the `com.apple.developer.icloud-container-environment` entitlement,
which Xcode injects at signing/export time (it is absent from the source
entitlements). The running binary's value is not directly readable on iOS
(`SecTaskCopyValueForEntitlement` is SPI there), so:

- **Both platforms:** parse the embedded provisioning profile —
  `embedded.mobileprovision` (iOS) / `Contents/embedded.provisionprofile` (macOS)
  in the app bundle. The profile is a CMS blob wrapping a plaintext XML plist:
  scan the raw bytes for the `<plist` … `</plist>` range, decode with
  `PropertyListSerialization`, read `Entitlements` →
  `com.apple.developer.icloud-container-environment` ("Development"/"Production").
- **No profile or no key → `.production`.** App Store installs strip the embedded
  profile, and App Store is production. macOS dev builds carry
  `embedded.provisionprofile` with the key = Development.
- **Pure core:** `CloudKitEnvironment.parse(profileData:)` is a pure function over
  `Data`, unit-tested against fixture plists (dev-tagged, prod-tagged, key absent,
  not-a-plist). The bundle lookup is the thin shell, per repo idiom.

Known imprecision, accepted: a manually-run simulator build has no embedded profile
and detects `.production` while actually talking to Development. Simulator runs
that sync at all are already rare (test/preview/UITest runners are gated out in
`shouldSync`), and the cost of a wrong tag is a bookkeeping wipe — a resync, never
data loss. Documented at the detection site.

### 2. Tag storage (`SyncBookkeepingStore`)

New file `sync/environment` (raw string `development` / `production`). Store gains
`environmentTag() -> CloudKitEnvironment?` (nil = absent/unreadable, per the
store's governing collapse rule) and `saveEnvironmentTag(_)`. `wipe()` is
untouched — it removes the whole `sync/` root, tag included.

### 3. Gate (pure decision + wiring in `SyncCoordinator.launch()`)

Pure table, `EnvironmentGateDecision.decide(tag:detected:bookkeepingExists:)`:

| tag on disk | bookkeeping exists | decision |
| --- | --- | --- |
| == detected | any | proceed |
| nil | no (fresh install) | write tag, proceed |
| nil | yes (pre-tag upgrade) | **wipe, write tag** ← the migration that frees the 20 |
| != detected | any | **wipe, write tag** |

"Bookkeeping exists" = the `sync/` root exists on disk (store gains a cheap
`hasBookkeeping()`).

Wired at the top of `SyncCoordinator.launch()`, before `bookkeeping.engineState()`
is read — the engine must never resume from a state blob the gate is about to
delete. `SyncCoordinator.init` takes the detected environment as a value
(defaulted parameter; `live()` passes the real detection), keeping the coordinator
testable with both environments.

Log lines (the #89 lesson — this event must be visible in a device log):

- `sync: environment tag <old|absent> vs <detected> — bookkeeping wiped, full resync`
- `sync: environment tag written (<value>)` on first write.

### 4. Why the wipe is safe (all pre-existing machinery)

- **Outbound, records prod already has** (post-heal pushes): empty ledger →
  reconcile enqueues everything; no system fields → push is a CREATE →
  `.serverRecordChanged` → `SaveFailureDisposition.mergeConflict` → per-field LWW
  merge → re-push as UPDATE. No clobber: merge wins are per-field, by timestamp.
- **Outbound, records prod lacks** (the stranded 20): CREATE succeeds. Done.
- **Inbound:** wiping `engine-state.bin` drops the change token → full refetch.
  Ingest is land-or-park and idempotent (digest checks), so redelivered records
  settle. `sync/staging/` and parked inbound records live under `sync/` and are
  wiped too — safe *because* the same wipe forces the full refetch that
  redelivers them.
- The directory's own doc comment already declares all of it disposable cache;
  this design adds the trigger, not the semantics.

Cost of a wipe: one full resync (re-upload dedupe is content-addressed server-side
only via conflict merge; bytes re-transfer). Acceptable at this archive's size,
and it fires only on environment crossings — for the owner, essentially once.

### 5. Testing

- Parser fixtures (4 cases above) — pure, no bundle.
- Gate decision table — all 6 cells (2 environments × {match, nil+empty,
  nil+existing, mismatch}).
- Store round-trip: save/read tag; unreadable file → nil; wipe removes tag.
- Coordinator integration: temp-root store seeded with a ledger + old tag, fake
  engine; `launch()` with a different detected environment must wipe before
  `engine.start` receives state (assert `start(stateData: nil)` and empty ledger
  after). Mismatch-free launch must not wipe (ledger survives).
- Adversarial guard (the vacuous-fixture lesson): the integration fixture's ledger
  must be non-empty and asserted-on both before and after.

### 6. Out of scope

- #91 (reconcile-latency mid-session) — untouched.
- The `#if DEBUG` Debug-screen manual wipe (#89) stays as-is.
- No UI. The wipe is silent except for log lines; a future About/sync-status
  screen (#89) can surface "last full resync".
