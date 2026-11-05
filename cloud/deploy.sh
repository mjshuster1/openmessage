#!/usr/bin/env bash
# Sets up OpenMessage for one client, start to finish, by running the other
# scripts in order. Resumable: a step that finished is skipped next time, so
# after a failure fix what it says and run the same command again.
#
#   cloud/deploy.sh --user <short-name> --email <their Google email> --project <new-or-existing-id>
#                   [--label "Mike"] [--auth google|access] [--zone us-east1-b]
#                   [--timezone America/New_York] [--release latest]
#                   [--billing-account <id>] [--alerts email|none] [--alert-email <address>] [--restart]
#                   [--name om-<user>] [--tunnel om-<user>] [--worker om-<user>] [--port auto]
#                   [--client-owned]
#
# --client-owned: everything goes in the client's OWN Google Cloud and
# Cloudflare accounts (gcloud and Wrangler signed in as the client), so the
# operator can't read their texts afterwards. Needs --alert-email (the
# operator's address; gcloud is signed in as the client). Its last step runs
# handback.sh, which removes this computer's access and prints a report for
# the client. Later checks go through the status-only link (doctor.sh --all).
#
# Hosted on the operator's accounts: every client's VM, tunnel and connector
# Worker is named om-<user> (KV namespace om-<user>-oauth), and each client
# gets its own Workers VPC port (Cloudflare allows one service per host:port
# per account): --port auto takes the client's existing one, or the lowest
# free port from 7101 up. The VM forwards that port to OpenMessage.
# Alerts (--alerts email, the default) are emails to the operator, from the
# client's own Google Cloud project: the VM logs each notice and an alert
# policy there mails it (vm/set-email-alerts.sh, vm/set-alerts.sh --email),
# labelled with --label. The client installs nothing. --alert-email defaults
# to the account gcloud is signed in as. --alerts none skips them.
#
# Steps (the ones marked * need a person):
#   1. check this computer (gcloud, Node, Chrome, Wrangler signed in to the hosting Cloudflare)
#   2. Google Cloud project, billing, budget alert          (setup-project.sh)
#   3. VM, release, Cloudflare tunnel                      (vm/create-vm.sh)
#   4. * claude.ai connector Worker                        (worker/setup-connector.sh)
#        google: a Google OAuth client; access: turn on Cloudflare Access
#   5. * pair Google Messages, phone in hand               (vm/reconnect.sh)
#   6. email alerts to the operator                        (vm/set-email-alerts.sh, set-alerts.sh)
#   7. check everything, add to the fleet file             (doctor.sh)
# Then it prints what to hand over. Before: `gcloud auth login` as an account
# that may create projects and use the billing account, and `cd cloud/worker &&
# npm ci && npx wrangler login` as the Cloudflare account that hosts clients.
# --restart forgets which steps finished.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
USER_NAME= EMAIL= PROJECT= AUTH=google ZONE=us-east1-b NAME= TUNNEL= WORKER= PORT=auto
TIMEZONE= RELEASE=latest BILLING= RESTART=no LABEL= ALERTS=email ALERT_EMAIL= CLIENT_OWNED=no
while [ $# -gt 0 ]; do
  case "$1" in
    --user) USER_NAME=$2; shift 2 ;;
    --email) EMAIL=$2; shift 2 ;;
    --project) PROJECT=$2; shift 2 ;;
    --auth) AUTH=$2; shift 2 ;;
    --zone) ZONE=$2; shift 2 ;;
    --name) NAME=$2; shift 2 ;;
    --tunnel) TUNNEL=$2; shift 2 ;;
    --worker) WORKER=$2; shift 2 ;;
    --port) PORT=$2; shift 2 ;;
    --label) LABEL=$2; shift 2 ;;
    --alerts) ALERTS=$2; shift 2 ;;
    --alert-email) ALERT_EMAIL=$2; shift 2 ;;
    --timezone) TIMEZONE=$2; shift 2 ;;
    --release) RELEASE=$2; shift 2 ;;
    --billing-account) BILLING=$2; shift 2 ;;
    --restart) RESTART=yes; shift ;;
    --client-owned) CLIENT_OWNED=yes; shift ;;
    -h|--help) sed -n '2,43p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[ -n "$USER_NAME" ] && [ -n "$EMAIL" ] && [ -n "$PROJECT" ] || { echo "--user, --email and --project are required (see --help)" >&2; exit 2; }
