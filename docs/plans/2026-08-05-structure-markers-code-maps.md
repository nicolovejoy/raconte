# Structure markers — code maps (Explore output, 2026-08-05)

Input material for the T6 §14 implementation plan. Three Explore-agent maps of the
code as of commit 1f2a44b5, captured 2026-08-05 ~09:07 PT (recovered from a crashed
session). Exact declarations, paths, and line numbers were verified against source at
capture time. Delete this file once the implementation plan lands.

---

# Map 1: capture-side PCM pipeline (PCMSink / TeeSink / recorder start sites)

Facts, with exact code.

## 1. `PCMSink` protocol + chunk type

`/Users/nico/src/raconte/Raconte/Capture/PCMSink.swift` (whole file, 23 lines):

```swift
// lines 4-13
/// A chunk of canonical capture PCM handed off by the tap thread.
///
/// `data` is a flat little-endian `Float32` stream: mono, non-interleaved, one channel,
/// at `sampleRate`. This matches the on-disk segment format (design §1) exactly, so a
/// sink can append the bytes verbatim.
struct PCMChunk: Sendable, Equatable {
    let data: Data
    let frameCount: AVAudioFrameCount
    let sampleRate: Double
}

// lines 15-23
/// Destination for canonical PCM produced during capture.
///
/// `receive(_:)` is called on the audio tap thread and MUST NOT block (no disk I/O, no
/// locks held across syscalls). The concrete sink (`SegmentStore`, T3) enqueues the bytes
/// onto its own serial writer. `Sendable` because the tap thread is a different execution
/// context than the caller that installed it.
protocol PCMSink: Sendable {
    func receive(_ chunk: PCMChunk)
}
```

Note: `frameCount` is `AVAudioFrameCount` (= `UInt32`), NOT `Int64`. `startFrame` does not exist on `PCMChunk` — it exists only on `StampedChunk`, which is declared in `BoundedPCMSink.swift`, not in `PCMSink.swift`:

`/Users/nico/src/raconte/Raconte/Capture/BoundedPCMSink.swift:1-15`
```swift
/// A `PCMChunk` labelled with its position on the capture-frame axis — the same
/// axis as `SegmentSidecar.startFrameOffset`, so a stamped chunk maps directly to
/// a position in the finalized `recording.m4a`.
struct StampedChunk: Sendable, Equatable {
    let chunk: PCMChunk
    let startFrame: Int64

    /// The span this chunk occupies on the capture-frame axis — what a consumer
    /// records when it cannot use the chunk, so a gap stays expressible.
    var frameRange: FrameRange {
        FrameRange(start: startFrame, end: startFrame + Int64(chunk.frameCount))
    }
}
```

`FrameRange` — `/Users/nico/src/raconte/Raconte/Capture/Models/FrameRange.swift:9-22`: `struct FrameRange: Codable, Sendable, Equatable` with `var start: Int64`, `var end: Int64`, `var frameCount: Int64 { max(0, end - start) }`, `func isContiguous(with other: FrameRange) -> Bool { end == other.start }`.

## 2. `TeeSink`

`/Users/nico/src/raconte/Raconte/Capture/TeeSink.swift` (whole file, 33 lines):

```swift
/// Fans one tap's PCM out to several sinks (M2 design §2: transcription is a
/// second consumer of the same chunks, never a rewiring of the disk path).
///
/// Checked `Sendable`, not `@unchecked`: the only stored property is an immutable
/// array of `Sendable` branches. **Never add mutable state here.** A counter or a
/// drop ledger would force `@unchecked` plus a lock taken on the real-time tap
/// thread for every chunk of every capture — that bookkeeping belongs in a branch
/// (`BoundedPCMSink`), which knows its own frame cursor.
///
/// Always constructed, even with a single branch: one tee identity means both
/// `recorder.start` sites (initial + resume) pass the same object, so a second
/// branch can't silently die at the first interruption.
final class TeeSink: PCMSink {
    let branches: [any PCMSink]

    init(branches: [any PCMSink]) {
        self.branches = branches
    }

    /// Called on the audio tap thread. No lock, no allocation, no `Task` — just
    /// the loop. `PCMChunk.data` is copy-on-write, so fanning to N branches costs
    /// N retains, not N copies.
    ///
    /// **Branch order is load-bearing, not cosmetic.** The tee runs on the
    /// caller's thread, so nothing preempts a slow branch; the disk branch is
    /// isolated purely by being entered first. Chunk N is on the pump's stream
    /// before any secondary branch is entered.
    nonisolated func receive(_ chunk: PCMChunk) {
        for branch in branches { branch.receive(chunk) }
    }
}
```

Composition: a plain `[any PCMSink]` array passed to `init(branches:)`; order = iteration order.

## 3. `BoundedPCMSink`

`/Users/nico/src/raconte/Raconte/Capture/BoundedPCMSink.swift:28-96`. Declaration: `final class BoundedPCMSink: PCMSink, @unchecked Sendable`. Stored: `let stream: AsyncStream<StampedChunk>`, `private let continuation`, `private let lock = NSLock()`, `private var cursor: Int64 = 0`, `private var droppedRanges: [FrameRange]`, `private var droppedChunkCount = 0`. `init(capacity: Int)` uses `AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(max(1, capacity)))`. Public reads `ingestedFrames: Int64`, `dropped: [FrameRange]`, `dropCount: Int`, `func finish()`.

`receive` pattern (lines 64-81) is the closest analogue for a frame counter:
```swift
    nonisolated func receive(_ chunk: PCMChunk) {
        let frames = Int64(chunk.frameCount)
        // Lock held for a few instructions only — never across the yield's
        // consumer-side work, and never across an `await` on the drain side.
        lock.lock()
        let start = cursor
        cursor += frames
        lock.unlock()
        ...
```

Constructed only at `/Users/nico/src/raconte/Raconte/Transcription/LiveTranscription.swift:67` inside `LiveTranscriptionRun.init(captureID:captureDirectory:capacity: Int = 256)`:
```swift
    init(captureID: String, captureDirectory: URL, capacity: Int = 256) {
        self.captureID = captureID
        self.captureDirectory = captureDirectory
        self.sink = BoundedPCMSink(capacity: capacity)
    }
```
and handed to the coordinator via `LiveTranscriptionCoordinator.begin(captureID:)` (`LiveTranscription.swift:201-209`, `return run.sink`).

## 4. BOTH `recorder.start` sites — `/Users/nico/src/raconte/Raconte/Capture/CaptureCoordinator.swift`, type `CaptureCoordinator` (`@MainActor @Observable final class`)

Site A — `configureAndStart(captureID:)`, lines 347-384:
```swift
        let recorder = makeRecorder()
        let forwarder = PCMForwarder()
        // The format isn't known yet — `captureFormatDescriptor` only reads back
        // after `start` returns — so the factory gets the ID only and reads
        // `activeFormat` afterwards.
        let secondary = makeSecondarySink?(captureID)
        let tee = TeeSink(branches: [forwarder] + (secondary.map { [$0] } ?? []))
        let level = levelBox
        do {
            try recorder.start(sink: tee, matching: nil, onLevel: { level.set($0) })
        } catch {
            // NOTE: a produced secondary sink is simply dropped here and on the
            // format-guard path below. Harmless while it's inert; once it owns an
            // analyzer (T2) it will need an explicit abandon hook.
            session.deactivate()
            await send(.prepareFailed(.configurationFailed)); return
        }
        guard let format = recorder.captureFormatDescriptor else {
            recorder.stop(); session.deactivate()
            await send(.prepareFailed(.configurationFailed)); return
        }
        currentRecorder = recorder
        currentForwarder = forwarder
        currentTee = tee
        activeFormat = format
        await send(.engineReady)
```
(`let tee = ...` is line 364; `try recorder.start(...)` is line 367.)

Site B — `rebuildAndReacquire()`, lines 422-441:
```swift
    private func rebuildAndReacquire() async {
        await store(setState: .resuming)   // write-ahead (§2 row 8) before reacquiring
        do { try await session.activate() }
        catch { await send(.reacquireFailed); return }
        // The tee, not the forwarder: the resume start must install the SAME
        // fan-out, or every branch past the disk one dies at the first
        // interruption while the on-disk result stays perfect.
        guard let tee = currentTee, let format = activeFormat else {
            await send(.reacquireFailed); return
        }
        // Fresh recorder: a new AVAudioEngine binds the CURRENT default input (the old
        // engine can be stale after a device switch / media services reset). Pinned to
        // the capture's canonical format — the new device's rate may differ, and the
        // segment chain must keep one rate (the tap resamples if needed).
        currentRecorder?.stop()
        let recorder = makeRecorder()
        let level = levelBox
        do { try recorder.start(sink: tee, matching: format, onLevel: { level.set($0) }) }
        catch { await send(.reacquireFailed); return }
        currentRecorder = recorder
```

Held state: `private var currentTee: TeeSink?` at line 127 with the doc comment at 122-126; `private var currentForwarder: PCMForwarder?` at 121.

`EngineRecording` protocol (same file, lines 30-39):
```swift
protocol EngineRecording: AnyObject {
    var isRunning: Bool { get }
    /// Canonical capture format, available once `start` succeeds.
    var captureFormatDescriptor: AudioFormatDescriptor? { get }
    /// `matching` non-nil pins output to that format (resume path — the new input
    /// device's rate may differ from the capture's); nil adopts the hardware format.
    func start(sink: PCMSink, matching canonical: AudioFormatDescriptor?,
               onLevel: (@Sendable (Float) -> Void)?) throws
    func stop()
}
```

## 5. `SecondarySinkFactory`

Declared `/Users/nico/src/raconte/Raconte/Capture/CaptureCoordinator.swift:46-52`:
```swift
/// Builds an optional second `PCMSink` branch, fanned alongside the disk branch by
/// `TeeSink` (M2 design §4). `@MainActor` rather than `@Sendable` so the owner can
/// retain the product — a transcription session outlives the coordinator.
///
/// The format is deliberately NOT a parameter: it is unknown until
/// `recorder.start` returns. Read `CaptureCoordinator.activeFormat` instead.
typealias SecondarySinkFactory = @MainActor (_ captureID: String) -> (any PCMSink)?
```

