#!/usr/bin/env bash
# Pairs (or re-pairs) the VM with the phone's Google Messages in one command.
# Use it for the first pairing and whenever alerts say "needs reconnecting".
#
#   cloud/vm/reconnect.sh [--name om-test] [--zone us-east1-b] [--project <id>] [--no-watch]
#                         [--cookies <file>]   (a cookie file captured another way,
#                                               e.g. from Firefox; deleted after copying)
#
# Run it on a computer with Chrome, Node 22+ and gcloud (signed in to the VM's
# project), with the phone in hand. It:
#   1. shows the VM's current Google state (and asks before re-pairing a
#      connected one);
#   2. opens a throwaway Incognito Chrome (capture-google-cookies.mjs): sign in
#      with the Google account linked to the phone's Google Messages, let it
#      reach messages.google.com/web, press Enter;
#   3. copies the cookies to the VM and deletes the local copy;
#   4. stops OpenMessage, pairs, and shows the emoji: tap the same one on the
#      phone within 5 minutes;
#   5. deletes the cookie file on the VM whatever happened, starts OpenMessage
#      and checks the connection now and (unless --no-watch) for 10 minutes,
#      since a bad login shows up as a disconnect within minutes.
# Never run two copies at once, and don't run it in a loop: repeated pairings
# can get the Google account throttled.
set -euo pipefail

NAME=om-test
ZONE=us-east1-b
PROJECT_ARGS=()
WATCH=yes
GIVEN=
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME=$2; shift 2 ;;
    --zone) ZONE=$2; shift 2 ;;
    --project) PROJECT_ARGS=(--project "$2"); shift 2 ;;
    --no-watch) WATCH=no; shift ;;
    --cookies) GIVEN=$2; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
HERE=$(cd "$(dirname "$0")" && pwd)
G=(gcloud ${PROJECT_ARGS[@]+"${PROJECT_ARGS[@]}"})
vm() { "${G[@]}" compute ssh --quiet "$NAME" --zone "$ZONE" -- "$@" 2>&1 | { grep --line-buffered -v 'Pseudo-terminal' || true; }; }
status() {
  vm 'curl -s -m 5 127.0.0.1:7007/api/status | jq -r "if .google == null then \"not running\" else \"\(if .google.connected then \"connected\" else \"DISCONNECTED\" end) (\(.google.supervisor.state // \"?\")\(if .google.supervisor.block_reason then \", \" + .google.supervisor.block_reason else \"\" end))\" end" 2>/dev/null || echo "not running"'
}

if [ -z "$GIVEN" ]; then
  command -v node >/dev/null || { echo "Node 22+ is needed (https://nodejs.org)." >&2; exit 1; }
  node -e 'process.exit(+process.versions.node.split(".")[0] >= 22 ? 0 : 1)' || { echo "Node 22+ is needed; this is $(node --version)." >&2; exit 1; }
else
  [ -f "$GIVEN" ] || { echo "No such file: $GIVEN" >&2; exit 1; }
fi

echo "Checking $NAME ..."
now=$(status | tail -1)
echo "  Google Messages on the VM: $now"
if [[ "$now" == connected* ]]; then
  read -rp "It is connected. Re-pair anyway? [y/N] " yn
  [[ "$yn" == [yY]* ]] || exit 0
fi

COOKIES=$(mktemp -d)/google-cookies.json
cleanup_local() { rm -rf "$(dirname "$COOKIES")"; }
trap cleanup_local EXIT

echo
if [ -n "$GIVEN" ]; then
  echo "Step 1 of 3: using $GIVEN (it will be deleted after copying)."
  mv "$GIVEN" "$COOKIES"
else
  echo "Step 1 of 3: sign in (a separate Chrome window opens)."
  node "$HERE/capture-google-cookies.mjs" "$COOKIES"
fi

echo
echo "Step 2 of 3: copying the login to the VM ..."
"${G[@]}" compute scp --quiet --zone "$ZONE" "$COOKIES" "$NAME:/tmp/om-google-cookies.json" >/dev/null
cleanup_local

echo
echo "Step 3 of 3: pairing. Have the phone ready; an emoji will appear below."
# Line-buffered all the way, or the emoji sits in a buffer while the 5 minutes run out.
vm 'set -u
  f=/tmp/om-google-cookies.json
  trap "sudo rm -f $f" EXIT
  sudo systemctl stop openmessage
  sudo chown openmessage:openmessage "$f" && sudo chmod 600 "$f"
  sudo -u openmessage OPENMESSAGES_DATA_DIR=/var/lib/openmessage stdbuf -oL -eL \
    /usr/local/bin/openmessage pair --google-file "$f" 2>&1 | grep --line-buffered -E "EMOJI|successful|FTL|rror" | grep --line-buffered -v "HMAC mismatch" | sed -u "s/\x1b\[[0-9;]*m//g"
  echo "PAIR_EXIT=${PIPESTATUS[0]}"
  sudo systemctl start openmessage' | while IFS= read -r line; do
  case "$line" in
    *EMOJI:*)
      e=${line##*EMOJI: }
      printf '\n   ┌─────────────────────────────────────────┐\n'
      printf '   │  On the phone, tap:   %s   %s   %s          │\n' "$e" "$e" "$e"
      printf '   └─────────────────────────────────────────┘\n'
      echo "   (Google Messages shows a pairing prompt; you have 5 minutes.)" ;;
    *successful*) echo "  Paired." ;;
    PAIR_EXIT=0) ;;
    PAIR_EXIT=*) echo "  Pairing failed (${line#PAIR_EXIT=}). OpenMessage was restarted on its previous session." ;;
    *) echo "  $line" ;;
  esac
done

echo
sleep 25
now=$(status | tail -1)
echo "Google Messages on the VM: $now"
[[ "$now" == connected* ]] || { echo "Not connected. Check the phone, then run this again once (not in a loop)." >&2; exit 1; }
if [ "$WATCH" = yes ]; then
  echo "Watching for 10 minutes (a bad login drops within minutes) ..."
  for i in 1 2 3 4 5; do
    sleep 120
    now=$(status | tail -1)
    echo "  $(date +%H:%M) $now"
    [[ "$now" == connected* ]] || { echo "It dropped. Run this again once; if it drops again, see cloud/vm/README.md step 4." >&2; exit 1; }
  done
fi
echo "Done: connected."
