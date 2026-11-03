#!/bin/sh
# Appends one line of OpenMessage's Google status to the test log.
# Run every 5 minutes by om-status-log.timer.
LOG=/var/lib/openmessage/test-status.jsonl
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if BODY=$(curl -sf -m 10 http://127.0.0.1:7007/api/status); then
  printf '%s' "$BODY" | jq -c --arg t "$NOW" '{t: $t, up: true,
    connected: .google.connected, needs_pairing: .google.needs_pairing,
    state: .google.supervisor.state, block: (.google.supervisor.block_reason // null),
    error: (.google.supervisor.error_class // null)}' >> "$LOG"
else
  printf '{"t":"%s","up":false}\n' "$NOW" >> "$LOG"
fi
# Push alerts, if configured (om-alert.sh, set-alerts.sh). Never fails the log.
[ -x /usr/local/bin/om-alert.sh ] && /usr/local/bin/om-alert.sh "$LOG" || true
