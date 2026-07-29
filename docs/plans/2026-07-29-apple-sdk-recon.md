# Apple SDK recon for native rebuild (2026-07-29)

Machine: Xcode 26.6 (build 17F113). SDKs confirmed via `xcrun --show-sdk-path`:
`iPhoneOS26.5.sdk`, `MacOSX26.5.sdk` (both report SDK version 26.5).
Method: grepped installed `.swiftinterface`/headers directly, no memory-based claims.
GRDB checked live via `gh api repos/groue/GRDB.swift/...` (network available).

## 1. SpeechAnalyzer / SpeechTranscriber — VERIFIED

File (identical content parked under both platform SDKs — Speech is a single shared
Swift overlay):
`/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.5.sdk/System/Library/Frameworks/Speech.framework/Modules/Speech.swiftmodule/arm64e-apple-ios.swiftinterface`
macOS variant: `.../MacOSX26.5.sdk/System/Library/Frameworks/Speech.framework/Versions/A/Modules/Speech.swiftmodule/arm64e-apple-macos.swiftinterface` (same API surface).

Top-of-file availability banner (line 10-11):
`@available(macOS 26.0, iOS 26.0, visionOS 26.0, tvOS 26.0, *)` / `@available(watchOS, unavailable)`
— every SpeechAnalyzer/SpeechTranscriber/AssetInventory type carries this same
26.0/26.0 floor on both platforms. No iOS-only or macOS-only gap.

Types confirmed present, with exact signatures:

- `final public actor SpeechAnalyzer : Swift.Sendable` (line 207). Init options:
  - `init(modules:options:)` — push-model, call `.start(inputSequence:)` yourself.
  - `init(inputSequence:modules:options:analysisContext:volatileRangeChangedHandler:)`
    — pull-model over an `AsyncSequence<AnalyzerInput>`.
  - `init(inputAudioFile:modules:options:analysisContext:finishAfterFile:volatileRangeChangedHandler:)` (line 329, `async throws`) — file-based one-shot.
  - Lifecycle: `prepareToAnalyze(in:)`, `start(inputSequence:)`,
    `analyzeSequence(_:) async throws -> CMTime?`,
    `finalize(through:)`, `finalizeAndFinishThroughEndOfInput()`,
    `finalizeAndFinish(through:)`, `finish(after:)`, `cancelAnalysis(before:)`,
    `cancelAndFinishNow()`.
  - `volatileRange: CMTimeRange?` + `setVolatileRangeChangedHandler(_:)` — this is the
    "volatile vs finalized" boundary the plan calls for; ranges are `CMTimeRange`/`CMTime`
    (audio-time-indexed, matches "time-indexed" requirement).
  - `AnalyzerInput` (line 243): `init(buffer: AVAudioPCMBuffer)` or
    `init(buffer:bufferStartTime: CMTime?)` — feeds straight from an AVAudioEngine tap
    buffer.

- `final public class SpeechTranscriber : SpeechModule, LocaleDependentSpeechModule`
  (line 335):
  - `init(locale:preset:)` with presets: `.transcription`,
    `.transcriptionWithAlternatives`, `.timeIndexedTranscriptionWithAlternatives`,
    `.progressiveTranscription`, `.timeIndexedProgressiveTranscription` — confirms
    both "progressive" (streaming/volatile) and "time-indexed" modes exist as named
    presets, not something to hand-roll.
  - `results: some Sendable & AsyncSequence<SpeechTranscriber.Result, any Error>` — the
    streaming surface; iterate with `for try await result in transcriber.results`.
  - `Result` struct (line 418): `range: CMTimeRange`, `resultsFinalizationTime: CMTime`,
    `text: AttributedString` (computed), `alternatives: [AttributedString]`. Text comes
    back as `AttributedString`, not plain `String` — run attributes likely carry
    per-word/segment timing (worth a deeper look at attribute keys when coding M2, not
    blocking — the type existing is what this recon needed to confirm).

- `AssetInventory` (line 12): `static func status(forModules:) async`,
  `assetInstallationRequest(supporting:) async throws -> AssetInstallationRequest?`,
  `reserve(locale:) async throws -> Bool`, `reservedLocales`, `maximumReservedLocales`
  — on-device model asset management, matches "no network" requirement.

Minimal usage shape (derived directly from the interface, not memory):
```swift
let transcriber = SpeechTranscriber(locale: Locale(identifier: "en-US"),
                                     preset: .timeIndexedProgressiveTranscription)
let analyzer = SpeechAnalyzer(modules: [transcriber])
try await analyzer.start(inputSequence: audioInputSequence) // AsyncSequence<AnalyzerInput>
for try await result in transcriber.results {
    // result.range: CMTimeRange, result.text: AttributedString
    // analyzer.volatileRange tells you what's still hypothesis vs settled
}
try await analyzer.finalizeAndFinishThroughEndOfInput()
```

