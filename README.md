# Raconte

Private, single-user spoken-word journaling — native SwiftUI app for iOS 26 + macOS 26.
Audio is ground truth; transcripts are derived on-device. No server.

Native rebuild of [recountly](https://github.com/nicolovejoy/recountly). Plan of record:
`docs/native-rebuild-plan.md`.

## Setup

```
brew install xcodegen
xcodegen generate
open Raconte.xcodeproj
```

The Xcode project is generated from `project.yml` and not checked in.
