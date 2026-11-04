#!/usr/bin/env bash
# Sets up OpenMessage for one person, start to finish, by running the other
# scripts in order. Resumable: a step that finished is skipped next time, so
# after a failure fix what it says and run the same command again.
#
#   cloud/deploy.sh --user <short-name> --email <their Google email> --project <new-or-existing-id>
#                   [--auth google|access] [--zone us-east1-b] [--name openmessage]
#                   [--tunnel om-vm] [--timezone America/New_York] [--release latest]
#                   [--billing-account <id>] [--restart]
#
# Steps (the ones marked * need a person):
#   1. check this computer (gcloud, Node, Chrome, Wrangler signed in to THEIR Cloudflare)
#   2. Google Cloud project, billing, budget alert          (setup-project.sh)
#   3. VM, release, Cloudflare tunnel                      (vm/create-vm.sh)
#   4. * claude.ai connector Worker                        (worker/setup-connector.sh)
#        google: a Google OAuth client; access: turn on Cloudflare Access
#   5. * pair Google Messages, phone in hand               (vm/reconnect.sh)
#   6. push alerts                                         (vm/set-alerts.sh)
#   7. check everything, add to the fleet file             (doctor.sh)
# Then it prints what to hand over. Before: `gcloud auth login` as an account
# that may create projects and use their billing, and `cd cloud/worker &&
# npm ci && npx wrangler login` as THEIR Cloudflare account.
# --restart forgets which steps finished.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
USER_NAME= EMAIL= PROJECT= AUTH=google ZONE=us-east1-b NAME=openmessage TUNNEL=om-vm
TIMEZONE= RELEASE=latest BILLING= RESTART=no
while [ $# -gt 0 ]; do
  case "$1" in
    --user) USER_NAME=$2; shift 2 ;;
    --email) EMAIL=$2; shift 2 ;;
    --project) PROJECT=$2; shift 2 ;;
    --auth) AUTH=$2; shift 2 ;;
    --zone) ZONE=$2; shift 2 ;;
    --name) NAME=$2; shift 2 ;;
    --tunnel) TUNNEL=$2; shift 2 ;;
    --timezone) TIMEZONE=$2; shift 2 ;;
    --release) RELEASE=$2; shift 2 ;;
    --billing-account) BILLING=$2; shift 2 ;;
    --restart) RESTART=yes; shift ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[ -n "$USER_NAME" ] && [ -n "$EMAIL" ] && [ -n "$PROJECT" ] || { echo "--user, --email and --project are required (see --help)" >&2; exit 2; }
[[ "$USER_NAME" =~ ^[a-z0-9-]+$ ]] || { echo "--user: lowercase letters, digits and - only" >&2; exit 2; }
[[ "$AUTH" == google || "$AUTH" == access ]] || { echo "--auth: google or access" >&2; exit 2; }

STATE_DIR=$HOME/.config/openmessage
DONE=$STATE_DIR/deploy-$USER_NAME.done
mkdir -p "$STATE_DIR"
[ "$RESTART" = no ] || rm -f "$DONE"
touch "$DONE"
VMARGS=(--name "$NAME" --zone "$ZONE" --project "$PROJECT")

done_step() { grep -qx "$1" "$DONE"; }
mark() { echo "$1" >> "$DONE"; }
header() { printf '\n\033[1m== Step %s\033[0m\n' "$*"; }
pause() { read -rp "$1 Press Enter to continue (Ctrl-C to stop) " _; }

echo "Deploying OpenMessage for $USER_NAME <$EMAIL> in project $PROJECT (sign-in: $AUTH)"
if [ -s "$DONE" ]; then echo "Already done: $(paste -sd, "$DONE"). (--restart to redo everything.)"; fi

header "1/7 This computer"
"$HERE/doctor.sh" --pre --project "$PROJECT" || {
  echo "Fix the ✗ items above, then run the same command again." >&2; exit 1; }
echo "Wrangler must be signed in to $USER_NAME's own Cloudflare account (shown above)."
done_step preflight || { pause "Is that the right Cloudflare account?"; mark preflight; }

if ! done_step project; then
  header "2/7 Google Cloud project"
  "$HERE/vm/setup-project.sh" --project "$PROJECT" ${BILLING:+--billing-account "$BILLING"}
  mark project
fi

if ! done_step vm; then
  header "3/7 VM and tunnel (about 5 minutes)"
  if gcloud compute instances describe "$NAME" --zone "$ZONE" --project "$PROJECT" --format='value(name)' >/dev/null 2>&1; then
    echo "VM $NAME already exists; keeping it."
  else
    "$HERE/vm/create-vm.sh" "${VMARGS[@]}" --tunnel "$TUNNEL" --release "$RELEASE" ${TIMEZONE:+--timezone "$TIMEZONE"}
  fi
  mark vm
fi

if ! done_step connector; then
  header "4/7 claude.ai connector"
  (cd "$HERE/worker" && ./setup-connector.sh --user "$USER_NAME" --email "$EMAIL" --tunnel "$TUNNEL" --auth "$AUTH")
  mark connector
fi

if ! done_step pair; then
  header "5/7 Pair Google Messages"
  echo "$USER_NAME needs their Android phone in hand, and you need to sign in to"
  echo "$EMAIL in the Chrome window that opens (or have them do it)."
  pause "Ready?"
  "$HERE/vm/reconnect.sh" "${VMARGS[@]}"
  mark pair
fi

if ! done_step alerts; then
  header "6/7 Alerts"
  "$HERE/vm/set-alerts.sh" "${VMARGS[@]}" | tee "$STATE_DIR/alerts-$USER_NAME.tmp"
  mark alerts
fi
TOPIC=$(grep -oE 'om-[0-9a-f]{24}' "$STATE_DIR/alerts-$USER_NAME.tmp" 2>/dev/null | head -1 || true)
rm -f "$STATE_DIR/alerts-$USER_NAME.tmp"

header "7/7 Check"
URL=$(grep -E '^PUBLIC_URL = "' "$HERE/worker/wrangler.$USER_NAME.toml" | head -1 | cut -d'"' -f2)/mcp
"$HERE/doctor.sh" "${VMARGS[@]}" --connector "$URL" || echo "(Fix the ✗ items above; the rest of the deploy is done.)"
"$HERE/doctor.sh" "${VMARGS[@]}" --connector "$URL" --save "$USER_NAME" >/dev/null
mark checked

cat <<EOF

Done. Hand over to $USER_NAME (in person or a private message):
  1. claude.ai > Settings > Connectors > Add custom connector
       URL: $URL
     then sign in as $EMAIL$( [ "$AUTH" = access ] && echo " (Cloudflare emails a one-time PIN)" ).
     Add it at claude.ai in a browser signed in to their Claude account; it
     then shows up in the desktop and phone apps too.
  2. Install the ntfy app and subscribe to the alert topic${TOPIC:+: $TOPIC}
  3. Their guide: cloud/USER-GUIDE.md
Check on it any time: cloud/doctor.sh --all
EOF
