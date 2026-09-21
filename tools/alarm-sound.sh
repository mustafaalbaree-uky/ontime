#!/bin/bash
#
# Puts the Radar alarm tone into the app, from this Mac's own system tone
# library. The tone is Apple's, so it is never committed: the output folder is
# gitignored and this runs from tools/install.sh before every build. On a Mac
# without the file the app still builds, and StartAlarms falls back to the iOS
# default alarm sound.
#
# AlarmKit plays a bundled sound file, and only LPCM, IMA4, uLaw or aLaw in a
# caf, aiff or wav, under 30 seconds. The system file is a 3.8 second AAC
# loop. It is repeated to just under the limit so the alarm keeps ringing
# whether or not iOS loops it for us.
#
set -euo pipefail

SRC="/System/Library/PrivateFrameworks/ToneLibrary.framework/Versions/A/Resources/Ringtones/Radar.m4r"
OUT_DIR="$(cd "$(dirname "$0")/.." && pwd)/OnTime/Resources/Sounds"
OUT="$OUT_DIR/Radar.caf"

if [ ! -f "$SRC" ]; then
  echo "    Radar.m4r is not on this Mac, alarms will use the default sound"
  exit 0
fi
if [ -f "$OUT" ] && [ "$OUT" -nt "$SRC" ]; then
  exit 0
fi

mkdir -p "$OUT_DIR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

afconvert -f WAVE -d LEI16@44100 -c 1 "$SRC" "$TMP/one.wav"
python3 - "$TMP/one.wav" "$TMP/loop.wav" <<'PY'
import sys, wave
src, dst = sys.argv[1], sys.argv[2]
with wave.open(src, "rb") as w:
    params, frames = w.getparams(), w.readframes(w.getnframes())
seconds = w.getnframes() / params.framerate if False else len(frames) / (params.framerate * params.sampwidth * params.nchannels)
repeats = max(1, int(29.0 // seconds))
with wave.open(dst, "wb") as out:
    out.setparams(params)
    out.writeframes(frames * repeats)
print(f"    Radar: {seconds:.2f} s clip repeated {repeats} times, {seconds * repeats:.1f} s")
PY
afconvert -f caff -d ima4 "$TMP/loop.wav" "$OUT"
