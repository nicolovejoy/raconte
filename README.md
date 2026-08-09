# Raconte

Private, single-user spoken-word journaling — native SwiftUI app for iOS 26 +
macOS 26. Built for reading decades of paper journals aloud: two-voice entries,
paper-page dates, word-level audio anchoring. No server, no accounts; iCloud
sync (private DB) arrives in M4.

**The one idea:** audio on disk is ground truth; the transcript — and every
other interpretation of it — is derived, replaceable, and can never overwrite
what a human did.

**Start here: [docs/overview.md](docs/overview.md)** — the current system in
plain words, with diagrams and links into the detailed design docs.

Native rebuild of [recountly](https://github.com/nicolovejoy/recountly)
(frozen; migrates in after M4). Milestone plan of record:
[docs/native-rebuild-plan.md](docs/native-rebuild-plan.md).

## Setup

```
brew install xcodegen
xcodegen generate
open Raconte.xcodeproj
```

The Xcode project is generated from `project.yml` and not checked in — rerun
`xcodegen generate` after every checkout that changes the file list.

## Test

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' test
```

UI tests run on the iOS simulator only (scheme `RaconteUI`).
