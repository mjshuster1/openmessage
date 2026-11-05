#!/bin/sh
# Sends one status notice the ways /etc/openmessage/alert.env turns on.
# om-alert.sh, om-weekly.sh and om-update.sh call it.
#
#   om-notify <title> <message> <severity> [ntfy-priority] [ntfy-tags]
#
# severity: WARNING (something is wrong), NOTICE (it's fixed, or a weekly
# check), INFO (recorded only).
#
# alert.env:
#   ALERT_EMAIL=yes   write a Cloud Logging entry (log "openmessage-alerts")
#                     in the VM's project. The alert policy that
#                     set-email-alerts.sh creates there emails the operator
#                     for each WARNING or NOTICE entry. Uses the VM's default
#                     service account (logging.write scope).
#   NTFY_TOPIC=...    an ntfy push (older setups; NTFY_SERVER optional)
# Status only, never message text. Exit status 0 if any way worked.
set -u
CONF=${OM_ALERT_CONF:-/etc/openmessage/alert.env}
[ -r "$CONF" ] || exit 0
# shellcheck disable=SC1090
. "$CONF"
title=$1 message=$2 severity=${3:-NOTICE} priority=${4:-default} tags=${5:-}
sent=no

if [ "${ALERT_EMAIL:-}" = yes ]; then
  MD=http://metadata.google.internal/computeMetadata/v1
  md() { curl -sf -m 5 -H 'Metadata-Flavor: Google' "$MD/$1"; }
  if token=$(md instance/service-accounts/default/token | jq -r .access_token) && [ -n "$token" ] \
     && project=$(md project/project-id) && id=$(md instance/id) && zone=$(md instance/zone); then
    if body=$(jq -n --arg p "$project" --arg id "$id" --arg z "${zone##*/}" --arg sev "$severity" \
      --arg title "$title" --arg msg "$message" --arg vm "${ALERT_VM:-$(hostname)}" --arg client "${ALERT_NAME:-}" '{
        logName: "projects/\($p)/logs/openmessage-alerts",
        resource: {type: "gce_instance", labels: {project_id: $p, instance_id: $id, zone: $z}},
        entries: [{severity: $sev, jsonPayload: {title: $title, message: $msg, vm: $vm, client: $client}}]}') \
       && [ -n "$body" ] && printf '%s' "$body" | curl -sf -m 15 -o /dev/null -X POST -H "Authorization: Bearer $token" \
         -H 'Content-Type: application/json' --data-binary @- https://logging.googleapis.com/v2/entries:write; then
      sent=yes
    else
      echo "om-notify: Cloud Logging write failed" >&2
    fi
  else
    echo "om-notify: no metadata token (is this a GCE VM with the default service account?)" >&2
  fi
fi

if [ -n "${NTFY_TOPIC:-}" ]; then
  if curl -fsS -m 15 -o /dev/null -H "Title: $title" -H "Priority: $priority" ${tags:+-H "Tags: $tags"} \
       -d "$message" "${NTFY_SERVER:-https://ntfy.sh}/$NTFY_TOPIC"; then
    sent=yes
  else
    echo "om-notify: ntfy send failed" >&2
  fi
fi
[ "$sent" = yes ]