**Verdict: VERIFIED.** Type/API shape matches the plan's "volatile + finalized
streaming, time-indexed, no network" description exactly. iOS 26.0/macOS 26.0 floor
confirmed identical on both platform SDKs — no cross-platform gap for M2.

## 2. CKSyncEngine — VERIFIED

Header: `CloudKit.framework/Headers/CKSyncEngine.h` present on both SDKs (iOS path:
`.../iPhoneOS26.5.sdk/System/Library/Frameworks/CloudKit.framework/Headers/CKSyncEngine.h`;
macOS: `.../MacOSX26.5.sdk/.../CloudKit.framework/Versions/A/Headers/CKSyncEngine.h`,
byte-identical availability macros).

`API_AVAILABLE(macos(14.0), ios(17.0), tvos(17.0), watchos(10.0))` on the `@interface
CKSyncEngine : NSObject` declaration (line 107) and every nested type
(`CKSyncEngineFetchChangesOptions`, `CKSyncEngineFetchChangesScope`,
`CKSyncEngineSendChangesOptions`, delegate protocol, etc.) — all gated at the same
floor. One narrower spot: `CKSyncEngineFetchChangesScope.containsZoneID:` is
`API_AVAILABLE(macos(14.2), ..., ios(17.2), ...)` (line 342) — a 14.2/17.2 bump within
the same era, irrelevant given the iOS-26/macOS-26 target.

Swift overlay confirms the same shape (`CloudKit.swiftmodule/arm64e-apple-ios.swiftinterface`,
line 1214): `final public class CKSyncEngine : Swift.Sendable`, `init(_ configuration:)`,
`state: CKSyncEngine.State`, `fetchChanges(_:) async throws`,
`sendChanges(_:) async throws`, `CKSyncEngineDelegate` with
`handleEvent(_:syncEngine:) async` and `nextRecordZoneChangeBatch(_:syncEngine:) async`.

**Verdict: VERIFIED.** Min OS macOS 14.0 / iOS 17.0 — well below the iOS-26/macOS-26
target, so no availability risk at all for this plan.

## 3. AVAudioEngine / AVAudioSession / mic permissions — VERIFIED, with the macOS caveat the plan already assumes

- **iOS AVAudioSession**: `AVFAudio.framework/Headers/AVAudioSession.h` — class-level
  annotation `API_AVAILABLE(ios(3.0), watchos(2.0), tvos(9.0)) API_UNAVAILABLE(macos)`
  (line 28). Confirmed unchanged: category `.playAndRecord` (`AVAudioSessionCategoryPlayAndRecord`)
  still present, same header text, same `API_UNAVAILABLE(macos)` stance — nothing
  changed in iOS 26. Same header file is physically present but functionally inert on
  macOS (Apple ships one shared header; every symbol keeps `API_UNAVAILABLE(macos)`
  in the macOS copy too — confirmed by diffing the same grep against the macOS SDK
  path, identical output).
- **AVAudioEngine / AVAudioNode.installTapOnBus:bufferSize:format:block:** — present
  and available on both platforms: `API_AVAILABLE(macos(10.13), ios(11.0), watchos(4.0),
  tvos(11.0))` on the engine class, tap method unconditionally available in
  `AVAudioNode.h`. No iOS-26-specific change found; API is over a decade stable.
- **macOS mic capture replacement**: confirmed AVAudioSession is a no-op stub on
  macOS (`API_UNAVAILABLE`), so the plan's own framing ("AVAudioEngine directly" on
  macOS, no AVAudioSession category dance) is the only path — there is no
  AVAudioSession-equivalent session object to configure on macOS; permission is via
  TCC (mic usage prompt keyed off `NSMicrophoneUsageDescription` in Info.plist) plus,
  for a sandboxed Mac app, the `com.apple.security.device.audio-input` entitlement.
  These two keys are Info.plist/entitlements metadata, not SDK header symbols, so they
  don't grep out of the SDK itself — noted as **UNCERTAIN (not SDK-verifiable, but
  standard/well-documented Apple keys, unchanged across OS versions)**. Recommend
  confirming exact wording against a fresh Xcode-generated entitlements file at
  scaffold time rather than trusting memory.
- **iOS background recording**: plan calls for `UIBackgroundModes: audio` — this is
  an Info.plist key, same caveat as above (not grep-verifiable in SDK headers).
  Marked **UNCERTAIN (not SDK-verifiable)**, unchanged mechanism historically.

**Verdict: VERIFIED** for the framework/API-availability questions (nothing changed
iOS 26 vs prior; macOS truly has no AVAudioSession). Plist/entitlement key names are
**UNCERTAIN** by this recon's method (SDK header grep can't see Info.plist schemas) —
low risk, standard Apple constants, confirm at scaffold time.

## 4. SQLite FTS5 + GRDB — VERIFIED

- **OS-bundled sqlite3 CLI** (`/usr/bin/sqlite3`, this machine): version
  `3.51.0 2025-06-12`. `pragma compile_options;` output includes `ENABLE_FTS5` (also
  FTS3/FTS4) — confirmed via direct run, not memory.
