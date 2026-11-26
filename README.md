# Raconte

Private, single-user spoken-word journaling: a native SwiftUI app for iOS 26 and
macOS 26. Built for reading decades of paper journals aloud, with two-voice
entries, paper-page dates and word-level audio anchoring. No server and no
accounts. Sync runs through the owner's private iCloud database.

**The one idea:** audio on disk is ground truth. The transcript, and every other
interpretation of it, is derived and replaceable, and can never overwrite what a
human did.

**Start here: [docs/overview.md](docs/overview.md)**, the current system in
plain words, with diagrams and links into the detailed design docs.

## Status

In daily use by its one user, on iPhone and Mac, through TestFlight. It is not
on the App Store. Capture, on-device transcription, journals and library, the
revision chain, the editor, iCloud sync, export and full-text search are built.
[docs/builds.md](docs/builds.md) lists every build handed over.

Raconte is a native rebuild of
[recountly](https://github.com/nicolovejoy/recountly), a web app that is now
frozen. The plan of record is
[docs/native-rebuild-plan.md](docs/native-rebuild-plan.md).

## How it is built

The stack is SwiftUI (one multiplatform target, not Catalyst), Swift 6 strict
concurrency, on-device `SpeechAnalyzer` transcription, GRDB/SQLite with FTS5,
and `CKSyncEngine` to a CloudKit private database.

The app is written with Claude Code, one planned task at a time, and the working
notes are in the repo on purpose:

- [CLAUDE.md](CLAUDE.md) holds the project conventions and the traps found
  along the way.
- [docs/plans/](docs/plans/) holds the design and implementation plan for each
  milestone.
- [docs/devlog.md](docs/devlog.md) is the session-by-session history.

## Setup

```
brew install xcodegen
xcodegen generate
open Raconte.xcodeproj
```

The Xcode project is generated from `project.yml` and not checked in. Rerun
`xcodegen generate` after every checkout that changes the file list.

Signing uses the owner's team. To run it yourself, set your own team and bundle
id in `project.yml`.

## Test

Unit tests run on macOS. The override signs ad hoc without the iCloud
entitlements and keeps the sandbox:

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS="$PWD/Raconte/Raconte-nocloud.entitlements" test
```

UI tests run on the iOS simulator only:

```
xcodebuild -project Raconte.xcodeproj -scheme RaconteUI -destination 'platform=iOS Simulator,name=iPhone 17' test
```

## Rights

The source is public to read. No license is granted: all rights reserved,
© Nico Lovejoy.
