#!/bin/sh
# Keeps the VM on the newest *-vmN release, with rollback. om-update.timer runs
# it daily; run it by hand as root to update now.
#
# Only acts when instance metadata om-release is "latest" (create-vm.sh's
# default) and om-auto-update isn't "no". It installs the new release with
# om-install-release (startup.sh), then watches Google Messages for up to 5
# minutes. If it was connected before and isn't after, it puts the previous
# binary back, restarts, skips that release from then on, and sends an alert
# (if alerts are set up). A release it skipped is retried only if a newer one
# appears.
#
# A new release waits a few days before this VM takes it (om-update-wait-days,
# default 3), so the operator's own server finds a bad release first: set 0 on
# that one. A clients' VM can't be fixed by hand once it's handed back. A
# release titled "(urgent)" (release-vm.sh with OM_URGENT=1) doesn't wait.
set -eu

log() { echo "om-update: $*"; logger -t om-update "$*" 2>/dev/null || true; }
md() {
  curl -sf -H 'Metadata-Flavor: Google' \
    "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1" 2>/dev/null || true
}
# Exactly "true" from a live server; no answer or no JSON is "not connected".
connected() { [ "$(curl -s -m 5 127.0.0.1:7007/api/status 2>/dev/null | jq -r '.google.connected' 2>/dev/null)" = true ]; }

REPO=$(md om-repo)
[ "$(md om-release)" = latest ] || { log "om-release isn't 'latest'; nothing to do"; exit 0; }
[ "$(md om-auto-update)" != no ] || { log "om-auto-update=no; nothing to do"; exit 0; }

STAMP=${OM_STAMP:-/var/lib/openmessage-release}
SKIP=${OM_SKIP:-/var/lib/openmessage/update-skip}
PREV=${OM_PREV_DIR:-/var/lib/openmessage-prev}
BIN=${OM_BIN:-/usr/local/bin/openmessage}
WAIT=$(md om-update-wait-days)
case "$WAIT" in ''|*[!0-9]*) WAIT=3 ;; esac
current=$(cut -d@ -f2 "$STAMP" 2>/dev/null || true)
curn=$(printf '%s' "$current" | sed -nE 's/.*-vm([0-9]+)$/\1/p')
# Newest first. Stop at the current release, and never pick an older one, so a
# held release never means going backwards.
latest=$(curl -fsSL -m 30 "https://api.github.com/repos/$REPO/releases?per_page=30" \
  | jq -r --arg cur "$current" --argjson wait "$WAIT" --argjson curn "${curn:-0}" '
      [.[] | select((.draft | not) and (.prerelease | not) and (.tag_name | test("-vm[0-9]+$")))
           | select((.tag_name | capture("-vm(?<n>[0-9]+)$").n | tonumber) >= $curn)
           | select(.tag_name == $cur or ((.name // "") | test("\\(urgent\\)"))
                    or ((now - (.published_at | fromdateiso8601)) >= ($wait * 86400)))
      ][0].tag_name // empty' 2>/dev/null || true)
[ -n "$latest" ] || { log "no newer release is ready on $REPO, or couldn't list them; will retry tomorrow"; exit 0; }
[ "$latest" != "$current" ] || { log "up to date ($current)"; exit 0; }
if [ "$(cat "$SKIP" 2>/dev/null)" = "$latest" ]; then
  log "$latest was rolled back before; waiting for a newer release"
  exit 0
fi

was=no
connected && was=yes
mkdir -p "$PREV"
cp -p "$BIN" "$PREV/openmessage"
cp -p "$STAMP" "$PREV/release" 2>/dev/null || true

log "updating $current -> $latest"
if ! OM_TAG=$latest "${OM_INSTALL:-/usr/local/sbin/om-install-release}"; then
  log "install of $latest failed; nothing changed"
  exit 1
fi
systemctl is-active --quiet openmessage || { log "updated to $latest (OpenMessage wasn't running)"; exit 0; }

if [ "$was" = yes ]; then
  i=0
  while [ $i -lt 30 ]; do
    sleep 10
    connected && { log "updated to $latest; Google Messages reconnected"; exit 0; }
    i=$((i + 1))
  done
  log "$latest didn't reconnect within 5 minutes; rolling back to $current"
  install -m 755 "$PREV/openmessage" "$BIN"
  cp -p "$PREV/release" "$STAMP" 2>/dev/null || true
  echo "$latest" > "$SKIP"
  systemctl restart openmessage
  sync
  if [ -r /etc/openmessage/alert.env ]; then
    . /etc/openmessage/alert.env
    who="Nothing for you to do; tell whoever set this up."
    [ "${ALERT_AUDIENCE:-client}" = operator ] && who="Check the release before the other VMs take it."
    /usr/local/bin/om-notify "${ALERT_NAME:-Texts}: update rolled back" \
      "Update $latest didn't reconnect to Google Messages, so ${ALERT_VM:-the VM} went back to $current. $who" \
      WARNING default warning || true
  fi
  exit 1
fi
log "updated to $latest"
