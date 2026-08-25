# #90 Environment-Tag Sync Bookkeeping Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tag `sync/` bookkeeping with the CloudKit environment that wrote it and wipe it wholesale on mismatch (or on pre-tag upgrade), so dev-era ledger/system-fields state can never suppress pushes to production.

**Architecture:** Three pure cores (profile-plist parser, gate decision table, tag file round-trip) plus one wiring site: the top of `SyncCoordinator.launch()`, before the engine resumes from `engine-state.bin`. Detection reads the embedded provisioning profile (absent ⇒ production).

**Tech Stack:** Swift 6 strict concurrency, XCTest, no new dependencies.

**Spec:** `docs/plans/2026-08-24-90-environment-tag-design.md` — read it first; the safety argument (why a wipe cannot lose data) lives there.

## Global Constraints

- Unit test command (macOS, sandbox REQUIRED — never `CODE_SIGNING_ALLOWED=NO`):
  `xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS=Raconte/Raconte-nocloud.entitlements test`
  Append `-only-testing:RaconteTests/<ClassName>` for the per-task cycle; the full suite runs in Task 4.
- **After creating any new FILE, run `xcodegen generate` before building** — a stale generated project silently drops new files (bit us on PR #97).
- Swift 6 strict concurrency: new types are `Sendable`; `SyncBookkeepingStore` is an actor — new members follow its existing isolation.
- Comments: plain and terse, matching each file's existing density. Log lines use the existing `Logger(subsystem: "org.pianohouseproject.raconte", category: "sync")` style with `privacy: .public` for enum raw values.
- Commit after each task with the repo's existing `feat:`/`chore:` style.

---

### Task 1: `CloudKitEnvironment` — value + profile parser + bundle detection

**Files:**
- Create: `Raconte/Sync/CloudKitEnvironment.swift`
- Test: `RaconteTests/CloudKitEnvironmentTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `enum CloudKitEnvironment: String, Sendable, Equatable { case development, production }` with `static func parse(profileData: Data) -> CloudKitEnvironment?` and `static func detectFromBundle(_ bundle: Bundle = .main) -> CloudKitEnvironment`. Tasks 2–4 use the enum; Task 4's `live()` calls `detectFromBundle()`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Raconte

/// #90: the pure parser over embedded-provisioning-profile bytes. The profile is a
/// CMS blob wrapping a plaintext XML plist; fixtures reproduce that shape as
/// junk + plist + junk, because the parser must find the plist range itself.
final class CloudKitEnvironmentTests: XCTestCase {

    private func profileFixture(entitlements: String) -> Data {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict>
            <key>Name</key><string>raconte appstore</string>
            <key>Entitlements</key>
            <dict>
        \(entitlements)
                <key>com.apple.developer.icloud-container-identifiers</key>
                <array><string>iCloud.org.pianohouseproject.raconte</string></array>
            </dict>
        </dict>
        </plist>
        """
        var data = Data([0x30, 0x82, 0x1a, 0x2b, 0x06, 0x09])  // CMS-ish leading junk
        data.append(Data(plist.utf8))
        data.append(Data([0x00, 0xff, 0x30, 0x82]))            // trailing signature junk
        return data
    }

    func testParsesDevelopmentTag() {
        let data = profileFixture(entitlements: """
                <key>com.apple.developer.icloud-container-environment</key>
                <string>Development</string>
        """)
        XCTAssertEqual(CloudKitEnvironment.parse(profileData: data), .development)
    }

    func testParsesProductionTag() {
        let data = profileFixture(entitlements: """
                <key>com.apple.developer.icloud-container-environment</key>
                <string>Production</string>
        """)
        XCTAssertEqual(CloudKitEnvironment.parse(profileData: data), .production)
    }

    func testMissingKeyParsesNil() {
        XCTAssertNil(CloudKitEnvironment.parse(profileData: profileFixture(entitlements: "")))
    }

    func testGarbageParsesNil() {
        XCTAssertNil(CloudKitEnvironment.parse(profileData: Data([0x00, 0x01, 0x02])))
        XCTAssertNil(CloudKitEnvironment.parse(profileData: Data("<plist".utf8)))  // start, no end
    }

    /// The App Store case: no embedded profile in the bundle at all ⇒ production.
    /// The unit-test bundle has no embedded.provisionprofile, so it IS that case.
    func testDetectWithoutProfileDefaultsToProduction() {
        XCTAssertEqual(CloudKitEnvironment.detectFromBundle(Bundle(for: Self.self)), .production)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodegen generate` first (new test file!), then the Global Constraints test command with `-only-testing:RaconteTests/CloudKitEnvironmentTests`.
Expected: BUILD FAILURE — `CloudKitEnvironment` unresolved.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// #90: which CloudKit environment this binary talks to, and where that answer
/// comes from. Design: docs/plans/2026-08-24-90-environment-tag-design.md.
///
/// The `com.apple.developer.icloud-container-environment` entitlement is injected
/// at signing/export time (it is absent from the source entitlements), and iOS
/// offers no public API to read the running signature — so detection parses the
/// embedded provisioning profile instead. No profile, or no key, means production:
/// App Store installs strip the embedded profile, and App Store is production.
///
/// Known imprecision, accepted: a manually-run simulator build has no embedded
/// profile and detects `.production` while actually talking to Development. Sync
/// in a simulator is already gated to rare manual runs (`shouldSync` excludes the
/// test/preview runners), and a wrong tag costs one bookkeeping wipe — a resync,
/// never data.
enum CloudKitEnvironment: String, Sendable, Equatable {
    case development
    case production

    /// Pure core: extract the environment from raw provisioning-profile bytes.
    /// The profile is a CMS blob wrapping a plaintext XML plist; the plist range
    /// is found by byte scan, then decoded. Any structural surprise is nil —
    /// callers decide the default.
    static func parse(profileData: Data) -> CloudKitEnvironment? {
        guard let start = profileData.range(of: Data("<plist".utf8)),
              let end = profileData.range(of: Data("</plist>".utf8),
                                          in: start.upperBound..<profileData.endIndex)
        else { return nil }
        let plistData = profileData.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData,
                                                                      format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let raw = entitlements["com.apple.developer.icloud-container-environment"] as? String
        else { return nil }
        return CloudKitEnvironment(rawValue: raw.lowercased())
    }

    /// Thin shell: find the embedded profile in `bundle` and parse it.
    /// iOS: `embedded.mobileprovision` at the bundle root. macOS:
    /// `Contents/embedded.provisionprofile`. Absent or unparseable ⇒ `.production`.
    static func detectFromBundle(_ bundle: Bundle = .main) -> CloudKitEnvironment {
        #if os(macOS)
        let url = bundle.bundleURL.appendingPathComponent("Contents/embedded.provisionprofile")
        #else
        let url = bundle.bundleURL.appendingPathComponent("embedded.mobileprovision")
        #endif
        guard let data = try? Data(contentsOf: url),
              let parsed = parse(profileData: data) else { return .production }
        return parsed
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Same command. Expected: 5/5 PASS.

- [ ] **Step 5: Commit**

```bash
git add Raconte/Sync/CloudKitEnvironment.swift RaconteTests/CloudKitEnvironmentTests.swift
git commit -m "feat(sync): CloudKitEnvironment detection from the embedded provisioning profile (#90)"
```

---

### Task 2: Tag storage on `SyncBookkeepingStore`

**Files:**
- Modify: `Raconte/Sync/SyncBookkeeping.swift` (add after the "Upload ledger" section, before "Wipe")
- Test: `RaconteTests/SyncBookkeepingTests.swift` (append to the existing class)

**Interfaces:**
- Consumes: `CloudKitEnvironment` (Task 1).
- Produces: on the actor — `func environmentTag() -> CloudKitEnvironment?`, `func saveEnvironmentTag(_ environment: CloudKitEnvironment) throws`, `func hasBookkeeping() -> Bool`; pure seam `static func environmentTagURL(root: URL) -> URL`. Task 4 calls all three actor methods.

- [ ] **Step 1: Write the failing tests** (append inside the existing `SyncBookkeepingTests` class; reuse its existing temp-root `store` fixture — read the file's `setUp` first and match it)

```swift
    // MARK: #90 environment tag

    func testEnvironmentTagRoundTrips() async throws {
        let store = makeStore()  // match the file's existing fixture helper/property
        let initial = await store.environmentTag()
        XCTAssertNil(initial)
        try await store.saveEnvironmentTag(.development)
        let read = await store.environmentTag()
        XCTAssertEqual(read, .development)
    }

    func testUnreadableTagIsNil() async throws {
        let store = makeStore()
        try Data([0xff, 0xfe]).write(to: SyncBookkeepingStore.environmentTagURL(root: store.root))
        let read = await store.environmentTag()
        XCTAssertNil(read)
    }

    func testWipeRemovesTag() async throws {
        let store = makeStore()
        try await store.saveEnvironmentTag(.production)
        try await store.wipe()
        let read = await store.environmentTag()
        XCTAssertNil(read)
    }

    func testHasBookkeepingTracksRootExistence() async throws {
        let store = makeStore()
        let before = await store.hasBookkeeping()
        XCTAssertFalse(before)
        try await store.recordUpload(UploadedDigest(sha256: "aa", bytes: 1), for: "e.X")
        let after = await store.hasBookkeeping()
        XCTAssertTrue(after)
    }
```

Note for the implementer: `testUnreadableTagIsNil` needs the tag's parent directory to exist before the raw write — create it with `FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)` first. If the class's fixture already creates the root, `testHasBookkeepingTracksRootExistence`'s `before` assertion must instead delete the root first — adapt to the file's actual `setUp`, keeping the assertion pair (false before anything is written / true after).

- [ ] **Step 2: Run to verify failure**

`-only-testing:RaconteTests/SyncBookkeepingTests`. Expected: BUILD FAILURE — `environmentTag` unresolved.

- [ ] **Step 3: Implement** (in `SyncBookkeepingStore`; filename constant beside the existing three)

```swift
    private static let environmentTagFileName = "environment"
```

```swift
    // MARK: Environment tag (#90)

    /// Which CloudKit environment wrote this bookkeeping directory. Absent and
    /// unreadable both answer nil, per the type's governing collapse rule — the
    /// gate treats nil as "unknown provenance" and wipes if anything else exists.
    func environmentTag() -> CloudKitEnvironment? {
        guard let data = Self.read(url: Self.environmentTagURL(root: root)),
              let raw = String(data: data, encoding: .utf8) else { return nil }
        return CloudKitEnvironment(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func saveEnvironmentTag(_ environment: CloudKitEnvironment) throws {
        try Self.write(Data(environment.rawValue.utf8), url: Self.environmentTagURL(root: root))
    }

    /// Whether any bookkeeping exists on disk at all — the gate's "is there
    /// anything a stale environment could poison" question.
    func hasBookkeeping() -> Bool {
        FileManager.default.fileExists(atPath: root.path)
    }
```

And beside the other pure seams:

```swift
    static func environmentTagURL(root: URL) -> URL {
        root.appendingPathComponent(environmentTagFileName)
    }
```

- [ ] **Step 4: Run to verify pass** — same command, all green including the pre-existing class members.

- [ ] **Step 5: Commit**

```bash
git add Raconte/Sync/SyncBookkeeping.swift RaconteTests/SyncBookkeepingTests.swift
git commit -m "feat(sync): environment tag storage on SyncBookkeepingStore (#90)"
```

---

### Task 3: `EnvironmentGate` decision table

**Files:**
- Create: `Raconte/Sync/EnvironmentGate.swift`
- Test: `RaconteTests/EnvironmentGateTests.swift`

**Interfaces:**
- Consumes: `CloudKitEnvironment` (Task 1).
- Produces: `enum EnvironmentGateAction: Equatable, Sendable { case proceed, writeTag, wipeAndWriteTag }` and `enum EnvironmentGate { static func decide(tag: CloudKitEnvironment?, detected: CloudKitEnvironment, bookkeepingExists: Bool) -> EnvironmentGateAction }`. Task 4 switches on the action.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Raconte

/// #90: the whole gate policy as a pure table. Every cell is pinned — this table
/// is what decides whether an owner's sync cache is deleted, so no cell is
/// "obvious enough" to skip.
final class EnvironmentGateTests: XCTestCase {

    func testMatchingTagProceeds() {
        XCTAssertEqual(EnvironmentGate.decide(tag: .production, detected: .production,
                                              bookkeepingExists: true), .proceed)
        XCTAssertEqual(EnvironmentGate.decide(tag: .development, detected: .development,
                                              bookkeepingExists: true), .proceed)
        // A matching tag with no other bookkeeping is still just "proceed".
        XCTAssertEqual(EnvironmentGate.decide(tag: .production, detected: .production,
                                              bookkeepingExists: false), .proceed)
    }

    func testFreshInstallWritesTagWithoutWiping() {
        XCTAssertEqual(EnvironmentGate.decide(tag: nil, detected: .production,
                                              bookkeepingExists: false), .writeTag)
        XCTAssertEqual(EnvironmentGate.decide(tag: nil, detected: .development,
                                              bookkeepingExists: false), .writeTag)
    }

    /// The migration cell that frees the dev-stranded archive: bookkeeping written
    /// before tagging existed is unknown provenance — wipe it.
    func testPreTagUpgradeWipes() {
        XCTAssertEqual(EnvironmentGate.decide(tag: nil, detected: .production,
                                              bookkeepingExists: true), .wipeAndWriteTag)
        XCTAssertEqual(EnvironmentGate.decide(tag: nil, detected: .development,
                                              bookkeepingExists: true), .wipeAndWriteTag)
    }

    func testMismatchWipesBothDirections() {
        XCTAssertEqual(EnvironmentGate.decide(tag: .development, detected: .production,
                                              bookkeepingExists: true), .wipeAndWriteTag)
        XCTAssertEqual(EnvironmentGate.decide(tag: .production, detected: .development,
                                              bookkeepingExists: true), .wipeAndWriteTag)
        // Mismatched tag but nothing else on disk: the tag itself is stale state — wipe.
        XCTAssertEqual(EnvironmentGate.decide(tag: .development, detected: .production,
                                              bookkeepingExists: false), .wipeAndWriteTag)
    }
}
```

- [ ] **Step 2: Run to verify failure** — `xcodegen generate` (new files), then `-only-testing:RaconteTests/EnvironmentGateTests`. Expected: BUILD FAILURE.

- [ ] **Step 3: Implement**

```swift
/// #90: what `SyncCoordinator.launch()` does about the environment tag before the
/// engine resumes. Pure so the table is unit-tested cell by cell — this decision
/// deletes an owner's sync cache when it says wipe.
/// Design: docs/plans/2026-08-24-90-environment-tag-design.md §3.
enum EnvironmentGateAction: Equatable, Sendable {
    case proceed
    case writeTag
    case wipeAndWriteTag
}

enum EnvironmentGate {
    static func decide(tag: CloudKitEnvironment?, detected: CloudKitEnvironment,
                       bookkeepingExists: Bool) -> EnvironmentGateAction {
        if tag == detected { return .proceed }
        if tag == nil && !bookkeepingExists { return .writeTag }
        return .wipeAndWriteTag
    }
}
```

- [ ] **Step 4: Run to verify pass** — 4/4 green.

- [ ] **Step 5: Commit**

```bash
git add Raconte/Sync/EnvironmentGate.swift RaconteTests/EnvironmentGateTests.swift
git commit -m "feat(sync): EnvironmentGate decision table (#90)"
```

---

### Task 4: Wire the gate into `SyncCoordinator.launch()` + `live()`

**Files:**
- Modify: `Raconte/Sync/SyncCoordinator.swift` — `init` (~line 33), `launch()` (~line 58), `live()` (~line 249 where the coordinator is constructed)
- Test: `RaconteTests/SyncCoordinatorTests.swift` (append; reuse `FakeCloudEngine` and the class's capture/ledger fixtures)

**Interfaces:**
- Consumes: `CloudKitEnvironment` (Task 1), store methods (Task 2), `EnvironmentGate.decide` (Task 3).
- Produces: `SyncCoordinator.init(bookkeeping:scanner:engine:log:now:environment:)` with `environment: CloudKitEnvironment = .production`; `live()` passes `CloudKitEnvironment.detectFromBundle()`.

- [ ] **Step 1: Write the failing tests** (append to `SyncCoordinatorTests`; **read the class's existing fixture helpers first** — it already has a temp `containerRoot`, a store, a `FakeCloudEngine`, and helpers that seed a finalized capture on disk and a matching ledger. Reuse them; the code below names the pieces to assert, adapt helper names to what the file actually defines.)

```swift
    // MARK: #90 environment gate

    /// The money test — the exact stranding this issue exists to fix: a ledger
    /// claiming "uploaded" (written under dev) must not suppress the production
    /// re-push. Mismatch ⇒ wipe ⇒ engine starts stateless ⇒ reconcile re-enqueues.
    func testLaunchWithMismatchedTagWipesAndReenqueues() async throws {
        // Seed: one finalized capture on disk + a ledger entry claiming its entry
        // record was uploaded (use the class's existing finalized-capture + ledger
        // helpers), and a development tag.
        try await store.saveEnvironmentTag(.development)
        let seededLedger = await store.ledger()
        XCTAssertFalse(seededLedger.isEmpty)  // adversarial guard: fixture is real

        let engine = FakeCloudEngine()
        let coordinator = SyncCoordinator(bookkeeping: store, scanner: scanner(),
                                          engine: engine, environment: .production)
        await coordinator.launch()

        let started = await engine.startedWith
        XCTAssertEqual(started, [nil])                       // never resumed stale state
        let ledgerAfter = await store.ledger()
        // Reconcile re-enqueued the capture, and recording an upload is the push
        // path's job — at launch-time the wiped ledger stays empty.
        XCTAssertTrue(ledgerAfter.isEmpty)
        let saved = await engine.savedNameSet
        XCTAssertFalse(saved.isEmpty)                        // the stranded record pushes again
        let tag = await store.environmentTag()
        XCTAssertEqual(tag, .production)
    }

    /// Same seed, matching tag: nothing is wiped, the engine resumes its state.
    func testLaunchWithMatchingTagPreservesBookkeeping() async throws {
        try await store.saveEnvironmentTag(.production)
        try await store.saveEngineState(Data("blob".utf8))
        let seededLedger = await store.ledger()
        XCTAssertFalse(seededLedger.isEmpty)

        let engine = FakeCloudEngine()
        let coordinator = SyncCoordinator(bookkeeping: store, scanner: scanner(),
                                          engine: engine, environment: .production)
        await coordinator.launch()

        let started = await engine.startedWith
        XCTAssertEqual(started, [Data("blob".utf8)])
        let ledgerAfter = await store.ledger()
        XCTAssertEqual(ledgerAfter, seededLedger)
        let tag = await store.environmentTag()
        XCTAssertEqual(tag, .production)
    }

    /// Pre-tag upgrade (today's phones): bookkeeping exists, no tag — wipe.
    func testLaunchWithUntaggedExistingBookkeepingWipes() async throws {
        let seededLedger = await store.ledger()
        XCTAssertFalse(seededLedger.isEmpty)

        let engine = FakeCloudEngine()
        let coordinator = SyncCoordinator(bookkeeping: store, scanner: scanner(),
                                          engine: engine, environment: .production)
        await coordinator.launch()

        let started = await engine.startedWith
        XCTAssertEqual(started, [nil])
        let ledgerAfter = await store.ledger()
        XCTAssertTrue(ledgerAfter.isEmpty)
        let tag = await store.environmentTag()
        XCTAssertEqual(tag, .production)
    }

    /// Fresh install: nothing on disk — tag written, no wipe path taken, and the
    /// engine starts stateless because there was never state.
    func testLaunchFreshInstallWritesTag() async throws {
        // Use a store over a root that does NOT exist yet (build a second store on
        // an un-created temp subdirectory rather than the class fixture if the
        // fixture pre-creates it).
        let engine = FakeCloudEngine()
        let freshRoot = containerRoot.appendingPathComponent("fresh-sync", isDirectory: true)
        let freshStore = SyncBookkeepingStore(root: freshRoot)
        let coordinator = SyncCoordinator(bookkeeping: freshStore, scanner: scanner(),
                                          engine: engine, environment: .development)
        await coordinator.launch()

        let tag = await freshStore.environmentTag()
        XCTAssertEqual(tag, .development)
        let started = await engine.startedWith
        XCTAssertEqual(started, [nil])
    }
```

Fixture note: these tests need the ledger seeded to non-empty and a finalized capture on disk so reconcile finds work — if the class's shared `setUp` doesn't do that, call its existing per-test seeding helpers (the class has them for the reconcile tests; mirror one of those tests' seeding lines exactly). If pre-existing tests in this class start failing because the new gate wipes their untagged fixtures at `launch()`, fix them by seeding `try await store.saveEnvironmentTag(.production)` in those tests (or the shared helper) — the default `environment:` parameter is `.production`, so a matching tag restores their old behavior; do NOT weaken the gate for them.

- [ ] **Step 2: Run to verify failure** — `-only-testing:RaconteTests/SyncCoordinatorTests`. Expected: BUILD FAILURE — no `environment:` parameter.

- [ ] **Step 3: Implement**

`init` gains a stored `private let environment: CloudKitEnvironment` and parameter `environment: CloudKitEnvironment = .production` (defaulted last, so existing call sites compile; `.production` is the safe default — a wrongly-defaulted prod build wipes at most a dev cache).

`launch()` becomes:

```swift
    func launch() async {
        await applyEnvironmentGate()
        let state = await bookkeeping.engineState()
        await engine.start(stateData: state)
        await reconcile()
        await fetchNow()
    }

    /// #90: before the engine resumes from `engine-state.bin`, make sure every
    /// byte of bookkeeping was written by the environment this binary talks to.
    /// Wipe-then-tag ordering matters: `wipe()` removes the tag file too, so the
    /// tag write must follow it. Failures are `try?` by the store's governing
    /// rule — a failed wipe leaves stale state whose pushes the NOT_FOUND
    /// self-heal already survives, and a failed tag write just re-runs the gate
    /// next launch.
    private func applyEnvironmentGate() async {
        let tag = await bookkeeping.environmentTag()
        let exists = await bookkeeping.hasBookkeeping()
        switch EnvironmentGate.decide(tag: tag, detected: environment, bookkeepingExists: exists) {
        case .proceed:
            return
        case .writeTag:
            try? await bookkeeping.saveEnvironmentTag(environment)
            log.notice("sync: environment tag written (\(self.environment.rawValue, privacy: .public))")
        case .wipeAndWriteTag:
            try? await bookkeeping.wipe()
            try? await bookkeeping.saveEnvironmentTag(environment)
            log.notice("""
                sync: environment tag \(tag?.rawValue ?? "absent", privacy: .public) vs \
                \(self.environment.rawValue, privacy: .public) — bookkeeping wiped, full resync
                """)
        }
    }
```

`live()`: at the `SyncCoordinator(bookkeeping:scanner:engine:)` construction site, add `environment: CloudKitEnvironment.detectFromBundle()`.

- [ ] **Step 4: Run the coordinator class, then the FULL unit suite**

First `-only-testing:RaconteTests/SyncCoordinatorTests` (expected: all green including pre-existing members), then the full Global Constraints command with no `-only-testing` filter. Expected: everything green; baseline was 1798 tests before this branch — the count must be baseline + the new tests from Tasks 1–4 (13). Any pre-existing failure traces to the gate wiping an untagged fixture — fix per the fixture note in Step 1, never by weakening the gate.

- [ ] **Step 5: iOS compile check**

```bash
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'generic/platform=iOS' CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add Raconte/Sync/SyncCoordinator.swift RaconteTests/SyncCoordinatorTests.swift
git commit -m "feat(sync): environment gate at launch — wipe bookkeeping on env mismatch (#90)"
```