- **macOS SDK's `sqlite3.h`**
  (`MacOSX26.5.sdk/usr/include/sqlite3.h`) declares `fts5_api` struct and
  `SQLITE_ENABLE_FTS5`-gated symbols directly in the header (lines ~11383-11620) —
  confirms the system library was built with FTS5 support compiled in.
- **GRDB is irrelevant to the system SQLite question anyway**: GRDB vendors its own
  SQLite amalgamation and explicitly defines `SQLITE_ENABLE_FTS5` itself in
  `Package.swift` (`swiftSettings: [.define("SQLITE_ENABLE_FTS5"), ...]`, confirmed via
  `gh api repos/groue/GRDB.swift/contents/Package.swift`) — so FTS5 availability
  doesn't depend on the OS-bundled library at all when using GRDB's default
  `GRDBSQLite` target, only if you deliberately link system SQLite instead.
- **GRDB version**: latest release `v7.11.1`, published 2026-06-18 (verified via
  `gh api repos/groue/GRDB.swift/releases`, not WebFetch summarization — a first
  WebFetch pass through a small summarizer model returned garbled/wrong dates,
  e.g. a nonsensical 2016 entry; discard that path, use `gh api` directly for GitHub
  data).
- **Swift 6 / concurrency**: `Package.swift` declares
  `// swift-tools-version:6.1`. Release notes for v7.9.0 (2025-12-13) state explicitly:
  *"BREAKING CHANGE: ... The library requirements are raised to Swift 6.1+, Xcode
  16.3+."* This machine runs Xcode 26.6, far above that floor. `platforms:` in
  Package.swift require iOS 13 / macOS 10.15 minimum (library's own floor, not a
  ceiling) — no conflict with an iOS-26/macOS-26 target app.

**Verdict: VERIFIED.** FTS5 available both via system SQLite and (independently,
more reliably) via GRDB's bundled SQLite build. GRDB v7.11.1 requires Swift 6.1+/Xcode
16.3+, satisfied.

## 5. AVAssetWriter / AVAudioConverter (PCM→AAC-LC) — VERIFIED

- **AVAssetWriter**: `AVFoundation.framework/Headers/AVAssetWriter.h`, class annotation
  `API_AVAILABLE(macos(10.7), ios(4.1), tvos(9.0), visionos(1.0)) API_UNAVAILABLE(watchos)`
  (line 65) — available on both target platforms, has been for well over a decade.
  Byte-identical header/availability on both SDKs (confirmed by diffing grep output).
- **AVAudioConverter**: `AVFAudio.framework/Headers/AVAudioConverter.h`, class
  available since `API_AVAILABLE(macos(10.11), ios(9.0), watchos(2.0), tvos(9.0))`
  (line 162). New in iOS 26/macOS 26 specifically: `audioSyncPacketFrequency`,
  `contentSource`, `dynamicRangeControlConfiguration` properties, all gated
  `API_AVAILABLE(macos(26.0), ios(26.0), ...)` — additive-only, doesn't affect a
  basic PCM→AAC-LC conversion path.
- **AAC-LC constant**: `kAudioFormatMPEG4AAC` confirmed present in
  `CoreAudioTypes.framework/Headers/CoreAudioBaseTypes.h` on the iOS SDK (standard
  `AudioFormatID`, used with `AVAudioConverter`/`AVAssetWriter` output settings to get
  AAC-LC, as opposed to `kAudioFormatMPEG4AAC_HE` etc. for HE-AAC).

**Verdict: VERIFIED.** Both encode paths (AVAssetWriter with an AAC output
`AVAssetWriterInput`, or AVAudioConverter PCM buffer → AAC packet) are available,
unchanged in essentials for iOS 26/macOS 26, on both platforms.

## Summary table

| # | Item | Status |
|---|------|--------|
| 1 | SpeechAnalyzer/SpeechTranscriber | VERIFIED — iOS 26.0/macOS 26.0 floor, identical API both platforms |
| 2 | CKSyncEngine | VERIFIED — macOS 14.0/iOS 17.0 floor, no risk |
| 3a | AVAudioEngine tap (iOS+macOS) | VERIFIED — unchanged |
| 3b | AVAudioSession category/background (iOS) | VERIFIED — unchanged |
| 3c | AVAudioSession unavailable on macOS | VERIFIED — confirmed still `API_UNAVAILABLE(macos)` |
| 3d | Info.plist/entitlement key names (NSMicrophoneUsageDescription, UIBackgroundModes=audio, com.apple.security.device.audio-input) | UNCERTAIN — not SDK-header-verifiable by this method; standard/stable keys, confirm at scaffold time |
| 4 | SQLite FTS5 (system + GRDB-bundled) | VERIFIED |
| 4b | GRDB version + Swift 6 compat | VERIFIED — v7.11.1, swift-tools-version 6.1 |
| 5 | AVAssetWriter/AVAudioConverter PCM→AAC-LC | VERIFIED |
