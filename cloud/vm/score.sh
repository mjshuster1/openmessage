#!/bin/sh
# Scores the 72-hour test from the status log. Each sample stands for 5 minutes.
LOG=${1:-/var/lib/openmessage/test-status.jsonl}
jq -rs '
  (length) as $n
  | (map(select(.up != true or .connected != true)) | length) as $down
  | (map(select(.state == "blocked" or .needs_pairing == true or .block != null)) | length) as $parked
  | "samples: \($n) (\($n * 5 / 60 | floor) h)",
    "first: \(.[0].t // "none")  last: \(.[-1].t // "none")",
    "disconnected: \($down * 5) min (pass is under 15)",
    "parked or needs pairing: \($parked) samples (pass is 0)",
    (map(select(.up != true or .connected != true)) | .[] | "  down at \(.t): \(.state // "server not answering") \(.block // "") \(.error // "")")
' "$LOG"
