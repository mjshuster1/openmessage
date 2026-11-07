#!/usr/bin/env bash
# Sets up "your texts in Claude" from the client's own browser, in Google Cloud
# Shell. Nobody else's computer touches their accounts, so there is nothing to
# hand back afterwards. It asks a few plain questions, checks the accounts
# before anything is created, then runs deploy.sh --client-owned --from-browser.
#
# Start it from https://shell.cloud.google.com/?show=terminal by pasting
# (CLIENT-SETUP.md has this line with your address in it):
#
#   git -C openmessage pull -q 2>/dev/null || git clone -q --depth 1 https://github.com/mjshuster1/openmessage; openmessage/cloud/setup.sh --helper-email you@example.com
#
# The same line ending in --update refreshes the connector on an existing setup
# (same address, sign-in and links); ending in --remove deletes the whole setup
# after asking. Both find the setup from the accounts, so they still work after
# Cloud Shell has cleared its files. Running plain setup when one already exists
# says so, rather than building a second server.
#
# --helper-email: who else gets status emails and the setup-finished email
# (status only, never messages). Run the same line again to carry on after any
# stop: finished steps are skipped and the answers are remembered.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
HELPER_EMAIL=
MODE=setup
while [ $# -gt 0 ]; do
  case "$1" in
    --helper-email) HELPER_EMAIL=$2; shift 2 ;;
    --update) MODE=update; shift ;;
    --remove) MODE=remove; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[ -z "$HELPER_EMAIL" ] || [[ "$HELPER_EMAIL" == *@*.* ]] || { echo "--helper-email doesn't look like an email address" >&2; exit 2; }
STATE_DIR=$HOME/.config/openmessage
ANSWERS=$STATE_DIR/setup.env
mkdir -p "$STATE_DIR"
stop() { printf '\n%s\n\nFix that, then paste the same line again to carry on.\n' "$*" >&2; exit 1; }
# Ctrl+C is how Windows people copy, and here it cancels (first real client,
# 2026-11-06). deploy.sh, which this hands over to, sets the same trap.
trap 'printf "\n\nStopped: in this window Ctrl+C cancels instead of copying. Nothing is lost.\nPaste the same line again to carry on.\n" >&2; exit 130' INT

printf '\n\033[1mYour texts in Claude: setup\033[0m\n'
echo "In this window, Ctrl+C cancels. To copy, highlight the text and right-click."
[ "${CLOUD_SHELL:-}" = true ] || [ -n "${DEVSHELL_PROJECT_ID+x}" ] || {
  echo "This doesn't look like Google Cloud Shell. Open https://shell.cloud.google.com/?show=terminal and run it there."
  read -rp "Carry on here anyway? [y/N] " yn; [[ "$yn" == [yY]* ]] || exit 1
}

# ---------------------------------------------------------------- tools
for c in gcloud git curl jq; do command -v "$c" >/dev/null || stop "$c is missing here."; done
if ! command -v node >/dev/null || ! node -e 'process.exit(+process.versions.node.split(".")[0] >= 22 ? 0 : 1)'; then
  echo "Getting a current version of Node (a minute)..."
  # shellcheck disable=SC1091
  . "${NVM_DIR:-/usr/local/nvm}/nvm.sh" 2>/dev/null || stop "Couldn't find nvm to install Node 22."
  nvm install 22 >/dev/null 2>&1 && nvm use 22 >/dev/null || stop "Couldn't install Node 22."
fi
(cd "$HERE/worker" && { [ -d node_modules ] || { echo "Getting the setup tools (a minute)..."; npm ci --silent --no-audit --no-fund >/dev/null; }; })
W() { (cd "$HERE/worker" && npx --no-install wrangler "$@"); }

