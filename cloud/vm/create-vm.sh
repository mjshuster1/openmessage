#!/usr/bin/env bash
# Creates the OpenMessage VM in one command (replaces README steps 1-3 by hand).
#
#   cloud/vm/create-vm.sh [--release latest|<tag>] [--name om-test] [--zone us-east1-b]
#                         [--repo mjshuster1/openmessage] [--project <id>]
#                         [--tunnel om-vm | --no-tunnel]
#                         [--timezone America/New_York]   (default: this computer's)
#
# Run it in Cloud Shell or anywhere gcloud is signed in to the project
# (`gcloud config set project <id>` or --project). It:
#   1. creates an e2-micro, Debian 12, 30 GB standard disk, no firewall rules,
#      with startup.sh attached and om-repo/om-release metadata. The default
#      --release latest installs the newest *-vmN release and turns on daily
#      updates with rollback (om-update.sh); a tag pins that release;
#   2. waits on the serial console until startup.sh reports it installed the
#      release (binary checked against SHA256SUMS, units installed, nothing
#      started);
#   3. unless --no-tunnel, installs cloudflared with the Cloudflare tunnel's
#      token over SSH. If Wrangler (cloud/worker) is signed in to the user's
#      Cloudflare account, it finds or creates the tunnel (default name om-vm,
#      which setup-connector.sh expects) and fetches the token itself.
#      Otherwise it asks for the token at a hidden prompt: Workers VPC,
#      Tunnels, create a tunnel (no public hostname), and copy the long string
#      after `service install`. The token never goes into metadata, arguments,
#      files or history.
# Pairing comes after: README steps 4-5.
#
# Costs: the e2-micro and 30 GB standard disk fall under the Always Free tier
# in us-east1, us-central1 and us-west1. The external IPv4 address is billed
# (about $3.65/month per Google's network pricing page).
set -euo pipefail

NAME=om-test
ZONE=us-east1-b
REPO=mjshuster1/openmessage
RELEASE=latest
PROJECT_ARGS=()
TUNNEL=yes
TUNNEL_NAME=om-vm
TIMEZONE=
while [ $# -gt 0 ]; do
  case "$1" in
    --release) RELEASE=$2; shift 2 ;;
    --name) NAME=$2; shift 2 ;;
    --zone) ZONE=$2; shift 2 ;;
    --repo) REPO=$2; shift 2 ;;
    --project) PROJECT_ARGS=(--project "$2"); shift 2 ;;
    --no-tunnel) TUNNEL=no; shift ;;
    --tunnel) TUNNEL_NAME=$2; shift 2 ;;
    --timezone) TIMEZONE=$2; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[ -n "$RELEASE" ] || { echo "--release: latest or a tag (see release-vm.sh)" >&2; exit 2; }
[[ "$TUNNEL_NAME" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "--tunnel: letters, digits, - and _" >&2; exit 2; }
HERE=$(cd "$(dirname "$0")" && pwd)
if [ -z "$TIMEZONE" ]; then
  TIMEZONE=$(timedatectl show -p Timezone --value 2>/dev/null || readlink /etc/localtime 2>/dev/null | sed -E 's|.*/zoneinfo/||' || true)
fi
if [ -z "$TIMEZONE" ] || [ "$TIMEZONE" = UTC ] || [ "$TIMEZONE" = Etc/UTC ]; then
  echo "Note: using UTC for the VM's clock (alerts and sync times). Cloud Shell is always UTC;"
  echo "      pass --timezone America/New_York (or the user's zone) to use local time."
  TIMEZONE=UTC
fi
[[ "$TIMEZONE" =~ ^[A-Za-z0-9_+/-]+$ ]] || { echo "--timezone: an IANA name like America/New_York" >&2; exit 2; }
G=(gcloud ${PROJECT_ARGS[@]+"${PROJECT_ARGS[@]}"})

case "$ZONE" in
  us-east1-*|us-central1-*|us-west1-*) ;;
  *) echo "Note: $ZONE is outside the free-tier regions (us-east1, us-central1, us-west1); the VM will be billed." ;;
esac

# The release must exist before the VM tries to download it.
CHECK=$RELEASE
if [ "$RELEASE" = latest ]; then
  CHECK=$(curl -fsSL "https://api.github.com/repos/$REPO/releases?per_page=30" \
    | grep -oE '"tag_name": *"[^"]+-vm[0-9]+"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/' || true)
  [ -n "$CHECK" ] || { echo "No *-vmN release on $REPO; publish one with release-vm.sh first." >&2; exit 1; }
  echo "Latest release: $CHECK (the VM will keep itself up to date)"
fi
if ! curl -fsLI -o /dev/null "https://github.com/$REPO/releases/download/$CHECK/SHA256SUMS"; then
  echo "Release $CHECK on $REPO has no SHA256SUMS; publish it with release-vm.sh first." >&2
  exit 1
fi
if "${G[@]}" compute instances describe "$NAME" --zone "$ZONE" --format='value(name)' >/dev/null 2>&1; then
  echo "A VM named $NAME already exists in $ZONE. Pick another --name, or upgrade it instead:" >&2
  echo "  gcloud compute instances add-metadata $NAME --zone $ZONE --metadata om-release=<tag> && reboot it" >&2
  exit 1
fi

