#!/bin/sh
# Weekly "all good" notice, so a quiet week of alerts doesn't leave the user
# wondering. om-weekly.timer runs it Sundays at 6 PM (VM time). Uses the same
# ntfy config as om-alert.sh; no config, no notice. Status only, no message text.
set -eu
CONF=${OM_ALERT_CONF:-/etc/openmessage/alert.env}
[ -r "$CONF" ] || exit 0
. "$CONF"
[ -n "${NTFY_TOPIC:-}" ] || exit 0
LOG=/var/lib/openmessage/test-status.jsonl
STATE=/var/lib/openmessage/weekly-total

# Connected share of the last 7 days of 5-minute samples.
pct=$(tail -n 2016 "$LOG" 2>/dev/null | jq -rs 'if length == 0 then "?" else (map(select(.up == true and .connected == true)) | length) * 100 / length | floor | tostring end')
now_ok=no
[ "$(curl -s -m 5 127.0.0.1:7007/api/status 2>/dev/null | jq -r '.google.connected' 2>/dev/null)" = true ] && now_ok=yes

total=$(sudo -u openmessage OPENMESSAGES_DATA_DIR=/var/lib/openmessage timeout 30 /usr/local/bin/openmessage status --json 2>/dev/null | jq -r '.total_messages // empty' || true)
count=
if [ -n "$total" ]; then
  prev=$(cat "$STATE" 2>/dev/null || true)
  [ -n "$prev" ] && count=$((total - prev))
  echo "$total" > "$STATE"
fi
synced=${count:+"$count texts synced this week. "}

if [ "$now_ok" = yes ] && [ "$pct" != "?" ] && [ "$pct" -ge 99 ]; then
  title="${ALERT_NAME:-Texts}: all good this week"
  body="${synced}Connected ${pct}% of the time. Nothing to do."
  tags=white_check_mark
else
  title="${ALERT_NAME:-Texts}: weekly check"
  state=$([ "$now_ok" = yes ] && echo "connected now" || echo "NOT connected now")
  share="Connected ${pct}% of the time this week"
  [ "$pct" = "?" ] && share="No status samples this week"
  next="If it says not connected, see your guide's 'If it stops'."
  [ "${ALERT_AUDIENCE:-client}" = operator ] && next="If it says not connected, ask Claude Code to check ${ALERT_VM:-$(hostname)}."
  body="${synced}${share}, ${state}. ${next}"
  tags=warning
fi
curl -fsS -m 15 -o /dev/null -H "Title: $title" -H "Tags: $tags" -d "$body" \
  "${NTFY_SERVER:-https://ntfy.sh}/$NTFY_TOPIC"
