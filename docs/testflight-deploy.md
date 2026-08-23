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
# Key ID is fixed (see One-time assets) — do NOT auto-discover via `ls
# AuthKey_*.p8 | head -1`, MusicForge's shared team key now sits in the same
# directory and sorts first alphabetically, which will silently authenticate
# as the wrong app-scoped key and fail. Issuer ID is account-wide, from the
# untracked sibling file.
ASC_KEY_ID="K3MNF85G68"
ASC_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"
ASC_ISSUER_ID="$(cat ~/.appstoreconnect/issuer_id)"
xcodebuild -exportArchive -archivePath <that .xcarchive> \
  -exportOptionsPlist scripts/ExportOptions.plist \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"
```

Success prints `Uploaded Raconte`. Internal testers get the build after Apple-side
processing (minutes); no Beta Review for internal.

If the provisioning profile is stale (e.g. after adding a capability like iCloud), run
`python3 scripts/asc_regenerate_profile.py --platform ios` (or `--platform macos`) first —
it deletes and recreates the named profile via the ASC API and prints the export command
above with the right paths filled in. Must be run by a human, not an agent — it reads the
`.p8` key, which Claude Code is intentionally blocked from doing.

## One-time assets (done 2026-08-12, key rotated 2026-08-23)

- Bundle ID registered: `org.pianohouseproject.raconte` (resource `KJ4D33V27R`) — dev
  builds had been riding the team's XC Wildcard App ID, which cannot ship to the store.
- Provisioning profile `raconte appstore` (IOS_APP_STORE) and `raconte appstore macos`
  (MAC_APP_STORE), both minted via `POST /v1/profiles` against distribution cert
  `89FGBW89NS`, installed at `~/Library/Developer/Xcode/UserData/Provisioning Profiles/`
  and `~/Library/MobileDevice/Provisioning Profiles/`. Regenerate either with
  `scripts/asc_regenerate_profile.py` (see above) — profile names are unique
  **account-wide**, not just per bundle ID, so the script deletes-then-recreates by name
  rather than assuming none exists.
- ASC API key: `AuthKey_K3MNF85G68.p8` under `~/.appstoreconnect/private_keys/`, App
  Manager role, **scoped to Raconte Journal only** (not team-wide — ASC's per-app access
  restriction meant MusicForge's original shared key, `AuthKey_5CFXBJT3G9.p8`, could not
  be edited to add Raconte access, only revoked, so this app got its own key instead; both
  files now coexist in the same directory, do not delete either). The Key ID is the
  filename; the Issuer ID lives in the untracked sibling `~/.appstoreconnect/issuer_id`
  (one line, account-wide, shared across all keys — from ASC → Users and Access →
  Integrations page, or 1Password vault `dev-secrets`). Key ID and Issuer ID are the
  PUBLIC half of the credential — still keep them out of this repo. Pass the key PATH to
  tools; never print its contents.
- Certificate type filter: query ASC certificates by type containing `DISTRIBUTION`, not
  the legacy `IOS_DISTRIBUTION` (that enum value no longer exists — Apple unified iOS/
  macOS/Catalyst distribution into one `DISTRIBUTION`-typed "Apple Distribution" cert
  around 2019). The same cert (`89FGBW89NS`) signs both the iOS and macOS App Store
  profiles.
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
