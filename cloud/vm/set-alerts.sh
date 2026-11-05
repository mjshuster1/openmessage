#!/usr/bin/env bash
# Turns on alerts for an OpenMessage VM and sends a test notice.
#
#   cloud/vm/set-alerts.sh [--name om-test] [--zone us-east1-b] [--project <id>]
#                          [--email] [--topic <existing topic>] [--label "Mike"] [--operator] [--off]
#                          [--reconnect-url https://<connector>/reconnect]
#
# --email (what deploy.sh uses): the VM writes each notice to Cloud Logging in
# its own project and the alert policy there emails the operator. Run
# set-email-alerts.sh --project <id> first for the policy. Needs om-notify on
# the VM (release v0.3.0-vm5 on).
# Without --email, alerts go through ntfy (ntfy.sh): install the ntfy app (Android or iPhone),
# tap +, and subscribe to the topic this prints. No account is needed. The topic
# name is the only secret: anyone who knows it can read the alerts. That's why
# it's long and random, and why alerts carry status only, never message text.
# --label names the client in each notice's title (default "Texts").
# --operator: the notices go to whoever runs the service, not the client, so
# they say which client and what to do as the operator. deploy.sh passes it
# with the operator's one topic for all clients.
# --reconnect-url: the client's Reconnect page; "needs reconnecting" notices
# then point to it (deploy.sh --client-owned passes it).
# --off removes the config (alerts stop; nothing else changes).
set -euo pipefail

NAME=om-test
ZONE=us-east1-b
PROJECT_ARGS=()
TOPIC=
OFF=no
LABEL=
AUDIENCE=client
EMAIL=no
RECONNECT_URL=
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME=$2; shift 2 ;;
    --zone) ZONE=$2; shift 2 ;;
    --project) PROJECT_ARGS=(--project "$2"); shift 2 ;;
    --topic) TOPIC=$2; shift 2 ;;
    --label) LABEL=$2; shift 2 ;;
    --operator) AUDIENCE=operator; shift ;;
    --email) EMAIL=yes; AUDIENCE=operator; shift ;;
    --off) OFF=yes; shift ;;
    --reconnect-url) RECONNECT_URL=$2; shift 2 ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
G=(gcloud ${PROJECT_ARGS[@]+"${PROJECT_ARGS[@]}"})
ssh_vm() { "${G[@]}" compute ssh --quiet "$NAME" --zone "$ZONE" -- "$@" 2>&1 | { grep -v 'Pseudo-terminal' || true; }; }

if [ "$OFF" = yes ]; then
  ssh_vm 'sudo rm -f /etc/openmessage/alert.env /var/lib/openmessage/alert-state && echo "alerts off"'
  exit 0
fi

if [ "$EMAIL" = yes ]; then
  [ -z "$TOPIC" ] || { echo "--email and --topic don't mix" >&2; exit 2; }
  TOPIC=none
elif [ -z "$TOPIC" ]; then
  TOPIC="om-$(openssl rand -hex 12)"
fi
case "$TOPIC" in *[!A-Za-z0-9_-]*|"") echo "topic may only use letters, digits, - and _" >&2; exit 2 ;; esac
[ -z "$LABEL" ] || [[ "$LABEL" =~ ^[A-Za-z0-9\ _.-]{1,30}$ ]] || { echo "--label: up to 30 letters, digits, spaces, . _ -" >&2; exit 2; }
[ -z "$RECONNECT_URL" ] || [[ "$RECONNECT_URL" =~ ^https://[A-Za-z0-9.-]+/reconnect$ ]] || { echo "--reconnect-url: https://<host>/reconnect" >&2; exit 2; }
TITLE=${LABEL:-Texts}
if [ "$AUDIENCE" = operator ]; then
  TEST_TITLE="$TITLE: alerts are on"
  TEST_BODY="Alerts for $TITLE ($NAME) come here: a notice if their texts connection stops, and when it is back."
else
  TEST_TITLE="$TITLE: alerts are on"
  TEST_BODY="You will get a notice here if your texts connection stops, and when it is back."
fi

# The VM must have om-alert.sh (installed by setup-vm.sh from release v0.3.0-vm2 on).
# alert.env is sourced by sh on the VM, so values are single-quoted (the
# label and topic can't contain quotes: both are checked above).
# Line 1 of stdin is the topic; the rest is the file.
out=$( { printf '%s\n' "$TOPIC"
         if [ "$EMAIL" = yes ]; then echo "ALERT_EMAIL='yes'"; else printf "NTFY_TOPIC='%s'\n" "$TOPIC"; fi
         [ -z "$LABEL" ] || printf "ALERT_NAME='%s'\n" "$LABEL"
         printf "ALERT_AUDIENCE='%s'\n" "$AUDIENCE"
         printf "ALERT_VM='%s'\n" "$NAME"
         [ -z "$RECONNECT_URL" ] || printf "ALERT_RECONNECT_URL='%s'\n" "$RECONNECT_URL"; } | ssh_vm "set -e
  read -r topic
  [ -x /usr/local/bin/om-alert.sh ] || { echo 'om-alert.sh is missing on this VM: upgrade it to a newer release first'; exit 1; }
  if [ \"\$topic\" = none ] && [ ! -x /usr/local/bin/om-notify ]; then echo 'om-notify is missing on this VM: email alerts need release v0.3.0-vm5 or newer'; exit 1; fi
  sudo install -d -m 750 -o root -g openmessage /etc/openmessage
  sudo tee /etc/openmessage/alert.env >/dev/null
  sudo chown root:openmessage /etc/openmessage/alert.env && sudo chmod 640 /etc/openmessage/alert.env
  if [ \"\$topic\" = none ]; then
    sudo /usr/local/bin/om-notify $(printf %q "$TEST_TITLE") $(printf %q "$TEST_BODY") NOTICE && echo 'test notice sent'
  else
    curl -fsS -m 15 -o /dev/null -H $(printf %q "Title: $TEST_TITLE") -H 'Tags: bell' \
      -d $(printf %q "$TEST_BODY") \
      \"https://ntfy.sh/\$topic\" && echo 'test notification sent'
  fi")
echo "$out"
grep -qE 'test (notification|notice) sent' <<<"$out" || { echo "Alerts were not set up (see above)." >&2; exit 1; }
if [ "$EMAIL" = yes ]; then
  echo "Email alerts are on for $NAME: the test notice \"$TEST_TITLE\" should arrive by email within a few minutes."
  exit 0
fi

cat <<EOF

Alerts are on for $NAME ($AUDIENCE). On the phone that should get them:
  1. Install the ntfy app (Play Store or App Store).
  2. Tap +, enter the topic below, and subscribe:
       $TOPIC
     (or open https://ntfy.sh/$TOPIC in a browser)
  3. A "$TEST_TITLE" test notification is already waiting there.
Keep the topic private: anyone who has it can read the alerts.
EOF