[[ "$USER_NAME" =~ ^[a-z0-9-]+$ ]] || { echo "--user: lowercase letters, digits and - only" >&2; exit 2; }
[[ "$AUTH" == google || "$AUTH" == access ]] || { echo "--auth: google or access" >&2; exit 2; }
[[ "$ALERTS" == email || "$ALERTS" == none ]] || { echo "--alerts: email or none" >&2; exit 2; }
[[ "$PORT" == auto || "$PORT" =~ ^[0-9]+$ ]] || { echo "--port: auto or a number" >&2; exit 2; }
if [ "$CLIENT_OWNED" = yes ] && [ "$ALERTS" = email ] && [ -z "$ALERT_EMAIL" ]; then
  echo "--client-owned needs --alert-email <your address> (gcloud is signed in as the client)" >&2; exit 2
fi
NAME=${NAME:-om-$USER_NAME} TUNNEL=${TUNNEL:-om-$USER_NAME} WORKER=${WORKER:-om-$USER_NAME}
LABEL=${LABEL:-$USER_NAME}
[[ "$LABEL" =~ ^[A-Za-z0-9\ _.-]{1,30}$ ]] || { echo "--label: up to 30 letters, digits, spaces, . _ -" >&2; exit 2; }

STATE_DIR=$HOME/.config/openmessage
DONE=$STATE_DIR/deploy-$USER_NAME.done
mkdir -p "$STATE_DIR"
[ "$RESTART" = no ] || rm -f "$DONE"
touch "$DONE"
VMARGS=(--name "$NAME" --zone "$ZONE" --project "$PROJECT")
PORT_FILE=$STATE_DIR/port-$USER_NAME
W() { (cd "$HERE/worker" && npx --no-install wrangler "$@"); }

# The client's Workers VPC port: the one its VPC service already has, else the
# lowest port from 7101 that no VPC service and no unfinished deploy uses.
pick_port() {
  local list mine used p
  list=$(W vpc service list 2>/dev/null) || { echo "Couldn't list Workers VPC services; is Wrangler signed in?" >&2; return 1; }
  mine=$(awk -F'│' -v n="$WORKER-origin" '{gsub(/ /,"",$3)} $3 == n {print $5}' <<<"$list" | grep -oE '[0-9]+' | head -1 || true)
  if [ -n "$mine" ]; then echo "$mine"; return 0; fi
  used=$( { awk -F'│' '{print $5}' <<<"$list" | grep -oE 'HTTP:[0-9]+' | cut -d: -f2;
            for f in "$STATE_DIR"/port-*; do [ -f "$f" ] && [ "$f" != "$PORT_FILE" ] && cat "$f"; done; } || true)
  p=7101
  while grep -qx "$p" <<<"$used"; do p=$((p + 1)); done
  echo "$p"
}

done_step() { grep -qx "$1" "$DONE"; }
mark() { echo "$1" >> "$DONE"; }
header() { printf '\n\033[1m== Step %s\033[0m\n' "$*"; }
pause() { read -rp "$1 Press Enter to continue (Ctrl-C to stop) " _; }

echo "Deploying OpenMessage for $USER_NAME <$EMAIL> in project $PROJECT (sign-in: $AUTH)"
if [ -s "$DONE" ]; then echo "Already done: $(paste -sd, "$DONE"). (--restart to redo everything.)"; fi

header "1/7 This computer"
"$HERE/doctor.sh" --pre --project "$PROJECT" || {
  echo "Fix the ✗ items above, then run the same command again." >&2; exit 1; }
if [ "$CLIENT_OWNED" = yes ]; then
  echo "Client-owned: gcloud and Wrangler (shown above) must both be signed in as $USER_NAME, not you."
  done_step preflight || { pause "Are both $USER_NAME's own accounts?"; mark preflight; }
else
  echo "Wrangler must be signed in to the Cloudflare account that hosts clients (shown above)."
  done_step preflight || { pause "Is that the right Cloudflare account?"; mark preflight; }
fi

if ! done_step project; then
  header "2/7 Google Cloud project"
  "$HERE/vm/setup-project.sh" --project "$PROJECT" ${BILLING:+--billing-account "$BILLING"}
  mark project