# ---------------------------------------------------------------- Google
echo
echo "Checking your Google Cloud account. If a box asks to authorize Cloud Shell, click Authorize."
gcloud auth print-access-token >/dev/null 2>&1 || stop "Couldn't reach your Google Cloud account."
EMAIL=$(gcloud config get-value account 2>/dev/null | tr '[:upper:]' '[:lower:]')
[[ "$EMAIL" == *@*.* ]] || stop "Cloud Shell isn't signed in to a Google account."
open_billing=$(gcloud billing accounts list --filter='open=true' --format='value(name)' 2>/dev/null | grep -c . || true)
[ "$MODE" != setup ] || [ "$open_billing" -gt 0 ] || stop "✗ No billing on this Google account yet. Add a card at https://console.cloud.google.com/billing (about \$4 a month)."
[ "$MODE" != setup ] || [ "$open_billing" = 1 ] || echo "  (You have $open_billing billing accounts; setup will ask which one.)"
echo "  ✓ Signed in as $EMAIL"

# ---------------------------------------------------------------- answers
USER_NAME= LABEL= PROJECT= TIMEZONE=
# shellcheck disable=SC1090
[ -f "$ANSWERS" ] && . "$ANSWERS"
# The setup these accounts already have: project, VM and zone. Cloud Shell's
# files may be long gone, so this asks Google, not the answers file.
find_existing() {
  FOUND_PROJECT= FOUND_VM= FOUND_ZONE=
  local p line
  for p in $(gcloud projects list --filter='projectId~^openmessage-' --format='value(projectId)' 2>/dev/null </dev/null || true); do
    line=$(gcloud compute instances list --project "$p" --filter='name~^om-' --format='value(name,zone.basename())' 2>/dev/null </dev/null | head -1 || true)
    if [ -n "$line" ]; then
      FOUND_PROJECT=$p FOUND_VM=${line%%[[:space:]]*} FOUND_ZONE=${line##*[[:space:]]}
      return 0
    fi
  done
  return 1
}
already_line() {
  echo "You already have a setup: server $FOUND_VM in project $FOUND_PROJECT."
  echo "Nothing was changed. To refresh it, or to delete it, paste the same line with"
  echo "--update or --remove on the end, or contact whoever helped you set this up."
}
if [ "$MODE" = setup ]; then
  if [ -n "$USER_NAME" ] && grep -qx "$USER_NAME" "$STATE_DIR/handed-back" 2>/dev/null; then
    echo
    echo "Setup already finished for $LABEL, so nothing was changed."
    echo "Your links came by email. To refresh it, or to delete it, paste the same line"
    echo "with --update or --remove on the end."
    exit 0
  fi
  if [ -z "$USER_NAME" ] && find_existing; then echo; already_line; exit 0; fi
else
  find_existing || stop "✗ No setup found in this Google account ($EMAIL)."
  USER_NAME=${FOUND_VM#om-} PROJECT=$FOUND_PROJECT
fi
if [ -z "$USER_NAME" ]; then
  while :; do
    read -rp "Your first name: " LABEL
    USER_NAME=$(tr '[:upper:]' '[:lower:]' <<<"$LABEL" | tr -cd 'a-z0-9-')
    [ -n "$USER_NAME" ] && [[ "$LABEL" =~ ^[A-Za-z0-9\ _.-]{1,30}$ ]] && break
    echo "  Letters and numbers only, please."
  done
  # Project ids are global, so a plain name may be taken.
  PROJECT="openmessage-${USER_NAME:0:12}-$(openssl rand -hex 2)"
  echo "Your time zone:"
  select tz in Eastern Central Mountain Pacific Other; do
    case "$tz" in
      Eastern) TIMEZONE=America/New_York ;;
      Central) TIMEZONE=America/Chicago ;;
      Mountain) TIMEZONE=America/Denver ;;
      Pacific) TIMEZONE=America/Los_Angeles ;;
      Other) read -rp "Time zone name (like Europe/London): " TIMEZONE ;;
      *) continue ;;
    esac
    break
  done
  [[ "$TIMEZONE" =~ ^[A-Za-z_]+/[A-Za-z_/+-]+$ ]] || stop "That doesn't look like a time zone name."
  # %q so a name with a space reads back correctly.
  (umask 077; printf 'USER_NAME=%q\nLABEL=%q\nPROJECT=%q\nTIMEZONE=%q\n' "$USER_NAME" "$LABEL" "$PROJECT" "$TIMEZONE" > "$ANSWERS")
fi

