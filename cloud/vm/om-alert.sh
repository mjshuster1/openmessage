#!/bin/sh
# Notice when OpenMessage loses Google Messages, and once when it's back.
# om-status-log.sh runs this after each 5-minute sample; om-notify delivers it.
#
# Config: /etc/openmessage/alert.env (set-alerts.sh writes it), e.g.
#   ALERT_EMAIL=yes                email the operator, through Cloud Logging
#                                  and the project's alert policy (om-notify.sh)
#   NTFY_TOPIC=om-7f3c...          or an ntfy push (older setups)
#   NTFY_SERVER=https://ntfy.sh    optional
#   ALERT_AFTER_MIN=10             optional; minutes disconnected before alerting
#   ALERT_NAME=Texts               optional; label in the notification title
#   ALERT_AUDIENCE=client          optional; "operator" when the notices go to
#                                  whoever runs the service (then they say
#                                  which VM and the operator's next step)
#   ALERT_VM=om-mike               optional; VM name for operator notices
#   ALERT_RECONNECT_URL=https://…/reconnect
#                                  optional; the client's Reconnect page. When
#                                  set, a "needs reconnecting" notice says to
#                                  open it (the client can do it themselves)
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
[ -n "${NTFY_TOPIC:-}" ] || [ "${ALERT_EMAIL:-}" = yes ] || exit 0
NOTIFY=${OM_NOTIFY:-/usr/local/bin/om-notify}
ALERT_AFTER_MIN=${ALERT_AFTER_MIN:-10}
ALERT_NAME=${ALERT_NAME:-Texts}
if [ "${ALERT_AUDIENCE:-client}" = operator ]; then
  vm=${ALERT_VM:-$(hostname)}
  FIX_PARKED="With the client's phone in hand, ask Claude Code to reconnect $vm."
  FIX_DOWN="It usually recovers on its own; if not, ask Claude Code to check $vm."
else
  FIX_PARKED="It won't fix itself: tell whoever runs your service (your guide, 'If it stops')."
  FIX_DOWN="It usually recovers on its own; you'll get another notice if it does."
fi
if [ -n "${ALERT_RECONNECT_URL:-}" ]; then
  FIX_PARKED="It won't fix itself. To reconnect, open $ALERT_RECONNECT_URL on a computer with Google Chrome, with the phone nearby (about 5 minutes)."
fi

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

send() { # title, message, ntfy priority, ntfy tags
  sev=WARNING; [ "$4" = white_check_mark ] && sev=NOTICE
  "$NOTIFY" "$1" "$2" "$sev" "$3" "$4" || echo "om-alert: notice not sent" >&2
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
    send "$ALERT_NAME: needs reconnecting" "Google Messages stopped at $(fmt_time "$since") ($reason). $FIX_PARKED" high warning
    notified=1
  elif [ $(( now - since )) -ge $(( ALERT_AFTER_MIN * 60 )) ]; then
    send "$ALERT_NAME: disconnected" "Google Messages has been down since $(fmt_time "$since") ($reason). $FIX_DOWN" default warning
    notified=1
  fi
fi
echo "down $since $notified" > "$STATE"
