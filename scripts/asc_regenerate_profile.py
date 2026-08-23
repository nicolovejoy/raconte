#!/usr/bin/env python3
"""Regenerate a Raconte App Store provisioning profile via the App Store
Connect API. Run this yourself in your own terminal — it reads the ASC
private key from disk, which Claude Code is (correctly) blocked from doing.

Needs: pip install pyjwt cryptography  (already present on this machine)

Usage:
    python3 scripts/asc_regenerate_profile.py --platform ios
    python3 scripts/asc_regenerate_profile.py --platform macos
"""
import argparse
import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

import jwt

KEY_ID = os.environ.get("ASC_KEY_ID", "K3MNF85G68")
KEY_PATH = os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{KEY_ID}.p8")
ISSUER_ID_PATH = os.path.expanduser("~/.appstoreconnect/issuer_id")

BUNDLE_ID_IDENTIFIER = "org.pianohouseproject.raconte"

PLATFORMS = {
    "ios": {
        "profile_name": "raconte appstore",
        "profile_type": "IOS_APP_STORE",
        "filename_prefix": "raconte_appstore",
        "stale_filenames": ["raconte_appstore_78D2Z6JR83.mobileprovision"],
        "archive_path": os.path.expanduser(
            "~/Library/Developer/Xcode/Archives/2026-08-23/Raconte-ios-tf1.xcarchive"
        ),
        "export_options": "scripts/ExportOptions.plist",
    },
    "macos": {
        "profile_name": "raconte appstore macos",
        "profile_type": "MAC_APP_STORE",
        "filename_prefix": "raconte_appstore_macos",
        "stale_filenames": [],
        "archive_path": os.path.expanduser(
            "~/Library/Developer/Xcode/Archives/2026-08-23/Raconte-macos-tf1.xcarchive"
        ),
        "export_options": "scripts/ExportOptions-macos.plist",
    },
}

PROFILE_DIRS = [
    os.path.expanduser("~/Library/MobileDevice/Provisioning Profiles"),
    os.path.expanduser("~/Library/Developer/Xcode/UserData/Provisioning Profiles"),
]


def make_token():
    with open(KEY_PATH) as f:
        private_key = f.read()
    with open(ISSUER_ID_PATH) as f:
        issuer_id = f.read().strip()
    now = int(time.time())
    payload = {"iss": issuer_id, "iat": now, "exp": now + 19 * 60, "aud": "appstoreconnect-v1"}
    headers = {"kid": KEY_ID, "typ": "JWT"}
    return jwt.encode(payload, private_key, algorithm="ES256", headers=headers)


def call(method, path, body=None):
    token = make_token()
    url = f"https://api.appstoreconnect.apple.com{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    if data:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read()
        return e.code, (json.loads(raw) if raw else {"raw_error": raw.decode(errors="replace")})


