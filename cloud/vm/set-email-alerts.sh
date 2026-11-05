#!/usr/bin/env bash
# Emails the operator when a client's VM loses Google Messages, when it's
# back, after a rolled-back update, and once a week. Safe to re-run.
#
#   cloud/vm/set-email-alerts.sh --project <id> [--email <address>]... [--check]
#
# In the client's Google Cloud project it:
#   1. turns on the Cloud Logging and Cloud Monitoring APIs;
#   2. adds an email notification channel for each --email (default: the
#      account gcloud is signed in as); repeat --email to mail several people,
#      e.g. the operator and the client (deploy.sh --client-owned does);
#   3. adds the alert policy "OpenMessage alerts": each WARNING or NOTICE
#      entry the VM writes to the log "openmessage-alerts" (om-notify.sh)
#      becomes one email, at most one per 5 minutes, with the notice's title
#      as the subject. Entries carry status only, never message text.
# The VM side is set-alerts.sh --email (deploy.sh runs both).
# --check only reports what's missing and changes nothing.
set -euo pipefail

PROJECT= CHECK=no
EMAILS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT=$2; shift 2 ;;
    --email) EMAILS+=("$2"); shift 2 ;;
    --check) CHECK=yes; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[ -n "$PROJECT" ] || { echo "--project is required" >&2; exit 2; }
[ ${#EMAILS[@]} -gt 0 ] || EMAILS=("$(gcloud config get-value account 2>/dev/null)")
for e in "${EMAILS[@]}"; do [[ "$e" == *@*.* ]] || { echo "--email doesn't look like an email address: $e" >&2; exit 2; }; done
command -v jq >/dev/null || { echo "jq is needed (brew install jq)" >&2; exit 1; }

API=https://monitoring.googleapis.com/v3/projects/$PROJECT
TOKEN=$(gcloud auth print-access-token 2>/dev/null) || { echo "gcloud isn't signed in" >&2; exit 1; }
call() { # method path [json]
  curl -sS -m 30 -X "$1" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -H "X-Goog-User-Project: $PROJECT" ${3:+--data-binary "$3"} "$API/$2"
}
todo=0

echo "1/3 APIs"
on=$(gcloud services list --project "$PROJECT" --enabled --format='value(config.name)' 2>/dev/null || true)
if grep -qx monitoring.googleapis.com <<<"$on" && grep -qx logging.googleapis.com <<<"$on"; then
  echo "   on"
elif [ "$CHECK" = yes ]; then
  echo "   missing: Cloud Logging / Monitoring API"; todo=$((todo + 1))
else
  gcloud services enable logging.googleapis.com monitoring.googleapis.com --project "$PROJECT"
  echo "   on"
fi

echo "2/3 Email channels (${EMAILS[*]})"
existing=$(call GET "notificationChannels?filter=type%3D%22email%22" 2>/dev/null || true)
CHANNELS=()
for EMAIL in "${EMAILS[@]}"; do
  CHANNEL=$(jq -r --arg e "$EMAIL" '[.notificationChannels[]? | select(.labels.email_address == $e)][0].name // empty' <<<"$existing" 2>/dev/null || true)
  if [ -n "$CHANNEL" ]; then
    echo "   $EMAIL: exists"
  elif [ "$CHECK" = yes ]; then
    echo "   missing: email channel for $EMAIL"; todo=$((todo + 1))
  else
    out=$(call POST notificationChannels "$(jq -n --arg e "$EMAIL" \
      '{type: "email", displayName: "OpenMessage alerts (\($e))", labels: {email_address: $e}}')")
    CHANNEL=$(jq -r '.name // empty' <<<"$out")
    [ -n "$CHANNEL" ] || { echo "   couldn't create it for $EMAIL:" >&2; jq -r '.error.message // .' <<<"$out" >&2; exit 1; }
    echo "   $EMAIL: created"
  fi
  [ -z "$CHANNEL" ] || CHANNELS+=("$CHANNEL")
done
SENDS_TO=$(IFS=,; echo "${EMAILS[*]}")

echo "3/3 Alert policy"
POLICY=$(call GET "alertPolicies?filter=display_name%3D%22OpenMessage%20alerts%22" 2>/dev/null \
  | jq -r '.alertPolicies[0]?.name // empty' 2>/dev/null || true)
want=$(jq -n --arg p "$PROJECT" --args '{
  displayName: "OpenMessage alerts",
  combiner: "OR",
  severity: "WARNING",
  conditions: [{
    displayName: "OpenMessage notice",
    conditionMatchedLog: {
      filter: "logName=\"projects/\($p)/logs/openmessage-alerts\" AND severity>=NOTICE",
      labelExtractors: {title: "EXTRACT(jsonPayload.title)", message: "EXTRACT(jsonPayload.message)"}
    }
  }],
  alertStrategy: {notificationRateLimit: {period: "300s"}, autoClose: "1800s", notificationPrompts: ["OPENED"]},
  documentation: {
    subject: "${log.extracted_label.title}",
    content: "${log.extracted_label.message}\n\n(OpenMessage, project \($p). Status only; no message text.)",
    mimeType: "text/markdown"
  },
  notificationChannels: $ARGS.positional
}' ${CHANNELS[@]+"${CHANNELS[@]}"})
if [ -n "$POLICY" ]; then
  if [ "$CHECK" = yes ]; then
    echo "   exists"
  else
    out=$(call PATCH "${POLICY#projects/$PROJECT/}" "$want")
    jq -e '.name' <<<"$out" >/dev/null || { echo "   couldn't update it:" >&2; jq -r '.error.message // .' <<<"$out" >&2; exit 1; }
    echo "   up to date (sends to $SENDS_TO)"
  fi
elif [ "$CHECK" = yes ]; then
  echo "   missing: alert policy"; todo=$((todo + 1))
else
  out=$(call POST alertPolicies "$want")
  jq -e '.name' <<<"$out" >/dev/null || { echo "   couldn't create it:" >&2; jq -r '.error.message // .' <<<"$out" >&2; exit 1; }
  echo "   created (sends to $SENDS_TO)"
fi

if [ "$CHECK" = yes ]; then
  [ $todo -eq 0 ] && echo "Ready." || { echo "$todo thing(s) to set up: re-run without --check."; exit 1; }
fi
