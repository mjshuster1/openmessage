#!/usr/bin/env bash
# Hands a client-owned setup back: removes every way this computer (the
# operator) got into the client's Google Cloud project and Cloudflare account
# during setup, then checks it and prints a report the client can read.
# Run it at the end of setup, with the client watching. deploy.sh
# --client-owned runs it as its last step.
#
#   cloud/handback.sh --user <short-name> --email <client's Google email> --project <id>
#                     [--zone us-east1-b] [--name om-<user>] [--dry-run] [--yes]
#
# It removes, where it finds them:
#   1. this computer's SSH key from the project's and the VM's metadata
#      (gcloud compute ssh added it);
#   2. every person other than --email from the project's permissions (IAM).
#      Service accounts stay: the VM runs as one;
#   3. local setup leftovers: the deploy state file, the port file, any
#      Google cookie file left in the usual places;
#   4. Wrangler's sign-in to the client's Cloudflare (wrangler logout) after
#      you confirm whoami shows the client's account;
#   5. gcloud's sign-in as the client (gcloud auth revoke --email), and the
#      gcloud configuration named after the user, if there is one.
# Then it checks that no account still signed in to gcloud here can open the
# project, and writes the report to ~/.config/openmessage/handback-<user>.txt.
#
# --from-browser: setup ran in the client's own Cloud Shell, so no other
# computer ever held a sign-in. It still removes the SSH key and checks who has
# access, signs Wrangler out without asking, and leaves their gcloud sign-in
# alone (it's Cloud Shell's own).
#
# Kept on purpose (the report says so): the status-only link (connected or
# not, newest text's age), the status emails, cloud/worker/wrangler.<user>.toml
# (resource ids, no secrets) and the fleet entry, which doctor.sh --all then
# checks through the status link. Updates still come from the operator's
# GitHub releases unless the VM was created with --release <tag>.
#
# Run it with gcloud still signed in to an account that can change the
# project (the client's, or yours if the client added you). Afterwards, to
# help again the client must let you back in (a gcloud sign-in or IAM).
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
STATE_DIR=$HOME/.config/openmessage
mkdir -p "$STATE_DIR"
USER_NAME= EMAIL= PROJECT= ZONE=us-east1-b NAME= DRY=no YES=no FROM_BROWSER=no
while [ $# -gt 0 ]; do
  case "$1" in
    --user) USER_NAME=$2; shift 2 ;;
    --email) EMAIL=$2; shift 2 ;;
    --project) PROJECT=$2; shift 2 ;;
    --zone) ZONE=$2; shift 2 ;;
    --name) NAME=$2; shift 2 ;;
    --dry-run) DRY=yes; shift ;;
    --yes) YES=yes; shift ;;
    --from-browser) FROM_BROWSER=yes; shift ;;
    -h|--help) sed -n '2,38p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[ -n "$USER_NAME" ] && [ -n "$EMAIL" ] && [ -n "$PROJECT" ] || { echo "--user, --email and --project are required (see --help)" >&2; exit 2; }
[[ "$USER_NAME" =~ ^[a-z0-9-]+$ ]] || { echo "--user: lowercase letters, digits and - only" >&2; exit 2; }
EMAIL=$(tr '[:upper:]' '[:lower:]' <<<"$EMAIL")
NAME=${NAME:-om-$USER_NAME}
command -v jq >/dev/null || { echo "jq is needed (brew install jq)" >&2; exit 1; }

REPORT=()   # lines for the client
TODO=()     # things that didn't work
note() { echo "   $*"; }
did() { REPORT+=("✓ $*"); note "✓ $*"; }
fail() { TODO+=("$*"); note "✗ $*"; }
run() { if [ "$DRY" = yes ]; then note "(dry run) $*"; else "$@"; fi; }
ask() { [ "$YES" = yes ] && return 0; read -rp "   $1 [y/N] " yn; [[ "$yn" == [yY]* ]]; }
W() { (cd "$HERE/worker" && npx --no-install wrangler "$@"); }
G=(gcloud --project "$PROJECT" --quiet)

echo "Handing $PROJECT back to $EMAIL$( [ "$DRY" = yes ] && echo " (dry run: changes nothing)")"