def die(msg, detail=None):
    print(f"FAILED: {msg}", file=sys.stderr)
    if detail is not None:
        print(json.dumps(detail, indent=2), file=sys.stderr)
    sys.exit(1)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--platform", choices=PLATFORMS.keys(), default="ios")
    args = parser.parse_args()
    cfg = PLATFORMS[args.platform]
    profile_name = cfg["profile_name"]

    if not os.path.exists(KEY_PATH):
        die(f"key not found at {KEY_PATH} (set ASC_KEY_ID env var if it's named differently)")
    if not os.path.exists(ISSUER_ID_PATH):
        die(f"issuer id not found at {ISSUER_ID_PATH}")

    print(f"Platform: {args.platform} ({cfg['profile_type']})")
    print(f"Using key {KEY_ID}")

    # 1. Resolve the bundle ID resource.
    status, body = call("GET", f"/v1/bundleIds?filter[identifier]={BUNDLE_ID_IDENTIFIER}")
    if status != 200 or not body.get("data"):
        die("could not resolve bundle ID", body)
    bundle_id_resource = body["data"][0]["id"]
    print(f"Bundle ID resource: {bundle_id_resource}")

    # 2. Confirm the bundle ID has the iCloud capability enabled (informational).
    status, caps = call("GET", f"/v1/bundleIds/{bundle_id_resource}/bundleIdCapabilities")
    cap_types = [c["attributes"]["capabilityType"] for c in caps.get("data", [])]
    print(f"Enabled capabilities: {cap_types}")
    if not any("ICLOUD" in c for c in cap_types):
        print("WARNING: no ICLOUD capability found on the App ID — profile will lack iCloud entitlements.")

    # 3. Find the current (non-expired) Apple Distribution certificate. The unified
    # "Apple Distribution" cert (type DISTRIBUTION) covers iOS, macOS, and Mac
    # Catalyst App Store distribution — same cert works for both platforms here.
    status, certs = call("GET", "/v1/certificates?limit=200")
    if status != 200:
        die("could not list certificates", certs)
    dist_certs = [
        c for c in certs.get("data", [])
        if "DISTRIBUTION" in c["attributes"]["certificateType"]
    ]
    if not dist_certs:
        die("no distribution-type certificates found", certs)
    certs_sorted = sorted(
        dist_certs, key=lambda c: c["attributes"]["expirationDate"], reverse=True
    )
    cert = certs_sorted[0]
    cert_id = cert["id"]
    print(
        f"Using certificate: {cert_id} type={cert['attributes']['certificateType']} "
        f"expires {cert['attributes']['expirationDate']}"
    )

    # 4. Delete any existing profile(s) with this exact name — profile names are
    # unique account-wide (not just per bundle ID). Filter by name and paginate.
    to_delete = []
    next_path = f"/v1/profiles?filter[name]={profile_name.replace(' ', '%20')}&limit=200"
    while next_path:
        status, page = call("GET", next_path)
        if status != 200:
            die("could not list profiles by name", page)
        to_delete.extend(page.get("data", []))
        next_link = page.get("links", {}).get("next")
        next_path = next_link.replace("https://api.appstoreconnect.apple.com", "") if next_link else None

    if not to_delete:
        print(f"No existing profiles found named '{profile_name}'.")
    for p in to_delete:
        print(
            f"Found existing profile {p['id']} name={p['attributes']['name']!r} "
            f"type={p['attributes']['profileType']} state={p['attributes']['profileState']}"
        )
        del_status, del_body = call("DELETE", f"/v1/profiles/{p['id']}")
        if del_status not in (204, 200):
            die(f"failed to delete profile {p['id']}", del_body)
        print(f"Deleted profile {p['id']} (status {del_status})")

    # 5. Create the new profile.
    payload = {
        "data": {
            "type": "profiles",
            "attributes": {"name": profile_name, "profileType": cfg["profile_type"]},
            "relationships": {
                "bundleId": {"data": {"type": "bundleIds", "id": bundle_id_resource}},
                "certificates": {"data": [{"type": "certificates", "id": cert_id}]},
            },
        }
    }
    status, result = call("POST", "/v1/profiles", payload)
    if status != 201:
        die("profile creation failed", result)

    attrs = result["data"]["attributes"]
    profile_uuid = attrs["uuid"]
    profile_content_b64 = attrs["profileContent"]
    expiration = attrs["expirationDate"]
    print(f"Created profile {profile_uuid}, expires {expiration}")

    # 6. Install it, removing any stale file for this platform from both directories.
    new_filename = f"{cfg['filename_prefix']}_{profile_uuid}.mobileprovision"
    content = base64.b64decode(profile_content_b64)
    for d in PROFILE_DIRS:
        os.makedirs(d, exist_ok=True)
        for stale_name in cfg["stale_filenames"]:
            stale_path = os.path.join(d, stale_name)
            if os.path.exists(stale_path):
                os.remove(stale_path)
                print(f"Removed stale {stale_path}")
        new_path = os.path.join(d, new_filename)
        with open(new_path, "wb") as f:
            f.write(content)
        print(f"Installed {new_path}")

    # 7. Sanity-check entitlements on the freshly installed profile (no secret material involved).
    check_path = os.path.join(PROFILE_DIRS[0], new_filename)
    decoded = subprocess.run(
        ["security", "cms", "-D", "-i", check_path], capture_output=True, text=True
    ).stdout
    if "icloud" in decoded.lower():
        print("Confirmed: new profile includes iCloud entitlements.")
    else:
        print("WARNING: new profile does NOT appear to include iCloud entitlements — check manually.")

    print("\nDone. Re-run the export step:")
    print(
        f"xcodebuild -exportArchive "
        f"-archivePath {cfg['archive_path']} "
        f"-exportOptionsPlist {cfg['export_options']} "
        f'-authenticationKeyPath "{KEY_PATH}" '
        f'-authenticationKeyID "{KEY_ID}" '
        '-authenticationKeyIssuerID "$(cat ~/.appstoreconnect/issuer_id)"'
    )


if __name__ == "__main__":
    main()
