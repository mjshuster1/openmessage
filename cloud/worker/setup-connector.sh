#!/usr/bin/env bash
# Sets up a user's claude.ai connector Worker end to end (cloud/NEW-USER.md
# steps 3-4): VPC service on their tunnel, KV namespace, wrangler.<user>.toml,
# deploys, Worker secrets. Safe to re-run: it reuses what already exists.
#
#   cloud/worker/setup-connector.sh --user <short-name> --email <google email>
#                                   [--tunnel om-vm] [--worker openmessage-connector] [--port 7007]
#
# Before: `npx wrangler login` as the user (check `npx wrangler whoami`), the
# tunnel created and Healthy (create-vm.sh installs it), `npm ci` in this
# folder. The one manual step left is the Google OAuth client; the script
# stops and says exactly what to create, then asks for its id and secret at
# hidden prompts. Nothing secret is written to disk or echoed.
#
# Writes wrangler.<user>.toml here (git ignores it). Prints the connector URL
# to add in claude.ai.
set -euo pipefail

USER_NAME=
EMAIL=
TUNNEL=om-vm
WORKER=openmessage-connector
PORT=7007
while [ $# -gt 0 ]; do
  case "$1" in
    --user) USER_NAME=$2; shift 2 ;;
    --email) EMAIL=$2; shift 2 ;;
    --tunnel) TUNNEL=$2; shift 2 ;;
    --worker) WORKER=$2; shift 2 ;;
    --port) PORT=$2; shift 2 ;;   # OpenMessage's port on the VM; Cloudflare allows one service per host:port per account
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[ -n "$USER_NAME" ] && [ -n "$EMAIL" ] || { echo "--user and --email are required (see --help)" >&2; exit 2; }
[[ "$USER_NAME" =~ ^[a-z0-9-]+$ ]] || { echo "--user: lowercase letters, digits and - only" >&2; exit 2; }
[[ "$WORKER" =~ ^[a-z0-9-]+$ ]] || { echo "--worker: lowercase letters, digits and - only" >&2; exit 2; }
[[ "$EMAIL" == *@*.* ]] || { echo "--email doesn't look like an email address" >&2; exit 2; }

cd "$(dirname "$0")"
W() { npx --no-install wrangler "$@"; }
CFG=wrangler.$USER_NAME.toml
UUID='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
json() { node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{const d=JSON.parse(s);console.log(($1)(d)??'')})"; }

[ -d node_modules ] || { echo "Run npm ci in cloud/worker first." >&2; exit 1; }
who=$(W whoami --json 2>/dev/null) || { echo "Wrangler isn't signed in: run npx wrangler login (as the user)." >&2; exit 1; }
acct_count=$(json 'd=>d.accounts.length' <<<"$who")
[ "$acct_count" = 1 ] || { echo "This login sees $acct_count Cloudflare accounts; set CLOUDFLARE_ACCOUNT_ID to the user's and re-run." >&2; [ -n "${CLOUDFLARE_ACCOUNT_ID:-}" ] || exit 1; }
echo "Cloudflare account: $(json 'd=>d.accounts[0].name' <<<"$who") ($(json 'd=>d.email' <<<"$who"))"
read -rp "Is this the user's account? [y/N] " yn; [[ "$yn" == [yY]* ]] || exit 1

echo "1/6 Tunnel '$TUNNEL'"
tline=$(W tunnel list 2>/dev/null | grep -E "│ *$UUID *│ *$TUNNEL *│" || true)
TUNNEL_ID=$(grep -oE "$UUID" <<<"$tline" | head -1)
[ -n "$TUNNEL_ID" ] || { echo "No tunnel named $TUNNEL. Create it (Workers VPC, Tunnels) and install it on the VM (create-vm.sh)." >&2; exit 1; }
grep -q healthy <<<"$tline" || echo "   warning: the tunnel isn't healthy yet; the connector won't answer until it is."
echo "   $TUNNEL_ID"

echo "2/6 VPC service '$WORKER-origin'"
VPC_ID=$(W vpc service list 2>/dev/null | grep -E "│ *$UUID *│ *$WORKER-origin *│" | grep -oE "$UUID" | head -1 || true)
if [ -z "$VPC_ID" ]; then
  out=$(W vpc service create "$WORKER-origin" --type http --tunnel-id "$TUNNEL_ID" --ipv4 127.0.0.1 --http-port "$PORT" 2>&1 || true)
  VPC_ID=$( { grep -oE "$UUID" <<<"$out" || true; } | { grep -v "$TUNNEL_ID" || true; } | head -1)
  if [ -z "$VPC_ID" ]; then
    echo "$out" | grep -vE '^\s*$|Logs were written|open an issue' >&2
    echo "Creating the VPC service failed (above). \"Service already exists for port\" means another service in this account already uses 127.0.0.1:$PORT." >&2
    exit 1
  fi
