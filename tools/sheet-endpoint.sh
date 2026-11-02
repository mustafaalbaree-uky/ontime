#!/bin/bash
#
# Puts the Work Hours sheet's Apps Script URL and key into the app, from
# ~/.ontime/sheet_url and ~/.ontime/sheet_key. Either one lets anybody write
# to the sheet, so they are never committed: the output folder is gitignored
# and this runs from tools/install.sh before every build. Without both files
# the app builds with no endpoint and SheetSync does nothing.
#
set -euo pipefail

STATE="$HOME/.ontime"
OUT_DIR="$(cd "$(dirname "$0")/.." && pwd)/OnTime/Resources/Sheet"

if [ ! -f "$STATE/sheet_url" ] || [ ! -f "$STATE/sheet_key" ]; then
  echo "    no ~/.ontime/sheet_url or sheet_key, sessions will not reach the sheet"
  rm -rf "$OUT_DIR"
  exit 0
fi

mkdir -p "$OUT_DIR"
python3 - "$STATE/sheet_url" "$STATE/sheet_key" "$OUT_DIR/SheetEndpoint.json" <<'PY'
import json, sys
url, key, out = sys.argv[1:]
with open(out, "w") as f:
    json.dump({"url": open(url).read().strip(), "key": open(key).read().strip()}, f)
PY
