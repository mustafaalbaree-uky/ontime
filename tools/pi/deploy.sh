#!/bin/bash
#
# Copies the push daemon to the Pi and restarts it. The signing key is not
# part of this: it was placed in ~/.ontime-push on the Pi once, by hand, and
# is never in the repo.
#
set -euo pipefail

HOST="${WARDEN_HOST:-100.88.112.8}"
HERE="$(cd "$(dirname "$0")" && pwd)"

ssh "mustafa@$HOST" 'mkdir -p ~/.ontime-push && chmod 700 ~/.ontime-push'
scp -q "$HERE/ontime_pushd.py" "$HERE/ontime_push.py" "mustafa@$HOST:.ontime-push/"
scp -q "$HERE/ontime-push.service" "mustafa@$HOST:/tmp/ontime-push.service"
ssh "mustafa@$HOST" '
  sudo mv /tmp/ontime-push.service /etc/systemd/system/ontime-push.service
  sudo systemctl daemon-reload
  sudo systemctl enable --quiet ontime-push.service
  sudo systemctl restart ontime-push.service
  sleep 2
  systemctl is-active ontime-push.service
  journalctl -u ontime-push.service -n 3 --no-pager -o cat
'