fi
echo "   $VPC_ID"

echo "3/6 KV namespace '$WORKER-oauth'"
KV_ID=$(W kv namespace list 2>/dev/null | json "d=>(d.find(n=>n.title==='$WORKER-oauth')||{}).id")
if [ -z "$KV_ID" ]; then
  W kv namespace create "$WORKER-oauth" >/dev/null 2>&1 || true
  KV_ID=$(W kv namespace list 2>/dev/null | json "d=>(d.find(n=>n.title==='$WORKER-oauth')||{}).id")
  [ -n "$KV_ID" ] || { echo "Creating the KV namespace failed." >&2; exit 1; }
fi
echo "   $KV_ID"

write_cfg() { # $1 = PUBLIC_URL
  sed -e "s|^name = \".*\"|name = \"$WORKER\"|" \
      -e "s|FILL-kv-namespace-id|$KV_ID|" \
      -e "s|FILL-vpc-service-id|$VPC_ID|" \
      -e "s|^PUBLIC_URL = \".*\"|PUBLIC_URL = \"$1\"|" \
      wrangler.example.toml > "$CFG"
}

echo "4/6 First deploy (learns the workers.dev address)"
PUBLIC_URL=$(grep -E '^PUBLIC_URL = "https://[a-z0-9.-]+\.workers\.dev"' "$CFG" 2>/dev/null | grep -oE 'https://[a-z0-9.-]+\.workers\.dev' || true)
if [ -z "$PUBLIC_URL" ]; then
  # The Worker answers only on PUBLIC_URL's host, so this placeholder deploy serves nothing.
  write_cfg "https://placeholder.invalid"
  out=$(W deploy -c "$CFG" 2>&1) || { echo "$out" >&2; exit 1; }
  PUBLIC_URL=$(grep -oE "https://$WORKER\.[a-z0-9-]+\.workers\.dev" <<<"$out" | head -1)
  [ -n "$PUBLIC_URL" ] || { echo "$out" >&2; echo "Couldn't find the workers.dev URL above (is workers.dev turned on for the account?)." >&2; exit 1; }
fi
write_cfg "$PUBLIC_URL"
echo "   $PUBLIC_URL  (config: cloud/worker/$CFG)"

echo "5/6 Secrets"
existing=$(W secret list -c "$CFG" 2>/dev/null || true)
printf '%s' "$EMAIL" | W secret put ALLOWED_EMAIL -c "$CFG" >/dev/null 2>&1
echo "   ALLOWED_EMAIL set"
if grep -q GOOGLE_CLIENT_SECRET <<<"$existing" && grep -q GOOGLE_CLIENT_ID <<<"$existing"; then
  read -rp "   Google OAuth client already set. Replace it? [y/N] " yn
else
  yn=y
fi
if [[ "$yn" == [yY]* ]]; then
  cat <<EOF

   One manual step: a Google OAuth client for sign-in. In the user's Google Cloud
   project (console.cloud.google.com, the same project as the VM is fine):
     a. APIs & Services > OAuth consent screen: set it up (External; app name e.g.
        "OpenMessage connector"; add $EMAIL as a test user).
     b. APIs & Services > Credentials > Create credentials > OAuth client ID:
        type "Web application", authorized redirect URI exactly:
          $PUBLIC_URL/callback
     c. Copy the client ID and secret and paste them here.
EOF
  read -rp "   Client ID: " CID
  read -rsp "   Client secret (hidden): " CSECRET; echo
  [ -n "$CID" ] && [ -n "$CSECRET" ] || { echo "Both are needed; re-run to finish (everything else is kept)." >&2; exit 1; }
  printf '%s' "$CID" | W secret put GOOGLE_CLIENT_ID -c "$CFG" >/dev/null 2>&1
  printf '%s' "$CSECRET" | W secret put GOOGLE_CLIENT_SECRET -c "$CFG" >/dev/null 2>&1
  unset CSECRET
  echo "   Google client set"
fi

echo "6/6 Deploy"
W deploy -c "$CFG" >/dev/null 2>&1 || { W deploy -c "$CFG"; exit 1; }
code=$(curl -s -o /dev/null -w '%{http_code}' -m 15 "$PUBLIC_URL/mcp" || true)
echo "   $PUBLIC_URL/mcp answers $code without sign-in (401 is right)"

cat <<EOF

Done. In claude.ai (Settings > Connectors > Add custom connector):
  URL:  $PUBLIC_URL/mcp
then sign in with $EMAIL. Ask it for the last three texts to check.
EOF