fi

if [ "$PORT" = auto ]; then
  PORT=$(cat "$PORT_FILE" 2>/dev/null || true)
  [ -n "$PORT" ] || PORT=$(pick_port) || exit 1
fi
echo "$PORT" > "$PORT_FILE"
echo "Names: VM $NAME, tunnel $TUNNEL, Worker $WORKER; Workers VPC port $PORT"

if ! done_step vm; then
  header "3/7 VM and tunnel (about 5 minutes)"
  if gcloud compute instances describe "$NAME" --zone "$ZONE" --project "$PROJECT" --format='value(name)' >/dev/null 2>&1; then
    echo "VM $NAME already exists; keeping it."
    [ "$PORT" = 7007 ] || "$HERE/vm/create-vm.sh" "${VMARGS[@]}" --origin-port "$PORT"
  else
    "$HERE/vm/create-vm.sh" "${VMARGS[@]}" --tunnel "$TUNNEL" --release "$RELEASE" --origin-port "$PORT" ${TIMEZONE:+--timezone "$TIMEZONE"}
  fi
  mark vm
fi

if ! done_step connector; then
  header "4/7 claude.ai connector"
  (cd "$HERE/worker" && ./setup-connector.sh --user "$USER_NAME" --email "$EMAIL" --tunnel "$TUNNEL" --worker "$WORKER" --port "$PORT" --auth "$AUTH")
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
  if [ "$ALERTS" = email ]; then
    "$HERE/vm/set-email-alerts.sh" --project "$PROJECT" ${ALERT_EMAIL:+--email "$ALERT_EMAIL"}
    "$HERE/vm/set-alerts.sh" "${VMARGS[@]}" --email --label "$LABEL"
  else
    echo "Skipped (--alerts none)."
  fi
  mark alerts
fi

header "7/7 Check"
URL=$(grep -E '^PUBLIC_URL = "' "$HERE/worker/wrangler.$USER_NAME.toml" | head -1 | cut -d'"' -f2)/mcp
"$HERE/doctor.sh" "${VMARGS[@]}" --connector "$URL" || echo "(Fix the ✗ items above; the rest of the deploy is done.)"
"$HERE/doctor.sh" "${VMARGS[@]}" --connector "$URL" --save "$USER_NAME" >/dev/null
mark checked
rm -f "$PORT_FILE"   # the VPC service holds the port now
STATUS_FILE=$HOME/.config/openmessage/status-$USER_NAME.url

if [ "$CLIENT_OWNED" = yes ]; then
  cat <<EOF

Next: $USER_NAME adds the connector in claude.ai (in a browser, signed in to
their Claude account):
  URL: $URL
  then sign in as $EMAIL$( [ "$AUTH" = access ] && echo " (Cloudflare emails a one-time PIN)" ).
Check together that "what are my last three texts?" works.
EOF
  pause "Once that works, hand the accounts back."
  header "8/8 Hand back"
  "$HERE/handback.sh" --user "$USER_NAME" --email "$EMAIL" --project "$PROJECT" --zone "$ZONE" --name "$NAME" \
    || echo "(Fix the ✗ items above, then run cloud/handback.sh again with the same options.)"
  cat <<EOF

Done. Give $USER_NAME their guide (cloud/USER-GUIDE.md) and the report above.
Alerts come to $ALERT_EMAIL (subject starts "$LABEL:").
Check on it any time: cloud/doctor.sh --all$( [ -s "$STATUS_FILE" ] && echo ", or the status link in $STATUS_FILE")
EOF
  exit 0
fi

cat <<EOF

Done. Hand over to $USER_NAME (in person or a private message):
  1. claude.ai > Settings > Connectors > Add custom connector
       URL: $URL
     then sign in as $EMAIL$( [ "$AUTH" = access ] && echo " (Cloudflare emails a one-time PIN)" ).
     Add it at claude.ai in a browser signed in to their Claude account; it
     then shows up in the desktop and phone apps too.
  2. Nothing else for them to install. Alerts come to you by email
     (subject starts "$LABEL:").
  3. Their guide: cloud/USER-GUIDE.md
Check on it any time: cloud/doctor.sh --all
EOF