echo "Creating $NAME in $ZONE from $REPO $RELEASE ..."
"${G[@]}" compute instances create "$NAME" --zone "$ZONE" \
  --machine-type e2-micro \
  --image-family debian-12 --image-project debian-cloud \
  --boot-disk-size 30GB --boot-disk-type pd-standard \
  --metadata "om-repo=$REPO,om-release=$RELEASE,om-timezone=$TIMEZONE" \
  --metadata-from-file "startup-script=$HERE/startup.sh"

echo "Waiting for the startup script (usually 1-3 minutes) ..."
deadline=$((SECONDS + 600))
while :; do
  out=$("${G[@]}" compute instances get-serial-port-output "$NAME" --zone "$ZONE" 2>/dev/null | grep 'om-startup:' || true)
  if grep -q 'om-startup: done' <<<"$out"; then
    grep 'om-startup: installed' <<<"$out" | tail -1 | sed 's/.*om-startup: /  /'
    break
  fi
  if grep -qE 'om-startup: (download failed|checksum mismatch|.* not in SHA256SUMS|metadata .* required|unsupported)' <<<"$out"; then
    echo "Startup script failed:" >&2
    sed 's/.*om-startup: /  /' <<<"$out" >&2
    exit 1
  fi
  if [ $SECONDS -ge $deadline ]; then
    echo "No 'om-startup: done' after 10 minutes. Check: gcloud compute instances get-serial-port-output $NAME --zone $ZONE | grep -i startup" >&2
    exit 1
  fi
  sleep 10
done

# Tunnel token via Wrangler's login: find or create the tunnel, then ask the
# API for its token. Prints the token on stdout only; empty if not possible.
wrangler_token() {
  local wdir="$HERE/../worker" W who acct uuid tok
  [ -d "$wdir/node_modules" ] || return 0
  W() { (cd "$wdir" && npx --no-install wrangler "$@"); }
  who=$(W whoami --json 2>/dev/null) || return 0
  acct=${CLOUDFLARE_ACCOUNT_ID:-$(node -e 'const d=JSON.parse(process.argv[1]);if(d.accounts.length===1)console.log(d.accounts[0].id)' "$who" 2>/dev/null)}
  [ -n "$acct" ] || { echo "  (Wrangler sees several Cloudflare accounts; set CLOUDFLARE_ACCOUNT_ID)" >&2; return 0; }
  local UUID='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
  uuid=$(W tunnel list 2>/dev/null | grep -E "│ *$UUID *│ *$TUNNEL_NAME *│" | grep -oE "$UUID" | head -1 || true)
  if [ -z "$uuid" ]; then
    echo "  creating Cloudflare tunnel $TUNNEL_NAME ($(node -e 'console.log(JSON.parse(process.argv[1]).email)' "$who"))" >&2
    W tunnel create "$TUNNEL_NAME" >/dev/null 2>&1 || true
    uuid=$(W tunnel list 2>/dev/null | grep -E "│ *$UUID *│ *$TUNNEL_NAME *│" | grep -oE "$UUID" | head -1 || true)
    [ -n "$uuid" ] || { echo "  (couldn't create the tunnel with Wrangler)" >&2; return 0; }
  else
    echo "  using Cloudflare tunnel $TUNNEL_NAME ($uuid)" >&2
  fi
  tok=$(curl -s -m 20 -H "Authorization: Bearer $(W auth token 2>/dev/null | tail -1)" \
    "https://api.cloudflare.com/client/v4/accounts/$acct/cfd_tunnel/$uuid/token" \
    | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s);if(j.success&&j.result)process.stdout.write(j.result)}catch{}})')
  printf '%s' "$tok"
}

if [ "$TUNNEL" = yes ]; then
  echo
  echo "Cloudflare tunnel '$TUNNEL_NAME':"
  TOKEN=$(wrangler_token)
  if [ -z "$TOKEN" ]; then
    echo "Paste the tunnel token (input hidden), or press Enter to skip."
    read -rs TOKEN
    echo
  fi
  if [ -n "$TOKEN" ]; then
    printf '%s\n' "$TOKEN" | "${G[@]}" compute ssh --quiet "$NAME" --zone "$ZONE" -- 'set -e
      read -r t
      sudo install -d -m 0755 /usr/share/keyrings
      curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
      echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" | sudo tee /etc/apt/sources.list.d/cloudflared.list >/dev/null
      sudo apt-get update -q >/dev/null && sudo apt-get install -y -q cloudflared >/dev/null
      sudo cloudflared service install "$t" >/dev/null 2>&1
      sleep 5
      echo "cloudflared: $(systemctl is-active cloudflared)"' 2>&1 | grep -v 'Pseudo-terminal'
    unset TOKEN
  else
    echo "Skipped. Install it later from the tunnel's Debian instructions (README step 3)."
  fi
fi

cat <<EOF

Done: $NAME is installed; OpenMessage is enabled but not started (no pairing yet).
Tunnel: $TUNNEL_NAME (setup-connector.sh --tunnel $TUNNEL_NAME)
Next, with the phone in hand:  cloud/vm/reconnect.sh --name $NAME --zone $ZONE
Then alerts:                   cloud/vm/set-alerts.sh --name $NAME --zone $ZONE
Connector Worker:              cloud/worker/setup-connector.sh (cloud/NEW-USER.md step 3)
Check later:  gcloud compute ssh $NAME --zone $ZONE -- sudo om-score
EOF
