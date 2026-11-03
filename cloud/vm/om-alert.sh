#!/bin/sh
# Push notification when OpenMessage loses Google Messages, and once when it's
# back. om-status-log.sh runs this after each 5-minute sample.
#
# Config: /etc/openmessage/alert.env (set-alerts.sh writes it), e.g.
#   NTFY_TOPIC=om-7f3c...          required; a long random name, since anyone
#                                  who knows an ntfy.sh topic can read it
#   NTFY_SERVER=https://ntfy.sh    optional
#   ALERT_AFTER_MIN=10             optional; minutes disconnected before alerting
#   ALERT_NAME=Texts               optional; label in the notification title
# No config file, no alerts. Notifications carry status only, never message
# text. A park (blocked, or needs pairing) alerts at once because it won't
# recover by itself; a plain disconnect waits ALERT_AFTER_MIN.
#
# Usage: om-alert.sh [status-log] [state-file]   (defaults below; tests pass both)
set -eu

LOG=${1:-/var/lib/openmessage/test-status.jsonl}
STATE=${2:-/var/lib/openmessage/alert-state}
CONF=${OM_ALERT_CONF:-/etc/openmessage/alert.env}

[ -r "$CONF" ] || exit 0
# shellcheck disable=SC1090
. "$CONF"
[ -n "${NTFY_TOPIC:-}" ] || exit 0
NTFY_SERVER=${NTFY_SERVER:-https://ntfy.sh}
ALERT_AFTER_MIN=${ALERT_AFTER_MIN:-10}
ALERT_NAME=${ALERT_NAME:-Texts}

sample=$(tail -n 1 "$LOG" 2>/dev/null || true)
[ -n "$sample" ] || exit 0
now=$(date -u +%s)

# up|down|parked, and a short reason, from one status-log line.
kind=$(printf '%s' "$sample" | jq -r '
  if .up != true then "down"
  elif (.state == "blocked" or .needs_pairing == true or .block != null) then "parked"
  elif .connected != true then "down"
  else "up" end')
reason=$(printf '%s' "$sample" | jq -r '
  if .up != true then "OpenMessage is not answering"
  else [(.state // empty), (.block // empty), (.error // empty)] | join(", ") end')

prev=$(cat "$STATE" 2>/dev/null || echo up)   # up | down <since-epoch> <notified 0|1>
set -- $prev
pkind=$1; since=${2:-$now}; notified=${3:-0}

send() { # title, message, priority, tags
  curl -fsS -m 15 -o /dev/null \
    -H "Title: $1" -H "Priority: $3" -H "Tags: $4" \
    -d "$2" "$NTFY_SERVER/$NTFY_TOPIC" || echo "om-alert: ntfy send failed" >&2
}
fmt_time() { date -d "@$1" '+%a %H:%M %Z' 2>/dev/null || date -r "$1" '+%a %H:%M %Z'; }

if [ "$kind" = up ]; then
  if [ "$pkind" = down ] && [ "$notified" = 1 ]; then
    mins=$(( (now - since) / 60 ))
    send "$ALERT_NAME: back online" "Google Messages reconnected after about $mins minutes. Texts sent while it was down may need a moment to sync." default white_check_mark
  fi
  echo up > "$STATE"
  exit 0
fi

[ "$pkind" = down ] || { since=$now; notified=0; }
if [ "$notified" = 0 ]; then
  if [ "$kind" = parked ]; then
    send "$ALERT_NAME: needs reconnecting" "Google Messages stopped at $(fmt_time "$since") ($reason). It won't fix itself: run the reconnect command once (your guide, 'If it stops')." high warning
    notified=1
  elif [ $(( now - since )) -ge $(( ALERT_AFTER_MIN * 60 )) ]; then
    send "$ALERT_NAME: disconnected" "Google Messages has been down since $(fmt_time "$since") ($reason). It usually recovers on its own; you'll get another notice if it does." default warning
    notified=1
  fi
fi
echo "down $since $notified" > "$STATE"