# ------------------------------------------------------------ 1. SSH keys
echo
echo "1/5 SSH keys"
PUB=$HOME/.ssh/google_compute_engine.pub
mykey=$( [ -f "$PUB" ] && awk '{print $2}' "$PUB" || true)
strip_keys() { # scope: project | instance
  local scope=$1 json keys left
  if [ "$scope" = project ]; then
    json=$("${G[@]}" compute project-info describe --format=json 2>/dev/null) || { fail "couldn't read the project's SSH keys"; return; }
  else
    json=$("${G[@]}" compute instances describe "$NAME" --zone "$ZONE" --format=json 2>/dev/null) || { note "no VM $NAME (skipped)"; return; }
  fi
  keys=$(jq -r '(.commonInstanceMetadata // .metadata).items[]? | select(.key == "ssh-keys") | .value' <<<"$json") \
    || { fail "couldn't read the $scope's SSH keys"; return; }
  if [ -z "$keys" ]; then did "no SSH keys on the $scope"; return; fi
  # Every key here was added by setup (the client never uses SSH), but keep
  # any that isn't this computer's and list it, so nothing is removed blindly.
  left=$(grep -v -F "${mykey:-__none__}" <<<"$keys" || true)
  local n_all n_left; n_all=$(grep -c . <<<"$keys"); n_left=$(grep -c . <<<"$left" || true)
  if [ "$n_all" = "$n_left" ]; then
    note "this computer's key isn't on the $scope"
  else
    if [ -z "$left" ]; then
      if [ "$scope" = project ]; then run "${G[@]}" compute project-info remove-metadata --keys ssh-keys >/dev/null 2>&1
      else run "${G[@]}" compute instances remove-metadata "$NAME" --zone "$ZONE" --keys ssh-keys >/dev/null 2>&1; fi
    else
      local f; f=$(mktemp); printf '%s\n' "$left" > "$f"
      if [ "$scope" = project ]; then run "${G[@]}" compute project-info add-metadata --metadata-from-file ssh-keys="$f" >/dev/null 2>&1
      else run "${G[@]}" compute instances add-metadata "$NAME" --zone "$ZONE" --metadata-from-file ssh-keys="$f" >/dev/null 2>&1; fi
      rm -f "$f"
    fi && did "removed the operator's SSH key from the $scope" || fail "couldn't remove the SSH key from the $scope"
  fi
  if [ -n "$left" ]; then
    fail "other SSH keys remain on the $scope (users: $(awk -F: '{print $1}' <<<"$left" | sort -u | paste -sd, -)); remove them in the console (Compute Engine > Metadata > SSH keys) if they aren't the client's"
  fi
}
strip_keys project
strip_keys instance
# The VM keeps the login user's home directory (and authorized_keys, now
# unmanaged); with the metadata key gone, Google's guest agent removes the key
# from authorized_keys on its next metadata sync.

# ------------------------------------------------------------ 2. IAM
echo
echo "2/5 Who can open the project"
policy=$("${G[@]}" projects get-iam-policy "$PROJECT" --format=json 2>/dev/null)
if [ -z "$policy" ]; then
  fail "couldn't read the project's permissions (is gcloud signed in to an account that can?)"
else
  others=$(jq -r --arg me "user:$EMAIL" '[.bindings[] | .role as $r | .members[] | select((startswith("user:") or startswith("group:") or startswith("domain:")) and (ascii_downcase != $me)) | "\(.)\t\($r)"] | unique | sort_by(split("\t")[1] == "roles/owner")[]' <<<"$policy")
  if [ -z "$others" ]; then
    did "only $EMAIL (and the VM's own service accounts) has access"
  else
    note "Others with access:"
    sed 's/^/      /' <<<"$others"
    if ask "Remove all of them?"; then
      while IFS=$'\t' read -r member role; do
        run "${G[@]}" projects remove-iam-policy-binding "$PROJECT" --member "$member" --role "$role" --condition=None >/dev/null 2>&1 \
          && did "removed $member ($role)" || fail "couldn't remove $member ($role)"
      done <<<"$others"
    else
      fail "others still have access to the project: $(cut -f1 <<<"$others" | sort -u | paste -sd, -)"
    fi
  fi
  jq -e --arg me "user:$EMAIL" '[.bindings[] | select(.role == "roles/owner") | .members[]] | map(ascii_downcase) | index($me)' <<<"$policy" >/dev/null \
    || fail "$EMAIL isn't an Owner of the project; add them in the console (IAM) before anyone else is removed"
fi

# ------------------------------------------------------------ 3. local files
echo
echo "3/5 Setup leftovers on this computer"
for f in "$STATE_DIR/deploy-$USER_NAME.done" "$STATE_DIR/port-$USER_NAME"; do
  [ -e "$f" ] && { run rm -f "$f"; did "deleted $(basename "$f")"; }
done
found=$(find "$HOME/Downloads" "$HOME/Desktop" "$HERE" "${TMPDIR:-/tmp}" -maxdepth 3 \( -name 'google-cookies*.json' -o -name 'om-google-cookies*.json' \) 2>/dev/null || true)
if [ -n "$found" ]; then
  while IFS= read -r f; do run rm -f "$f" && did "deleted a Google login file ($f)"; done <<<"$found"
