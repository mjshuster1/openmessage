#!/bin/sh
# GCE startup script for the OpenMessage VM. create-vm.sh attaches it; the
# guest agent runs it as root on every boot.
#
# Reads instance metadata om-repo (owner/repo) and om-release (tag), downloads
# that release's Linux binary and VM files, checks both against the release's
# SHA256SUMS, and runs setup-vm.sh from them: swap, the openmessage user and
# data dir, the binary and the systemd units. A boot at the release already
# installed does nothing. Changing om-release and rebooting upgrades in place
# and restarts OpenMessage if it was running.
#
# It never pairs or starts OpenMessage the first time, and never touches the
# tunnel; see create-vm.sh. Testing without a release: put the four files in a
# folder and run   OM_ASSETS=/that/folder sh startup.sh
set -eu

log() { echo "om-startup: $*"; }
md() {
  curl -sf -H 'Metadata-Flavor: Google' \
    "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1" 2>/dev/null || true
}

REPO=$(md om-repo)
TAG=$(md om-release)
if [ -z "${OM_ASSETS:-}" ] && { [ -z "$REPO" ] || [ -z "$TAG" ]; }; then
  log "metadata om-repo and om-release are required; nothing installed"
  exit 1
fi
WANT="${REPO}@${TAG}"
STAMP=/var/lib/openmessage-release
if [ -z "${OM_ASSETS:-}" ] && [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$WANT" ]; then
  log "already at $WANT"
  exit 0
fi

case $(uname -m) in
  x86_64) ARCH=amd64 ;;
  aarch64) ARCH=arm64 ;;
  *) log "unsupported architecture $(uname -m)"; exit 1 ;;
esac
BIN=openmessage-linux-$ARCH.tar.gz
VMF=openmessage-vm.tar.gz

command -v curl >/dev/null 2>&1 || { apt-get update -q && apt-get install -y -q curl ca-certificates; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
if [ -n "${OM_ASSETS:-}" ]; then
  cp "$OM_ASSETS/SHA256SUMS" "$OM_ASSETS/$BIN" "$OM_ASSETS/$VMF" "$WORK/"
  WANT="local:$OM_ASSETS"
else
  BASE="https://github.com/$REPO/releases/download/$TAG"
  for f in SHA256SUMS "$BIN" "$VMF"; do
    curl -fsSL --retry 5 --retry-delay 3 -o "$WORK/$f" "$BASE/$f" || { log "download failed: $BASE/$f"; exit 1; }
  done
fi

# Both files must be listed and match; a missing line fails too.
(cd "$WORK" && for f in "$BIN" "$VMF"; do
  grep -E "^[0-9a-f]{64}  $f\$" SHA256SUMS || { log "$f not in SHA256SUMS"; exit 1; }
done > sums.check && sha256sum -c sums.check) || { log "checksum mismatch; nothing installed"; exit 1; }

tar -C "$WORK" -xzf "$WORK/$VMF"
tar -C "$WORK/vm" -xzf "$WORK/$BIN" openmessage

was_active=no
systemctl is-active --quiet openmessage 2>/dev/null && was_active=yes

sh "$WORK/vm/setup-vm.sh"
install -m 755 "$WORK/vm/score.sh" /usr/local/bin/om-score

if [ "$was_active" = yes ]; then
  systemctl restart openmessage
  log "restarted OpenMessage on the new binary"
fi
echo "$WANT" > "$STAMP"
# Flush now: a hard reset within ~30 s of install otherwise loses the stamp
# (seen 2026-11-03) and the next boot installs again.
sync
log "installed $WANT"
log "done"