Threading through the composition root:
- `CaptureCoordinator` stored prop line 114 (`private let makeSecondarySink: SecondarySinkFactory?`), init param line 161 (`makeSecondarySink: SecondarySinkFactory? = nil`), assignment 172.
- `CaptureScreenModel.init` in `/Users/nico/src/raconte/Raconte/Capture/UI/CaptureView.swift:95-134` — param at line 100, passed into the `spawn` closure at line 130 that builds `CaptureCoordinator`. Note the coordinator is *respawned* through `self.spawn` per capture.
- `CaptureScreenModel.liveWithTranscription(library:)` — `/Users/nico/src/raconte/Raconte/Capture/UI/CaptureView.swift:168-191`, line 188: `makeSecondarySink: { [weak transcription] id in transcription?.begin(captureID: id) },`
- `CaptureScreenModel.live(library:)` (lines 138-155) does **not** pass one (nil).
- Factory body: `LiveTranscriptionCoordinator.begin(captureID:)` at `/Users/nico/src/raconte/Raconte/Transcription/LiveTranscription.swift:194-209`.

UI-test harness — `/Users/nico/src/raconte/Raconte/Capture/Debug/UITestSupport.swift` (whole file `#if DEBUG`), lines 41-64:
```swift
    @MainActor static func uiTestHarness(library: LibraryScreenModel) -> CaptureScreenModel? {
        guard let id = ProcessInfo.processInfo.environment["RACONTE_UITEST_ID"] else { return nil }
        let root = UITestHarnessRoot.capturesRoot(id: id)
        return CaptureScreenModel(
            capturesRoot: root,
            makeSession: { UITestSessionController() },
            makeRecorder: { SyntheticRecorder() },
            encoder: AVAssetWriterAudioEncoder(),
            // A second branch on every capture, so the simulator suite drives
            // record→finalize→relaunch over a two-branch tee rather than the
            // one-branch shape no shipping build will use.
            makeSecondarySink: { _ in NoOpPCMSink() },
            ...
            library: library)
    }
}

/// A tee branch that does nothing. Exists so the tested path has the same shape
/// as the shipping path.
final class NoOpPCMSink: PCMSink {
    nonisolated func receive(_ chunk: PCMChunk) {}
}
```
`SyntheticRecorder` (same file, lines 79-114) is the harness `EngineRecording`; it calls `sink.receive(PCMChunk(...))` from a `Task.detached` in 100 ms chunks.

## 6. The T1 mutation-verified regression test

File `/Users/nico/src/raconte/RaconteTests/CaptureCoordinatorTests.swift`, section marker `// MARK: M2 T1 — the tee is invisible to the disk path` (line 570).

Primary test, `testSecondBranchSurvivesInterruptionResume()` at lines 663-688:
```swift
    /// The regression that matters: the resume `recorder.start` must install the
    /// SAME tee. Wire the second branch only at `configureAndStart` and this fails
    /// at 750 frames while every on-disk assertion stays green.
    func testSecondBranchSurvivesInterruptionResume() async throws {
        let counter = CountingSink()
        let session = FakeSession(); let recorder = FakeRecorder()
        let coordinator = makeCoordinator(session: session, recorder: recorder,
                                          makeSecondarySink: { _ in counter })

        await coordinator.record()
        recorder.feed(frames: 750)
        session.emit(.interrupted)
        await waitUntil({ coordinator.phase == .interrupted }, "did not interrupt")

        session.emit(.resumeAvailable(shouldResume: true))
        await waitUntil({ coordinator.phase == .recording }, "did not resume")

        recorder.feed(frames: 250)
        await coordinator.done()
        XCTAssertEqual(coordinator.phase, .captured)

        XCTAssertEqual(counter.frames, 1000,
                       "second branch missed the post-resume audio — the resume start "
                       + "is not passing the tee")
        XCTAssertEqual(counter.chunks, 2)
    }
```

Companion `testSecondBranchSurvivesRouteLossResume()` (lines 690-705) does the same over `session.emit(.routeLost)` waiting on `recorder.startCount >= 2`, asserting `counter.frames == 1000`.

The counting branch, lines 572-588:
```swift
    /// Counts chunks and frames, optionally doing slow or self-failing work.
    private final class CountingSink: PCMSink, @unchecked Sendable {
        private let lock = NSLock()
        private var _chunks = 0
        private var _frames = 0
        private let body: (@Sendable () -> Void)?

        init(body: (@Sendable () -> Void)? = nil) { self.body = body }

        var chunks: Int { lock.withLock { _chunks } }
        var frames: Int { lock.withLock { _frames } }

        nonisolated func receive(_ chunk: PCMChunk) {
            lock.withLock { _chunks += 1; _frames += Int(chunk.frameCount) }
            body?()
        }
    }
```

Supporting fixtures in the same file: `FakeRecorder` (lines 32-67; `feed(frames:)` synchronously calls `sink?.receive(...)` with a nonzero position-dependent byte pattern, tracks `startCount`, `lastMatching`), `FakeSession` (10-29), `makeCoordinator(...)` builder (96-119, has `makeSecondarySink: SecondarySinkFactory? = nil`), `waitUntil` (121-130). Also `testSecondBranchDoesNotChangeTheBytesOnDisk()` (614-655) and `runIdenticalScript(root:secondary:)` (593-604), plus factory-call tests at 709-734 (`testSecondarySinkFactoryIsCalledOncePerCaptureWithTheCaptureID`, `testSecondarySinkFactoryIsNotCalledWhenPermissionIsDenied`) with a `FactoryLog` helper at 736-741.

## 7. Atomics / locks

There are **no Swift package dependencies at all**. `/Users/nico/src/raconte/project.yml` is an XcodeGen manifest with `targets: Raconte / RaconteUITests / RaconteTests` and no `packages:` key; `Raconte.xcodeproj/project.pbxproj` has zero `packageReferences` / `XCRemoteSwiftPackageReference` entries. So no swift-atomics (`ManagedAtomic`).

Zero occurrences of `OSAllocatedUnfairLock`, `import Synchronization`, `Mutex<`, `Atomic<`, `os_unfair_lock`, `ManagedAtomic` anywhere in the repo. The universal pattern is `NSLock` + `@unchecked Sendable`. Occurrences of `private let lock = NSLock()` in app code: `Raconte/Capture/CaptureCoordinator.swift:724` (`PCMForwarder`), `:760` (`LevelBox`), `Raconte/Capture/BoundedPCMSink.swift:32`, `Raconte/Transcription/TranscriptionSession.swift:11`, `Raconte/Transcription/TranscriptionModuleCandidate.swift:227,290`, `Raconte/Library/CurrentJournal.swift:73`. Canonical minimal example, `CaptureCoordinator.swift:757-764`:
```swift
/// Thread-safe latest-value box so the @Sendable tap-level callback never touches the
/// main actor per buffer; the elapsed timer publishes `micLevel` from it.
final class LevelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var level: Float = 0
    func set(_ value: Float) { lock.lock(); level = value; lock.unlock() }
    func get() -> Float { lock.lock(); defer { lock.unlock() }; return level }
}
```
Build settings: `SWIFT_VERSION: "6.0"`, `SWIFT_STRICT_CONCURRENCY: complete`, deployment target iOS 26.0 / macOS 26.0 (so `Synchronization.Atomic` / `Mutex` from the stdlib would be available OS-wise, but is currently unused in this codebase).

## 8. Audio-thread tap

`/Users/nico/src/raconte/Raconte/Capture/AudioEngineRecorder.swift`:
- Type doc, lines 4-11: "The tap closure runs on a realtime audio thread and does NO disk I/O — it only converts, measures, and hands bytes to the sink (which enqueues them elsewhere)."
- Tap install, lines 58-60:
```swift
        input.installTap(onBus: 0, bufferSize: Self.tapBufferSize, format: inputFormat) { buffer, _ in
            proc.process(buffer)
        }
```
  `static let tapBufferSize: AVAudioFrameCount = 4800` (line 22, ≈100 ms @ 48 kHz); `private static let scratchHeadroom: AVAudioFrameCount = 2` (line 26).
- `final class TapProcessor: @unchecked Sendable` (line 123) holds `private let sink: PCMSink` (125). Its doc, lines 115-122, states safety rests on `process(_:)` being invoked serially by `AVAudioEngine` on a single audio thread — "a de-facto contract (observed, not documented by Apple), so no second caller of `process(_:)` may ever be added".
- Line 133 comment: "Reused converter-output buffer, allocated once at init (finding #1: no heap allocation per realtime tap callback → no priority-inversion / dropped-buffer risk)."
- Line 142: "VERIFY #2: store at the HARDWARE sample rate (no resample on the tap thread)".

Disk-side bridge off the tap thread: `PCMForwarder` at `CaptureCoordinator.swift:713-753` (`final class PCMForwarder: PCMSink, @unchecked Sendable`, `receive` just `continuation.yield(.chunk(chunk))`), draining into `actor SegmentStore: PCMSink` (`Raconte/Capture/SegmentStore.swift:18`, doc at 15-17).

## 9. Test framework and file naming

XCTest only — 52 files under `RaconteTests/` + `RaconteUITests/CaptureUITests.swift` import `XCTest`; **zero** files import `Testing` (Swift Testing is not used). Pattern: `final class XxxTests: XCTestCase`, e.g. `/Users/nico/src/raconte/RaconteTests/TeeSinkTests.swift:6` (`final class TeeSinkTests: XCTestCase`, header `/// M2 T1: fan-out semantics of the tap sink (design §2).`), `/Users/nico/src/raconte/RaconteTests/BoundedPCMSinkTests.swift`, `/Users/nico/src/raconte/RaconteTests/CaptureCoordinatorTests.swift:80-81` (`@MainActor final class CaptureCoordinatorTests: XCTestCase`), `/Users/nico/src/raconte/RaconteTests/AudioEngineRecorderTests.swift`, `/Users/nico/src/raconte/RaconteTests/SegmentStoreTests.swift`. Files are flat in `RaconteTests/` (no Capture subdirectory); target sources are declared as `sources: [RaconteTests]` in project.yml, so a new file is picked up on regeneration. Default test scheme runs `RaconteTests`; UI tests run under a separate `RaconteUI` scheme.

## Bonus: an existing design doc already specifies this work

`/Users/nico/src/raconte/docs/plans/2026-08-05-capture-structure-markers-design.md` line 51 onward names `FrameClockSink` ("a `PCMSink` that accumulates `frameCount` into an atomic `Int64` and exposes `currentFrame` readable from any thread. Installed as a **third tee branch**, after the disk sink and `BoundedPCMSink`"), line 165 ("constructed **once per capture** and installed at **both** `recorder.start` sites via the same tee identity. It must not reset on resume."), line 184 ("`FrameClockSink`: accumulates across a resume; **mutation-verified** that both `recorder.start` sites install it, mirroring the existing T1 tee regression test."), line 193 (task 1). `CLAUDE.md:22` also references it.

