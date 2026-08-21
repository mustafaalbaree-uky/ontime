#!/bin/bash
#
# Rebuilds and reinstalls OnTime to the connected iPhone, then resets the expiry
# clock. Same shape as the ClipKeyboard reinstall script, because it is the
# same free Apple ID and the same seven day provisioning limit.
#
# Phone must be plugged in and unlocked.
#
set -euo pipefail

DIR="/Users/mustafaalbaree/Code/ontime"
STATE="$HOME/.ontime"

cd "$DIR"

echo "==> Generating project"
xcodegen generate >/dev/null

# xcodebuild wants the hardware UDID, while `devicectl list devices` prints a
# different CoreDevice UUID that xcodebuild will reject. Ask xcodebuild itself
# rather than hardcoding either one.
echo "==> Looking for a connected iPhone"
# `|| true` matters: with `set -e` and `pipefail`, a grep that matches nothing
# returns 1 and would abort the script before it could explain why.
DEVICE_ID=$( { xcodebuild -project OnTime.xcodeproj -scheme OnTime -showdestinations 2>/dev/null \
  | grep "platform:iOS," | grep -v placeholder \
  | sed -n 's/.*id:\([^,}]*\).*/\1/p' | head -1 | tr -d ' '; } || true )

if [ -z "$DEVICE_ID" ]; then
  echo
  echo "No iPhone available to build for."
  echo "  1. Plug the phone in with a cable."
  echo "  2. Unlock it, and tap Trust if asked."
  echo "  3. Rerun this script."
  echo
  echo "Currently visible devices:"
  xcrun devicectl list devices 2>/dev/null | grep -i iphone || echo "  (none)"
  exit 1
fi
echo "    using $DEVICE_ID"

# Xcode reuses an existing provisioning profile whenever it is still valid, so
# a rebuild does NOT restart the seven day clock — the clock keeps running from
# whenever the profile was first issued. That is what bit ClipKeyboard on
# 11 Aug 2026: profiles issued 4 Aug were reused by the 8 Aug rebuild and died
# on schedule three days later, while PhoneDeck still showed four days left
# because it was counting from the install date. Deleting our own profiles
# first forces -allowProvisioningUpdates to mint new ones, so "reinstalled
# today" and "seven days left" actually mean the same thing.
echo "==> Clearing old provisioning profiles"
PROFILE_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
BUNDLE_ID="com.mammer55.ontime"
if [ -d "$PROFILE_DIR" ]; then
  for prof in "$PROFILE_DIR"/*.mobileprovision; do
    [ -e "$prof" ] || continue
    appid=$( { security cms -D -i "$prof" 2>/dev/null \
      | plutil -extract Entitlements.application-identifier raw - 2>/dev/null; } || true )
    # appid looks like TEAMID.com.example.app — match the app itself and
    # anything nested under it (extensions), nothing else.
    case "$appid" in
      *".$BUNDLE_ID"|*".$BUNDLE_ID".*)
        echo "    removing $(basename "$prof") ($appid)"
        rm -f "$prof"
        ;;
    esac
  done
fi

# Every install used to carry CFBundleVersion 1, so as far as iOS was concerned
# the app never changed. SpringBoard keeps its cached icon in that case, which
# is why a regenerated icon kept not appearing on the home screen. A build
# number that moves every time makes the reinstall visible.
BUILD_NUMBER=$(date +%Y%m%d%H%M)
echo "==> Building (build $BUILD_NUMBER)"
xcodebuild -project OnTime.xcodeproj -scheme OnTime -configuration Debug \
  -destination "platform=iOS,id=$DEVICE_ID" -allowProvisioningUpdates \
  -derivedDataPath build CURRENT_PROJECT_VERSION="$BUILD_NUMBER" build

echo "==> Installing"
xcrun devicectl device install app --device "$DEVICE_ID" \
  build/Build/Products/Debug-iphoneos/OnTime.app

echo "==> Resetting expiry clock"
mkdir -p "$STATE"
date +%s > "$STATE/last_install"

echo
echo "Done. OnTime reinstalled and the 7 day clock is reset."
echo "Your data is untouched: reinstalling over the app keeps its container."
