#!/bin/bash
# Fork addition (mjshuster1). Run by the com.mjshuster.openmessage.update
# agent every 30 minutes. Fast-forwards to origin/main of this fork, builds,
# runs the fork's tests, and restarts the server only if all of that works.
# On any failure the running binary is left alone. Upstream is never pulled.
set -u

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
STATE="$HOME/Library/Application Support/openmessage-autorun/built-commit"
SERVE_LABEL="com.mjshuster.openmessage.serve"
LOCK="/tmp/openmessage-autorun-update.lock"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }

# Everything runs inside main so bash has read the whole file before the
# merge below rewrites it.
main() {
# A lock left by a killed run expires after an hour.
if [ -d "$LOCK" ] && [ -n "$(find "$LOCK" -maxdepth 0 -mmin +60 2>/dev/null)" ]; then
  rmdir "$LOCK" 2>/dev/null
fi
if ! mkdir "$LOCK" 2>/dev/null; then
  log "another update is running; skipping"
  return 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

cd "$REPO" || { log "cannot cd to $REPO"; return 1; }

if ! git fetch --quiet origin main; then
  log "git fetch failed (offline?); will retry"
  return 0
fi
target="$(git rev-parse origin/main)"
built="$(cat "$STATE" 2>/dev/null || true)"
if [ "$target" = "$built" ]; then
  return 0
fi

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  log "local changes in $REPO; not updating. Ask Claude to look at: git -C $REPO status"
  return 1
fi
if ! git merge --quiet --ff-only origin/main; then
  log "cannot fast-forward to $target; not updating"
  return 1
fi

log "building $target"
if ! go build -o openmessage.new . >/tmp/openmessage-autorun-build.log 2>&1; then
  log "build of $target failed; still running ${built:-the previous build}. Details: /tmp/openmessage-autorun-build.log"
  rm -f openmessage.new
  return 1
fi
if ! go test ./internal/spamwatch ./internal/tools >/tmp/openmessage-autorun-test.log 2>&1; then
  log "tests failed for $target; still running ${built:-the previous build}. Details: /tmp/openmessage-autorun-test.log"
  rm -f openmessage.new
  return 1
fi

mv -f openmessage.new openmessage
echo "$target" > "$STATE"
if launchctl kickstart -k "gui/$(id -u)/$SERVE_LABEL"; then
  log "updated to $target and restarted"
else
  log "updated to $target but restart failed; it takes effect on the next restart"
fi
}

main "$@"
exit $?
