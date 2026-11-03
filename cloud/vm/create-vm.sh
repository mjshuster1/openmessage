#!/usr/bin/env bash
# Creates the OpenMessage VM in one command (replaces README steps 1-3 by hand).
#
#   cloud/vm/create-vm.sh --release <tag> [--name om-test] [--zone us-east1-b]
#                         [--repo mjshuster1/openmessage] [--project <id>] [--no-tunnel]
#
# Run it in Cloud Shell or anywhere gcloud is signed in to the project
# (`gcloud config set project <id>` or --project). It:
#   1. creates an e2-micro, Debian 12, 30 GB standard disk, no firewall rules,
#      with startup.sh attached and om-repo/om-release metadata;
#   2. waits on the serial console until startup.sh reports it installed the
#      release (binary checked against SHA256SUMS, units installed, nothing
#      started);
#   3. unless --no-tunnel, asks for the Cloudflare tunnel token at a hidden
#      prompt and installs cloudflared with it over SSH. The token never goes
#      into metadata, arguments or history. Get it from Cloudflare: Workers VPC,
#      Tunnels, create a tunnel (no public hostname), and copy the token from
#      its install command (the long string after `service install`).
# Pairing comes after: README steps 4-5.
#
# Costs: the e2-micro and 30 GB standard disk fall under the Always Free tier
# in us-east1, us-central1 and us-west1. The external IPv4 address is billed
# (about $3.65/month per Google's network pricing page).
set -euo pipefail

NAME=om-test
ZONE=us-east1-b
REPO=mjshuster1/openmessage
RELEASE=
PROJECT_ARGS=()
TUNNEL=yes
while [ $# -gt 0 ]; do
  case "$1" in
    --release) RELEASE=$2; shift 2 ;;
    --name) NAME=$2; shift 2 ;;
    --zone) ZONE=$2; shift 2 ;;
    --repo) REPO=$2; shift 2 ;;
    --project) PROJECT_ARGS=(--project "$2"); shift 2 ;;
    --no-tunnel) TUNNEL=no; shift ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[ -n "$RELEASE" ] || { echo "--release <tag> is required (see release-vm.sh)" >&2; exit 2; }
HERE=$(cd "$(dirname "$0")" && pwd)
G=(gcloud ${PROJECT_ARGS[@]+"${PROJECT_ARGS[@]}"})

case "$ZONE" in
  us-east1-*|us-central1-*|us-west1-*) ;;
  *) echo "Note: $ZONE is outside the free-tier regions (us-east1, us-central1, us-west1); the VM will be billed." ;;
esac

# The release must exist before the VM tries to download it.
if ! curl -fsLI -o /dev/null "https://github.com/$REPO/releases/download/$RELEASE/SHA256SUMS"; then
  echo "Release $RELEASE on $REPO has no SHA256SUMS; publish it with release-vm.sh first." >&2
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
  --metadata "om-repo=$REPO,om-release=$RELEASE" \
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

if [ "$TUNNEL" = yes ]; then
  echo
  echo "Cloudflare tunnel: paste the tunnel token (input hidden), or press Enter to skip."
  read -rs TOKEN
  echo
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
Next, with the phone in hand:  cloud/vm/reconnect.sh --name $NAME --zone $ZONE
Then alerts:                   cloud/vm/set-alerts.sh --name $NAME --zone $ZONE
Connector Worker:              cloud/worker/setup-connector.sh (cloud/NEW-USER.md step 3)
Check later:  gcloud compute ssh $NAME --zone $ZONE -- sudo om-score
EOF
