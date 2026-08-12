# TestFlight deploy (fully CLI)

Adopted from MusicForge's 2026-08-10 recipe (handoff channel). No Xcode GUI needed after
the one-time setup below. Signing assets are TEAM-scoped (8UK463WB83) and shared with
MusicForge.

## Per-release pipeline

Bump `CFBundleVersion` in `Raconte/Info.plist` (must be unique per upload; bump
`CFBundleShortVersionString` for real releases), run the suite, then:

```bash
xcodegen generate
xcodebuild archive -project Raconte.xcodeproj -scheme Raconte \
  -destination 'generic/platform=iOS' \
  -archivePath /tmp/Raconte-$(date +%Y%m%d%H%M).xcarchive \
  -allowProvisioningUpdates
xcodebuild -exportArchive -archivePath <that .xcarchive> \
  -exportOptionsPlist scripts/ExportOptions.plist \
  -authenticationKeyPath ~/.appstoreconnect/private_keys/AuthKey_5CFXBJT3G9.p8 \
  -authenticationKeyID 5CFXBJT3G9 \
  -authenticationKeyIssuerID 75fc3ac1-a302-4c0d-8683-c20fc8d6d495
```

Success prints `Uploaded Raconte`. Internal testers get the build after Apple-side
processing (minutes); no Beta Review for internal.

## One-time assets (done 2026-08-12)

- Bundle ID registered: `org.pianohouseproject.raconte` (resource `KJ4D33V27R`) — dev
  builds had been riding the team's XC Wildcard App ID, which cannot ship to the store.
- Provisioning profile `raconte appstore` (`78D2Z6JR83`, IOS_APP_STORE), minted via
  `POST /v1/profiles` against distribution cert `89FGBW89NS`, installed at
  `~/Library/Developer/Xcode/UserData/Provisioning Profiles/` and
  `~/Library/MobileDevice/Provisioning Profiles/`.
- ASC API key: `~/.appstoreconnect/private_keys/AuthKey_5CFXBJT3G9.p8` (Key ID
  `5CFXBJT3G9`, Issuer `75fc3ac1-a302-4c0d-8683-c20fc8d6d495`, App Manager). Pass the
  PATH to tools; never print its contents.
- App Store Connect app record: **created manually in the web UI** (the one step the
  public API cannot do).

## Known traps

- Cloud signing does not work with API keys ("Cloud signing permission error") — that is
  why `signingStyle` is `manual`. Do not chase it.
- The Apple Distribution cert expires **2027-08-10**. Renewal is four clicks in Xcode →
  Settings → Accounts → Manage Certificates (Nico), after which the provisioning profile
  must be RECREATED against the new cert (POST /v1/profiles again) — a stale profile
  fails the export with a signing error.
- When the app gains iCloud (M4), the bundle ID needs the iCloud capability added and
  the profile regenerated, or the export fails on entitlements.
- Release archives can hit swift-frontend optimizer crashes that Debug + tests never see
  (MusicForge: the 6.3.3 EarlyPerfInliner segfault on a synthesized MainActor deinit of a
  generic class; workaround `@_optimize(none) deinit {}`). If the archive fails with
  "Command SwiftCompile failed" and no diagnostic, search the full log for "Stack dump" —
  it names the exact function.
- Never pipe `xcodebuild` through `head`/`tail` for the authoritative result — check the
  exit code, or `xcrun xcresulttool get test-results summary --path <.xcresult>`.
