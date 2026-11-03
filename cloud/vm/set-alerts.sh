#!/usr/bin/env bash
# Turns on push alerts for an OpenMessage VM and sends a test notification.
#
#   cloud/vm/set-alerts.sh [--name om-test] [--zone us-east1-b] [--project <id>]
#                          [--topic <existing topic>] [--off]
#
# Alerts go through ntfy (ntfy.sh): install the ntfy app (Android or iPhone),
# tap +, and subscribe to the topic this prints. No account is needed. The topic
# name is the only secret: anyone who knows it can read the alerts. That's why
# it's long and random, and why alerts carry status only, never message text.
# --off removes the config (alerts stop; nothing else changes).
set -euo pipefail

NAME=om-test
ZONE=us-east1-b
PROJECT_ARGS=()
TOPIC=
OFF=no
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME=$2; shift 2 ;;
    --zone) ZONE=$2; shift 2 ;;
    --project) PROJECT_ARGS=(--project "$2"); shift 2 ;;
    --topic) TOPIC=$2; shift 2 ;;
    --off) OFF=yes; shift ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
G=(gcloud ${PROJECT_ARGS[@]+"${PROJECT_ARGS[@]}"})
ssh_vm() { "${G[@]}" compute ssh --quiet "$NAME" --zone "$ZONE" -- "$@" 2>&1 | { grep -v 'Pseudo-terminal' || true; }; }

if [ "$OFF" = yes ]; then
  ssh_vm 'sudo rm -f /etc/openmessage/alert.env /var/lib/openmessage/alert-state && echo "alerts off"'
  exit 0
fi

if [ -z "$TOPIC" ]; then
  TOPIC="om-$(openssl rand -hex 12)"
fi
case "$TOPIC" in *[!A-Za-z0-9_-]*|"") echo "topic may only use letters, digits, - and _" >&2; exit 2 ;; esac

# The VM must have om-alert.sh (installed by setup-vm.sh from release v0.3.0-vm2 on).
out=$(printf 'NTFY_TOPIC=%s\n' "$TOPIC" | ssh_vm 'set -e
  read -r line
  [ -x /usr/local/bin/om-alert.sh ] || { echo "om-alert.sh is missing on this VM: upgrade it to a newer release first"; exit 1; }
  sudo install -d -m 750 -o root -g openmessage /etc/openmessage
  printf "%s\n" "$line" | sudo tee /etc/openmessage/alert.env >/dev/null
  sudo chown root:openmessage /etc/openmessage/alert.env && sudo chmod 640 /etc/openmessage/alert.env
  NTFY_TOPIC=${line#NTFY_TOPIC=}
  curl -fsS -m 15 -o /dev/null -H "Title: Texts: alerts are on" -H "Tags: bell" \
    -d "You will get a notice here if your texts connection stops, and when it is back." \
    "https://ntfy.sh/$NTFY_TOPIC" && echo "test notification sent"')
echo "$out"
grep -q 'test notification sent' <<<"$out" || { echo "Alerts were not set up (see above)." >&2; exit 1; }

cat <<EOF

Alerts are on for $NAME. On the phone that should get them:
  1. Install the ntfy app (Play Store or App Store).
  2. Tap +, enter the topic below, and subscribe:
       $TOPIC
     (or open https://ntfy.sh/$TOPIC in a browser)
  3. A "Texts: alerts are on" test notification is already waiting there.
Keep the topic private: anyone who has it can read the alerts.
EOF