# ---------------------------------------------------------------- Cloudflare
echo
echo "Checking your Cloudflare account."
if ! who=$(W whoami --json 2>/dev/null) || [ "$(jq -r '.loggedIn // (.accounts != null)' <<<"$who" 2>/dev/null)" != true ]; then
  echo "Open the link below, sign in to Cloudflare if asked, and approve it."
  W login --device || stop "✗ Cloudflare sign-in didn't finish."
  who=$(W whoami --json 2>/dev/null) || stop "✗ Cloudflare sign-in didn't finish."
fi
n=$(jq -r '.accounts | length' <<<"$who")
[ "$n" -gt 0 ] || stop "✗ This Cloudflare sign-in has no account."
if [ "$n" -gt 1 ] && [ -z "${CLOUDFLARE_ACCOUNT_ID:-}" ]; then
  echo "This sign-in has $n Cloudflare accounts:"
  jq -r '.accounts | to_entries[] | "  \(.key + 1). \(.value.name)"' <<<"$who"
  read -rp "Which number? " pick
  [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le "$n" ] || stop "That isn't one of the numbers."
  CLOUDFLARE_ACCOUNT_ID=$(jq -r --argjson i "$((pick - 1))" '.accounts[$i].id' <<<"$who")
  export CLOUDFLARE_ACCOUNT_ID
fi
ACCT=${CLOUDFLARE_ACCOUNT_ID:-$(jq -r '.accounts[0].id' <<<"$who")}
# A new account has no workers.dev address until one is chosen, and the first
# deploy would stop to ask.
TOKEN=$(W auth token 2>/dev/null | tail -1)
CF=https://api.cloudflare.com/client/v4/accounts/$ACCT/workers/subdomain
sub=$(curl -s -m 20 -H "Authorization: Bearer $TOKEN" "$CF" | jq -r '.result.subdomain // empty')
if [ -z "$sub" ]; then
  want="om-${USER_NAME:0:12}-$(openssl rand -hex 2)"
  sub=$(curl -s -m 20 -X PUT -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "{\"subdomain\":\"$want\"}" "$CF" | jq -r '.result.subdomain // empty')
  [ -n "$sub" ] || stop "✗ Couldn't set up a workers.dev address. Open Workers & Pages in the Cloudflare dashboard once, then try again."
fi
unset TOKEN
echo "  ✓ Signed in as $(jq -r '.email // "your account"' <<<"$who"), Workers address $sub.workers.dev"

if [ "$MODE" = update ]; then
  echo
  echo "Refreshing your connector (its address, sign-in and links stay the same)."
  (cd "$HERE/worker" && ./setup-connector.sh --update --account-confirmed --user "$USER_NAME" --email "$EMAIL" \
     --tunnel "$FOUND_VM" --worker "$FOUND_VM" --reconnect --project "$PROJECT" \
     --public-url "https://$FOUND_VM.$sub.workers.dev") >/dev/null || stop "✗ The refresh didn't finish."
  W logout >/dev/null 2>&1 || true
  echo "  ✓ Done. Nothing else changed. You can close this tab."
  exit 0
fi
if [ "$MODE" = remove ]; then
  cat <<EOF

This deletes your texts setup for good: the server, the texts stored on it, its
backups and your connector. Your texts on your phone aren't touched. Google
keeps the deleted project recoverable for 30 days, and then it's gone.
EOF
  "$HERE/teardown.sh" --user "$USER_NAME" --project "$PROJECT" --zone "$FOUND_ZONE" --name "$FOUND_VM" \
    --tunnel "$FOUND_VM" --worker "$FOUND_VM" --delete-project || stop "✗ Not everything was removed (see above)."
  W logout >/dev/null 2>&1 || true
  rm -f "$ANSWERS"
  echo "  ✓ Removed. You can close this tab."
  exit 0
fi

echo
echo "All checks passed. Project: $PROJECT"
exec "$HERE/deploy.sh" --client-owned --from-browser --user "$USER_NAME" --email "$EMAIL" --project "$PROJECT" \
  --label "$LABEL" --timezone "$TIMEZONE" --alert-email "${HELPER_EMAIL:-$EMAIL}"