---

# Map 2: CaptureCoordinator, capture UI, entry sidecar

Facts, by area.

# A. `CaptureCoordinator` — `/Users/nico/src/raconte/Raconte/Capture/CaptureCoordinator.swift`

**A1. Declaration + published state** (lines 54–95):

```swift
@MainActor
@Observable
final class CaptureCoordinator {

    // MARK: Observable state (bound by the T10 UI)

    private(set) var phase: CaptureState = .idle
    private(set) var elapsed: TimeInterval = 0
    private(set) var micLevel: Float = 0
    private(set) var lastError: String?
    /// True after an interruption ended WITHOUT `.shouldResume`: UI shows a Resume button.
    private(set) var canResume = false
    private(set) var recoveredRecordings: [RecoveredRecording] = []
    private(set) var quarantinedCaptureIDs: [String] = []
    private(set) var finalizeQueue: [String] = []
    private(set) var executedEffectLog: [Effect] = []
```

`activeCaptureID` line 85, `activeFormat` line 92, `capturesRoot` line 95:

```swift
    private(set) var activeCaptureID: String?      // line 85
    private(set) var activeFormat: AudioFormatDescriptor?   // line 92
    let capturesRoot: URL                          // line 95
```
Both are cleared in `resetCaptureWiring()` (lines 624–634). `activeCaptureID` is set at `realize`'s `.record` case (line 296: `activeCaptureID = id`); `activeFormat` set at line 382 after `recorder.start` returns.

Phase enum: `/Users/nico/src/raconte/Raconte/Capture/Models/CaptureState.swift:5-17`
```swift
enum CaptureState: String, Codable, Sendable, CaseIterable {
    case idle
    case preparing
    case recording
    case interrupted
    case resuming
    case stopping
    case captured
    case finalizing
    case complete
}
```
Plus `var keepsDisplayAwake: Bool` (lines 27–32) with an exhaustive switch that a new case breaks.

How errors surface today: `lastError: String?` is assigned in-line at four places — line 335 (`lastError = message(for: .diskFull)`), 393, 404, 476 (`lastError = "Couldn't resume recording — retrying"`), 482 (`"Couldn't resume recording. Saved what was recorded."`), 517; mapped strings in `message(for:)` lines 646–652 (`"Microphone access denied"`, `"Couldn't start recording"`, `"Storage full"`). `CaptureView` renders it (CaptureView.swift:640-645):
```swift
                    if let error = model.coordinator.lastError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
```
`record()` clears it (line 211: `lastError = nil`).

**A2. Where the capture directory / `SegmentLayout` is known.** The coordinator itself holds only `capturesRoot` (line 95) + `activeCaptureID`; it never computes a capture directory. The directory lives on `SegmentStore` (`/Users/nico/src/raconte/Raconte/Capture/SegmentStore.swift:48-51`):
```swift
    nonisolated let captureID: String
    nonisolated let capturesRoot: URL
    nonisolated let captureDirectory: URL
    nonisolated let segmentsDirectory: URL
```
built in init lines 81–83 from `SegmentLayout.captureDirectory(capturesRoot:captureID:)`. The coordinator holds it as `private var currentStore: SegmentStore?` (line 120), minted by `makeStore` (line 389: `let store = makeStore(id, format)`).

Path helpers, `/Users/nico/src/raconte/Raconte/Capture/SegmentLayout.swift`: `captureDirectory` (63-65), `entryMetadataURL` (78-80), `transcriptDirectory` (102-104), `liveTranscriptURL` (108-111), `canonicalTranscriptURL` (116-119). Constants at 7-19 include `static let transcriptDirName = "transcript"` and `liveTranscriptFileName = "live.jsonl"`. `CaptureScreenModel.recordTranscriptRef` (CaptureView.swift:452-454) is the existing example of composing a path off `capturesRoot` + captureID from the UI layer.

**A3. One coordinator per capture, and where it's minted.** `/Users/nico/src/raconte/Raconte/Capture/UI/CaptureView.swift:10-13` doc comment, then lines 121–133:
```swift
        let spawn: @MainActor () -> CaptureCoordinator = {
            CaptureCoordinator(
                capturesRoot: capturesRoot,
                session: makeSession(),
                makeRecorder: makeRecorder,
                makeStore: { id, fmt in
                    SegmentStore(capturesRoot: capturesRoot, captureID: id, format: fmt)
                },
                startCue: startCue,
                makeSecondarySink: makeSecondarySink)
        }
        self.spawn = spawn
        self.coordinator = spawn()
```
Re-spawn after each capture, `finishCurrentCapture()` line 417: `coordinator = spawn()`. Owner is `@MainActor @Observable final class CaptureScreenModel` (lines 14–17: `private(set) var coordinator: CaptureCoordinator`). Composition roots: `static func live()` (138-155), `static func liveWithTranscription(library:)` (168-191); `ContentView.init()` (`/Users/nico/src/raconte/Raconte/App/ContentView.swift:13-17`) builds it once.

Coordinator init signature (lines 151–161) — the seam any new dependency (e.g. a frame clock / marker log) would be threaded through:
```swift
    init(capturesRoot: URL,
         session: AudioSessionController,
         makeRecorder: @escaping () -> EngineRecording,
         makeStore: @escaping StoreFactory,
         mintCaptureID: @escaping @Sendable () -> String = { CaptureCoordinator.makeULID() },
         now: @escaping @Sendable () -> Date = Date.init,
         machine: CaptureMachine = CaptureMachine(),
         flushInterval: Duration = .milliseconds(300),
         resumeBackoff: Duration = .milliseconds(500),
         startCue: (@MainActor () async -> Void)? = nil,
         makeSecondarySink: SecondarySinkFactory? = nil) {
```
Tee identity across both `recorder.start` sites: `private var currentTee: TeeSink?` (line 127, doc 122-126), installed at line 367 and again at line 439 (`try recorder.start(sink: tee, matching: format, ...)`).

**A4. "Sidecar writes fail loudly" (2026-08-03).** `/Users/nico/src/raconte/Raconte/Library/LibraryScreenModel.swift`:
```swift
    @discardableResult
    func trashEntry(_ captureID: String, now: Date = Date()) async -> Bool {   // line 254-255
        let succeeded: Bool
        do {
            _ = try await entryMetadataStore.update(captureID: captureID) { $0.trashedAt = now }
            succeeded = true
        } catch {
            succeeded = false
        }
        await rescan()
        return succeeded
    }
```
Same shape: `moveEntry` (191-202), `setBackdate` (208-222), `restoreEntry` (269-280), `deleteEntryPermanently` (288-304).

Call site with alert, `/Users/nico/src/raconte/Raconte/Library/UI/EntryDetailView.swift:290-299`:
```swift
    private func moveToTrash() {
        playback?.stop()
        Task {
            if await model.trashEntry(captureID) {
                dismiss()
            } else {
                trashFailed = true
            }
        }
    }
```
with the alert at 72-76:
```swift
        .alert("Couldn’t move this entry to the trash", isPresented: $trashFailed) {
            Button("OK") { trashFailed = false }
        } message: {
            Text("The change didn’t save. Try again.")
        }
```
Other alerts: `moveFailed` 77-81, `backdateFailed` 82-86; call sites 150, 163, 193. Also `LibraryView.swift:53` (`if !(await model.trashEntry(id)) { trashFailed = true }`), `TrashView.swift:34` and `:57`.

Counter-example still in force (best-effort, silent) — `CaptureView.swift:462`: `try? AtomicFile.replace(at: url, writing: encoded)` and `enqueueEntryMetadataWrite`'s `_ = try? await store.update(...)` at line 546.

# B. Capture screen — `/Users/nico/src/raconte/Raconte/Capture/UI/CaptureView.swift` (890 lines; contains `CaptureScreenModel`, `CaptureView`, `JournalHeaderView`, `BackdateField`)

**B5. Setup area, pre-record** — `CaptureView.body` lines 600-601:
```swift
                    JournalHeaderView(model: model)
                    BackdateField(model: model)
```
`JournalHeaderView` = lines 741–840 (Menu-based journal picker, id `capture.journalPicker`, alerts for new/rename, cover sheet). `BackdateField` = lines 846–889 (`Toggle` id `capture.backdateToggle` + always-rendered `PrecisionDatePicker` disabled at 0.45 opacity).

Recording-state controls area — lines 623–645, in the same `VStack(spacing: 28)`:
```swift
                    RecStatusLine(phase: model.coordinator.phase,
                                  canResume: model.coordinator.canResume,
                                  elapsed: model.coordinator.elapsed)

                    MicMeter(level: model.coordinator.micLevel,
                             isLive: model.coordinator.phase == .recording)

                    RecordButton(model: control, action: primaryAction)
                        .accessibilityIdentifier("capture.record")

                    if control.showsDoneButton {
                        Button("Done") { Task { await model.done() } }
                            .buttonStyle(.bordered)
                            .tint(.red)
                            .accessibilityIdentifier("capture.done")
                    }
```
Phase→control mapping is pure and unit-tested: `RecordControlModel.make(phase:canResume:)` at `/Users/nico/src/raconte/Raconte/Capture/UI/RecordButton.swift:36-73`; `CaptureView.control` computed property at lines 573–576. Live transcript block (conditional on non-empty) at 612-621, id `capture.transcript`.

**B6. Near-black background + dark scheme.** Background, line 580: `Color(white: 0.05).ignoresSafeArea()`, with `.foregroundStyle(.white)` on the ZStack at line 663. Verbatim example, lines 862-866:
```swift
            .accessibilityIdentifier("capture.backdateToggle")
            // The capture screen's background is near-black regardless of the app's
            // color scheme; an ambient-scheme system control renders dark-on-dark in
            // light mode (smoke feedback 2026-08-02) — same rule as the date picker below.
            .environment(\.colorScheme, .dark)
```
Second instance at 879-882 on `PrecisionDatePicker`. Those two (866, 882) are the only `.environment(\.colorScheme, .dark)` occurrences in the repo. Sheets reset the inherited white with `.foregroundStyle(Color.primary)` (lines 596-597, 829).

**B7. Haptics.** None. `grep -rn "UIImpactFeedbackGenerator|sensoryFeedback|UINotificationFeedback|UISelectionFeedback|hapt|Haptic"` over `Raconte/`, `RaconteTests/`, `RaconteUITests/` returns zero hits; the only match in the repo is `docs/plans/2026-08-05-capture-structure-markers-design.md:133` ("Both fire a haptic on tap…").

