#!/bin/bash
# Headless iOS TestFlight upload: archive + export-with-upload in one go.
# Recipe cribbed from MusicForge (see ~/src/.handoff/musicforge-raconte.md):
# raw xcodebuild, ASC API key for the upload leg, Xcode GUI account for the
# archive leg (-allowProvisioningUpdates cannot cloud-sign with an API key).
#
# Usage: scripts/upload_testflight.sh [ios|macos]   (default: ios)
# Env:   ASC_KEY_ID overrides the key id (default matches asc_regenerate_profile.py)
# macOS additionally needs a "3rd Party Mac Developer Installer" identity in the
# login keychain (created 2026-08-25 via the ASC API) — the Mac App Store leg
# signs a .pkg, which the Apple Distribution cert alone cannot do.
set -euo pipefail
cd "$(dirname "$0")/.."

PLATFORM="${1:-ios}"
case "$PLATFORM" in
  ios)   DESTINATION='generic/platform=iOS';   EXPORT_PLIST=scripts/ExportOptions.plist ;;
  macos) DESTINATION='generic/platform=macOS'; EXPORT_PLIST=scripts/ExportOptions-macos.plist ;;
  *) echo "FAILED: unknown platform '$PLATFORM' (ios|macos)" >&2; exit 1 ;;
esac

KEY_ID="${ASC_KEY_ID:-K3MNF85G68}"
KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8"
ISSUER_FILE="$HOME/.appstoreconnect/issuer_id"
BUILD="$(sed -n 's/.*CFBundleVersion: "\(.*\)".*/\1/p' project.yml | head -1)"
ARCHIVE="$HOME/Library/Developer/Xcode/Archives/raconte-cli/Raconte-${PLATFORM}-build${BUILD}.xcarchive"

[ -f "$KEY_PATH" ] || { echo "FAILED: ASC key not found at $KEY_PATH (set ASC_KEY_ID)" >&2; exit 1; }
[ -f "$ISSUER_FILE" ] || { echo "FAILED: issuer id file not found at $ISSUER_FILE" >&2; exit 1; }
[ -n "$BUILD" ] || { echo "FAILED: could not read CFBundleVersion from project.yml" >&2; exit 1; }

echo "== Archiving build $BUILD ($PLATFORM) -> $ARCHIVE"
if [ -d "$ARCHIVE" ]; then
  echo "== Archive already exists, skipping archive step"
else
  xcodebuild archive -project Raconte.xcodeproj -scheme Raconte \
    -destination "$DESTINATION" \
    -archivePath "$ARCHIVE" \
    -allowProvisioningUpdates
fi

echo "== Exporting + uploading to App Store Connect"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$EXPORT_PLIST" \
  -authenticationKeyPath "$KEY_PATH" \
  -authenticationKeyID "$KEY_ID" \
  -authenticationKeyIssuerID "$(cat "$ISSUER_FILE")"

echo "== Done: build $BUILD ($PLATFORM) uploaded (watch App Store Connect for processing)"
