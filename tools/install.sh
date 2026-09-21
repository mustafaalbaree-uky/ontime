#!/bin/bash
#
# Rebuilds and reinstalls OnTime to the connected iPhone. Phone must be
# plugged in and unlocked.
#
set -euo pipefail

DIR="/Users/mustafaalbaree/Code/ontime"
STATE="$HOME/.ontime"

cd "$DIR"

# Before the project is generated: XcodeGen only picks up files that exist.
echo "==> Alarm sound"
./tools/alarm-sound.sh

echo "==> Generating project"
xcodegen generate >/dev/null

# xcodebuild wants the hardware UDID, while `devicectl list devices` prints a
# different CoreDevice UUID that xcodebuild will reject. Ask xcodebuild itself
# rather than hardcoding either one.
echo "==> Looking for a connected iPhone"
# PhoneDeck sets PHONEDECK_DEVICE_ID to the phone picked in its device menu,
# as a hardware UDID. Honour it rather than deciding again here: with more
# than one phone reachable, a fresh lookup can land on a different one from
# the phone PhoneDeck is showing, and that other phone is often somebody
# else's. Run by hand from a terminal with nothing set, the lookup below
# runs as it always has.
DEVICE_ID="${PHONEDECK_DEVICE_ID:-}"

if [ -z "$DEVICE_ID" ]; then
  # `|| true` matters: with `set -e` and `pipefail`, a grep that matches nothing
  # returns 1 and would abort the script before it could explain why.
  DEVICE_ID=$( { xcodebuild -project OnTime.xcodeproj -scheme OnTime -showdestinations 2>/dev/null \
    | grep "platform:iOS," | grep -v placeholder \
    | sed -n 's/.*id:\([^,}]*\).*/\1/p' | head -1 | tr -d ' '; } || true )
fi

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
echo "    using ${PHONEDECK_DEVICE_NAME:+${PHONEDECK_DEVICE_NAME} }$DEVICE_ID"

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

echo "==> Recording the install"
mkdir -p "$STATE"
NOW=$(date +%s)
echo "$NOW" > "$STATE/last_install"
# Per phone as well, so PhoneDeck can say whether this build is on the phone
# you are looking at rather than on whichever phone was here last. The plain
# last_install stays, for anything still reading it.
echo "$NOW" > "$STATE/last_install_$DEVICE_ID"

echo
echo "Done. OnTime reinstalled."
echo "Your data is untouched: reinstalling over the app keeps its container."