Platform-conditional precedent (multiplatform target, iOS+macOS). CaptureView.swift lines 1-4:
```swift
import SwiftUI
#if os(iOS)
import UIKit
#endif
```
and the iOS-only modifier block, lines 671-692 (`#if os(iOS)` … `UIApplication.shared.isIdleTimerDisabled = phase.keepsDisplayAwake` … `#endif`). Other `#if os(iOS)` sites: `CaptureView.swift:145,179` (session controller selection), `CapturePlayback.swift:200`, `CameraCapture.swift:1`, `IOSAudioSessionController.swift:1`, `JournalCoverPickerSheet.swift:3,27,48,90`, `JournalCoverImage.swift:2,26`; `#if os(macOS)` at `MacAudioSessionController.swift:1`, `ContentView.swift:47`.

**B8. UI tests.** Single file: `/Users/nico/src/raconte/RaconteUITests/CaptureUITests.swift` (405 lines, `final class CaptureUITests: XCTestCase`). Harness env:
```swift
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["RACONTE_UITEST_ID"] = testID
        app.launch()
        return app
    }
```
(lines 16-21; `testID = UUID().uuidString` at line 13). Cross-platform activation helper lines 24-30 (`#if os(macOS) element.click() #else element.tap()`); poll helper `waitUntil` lines 51-59. Element accessors: `app.buttons["capture.record"].firstMatch` (33), `app.staticTexts["recovery.title"]` (46), `app.descendants(matching: .any).matching(identifier: "capture.recentRow")` (41-43, with the note that a `NavigationLink` merges its label into one element so only the link's own identifier is queryable).

Tests: `testRecordStopProducesFinishedEntry` (63), `testTerminateMidRecordingRecoversOnRelaunch` (83), `testIdleRelaunchShowsNoBannerAndKeepsEntry` (102), `testRepeatedRecordStopCyclesProduceSeparateEntries` (123), `testScrubbingAFinishedEntryMovesThePosition` (155), `testTrashAndRestoreAnEntry` (212), `testDeleteNowPermanentlyRemovesEntry` (260), `testMoveToTrashWhilePlaybackIsRunningStillTrashesTheEntry` (335). Identifiers driven: `capture.record`, `capture.libraryButton`, `detail.play`, `detail.total`, `detail.position`, `detail.trashButton`, `detail.confirmTrash`, `library.trashLink`, `trash.row.remaining`, `trash.row.restore`, `trash.row.deleteNow`, `trash.confirmDeleteNow`, `trash.empty`.

App-side harness: `/Users/nico/src/raconte/Raconte/Capture/Debug/UITestSupport.swift` (whole file `#if DEBUG`): `UITestHarnessRoot.containerRoot(id:)`/`capturesRoot(id:)` (20-32), `CaptureScreenModel.uiTestHarness(library:)` (41-57) gated on `ProcessInfo.processInfo.environment["RACONTE_UITEST_ID"]`, `NoOpPCMSink` (62-64), `UITestSessionController` (67-74), `SyntheticRecorder` (79-114). Library side mirrors it at `LibraryScreenModel.live()` lines 95-104. Note for markers: the harness passes `makeSecondarySink: { _ in NoOpPCMSink() }` (line 52) and supplies no frame clock.

# C. `EntryMetadata` sidecar + carry-over precedent

**C9. `EntryMetadata`** — `/Users/nico/src/raconte/Raconte/Library/EntryMetadata.swift`. Declaration line 44: `struct EntryMetadata: Codable, Sendable, Equatable`. Fields: `journalID: String?` (47), `originalDate: PartialDate?` (57), `trashedAt: Date?` (61), `detectedDate: PartialDate?` (76), `detectionRan: Bool` (87). Memberwise init 89-99 with `self.detectionRan = detectionRan ?? (detectedDate != nil)`. `static let defaults = EntryMetadata()` (102); `isDefault` (109); `effectivePrecision` (121); `effectiveDate(capturedAt:calendar:)` (125-128).

Guarded write path (the `setBackdate`-style precedent), lines 135-141:
```swift
    @discardableResult
    mutating func setOriginalDate(_ date: PartialDate?, now: Date = Date(),
                                   calendar: Calendar = .gregorianCurrent) -> Bool {
        if let date, date.isFuture(now: now, calendar: calendar) { return false }
        originalDate = date
        return true
    }
```

Coding keys, lines 146-149:
```swift
    private enum CodingKeys: String, CodingKey {
        case journalID, originalDate, trashedAt, detectedDate, detectionRan
        case legacyPrecision = "precision"
    }
```
Hand-written decoder (house rule: synthesized decoder ignores property defaults), lines 165-184 — the lenient-vs-strict split a `multiVoice: Bool` would slot into:
```swift
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        journalID = try container.decodeIfPresent(String.self, forKey: .journalID)
        trashedAt = try container.decodeIfPresent(Date.self, forKey: .trashedAt)
        originalDate = try Self.decodeOriginalDate(container)
        detectedDate = (try? container.decodeIfPresent(PartialDate.self, forKey: .detectedDate)) ?? nil
        detectionRan = container.contains(.detectedDate)
            || ((try? container.decodeIfPresent(Bool.self, forKey: .detectionRan)) ?? false)
    }
```
Encoder, lines 209-223, nil-key-omitting so an empty sidecar is literally `{}`:
```swift
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(journalID, forKey: .journalID)
        try container.encodeIfPresent(originalDate, forKey: .originalDate)
        try container.encodeIfPresent(trashedAt, forKey: .trashedAt)
        try container.encodeIfPresent(detectedDate, forKey: .detectedDate)
        if detectionRan && detectedDate == nil {
            try container.encode(true, forKey: .detectionRan)
        }
    }
```

Store: `/Users/nico/src/raconte/Raconte/Library/EntryMetadataStore.swift` — `actor EntryMetadataStore` (20), `nonisolated func url(captureID:)` (27-31), `read` (37-39, absent ⇒ `.defaults`, unreadable throws `EntryMetadataError.unreadable`), `update(captureID:_:)` read-modify-write (47-54), static seams `read(url:)` (58), `decode` (71), `encode` (81, uses `CaptureCoding.lineEncoder()`), `write(_:url:)` (85-89, via `AtomicFile.replace`).

Write path from the capture screen: `CaptureScreenModel.enqueueEntryMetadataWrite(for:clearingBackdateIfDisabled:)` — CaptureView.swift:534-555, the serialized chain (`pendingMetadataWrite`, declared line 23):
```swift
        let task = Task { @MainActor in
            await previous?.value
            _ = try? await store.update(captureID: captureID) { metadata in
                if let journalID { metadata.journalID = journalID }
                if writeBackdate {
                    metadata.setOriginalDate(originalDate)
                }
            }
        }
        pendingMetadataWrite = task
```
Triggered from `handlePhase()` (246-252, on `.recording`) and `syncActiveEntryMetadata(clearingBackdateIfDisabled:)` (505-509).

**C10. `LibraryScanner`** — `/Users/nico/src/raconte/Raconte/Library/LibraryScanner.swift`. `struct LibraryScanner: Sendable` (46) with `capturesRoot`/`containerRoot` (47-48); `func scan(filter:) async -> LibraryScanResult` (58-62) = `DirectorySnapshot.gather` + `loadRegistry` + `build`. `static func build(snapshot:journals:filter:)` (81-99). The per-entry sidecar read, lines 117-141:
```swift
        var metadata = EntryMetadata.defaults
        do {
            metadata = try EntryMetadataStore.read(
                url: SegmentLayout.entryMetadataURL(captureDirectory: capture.directory))
        } catch {
            degradations.insert(.metadataUnreadable)
        }

        let journal = metadata.journalID.flatMap(registry.journal(id:))
        if metadata.journalID != nil, journal == nil { degradations.insert(.journalUnresolved) }

        let transcript = transcriptSummary(capture)
        degradations.formUnion(transcript.degradations)

        return EntryListItem(
            captureID: capture.captureID,
            capturedAt: capturedAt(capture),
            durationSeconds: durationSeconds(capture),
            metadata: metadata,
            journal: journal,
            snippet: transcript.snippet,
            transcript: transcript.state,
            degradations: degradations)
```
`EntryListItem` holds `var metadata: EntryMetadata` **whole** (`/Users/nico/src/raconte/Raconte/Library/EntryListItem.swift:94`), with `journalID`/`originalDate`/`trashedAt` as computed passthroughs (97-127) — so a new sidecar field is already carried by the scan with no scanner change; a `multiVoice` accessor would be a one-line computed property beside them. `capturedAt(_:)` at 149-153 (manifest `createdAt` → ULID timestamp → epoch).

The consumer that would host a "most recent entry's multiVoice per journal" read: `LibraryScreenModel.rescan()` (`LibraryScreenModel.swift:119-154`) publishes `allEntries` (line 151, `.all`/`.excludeTrashed`) and `recent = Self.mostRecentlyCaptured(allEntries, limit: 3)` (152). Existing per-journal derived-from-`allEntries` precedent, lines 158-160:
```swift
    func dateRange(forJournal journalID: String) -> JournalDateRange? {
        JournalDateRange.compute(from: allEntries.filter { $0.journalID == journalID })
    }
```
and the sort helper `static func mostRecentlyCaptured(_:limit:)` (164-171, `capturedAt` desc, captureID tiebreak). `CaptureScreenModel` reads through the *same* `LibraryScreenModel` instance (`let library: LibraryScreenModel`, CaptureView.swift:31; assert at 111-112; example use `selectedJournalCover` 307-309 and `menuTitle(for:)` 836-839).

**C11. The existing backdate per-journal carry-over (in-memory).** All in `CaptureScreenModel`, `/Users/nico/src/raconte/Raconte/Capture/UI/CaptureView.swift`:

State, line 88 (doc 80-87 explains the in-memory choice and names the durable upgrade):
```swift
    private var carriedBackdates: [String: PartialDate] = [:]
```
Live UI state, lines 76-78: `private(set) var backdateEnabled = false`, `backdateDate = Date()`, `backdatePrecision: DatePrecision = .day`.

Pre-fill on toggle-enable, lines 330-347:
```swift
    func setBackdateEnabled(_ enabled: Bool) {
        let wasEnabled = backdateEnabled
        backdateEnabled = enabled
        if enabled {
            if !wasEnabled, let carried = carriedBackdate() {
                backdateDate = carried.anchorDate(calendar: .gregorianCurrent)
                backdatePrecision = carried.precision
            }
            rememberBackdate()
        } else {
            backdateDate = Date()
            backdatePrecision = .day
        }
        syncActiveEntryMetadata(clearingBackdateIfDisabled: true)
    }
```
Read accessor, 363-365:
```swift
    func carriedBackdate() -> PartialDate? {
        selectedJournalID.flatMap { carriedBackdates[$0] }
    }
```
Re-anchor on journal switch, 378-387:
```swift
    private func resolveBackdateForJournalChange() {
        guard backdateEnabled else { return }
        if let carried = carriedBackdate() {
            backdateDate = carried.anchorDate(calendar: .gregorianCurrent)
            backdatePrecision = carried.precision
        } else {
            backdateDate = Date()
            backdatePrecision = .day
        }
    }
```
Write side, 391-396:
```swift
    private func rememberBackdate() {
        guard backdateEnabled, let journalID = selectedJournalID else { return }
        carriedBackdates[journalID] = PartialDate(from: backdateDate,
                                                  precision: backdatePrecision,
                                                  calendar: .gregorianCurrent)
    }
```
Callers of `resolveBackdateForJournalChange()`: `selectJournal(_:)` line 283 and `createJournal(name:)` line 293 (both immediately before `syncActiveEntryMetadata()`). `setBackdateDate`/`setBackdatePrecision` (349-359) each call `rememberBackdate()` then `syncActiveEntryMetadata()`.

Tests: `/Users/nico/src/raconte/RaconteTests/BackdateCarryOverTests.swift` (167 lines, `@MainActor final class BackdateCarryOverTests: XCTestCase`, fakes at 5-22, `makeModel()` 41-46). Six tests: `testBackdateCarriesOverWithinAJournal` (49), `testCarryOverDoesNotCrossJournals` (74), `testCarryOverDoesNotCrossJournalsWhileToggleStaysOn` (96), `testPrefilledBackdateIsStillEditable` (123), `testDisabledBackdateIsNotRemembered` (154), and the one the multi-voice divergence explicitly reverses — `testCarryOverNeverAutoEnablesTheToggle` (138-150), which asserts `XCTAssertFalse(second.backdateEnabled)` on a freshly constructed model.

**C12. Journal registry types.** `/Users/nico/src/raconte/Raconte/Library/Journal.swift`: `struct Journal: Codable, Sendable, Equatable, Identifiable, Hashable` (10) with `var id: String`, `var name: String`, `var createdAt: Date` (12-18) and a **strict** hand-written `init(from:)` (30-35) — doc at 22-29 states "Fields *added later* decode with `decodeIfPresent`. Unknown keys are ignored." `struct JournalRegistry: Codable, Sendable, Equatable` (48) with `var journals: [Journal] = []` (50) and a strict `init(from:)` (63-66); mutators `insert` (81-88), `rename` (91-99), `normalized` (101-103); lookups `journal(id:)` (68-70), `contains(id:)` (72).

Store: `/Users/nico/src/raconte/Raconte/Library/JournalStore.swift` — `actor JournalStore` (15), `nonisolated let url: URL` (16), init `containerRoot:mintID:now:` (23-29), `load()` (35-37), `list()` (39-41), `create(name:)` (49-56, read-modify-write + `save`), `rename(id:to:)` (58-64), `private func save` (69-73, `AtomicFile.replace`), static seams `load(url:)` (77-92, absent ⇒ empty registry, otherwise `JournalStoreError.unreadable`) and `encode` (98-100, `CaptureCoding.lineEncoder()`). Comment at 66-67: "Deletion is deliberately absent".

Path: `/Users/nico/src/raconte/Raconte/Library/AppContainer.swift:18` `static let journalsFileName = "journals.json"`, `journalsURL(containerRoot:)` (50-52), layout doc 11-14, `containerRoot(capturesRoot:)` inverse (65-67).

Design doc for reference (not code): `/Users/nico/src/raconte/docs/plans/2026-08-05-capture-structure-markers-design.md` — §4 on-disk format at line 87 (`transcript/markers.jsonl`), §5 UI at 118, §7 failure modes at 154, §9 seven-step task breakdown at 191.

---

# Map 3: transcript on-disk storage layer (JSONL patterns)

Complete map of the transcript on-disk storage layer.

---

## 1. `LiveTranscriptWriter` / `LiveTranscriptReader`

Both live in a single file: **`/Users/nico/src/raconte/Raconte/Transcription/LiveTranscriptStore.swift`** (336 lines). There is no type named `LiveTranscriptStore` — the file is named that, the types are `LiveTranscriptWriter` (final class) and `LiveTranscriptReader` (caseless `enum`, all statics).

### Error type — lines 3-13

```swift
enum LiveTranscriptError: Error, Equatable {
    case posix(operation: String, code: Int32)
    case notOpen
    /// A record encoded to something containing a raw newline, which JSONL cannot
    /// represent. Thrown rather than trapped: this is the derived path, and §0's rule
    /// is that transcription may fail at any moment *without* touching capture.
    case multilineRecord
    /// A log exists but could not be read, so its tail is unknown. Refusing to open is
    /// the whole point — see `LiveTranscriptWriter.open()`.
    case unreadableExistingLog(String)
}
```

### The three-answer read type — `LiveTranscriptSource`, lines 15-28

Exact name is **`LiveTranscriptSource`** (not nested; top-level in the same file):

```swift
enum LiveTranscriptSource: Equatable {
    /// No file. The honest "no transcript yet".
    case absent
    /// The file exists and we could not read it. **Not** the same as empty: any UI that
    /// offers "no transcript, re-derive?" would be wrong here, and a writer that resumed
    /// numbering from zero would append colliding `seq` values into it.
    case unreadable(String)
    case present(Data)
}
```

Produced by `LiveTranscriptReader.loadBytes(at:)`, lines 245-254:

```swift
    static func loadBytes(at url: URL) -> LiveTranscriptSource {
        do {
            return .present(try Data(contentsOf: url))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile
                                           || error.code == .fileNoSuchFile {
            return .absent
        } catch {
            return .unreadable(String(describing: error))
        }
    }
```

### Writer state — lines 42-57

```swift
final class LiveTranscriptWriter {

    private let url: URL
    private let fd = FileDescriptorBox()
    private(set) var recordsWritten = 0
    /// Next `seq` to assign. Continues from the file's existing tail so reopening an
    /// interrupted capture doesn't restart numbering.
    private(set) var nextSeq = 0
    /// A write failed partway and left an unterminated line behind.
    private var tornTail = false

    init(captureDirectory: URL) {
        self.url = SegmentLayout.liveTranscriptURL(captureDirectory: captureDirectory)
    }

    deinit { fd.closeIfOpen() }
```

### `O_APPEND` open + torn-tail termination — lines 64-119

Full public API surface of the writer: `init(captureDirectory:)`, `open() throws`, `@discardableResult append(_:) throws -> TranscriptRecord`, `sync() throws`, `close() throws`, plus `recordsWritten` / `nextSeq` read-only.

```swift
    func open() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)

        // Reopening must not reuse a descriptor slot — two append handles on one file
        // is a leak and a corruption source.
        fd.closeIfOpen()
        ...
        let existing: Data
        switch LiveTranscriptReader.loadBytes(at: url) {
        case .absent:
            existing = Data()
        case .unreadable(let reason):
            throw LiveTranscriptError.unreadableExistingLog(reason)
        case .present(let data):
            existing = data
        }
        ...
        let survivors = LiveTranscriptReader.parse(existing)
        nextSeq = max(survivors.records.last.map { $0.seq + 1 } ?? 0, survivors.completeLines)

        let descriptor = Foundation.open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard descriptor >= 0 else {
            throw LiveTranscriptError.posix(operation: "open", code: errno)
        }
        fd.value = descriptor
        ...
        if let last = existing.last, last != UInt8(ascii: "\n") {
            try Self.writeAll(fd: descriptor, data: Data([UInt8(ascii: "\n")]))
        }
    }
```

Note `Foundation.open(...)` — the module qualifier is required because the method is also named `open`.

The "first record after a torn tail must not fuse onto it" handling exists **twice**, in two forms:

- *Across a process boundary* — lines 109-118 above (the `if let last = existing.last, last != "\n"` block, with the comment "`O_APPEND` writes at the current end of file, so without this the first new record lands *directly onto* the unterminated line a kill left behind, fusing the two into one undecodable line and losing the new record as well as the old.")
- *Within one process* — the `tornTail` flag, lines 145-155.

### `append` — lines 121-159

```swift
    @discardableResult
    func append(_ record: TranscriptRecord) throws -> TranscriptRecord {
        guard fd.value >= 0 else { throw LiveTranscriptError.notOpen }
        var stamped = record
        stamped.seq = nextSeq

        var data = try CaptureCoding.lineEncoder().encode(stamped)
        ...
        guard !data.contains(UInt8(ascii: "\n")) else { throw LiveTranscriptError.multilineRecord }
        data.append(UInt8(ascii: "\n"))
        ...
        if tornTail {
            try Self.writeAll(fd: fd.value, data: Data([UInt8(ascii: "\n")]))
            tornTail = false
        }

        do {
            try Self.writeAll(fd: fd.value, data: data)
        } catch {
            tornTail = true
            throw error
        }
        nextSeq += 1
        recordsWritten += 1
        return stamped
    }
```

### `sync` / `close` / `writeAll` — lines 161-188

```swift
    func sync() throws {
        guard fd.value >= 0 else { return }
        if fsync(fd.value) != 0 {
            throw LiveTranscriptError.posix(operation: "fsync", code: errno)
        }
    }

    /// Final sync + close. Safe to call twice.
    func close() throws {
        guard fd.value >= 0 else { return }
        try sync()
        fd.closeIfOpen()
    }

    private static func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress, raw.count > 0 else { return }
            var offset = 0
            while offset < raw.count {
                let n = write(fd, base.advanced(by: offset), raw.count - offset)
                if n < 0 { throw LiveTranscriptError.posix(operation: "write", code: errno) }
                offset += n
            }
        }
    }
}
```

### `FileDescriptorBox` — lines 328-335 (fileprivate, bottom of the file)

```swift
private final class FileDescriptorBox {
    var value: Int32 = -1
    func closeIfOpen() { if value >= 0 { close(value); value = -1 } }
    deinit { closeIfOpen() }
}
```

### Reader — `LoadResult`, lines 210-222

```swift
    struct LoadResult: Equatable {
        var source: LiveTranscriptSource = .absent
        var records: [TranscriptRecord] = []
        /// Complete lines in the file, decodable or not. Differs from `records.count`
        /// when a line is intact but undecodable, which is what `nextSeq` must respect
        /// and what tail-loss detection compares against.
        var completeLines: Int = 0

        var isUnreadable: Bool {
            if case .unreadable = source { return true }
            return false
        }
    }
```

The doc comment above it (lines 207-209) states there is deliberately **no** convenience returning a bare `[TranscriptRecord]`.

### `load` overloads — lines 224-240

```swift
    static func load(url: URL) -> LoadResult {
        switch loadBytes(at: url) {
        case .absent:
            return LoadResult(source: .absent)
        case .unreadable(let reason):
            return LoadResult(source: .unreadable(reason))
        case .present(let data):
            let parsed = parse(data)
            return LoadResult(source: .present(data),
                              records: parsed.records,
                              completeLines: parsed.completeLines)
        }
    }

    static func load(captureDirectory: URL) -> LoadResult {
        load(url: SegmentLayout.liveTranscriptURL(captureDirectory: captureDirectory))
    }
```

### `Completeness` + `completeness(lines:expected:)` — lines 263-274

```swift
    enum Completeness: Equatable {
        /// No `TranscriptRef` — the capture never closed cleanly. Tail loss is expected
        /// here and is not a defect.
        case unknown
        case complete
        case truncated(missing: Int)
    }

    static func completeness(lines: Int, expected: Int?) -> Completeness {
        guard let expected else { return .unknown }
        return lines >= expected ? .complete : .truncated(missing: expected - lines)
    }
```

### Torn-tail drop on read — `ParseResult` + `parse`, lines 297-324

```swift
    struct ParseResult: Equatable {
        var records: [TranscriptRecord] = []
        var completeLines: Int = 0
    }

    /// Split out so `LiveTranscriptWriter.open()` can reuse the one read it already
    /// needs for the torn-tail check rather than reading the file twice.
    static func parse(_ data: Data) -> ParseResult {
        guard !data.isEmpty else { return ParseResult() }

        let newline = UInt8(ascii: "\n")
        // No trailing newline → the last line was never committed. Everything up to
        // the final newline is intact.
        let complete: Data
        if data.last == newline {
            complete = data
        } else if let lastNewline = data.lastIndex(of: newline) {
            complete = data[..<data.index(after: lastNewline)]
        } else {
            return ParseResult()   // a single torn line and nothing else
        }

        let decoder = CaptureCoding.decoder()
        let lines = complete.split(separator: newline, omittingEmptySubsequences: true)
        return ParseResult(
            records: lines.compactMap { try? decoder.decode(TranscriptRecord.self, from: Data($0)) },
            completeLines: lines.count)
    }
```

### Lazy-open-at-first-append

Not in the writer — the writer has an explicit `open()`. The laziness lives in **`/Users/nico/src/raconte/Raconte/Transcription/TranscriptionSession.swift:500-516`**:

```swift
    /// Open on first write, never at construction.
    ///
    /// `open()` creates `transcript/` and `O_CREAT`s the file, and `transcriptPresent` is
    /// deliberately "any file at all" — so a zero-byte log flips
    /// `holdsIrreplaceableArtifacts` and turns `.deleteCaptureDirectory` into the
    /// quarantine no-op. Opening eagerly would therefore make every denied-permission tap
    /// and every sub-0.5 s accidental tap leave a permanently undeletable empty directory
    /// (design §11.6). Deferring to the first record means a capture that never produced a
    /// word never creates the directory at all.
    private func openWriterIfNeeded() throws -> LiveTranscriptWriter? {
        if let writer { return writer }
        guard let captureDirectory else { return nil }
        let writer = LiveTranscriptWriter(captureDirectory: captureDirectory)
        try writer.open()
        self.writer = writer
        return writer
    }
```

with the call site at `TranscriptionSession.swift:488-498`:

```swift
    private func persist(_ result: TranscriptResult) {
        guard !loggingBroken, let setup else { return }
        do {
            let writer = try openWriterIfNeeded()
            try writer?.append(TranscriptRecord(result,
                                                generator: setup.generator,
                                                locale: setup.locale))
        } catch {
            loggingBroken = true
        }
    }
```

and `closeWriter()` at 518-523 (`try? writer?.close()`). Session-level state: `private var writer: LiveTranscriptWriter?` (line 125), `private var loggingBroken = false` (line 128), `private let captureDirectory: URL?` (line 124, `nil` means "do not persist").

---

## 2. `lineEncoder()`

Lives in **`/Users/nico/src/raconte/Raconte/Capture/SegmentLayout.swift`**, in the `CaptureCoding` enum at the bottom of the file (lines 191-235).

The shared pretty-printed encoder it works around, lines 192-200:

```swift
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .custom { date, enc in
            var container = enc.singleValueContainer()
            try container.encode(iso8601Formatter().string(from: date))
        }
        return encoder
    }
```

`lineEncoder()`, lines 202-211 — verbatim, doc comment included:

```swift
    /// Same dates and key ordering as `encoder()`, minus `.prettyPrinted`. JSONL
    /// requires one record per line, and the manifest/sidecar encoder emits multi-line
    /// JSON — a pretty-printed record would make the reader's line split tear every
    /// record in half. `LiveTranscriptWriter` asserts single-line output, which is how
    /// this was caught rather than shipped.
    static func lineEncoder() -> JSONEncoder {
        let encoder = encoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
```

`decoder()` at lines 213-225 (custom ISO8601-with-fractional-seconds date strategy), `iso8601Formatter()` at 230-234. Note the enum-level doc (lines 187-190): factory functions rather than shared `static let`s because `JSONEncoder`/`Decoder` are non-`Sendable`.

---

## 3. `TranscriptRecord` / `TranscriptRun` / `TranscriptTimeStamp`

All in **`/Users/nico/src/raconte/Raconte/Transcription/TranscriptRecord.swift`**.

### `TranscriptTimeStamp` — lines 6-21

```swift
struct TranscriptTimeStamp: Codable, Sendable, Equatable {
    var value: Int64
    var timescale: Int32

    init(value: Int64, timescale: Int32) {
        self.value = value
        self.timescale = timescale
    }

    init(_ time: CMTime) {
        self.value = time.value
        self.timescale = time.timescale
    }

    var cmTime: CMTime { CMTime(value: value, timescale: timescale) }
}
```

No hand-written `init(from:)` — fully synthesized.

### `TranscriptRun` — lines 39-55. Yes, both frame bounds are optional.

```swift
struct TranscriptRun: Codable, Sendable, Equatable {
    var text: String
    var captureFrameStart: Int64?
    var captureFrameEnd: Int64?
    /// Present only when the transcriber attributed one. `nil` is not "zero".
    var confidence: Double?

    init(text: String,
         captureFrameStart: Int64? = nil,
         captureFrameEnd: Int64? = nil,
         confidence: Double? = nil) {
        self.text = text
        self.captureFrameStart = captureFrameStart
        self.captureFrameEnd = captureFrameEnd
        self.confidence = confidence
    }
}
```

Also fully synthesized `Codable` — no hand-written `init(from:)`, which is safe precisely because every non-`text` field is `Optional` (synthesis gives `decodeIfPresent` for `Optional`s).

### `TranscriptRecord` — lines 61-105. Record-level frame fields are **non-optional `Int64`**.

```swift
struct TranscriptRecord: Codable, Sendable, Equatable {
    /// Monotonic within a file, starting at 0.
    ...
    var seq: Int
    var text: String

    /// The durable, cross-revision truth: position in `final/recording.m4a`.
    var captureFrameStart: Int64
    var captureFrameEnd: Int64

    /// Revision-local, and **never comparable across revisions**.
    /// `bestAvailableAudioFormat` is asset- and device-dependent, so a later
    /// retranscription may run at an entirely different rate.
    var analyzerStart: TranscriptTimeStamp?
    var analyzerEnd: TranscriptTimeStamp?

    var runs: [TranscriptRun]
    var generator: String
    var locale: String

    init(seq: Int,
         text: String,
         captureFrameStart: Int64,
         captureFrameEnd: Int64,
         analyzerStart: TranscriptTimeStamp? = nil,
         analyzerEnd: TranscriptTimeStamp? = nil,
         runs: [TranscriptRun] = [],
         generator: String,
         locale: String) { ... }

    var frameRange: FrameRange {
        FrameRange(start: captureFrameStart, end: captureFrameEnd)
    }
```

### The hand-written `init(from:)` pattern — lines 111-139, verbatim and complete

This is the one full example to mirror:

```swift
    /// Hand-written because Swift's synthesized decoder **ignores property defaults**.
    ///
    /// Verified, not assumed: a `var runs: [TranscriptRun] = []` still throws
    /// `keyNotFound` on a line without a `"runs"` key. Only `Optional` properties get
    /// `decodeIfPresent` from synthesis; a default value buys nothing at decode time.
    ///
    /// That mattered because `LiveTranscriptReader.parse` deliberately skips a line it
    /// cannot decode — right for one torn line, catastrophic when *every* line fails.
    /// Adding a field to this struct would therefore not have produced a version error;
    /// it would have silently erased every existing log and reported an empty transcript.
    ///
    /// So the additive fields decode leniently while the identity fields stay strict: a
    /// line missing `runs` is an older record and reads fine, a line missing `text` is
    /// garbage and still fails. No per-record version field — this codebase has no
    /// migration machinery, and the standing rule is to version when there is something
    /// to migrate.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        seq = try container.decode(Int.self, forKey: .seq)
        text = try container.decode(String.self, forKey: .text)
        captureFrameStart = try container.decode(Int64.self, forKey: .captureFrameStart)
        captureFrameEnd = try container.decode(Int64.self, forKey: .captureFrameEnd)
        generator = try container.decode(String.self, forKey: .generator)
        locale = try container.decode(String.self, forKey: .locale)

        analyzerStart = try container.decodeIfPresent(TranscriptTimeStamp.self, forKey: .analyzerStart)
        analyzerEnd = try container.decodeIfPresent(TranscriptTimeStamp.self, forKey: .analyzerEnd)
        runs = try container.decodeIfPresent([TranscriptRun].self, forKey: .runs) ?? []
    }
}
```

Note: no explicit `CodingKeys` enum is declared — the synthesized one is used, and only `init(from:)` is overridden (`encode(to:)` stays synthesized). Contrast with `FinalRef` in `Manifest.swift:85-88`, which does write an explicit `encode(to:)`.

### The two bridging extensions — lines 142-174

```swift
extension TranscriptRecord {
    /// The record a committed result becomes on disk. `seq` is the writer's to assign.
    init(_ result: TranscriptResult, generator: String, locale: String) {
        self.init(seq: 0,
                  text: result.text,
                  captureFrameStart: result.range.start,
                  captureFrameEnd: result.range.end,
                  analyzerStart: result.analyzerStart.map(TranscriptTimeStamp.init),
                  analyzerEnd: result.analyzerEnd.map(TranscriptTimeStamp.init),
                  runs: result.runs,
                  generator: generator,
                  locale: locale)
    }
}

extension TranscriptResult {
    init(_ record: TranscriptRecord) {
        self.init(text: record.text,
                  range: record.frameRange,
                  isVolatile: false,
                  confidence: nil,
                  finalizedThroughFrame: nil,
                  runs: record.runs,
                  analyzerStart: record.analyzerStart?.cmTime,
                  analyzerEnd: record.analyzerEnd?.cmTime)
    }
}
```

`TranscriptResult` itself is declared in `/Users/nico/src/raconte/Raconte/Transcription/TranscriptionEngine.swift:15-62` and carries `var runs: [TranscriptRun] = []` (line 48).

---

## 4. `SegmentLayout` — transcript path helpers

**`/Users/nico/src/raconte/Raconte/Capture/SegmentLayout.swift`**.

Constants, lines 7-20 — a `markers.jsonl` name constant goes beside line 12:

```swift
    static let manifestFileName = "manifest.json"
    static let entryMetadataFileName = "entry.json"
    static let segmentsDirName = "segments"
    static let finalDirName = "final"
    static let transcriptDirName = "transcript"
    static let liveTranscriptFileName = "live.jsonl"
    static let canonicalTranscriptPrefix = "canonical-"
    static let finalRecordingName = "recording.m4a"
    static let partExtension = "part"
```

The transcript URL helpers, lines 98-133 — a `markerLogURL(captureDirectory:)` goes between `liveTranscriptURL` (ends line 111) and `canonicalTranscriptURL` (starts line 116):

```swift
    /// Where M2 T3 writes `live.jsonl` and the canonical transcript. Declared here
    /// ahead of T3 because issue #8's guard has to know the directory exists as a
    /// concept before anything writes into it — a delete rule added *after* the
    /// writer is a delete rule that shipped one release too late.
    static func transcriptDirectory(captureDirectory: URL) -> URL {
        captureDirectory.appendingPathComponent(transcriptDirName, isDirectory: true)
    }

    /// The live pass's append-only log. One JSON object per line, committed results
    /// only. No `.part` sibling: there is no rewrite, so there is nothing to stage.
    static func liveTranscriptURL(captureDirectory: URL) -> URL {
        transcriptDirectory(captureDirectory: captureDirectory)
            .appendingPathComponent(liveTranscriptFileName)
    }

    /// `canonical-<n>.json`. Revisions are addressable and never rewritten — a
    /// retranscription writes `n+1` rather than replacing `n`, so a user edit in an
    /// earlier revision is always still on disk.
    static func canonicalTranscriptURL(captureDirectory: URL, revision: Int) -> URL {
        transcriptDirectory(captureDirectory: captureDirectory)
            .appendingPathComponent("\(canonicalTranscriptPrefix)\(revision).json")
    }

    static func canonicalRevision(fromFileName fileName: String) -> Int? { ... }
```

Other layout helpers for reference: `captureDirectory(capturesRoot:captureID:)` 63-65, `manifestURL` 67-69, `partURL(for:)` 149-151.

---

## 5. `holdsIrreplaceableArtifacts`

**`/Users/nico/src/raconte/Raconte/Capture/DirectorySnapshot.swift:64-73`** — on `CaptureSnapshot`:

```swift
    /// True when the tree holds something that cannot be rebuilt from what remains.
    ///
    /// Issue #8: `state == nil` covers a manifest that is *corrupt*, not just absent,
    /// and a finalized capture has no `segments/` left (the finalizer removes them),
    /// so `hasData` is false forever. Without this guard a single flipped byte in the
    /// manifest of a finished recording routes it to `.deleteCaptureDirectory` and
    /// destroys `final/recording.m4a` — the one file M1 promises is indestructible.
    var holdsIrreplaceableArtifacts: Bool {
        finalM4APresent || finalM4APartPresent || transcriptPresent
    }
```

So: **m4a (non-empty), m4a.part (existence only), or a non-empty `transcript/` directory.** The three inputs are computed in `DirectorySnapshot.gather`, lines 195-216:

```swift
        let m4aURL = SegmentLayout.finalRecordingURL(captureDirectory: directory)
        let finalM4APresent = fm.fileExists(atPath: m4aURL.path) && fileSize(m4aURL) > 0
        let finalM4APartPresent =
            fm.fileExists(atPath: SegmentLayout.finalRecordingPartURL(captureDirectory: directory).path)

        // Transcript. Stats only — the log is never parsed here; the scan runs at
        // every launch over every capture and must stay cheap.
        let transcriptDir = SegmentLayout.transcriptDirectory(captureDirectory: directory)
        let transcriptNames = (try? fm.contentsOfDirectory(atPath: transcriptDir.path)) ?? []
        let liveURL = SegmentLayout.liveTranscriptURL(captureDirectory: directory)
        let liveSize: Int? = fm.fileExists(atPath: liveURL.path) ? fileSize(liveURL) : nil
        let canonicalRevisions = transcriptNames.compactMap(SegmentLayout.canonicalRevision(fromFileName:))
        // Deliberately "any file at all", not "a file we can name".
        //
        // Issue #8's guard reads this, and §3's rule is "never delete a capture
        // directory containing final/ or transcript/". Narrowing it to a non-empty
        // live.jsonl or a well-formed canonical-<n>.json would silently drop
        // protection for a `canonical-3.json.part` — precisely what AtomicFile.replace
        // leaves behind on a crash, and precisely what T6 will be writing. A tree we
        // cannot interpret is the *most* dangerous one to delete, not the least.
        // An empty directory holds nothing, so it must not keep junk alive forever.
        let transcriptPresent = !transcriptNames.isEmpty
```

Consequence for a new `markers.jsonl`: it lands in `transcript/`, so `transcriptPresent` and therefore `holdsIrreplaceableArtifacts` already cover it with zero changes — including a zero-byte one.

Consumers of the flag: `RecoveryPlanner.plan` at **`/Users/nico/src/raconte/Raconte/Capture/RecoveryPlanner.swift:82-88`** (turns `.deleteCaptureDirectory` into `.quarantineCaptureDirectory`), and `LibraryScanner.swift:101-105`.

---

## 6. `TranscriptRef`

**`/Users/nico/src/raconte/Raconte/Capture/Models/Manifest.swift:91-135`**:

```swift
struct TranscriptRef: Codable, Sendable, Equatable {
    /// "SpeechTranscriber" | "DictationTranscriber".
    var generator: String
    var locale: String
    /// Capture frames actually ingested by the transcriber.
    var coverageFrames: Int64
    /// Drops and suspensions, in capture frames.
    var skippedRanges: [FrameRange]
    var committedRecords: Int
    /// nil while live, and nil forever if the session was abandoned.
    var completedAt: Date?
    var latestRevision: Int?

    init(generator: String,
         locale: String,
         coverageFrames: Int64 = 0,
         skippedRanges: [FrameRange] = [],
         committedRecords: Int = 0,
         completedAt: Date? = nil,
         latestRevision: Int? = nil) { ... }

    /// True when the live pass did not see the whole capture — dropped chunks, a
    /// background suspension, or a session that died partway. The audio is unaffected;
    /// this is the flag that offers a re-derive from `final/recording.m4a`.
    func needsRetranscription(against totalFrames: Int) -> Bool {
        if completedAt == nil { return true }
        if !skippedRanges.isEmpty { return true }
        return coverageFrames < Int64(totalFrames)
    }
}
```

Hung off the manifest at `Manifest.swift:170` (`var transcript: TranscriptRef?`) with the init parameter at line 189 (`transcript: TranscriptRef? = nil`). Note `TranscriptRef` uses fully synthesized `Codable` — no hand-written `init(from:)`, unlike `TranscriptRecord`.

It is populated in exactly one place: `LiveTranscriptionRun.finish()` at **`/Users/nico/src/raconte/Raconte/Transcription/LiveTranscription.swift:112-136`**, and written to the manifest by `CaptureView.recordTranscriptRef(for:)` at `/Users/nico/src/raconte/Raconte/Capture/UI/CaptureView.swift:448`.

---

## 7. `LiveTranscriptReader.consolidate`

**`LiveTranscriptStore.swift:276-293`** — signature is `static func consolidate(_ records: [TranscriptRecord]) -> TranscriptConsolidator`:

```swift
    /// Replay: fold the log back through the consolidator (issue #10).
    ///
    /// Reading records raw does **not** reproduce the live view. The log is append-only
    /// and cannot express either thing the consolidator does — a later result *revising*
    /// an overlapping earlier one, and an empty-text result *deleting* a span. Read raw,
    /// a revised phrase appears twice and a revoked one appears at all.
    ///
    /// The fix is to keep exactly one implementation of those rules and let the file
    /// stay dumb: `TranscriptConsolidator.apply` already knows them, is unit-tested, and
    /// is what produced the log in the first place. Records replay in file order as
    /// non-volatile results, which is precisely what was written.
    static func consolidate(_ records: [TranscriptRecord]) -> TranscriptConsolidator {
        var consolidator = TranscriptConsolidator()
        for record in records {
            consolidator.apply(TranscriptResult(record))
        }
        return consolidator
    }
```

The single production caller is `EntryTranscriptLoader.load(captureDirectory:expectedRecords:)` at **`/Users/nico/src/raconte/Raconte/Library/EntryTranscript.swift:41-61`**, which is the canonical "switch on all three source cases" idiom:

```swift
    static func load(captureDirectory: URL, expectedRecords: Int?) -> EntryTranscript {
        let loaded = LiveTranscriptReader.load(captureDirectory: captureDirectory)
        switch loaded.source {
        case .absent:
            return EntryTranscript(state: .absent, text: nil, degradations: [])
        case .unreadable:
            // Not "no transcript". The log is there and we failed at it.
            return EntryTranscript(state: .unreadable, text: nil,
                                   degradations: [.transcriptUnreadable])
        case .present:
            var degradations: EntryDegradation = []
            if case .truncated = LiveTranscriptReader.completeness(lines: loaded.completeLines,
                                                                   expected: expectedRecords) {
                degradations.insert(.transcriptTruncated)
            }
            return EntryTranscript(
                state: .present,
                text: LiveTranscriptReader.consolidate(loaded.records).committedText,
                degradations: degradations)
        }
    }
```

---

## 8. Existing writer/reader tests

Two files, split by concern:

- **`/Users/nico/src/raconte/RaconteTests/LiveTranscriptStoreTests.swift`** (285 lines) — round-trip, torn tail, reopen, regressions, and the `DirectorySnapshot.gather` stats.
- **`/Users/nico/src/raconte/RaconteTests/LiveTranscriptIntegrityTests.swift`** (155 lines) — absent-vs-unreadable, tail loss, decoder leniency.

Also relevant: `/Users/nico/src/raconte/RaconteTests/TranscriptPromotionTests.swift` (replay-matches-live property), `/Users/nico/src/raconte/RaconteTests/LiveTranscriptWireUpTests.swift` (session-level lazy-open + `hasLog`). `SegmentLayoutTests.swift` has **no** transcript path tests — the layout assertions live in `LiveTranscriptStoreTests` under its `// MARK: Layout` / canonical-revision test at line 231.

### The setup/teardown idiom — `LiveTranscriptStoreTests.swift:6-36`

```swift
final class LiveTranscriptStoreTests: XCTestCase {

    private var capturesRoot: URL!
    private var captureDir: URL!

    override func setUpWithError() throws {
        // A real `captures/<id>/` shape: `DirectorySnapshot.gather` walks the root's
        // children, so the capture must be nested one level down rather than sitting
        // directly in the system temp directory alongside everything else on the Mac.
        capturesRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RaconteLiveTranscript-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("captures", isDirectory: true)
        captureDir = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: "cap")
        try FileManager.default.createDirectory(at: captureDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: capturesRoot.deletingLastPathComponent())
    }

    private var logURL: URL { SegmentLayout.liveTranscriptURL(captureDirectory: captureDir) }

    private func record(_ text: String, _ start: Int64, _ end: Int64) -> TranscriptRecord {
        TranscriptRecord(seq: 0, text: text,
                         captureFrameStart: start, captureFrameEnd: end,
                         analyzerStart: TranscriptTimeStamp(value: start / 3, timescale: 16_000),
                         analyzerEnd: TranscriptTimeStamp(value: end / 3, timescale: 16_000),
                         runs: [TranscriptRun(text: text, captureFrameStart: start,
                                              captureFrameEnd: end, confidence: 0.9)],
                         generator: "SpeechTranscriber", locale: "en_US")
    }
```

### The representative torn-tail test — `LiveTranscriptStoreTests.swift:72-99`

```swift
    // MARK: Torn trailing line — the force-kill case

    /// The expected shape after a kill mid-write. Not an error: everything before the
    /// last newline was committed and stays valid.
    func testTornTrailingLineIsDiscardedAndEarlierRecordsSurvive() throws {
        let writer = LiveTranscriptWriter(captureDirectory: captureDir)
        try writer.open()
        try writer.append(record("one", 0, 4_800))
        try writer.append(record("two", 4_800, 9_600))
        try writer.close()

        // Simulate the kill: a half-written third line with no terminating newline.
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"seq":2,"text":"thr"#.utf8))
        try handle.close()

        let read = LiveTranscriptReader.load(captureDirectory: captureDir).records
        XCTAssertEqual(read.map(\.text), ["one", "two"],
                       "the torn tail is dropped, the committed prefix is kept")
    }

    func testASingleTornLineWithNoNewlineReadsAsEmpty() throws {
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(#"{"seq":0,"text":"tor"#.utf8).write(to: logURL)
        XCTAssertTrue(LiveTranscriptReader.load(captureDirectory: captureDir).records.isEmpty)
    }
```

### The "must not fuse onto the torn tail" test — `LiveTranscriptStoreTests.swift:142-163`

```swift
    /// `O_APPEND` means a reopen writes past the torn tail rather than over it, so the
    /// damaged bytes stay damaged and everything new stays readable.
    func testReopeningAfterATornLineDoesNotCorruptNewRecords() throws {
        let first = LiveTranscriptWriter(captureDirectory: captureDir)
        try first.open()
        try first.append(record("one", 0, 4_800))
        try first.close()

        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"seq":1,"te"#.utf8))
        try handle.close()

        let second = LiveTranscriptWriter(captureDirectory: captureDir)
        try second.open()
        XCTAssertEqual(second.nextSeq, 1, "the torn line was never a committed record")
        try second.append(record("two", 4_800, 9_600))
        try second.close()

        let read = LiveTranscriptReader.load(captureDirectory: captureDir).records
        XCTAssertEqual(read.map(\.text), ["one", "two"])
    }
```

### The seq-vs-undecodable-line regression — `LiveTranscriptStoreTests.swift:182-205`

```swift
    /// A complete-but-undecodable line still occupied a sequence number. Reusing it
    /// would put two records with the same `seq` in a file whose whole purpose is
    /// letting a reader notice one is missing.
    func testSeqDoesNotCollideWithAnUndecodableLine() throws {
        ...
        let second = LiveTranscriptWriter(captureDirectory: captureDir)
        try second.open()
        XCTAssertEqual(second.nextSeq, 2, "the garbage line consumed seq 1")
        try second.append(record("three", 9_600, 14_400))
        try second.close()

        let seqs = LiveTranscriptReader.load(captureDirectory: captureDir).records.map(\.seq)
        XCTAssertEqual(seqs, [0, 2])
        XCTAssertEqual(Set(seqs).count, seqs.count, "no duplicate sequence numbers")
    }
```

Other tests worth mirroring by name: `testAppendBeforeOpenThrows` (165), `testCloseIsIdempotent` (170), `testReopeningTwiceDoesNotLeakADescriptor` (219), `testAMultilineRecordThrowsRatherThanTrapping` (208), `testAnUndecodableInteriorLineIsSkippedNotFatal` (102).

### The unreadable-log tests — `LiveTranscriptIntegrityTests.swift:42-82`

Both use the `chmod 000` + `XCTSkipIf(isReadableFile)` idiom:

```swift
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: logURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                       ofItemAtPath: logURL.path) }
        try XCTSkipIf(FileManager.default.isReadableFile(atPath: logURL.path),
                      "running as root — permissions cannot be made to bite")

        let second = LiveTranscriptWriter(captureDirectory: captureDir)
        XCTAssertThrowsError(try second.open()) { error in
            guard case LiveTranscriptError.unreadableExistingLog = error else {
                return XCTFail("expected unreadableExistingLog, got \(error)")
            }
        }
```

and the tail-loss pair, `LiveTranscriptIntegrityTests.swift:86-112`:

```swift
    func testTailLossIsDetectedAgainstTheManifestCount() {
        XCTAssertEqual(LiveTranscriptReader.completeness(lines: 3, expected: 3), .complete)
        XCTAssertEqual(LiveTranscriptReader.completeness(lines: 2, expected: 3),
                       .truncated(missing: 1))
        // No `TranscriptRef` — the capture was killed, so a short tail is expected and
        // is not a defect. `seq` alone can never tell you this.
        XCTAssertEqual(LiveTranscriptReader.completeness(lines: 2, expected: nil), .unknown)
    }
```

---

## 9. Promotion, and reachability of committed runs

### "Promotion" today means two unrelated things

**(a) Audio file promotion** — `.m4a.part` → `.m4a` atomic rename. `/Users/nico/src/raconte/Raconte/Capture/FinalizerWorker.swift:141-143` and the private `promote(partURL:finalURL:dir:)` at line 272; the effect case is `.promoteFinalRecording` at `/Users/nico/src/raconte/Raconte/Capture/Effect.swift:101`, emitted from `CaptureMachine.swift:195`. Also `SegmentStore.swift:257`.

**(b) Hypothesis promotion** — volatile → committed, driven by `finalizedThroughFrame`. `/Users/nico/src/raconte/Raconte/Transcription/TranscriptConsolidator.swift:49` and the private `promote(through:)` at lines 68-81. This is in-memory only; the promoted result is then written as its own record by `TranscriptionSession.persist`.

**There is no transcript-file promotion.** No `.part` staging exists for `live.jsonl` — `LiveTranscriptStore.swift:39-41` states it explicitly ("There is no `.part` staging because there is no rewrite"), and `SegmentLayout.swift:106-107` repeats it. So there is no existing promotion step for a `markers.jsonl` to hook into.

### Are committed `TranscriptRun`s reachable outside `TranscriptionSession`?

Two answers:

**Live, in-memory: no, not usefully.** `TranscriptionSession` is an `actor` (`TranscriptionSession.swift:56`) and exposes at lines 152-155:

```swift
    var committedText: String { consolidator.committedText }
    var displayText: String { consolidator.displayText }
    var committed: [TranscriptResult] { consolidator.committed }
    var provisional: [TranscriptResult] { consolidator.provisional }
```

`committed` is `[TranscriptResult]`, and `TranscriptResult.runs` is `[TranscriptRun]` — so the runs *are* on the actor's public surface. But the session instance is `private var session: TranscriptionSession?` inside `LiveTranscriptionRun` (`LiveTranscription.swift:53`), and `LiveTranscriptionRun` re-exposes only `displayText: String` (line 58) and `isRunning` (line 59). `LiveTranscriptionCoordinator` exposes only `displayText`, `isRunning`, `lastCompletedText`, `activeCaptureID`. **No path from outside reaches `session.committed` today** — a snapping step would need a new accessor threaded through `LiveTranscriptionRun` and `LiveTranscriptionCoordinator`.

**Post-hoc, from disk: yes, fully.** `LiveTranscriptReader.load(captureDirectory:)` → `.records` → `LiveTranscriptReader.consolidate(_:)` → `TranscriptConsolidator.committed: [TranscriptResult]` (declared `private(set) var committed: [TranscriptResult] = []` at `TranscriptConsolidator.swift:18`), each carrying `.runs` with per-run optional `captureFrameStart`/`captureFrameEnd`. `EntryTranscriptLoader.load` already walks exactly this path but throws the runs away, taking only `.committedText`. That is the seam a frame-snapping step would use.

### Existing "marker" naming

`grep -i marker` across all Swift finds no domain type — only prose ("the marker" for `resultsFinalizationTime`, `TranscriptConsolidator.swift:61`, `TranscriptionEngine.swift:35`), two SwiftUI accessibility identifiers (`library.row.backdatedMarker` / `library.row.degradedMarker`, `LibraryView.swift:300,308`), and a `DEBUG-HARNESS-MOUNT` source marker. The name `MarkerLog` is unclaimed.