else
  did "no Google login files left on this computer"
fi

# ------------------------------------------------------------ 4. Cloudflare
echo
echo "4/5 Cloudflare sign-in"
if who=$(W whoami --json 2>/dev/null) && [ -n "$who" ]; then
  note "Wrangler is signed in as: $(jq -r '"\(.email) (\([.accounts[]?.name] | join(", ")))"' <<<"$who" 2>/dev/null)"
  if [ "$FROM_BROWSER" = yes ] || ask "Is that $USER_NAME's Cloudflare account? Sign Wrangler out of it?"; then
    run W logout >/dev/null 2>&1 && did "signed this computer out of the client's Cloudflare account" || fail "wrangler logout failed"
    [ "$FROM_BROWSER" = yes ] || note "(sign back in to your own Cloudflare later with: cd cloud/worker && npx wrangler login)"
  else
    fail "Wrangler is still signed in to a Cloudflare account; if it's the client's, run: cd cloud/worker && npx wrangler logout"
  fi
else
  did "Wrangler isn't signed in to any Cloudflare account here"
fi
REPORT+=("! Check yourself: Cloudflare dashboard > Manage account > Members lists only you.")

# ------------------------------------------------------------ 5. gcloud
echo
echo "5/5 Google Cloud sign-in"
if [ "$FROM_BROWSER" = yes ]; then
  did "setup ran in your own browser, so no other computer ever had your Google or Cloudflare sign-in"
elif gcloud auth list --format='value(account)' 2>/dev/null | tr '[:upper:]' '[:lower:]' | grep -qx "$EMAIL"; then
  run gcloud auth revoke "$EMAIL" --quiet >/dev/null 2>&1 && did "signed this computer out of $EMAIL in gcloud" || fail "couldn't revoke gcloud's sign-in as $EMAIL"
else
  did "gcloud here isn't signed in as $EMAIL"
fi
if gcloud config configurations list --format='value(name)' 2>/dev/null | grep -qx "$USER_NAME"; then
  run gcloud config configurations activate default >/dev/null 2>&1
  run gcloud config configurations delete "$USER_NAME" --quiet >/dev/null 2>&1 && did "deleted the gcloud configuration $USER_NAME"
fi

# ------------------------------------------------------------ check
echo
echo "Check: can any account still signed in here open $PROJECT?"
if [ "$DRY" = yes ]; then
  note "(dry run: skipped)"
elif [ "$FROM_BROWSER" = yes ]; then
  note "(this is your own Cloud Shell: skipped)"
else
  still=
  for acct in $(gcloud auth list --format='value(account)' 2>/dev/null); do
    if gcloud projects describe "$PROJECT" --account "$acct" --format='value(projectId)' >/dev/null 2>&1; then
      still="$still $acct"
    fi
  done
  if [ -n "$still" ]; then
    fail "still able to open the project from here:$still"
  else
    did "no account signed in on this computer can open the project"
  fi
fi

# ------------------------------------------------------------ report
STATUS_FILE=$STATE_DIR/status-$USER_NAME.url
OUT=$STATE_DIR/handback-$USER_NAME.txt
{
  echo "OpenMessage hand-back for $EMAIL, project $PROJECT, $(date '+%Y-%m-%d %H:%M %Z')"
  echo
  echo "Removed or checked:"
  printf '  %s\n' "${REPORT[@]}"
  if [ ${#TODO[@]} -gt 0 ]; then
    echo
    echo "NOT done (fix these before you're finished):"
    printf '  ✗ %s\n' "${TODO[@]}"
  fi
  echo
  echo "Still there, on purpose:"
  echo "  - Status emails to the person who set this up: connected or not, never message text."
  [ -s "$STATUS_FILE" ] && echo "  - A status-only link they keep: connected or not, and how long ago the newest text arrived."
  echo "  - Automatic updates of the OpenMessage software from their published releases."
  echo
  echo "To get help later, you let them back in for that session, and run this again after."
} > "$OUT.tmp"
[ "$DRY" = yes ] && { cat "$OUT.tmp"; rm -f "$OUT.tmp"; exit 0; }
mv "$OUT.tmp" "$OUT"
[ -f "$STATE_DIR/handed-back" ] || touch "$STATE_DIR/handed-back"
grep -qx "$USER_NAME" "$STATE_DIR/handed-back" || echo "$USER_NAME" >> "$STATE_DIR/handed-back"

echo
echo "────────────────────────────────────────────────────────────"
cat "$OUT"
echo "────────────────────────────────────────────────────────────"
echo "(Saved in $OUT.)"
[ ${#TODO[@]} -eq 0 ]
