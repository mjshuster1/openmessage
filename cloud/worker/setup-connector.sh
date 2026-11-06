#!/usr/bin/env bash
# Sets up a user's claude.ai connector Worker end to end (cloud/NEW-USER.md
# steps 3-4): VPC service on their tunnel, KV namespace, wrangler.<user>.toml,
# deploys, Worker secrets. Safe to re-run: it reuses what already exists.
#
#   cloud/worker/setup-connector.sh --user <short-name> --email <email>
#                                   [--auth google|access] [--access-aud <AUD tag>]
#                                   [--tunnel om-vm] [--worker openmessage-connector] [--port 7007]
#                                   [--reconnect [--pair-port 7011]]
#                                   [--project <id>] [--account-confirmed]
#
# Before: `npx wrangler login` as the user (check `npx wrangler whoami`), the
# tunnel created and Healthy (create-vm.sh installs it), `npm ci` in this
# folder. Nothing secret is written to disk or echoed, except the status-only
# link (~/.config/openmessage/status-<user>.url), which shows connected or not
# and the newest text's age, never message data.
#
# --auth google (default): the Worker signs the user in with Google. The one
# manual step is a Google OAuth client; the script says exactly what to
# create, then asks for its id and secret at hidden prompts.
# --auth access: Cloudflare Access (Managed OAuth) does the sign-in, by
# emailed one-time PIN; no Google client, no KV. The manual step is turning
# Access on for the Worker in the dashboard; the script stops, says what to
# click, and checks it. Re-run after a manual step if it exits.
#
# --reconnect turns on the Reconnect page (<connector>/reconnect), so the
# client re-pairs Google Messages themselves with the Reconnect app: a second
# VPC service ('<worker>-pair', the VM's om-pair-helper on 127.0.0.1:7011)
# bound as PAIR, and the RECONNECT_SECRET secret. Google mode also needs the
# redirect URI <connector>/reconnect/callback on the OAuth client (it says
# so). deploy.sh --client-owned passes it; one VPC service per host:port per
# account means only one client per Cloudflare account can use port 7011.
#
# --project: the Google Cloud project, for direct links to the sign-in step.
# --account-confirmed: don't ask whether this is the right Cloudflare account
# (setup.sh runs in the client's own browser, so it is).
#
# Writes wrangler.<user>.toml here (git ignores it). Prints the connector URL
# to add in claude.ai.
set -euo pipefail

USER_NAME=
EMAIL=
TUNNEL=om-vm
WORKER=openmessage-connector
PORT=7007
AUTH=google
ACCESS_AUD=
RECONNECT=no
PAIR_PORT=7011
PROJECT=
ACCOUNT_CONFIRMED=no
while [ $# -gt 0 ]; do
  case "$1" in
    --user) USER_NAME=$2; shift 2 ;;
    --email) EMAIL=$2; shift 2 ;;
    --tunnel) TUNNEL=$2; shift 2 ;;
    --worker) WORKER=$2; shift 2 ;;
    --port) PORT=$2; shift 2 ;;   # OpenMessage's port on the VM; Cloudflare allows one service per host:port per account
    --auth) AUTH=$2; shift 2 ;;
    --access-aud) ACCESS_AUD=$2; shift 2 ;;
    --reconnect) RECONNECT=yes; shift ;;
    --pair-port) PAIR_PORT=$2; shift 2 ;;
    --project) PROJECT=$2; shift 2 ;;
    --account-confirmed) ACCOUNT_CONFIRMED=yes; shift ;;
    -h|--help) sed -n '2,41p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[ -n "$USER_NAME" ] && [ -n "$EMAIL" ] || { echo "--user and --email are required (see --help)" >&2; exit 2; }
[[ "$USER_NAME" =~ ^[a-z0-9-]+$ ]] || { echo "--user: lowercase letters, digits and - only" >&2; exit 2; }
[[ "$WORKER" =~ ^[a-z0-9-]+$ ]] || { echo "--worker: lowercase letters, digits and - only" >&2; exit 2; }
[[ "$EMAIL" == *@*.* ]] || { echo "--email doesn't look like an email address" >&2; exit 2; }
[[ "$AUTH" == google || "$AUTH" == access ]] || { echo "--auth: google or access" >&2; exit 2; }
[ -z "$ACCESS_AUD" ] || [[ "$ACCESS_AUD" =~ ^[A-Za-z0-9]{16,}$ ]] || { echo "--access-aud: the AUD tag is a long hex string" >&2; exit 2; }

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
[ "$ACCOUNT_CONFIRMED" = yes ] || { read -rp "Is this the account that should host $USER_NAME's connector? [y/N] " yn; [[ "$yn" == [yY]* ]] || exit 1; }

echo "1/6 Tunnel '$TUNNEL'  (sign-in: $AUTH)"
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

PAIR_ID=
if [ "$RECONNECT" = yes ]; then
  echo "   + VPC service '$WORKER-pair' (Reconnect page -> VM port $PAIR_PORT)"
  PAIR_ID=$(W vpc service list 2>/dev/null | grep -E "│ *$UUID *│ *$WORKER-pair *│" | grep -oE "$UUID" | head -1 || true)
  if [ -z "$PAIR_ID" ]; then
    out=$(W vpc service create "$WORKER-pair" --type http --tunnel-id "$TUNNEL_ID" --ipv4 127.0.0.1 --http-port "$PAIR_PORT" 2>&1 || true)
    PAIR_ID=$( { grep -oE "$UUID" <<<"$out" || true; } | { grep -v "$TUNNEL_ID" || true; } | head -1)
    if [ -z "$PAIR_ID" ]; then
      echo "$out" | grep -vE '^\s*$|Logs were written|open an issue' >&2
      echo "Creating the pair VPC service failed (above). Another service in this account may already use 127.0.0.1:$PAIR_PORT." >&2
      exit 1
    fi
  fi
  echo "     $PAIR_ID"
fi

KV_ID=
if [ "$AUTH" = google ]; then
  echo "3/6 KV namespace '$WORKER-oauth'"
  KV_ID=$(W kv namespace list 2>/dev/null | json "d=>(d.find(n=>n.title==='$WORKER-oauth')||{}).id")
  if [ -z "$KV_ID" ]; then
    W kv namespace create "$WORKER-oauth" >/dev/null 2>&1 || true
    KV_ID=$(W kv namespace list 2>/dev/null | json "d=>(d.find(n=>n.title==='$WORKER-oauth')||{}).id")
    [ -n "$KV_ID" ] || { echo "Creating the KV namespace failed." >&2; exit 1; }
  fi
  echo "   $KV_ID"
else
  echo "3/6 KV namespace: not needed with Access"
fi

# Values a previous run wrote, so a re-run keeps them.
cfg_val() { { grep -E "^$1 = \"" "$CFG" 2>/dev/null || true; } | head -1 | sed -E 's/^[A-Z_]+ = "(.*)"$/\1/'; }
TEAM=
if [ "$AUTH" = access ] && [ "$(cfg_val AUTH_MODE)" = access ]; then
  TEAM=$(cfg_val ACCESS_TEAM_DOMAIN)
  [ -n "$ACCESS_AUD" ] || ACCESS_AUD=$(cfg_val ACCESS_AUD)
fi

write_cfg() { # $1 = PUBLIC_URL; also uses AUTH, TEAM, ACCESS_AUD
  local drop='/^# google-auth-/d'
  [ "$AUTH" = access ] && drop='/^# google-auth-begin/,/^# google-auth-end/d'
  sed -e "s|^name = \".*\"|name = \"$WORKER\"|" \
      -e "s|FILL-kv-namespace-id|$KV_ID|" \
      -e "s|FILL-vpc-service-id|$VPC_ID|" \
      -e "s|^PUBLIC_URL = \".*\"|PUBLIC_URL = \"$1\"|" \
      -e "s|^AUTH_MODE = \".*\"|AUTH_MODE = \"$AUTH\"|" \
      -e "s|^ACCESS_TEAM_DOMAIN = \".*\"|ACCESS_TEAM_DOMAIN = \"$TEAM\"|" \
      -e "s|^ACCESS_AUD = \".*\"|ACCESS_AUD = \"$ACCESS_AUD\"|" \
      -e "$drop" \
      wrangler.example.toml > "$CFG"
  if [ -n "$PAIR_ID" ]; then
    printf '\n# Reconnect page: the VM'"'"'s om-pair-helper (setup-connector.sh --reconnect).\n[[vpc_services]]\nbinding = "PAIR"\nservice_id = "%s"\n' "$PAIR_ID" >> "$CFG"
  fi
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

# What answers at /mcp without a sign-in. 401 + resource_metadata: Access with
# Managed OAuth (sets TEAM from its metadata). A redirect to
# *.cloudflareaccess.com: Access without Managed OAuth. Anything else: the
# Worker itself answered, so Access isn't in front.
access_probe() {
  local hdrs meta
  hdrs=$(curl -s -o /dev/null -D - -m 15 -X POST -H 'Content-Type: application/json' -d '{}' "$PUBLIC_URL/mcp" | tr -d '\r' || true)
  if grep -qiE '^www-authenticate:.*resource_metadata="https://' <<<"$hdrs"; then
    meta=$(grep -iE '^www-authenticate:' <<<"$hdrs" | grep -oE 'resource_metadata="https://[^"]+"' | head -1 | cut -d'"' -f2)
    TEAM=$(curl -s -m 15 "$meta" | json 'd=>d.team_domain' 2>/dev/null || true)
    if [ -n "$TEAM" ]; then PROBE=managed; else PROBE=unknown; fi
  elif grep -qiE '^location: https://[a-z0-9-]+\.cloudflareaccess\.com/' <<<"$hdrs"; then
    PROBE=plain
  else
    PROBE=none
  fi
}

access_howto() {
  cat <<HOWTO

   Turn on Cloudflare Access for the Worker (Cloudflare dashboard, the user's account):
     a. Workers & Pages > $WORKER > Domains: on the Production workers.dev row,
        click "Enable Access". Scope: All traffic. Policy: Allow, only $EMAIL.
        (The first time, Zero Trust asks for a team name and a plan: Free.)
     b. Zero Trust > Access controls > Applications > the new $WORKER app > Edit:
        login method One-time PIN; turn on Managed OAuth with dynamic client
        registration and these allowed redirect URIs:
          https://claude.ai/api/mcp/auth_callback
          https://claude.com/api/mcp/auth_callback
        Save, and copy the app's "Application Audience (AUD) Tag".
HOWTO
}

if [ "$AUTH" = access ]; then
  echo "4b/6 Cloudflare Access in front of $PUBLIC_URL"
  while :; do
    access_probe
    case $PROBE in
      managed) echo "   Access with Managed OAuth is on (team $TEAM)"; break ;;
      plain) echo "   Access is on, but Managed OAuth isn't (sign-in redirects instead of answering 401)." ;;
      unknown) echo "   Access answered 401, but its metadata didn't name a team. Check the app." ;;
      none) echo "   Access isn't on yet: the Worker itself answered." ;;
    esac
    access_howto
    if [ -t 0 ]; then read -rp "   Press Enter once it's saved (Ctrl-C to stop) " _; else exit 1; fi
  done
  if [ -z "$ACCESS_AUD" ]; then
    [ -t 0 ] || { echo "   Re-run with --access-aud <the app's AUD tag>." >&2; exit 1; }
    read -rp "   Application Audience (AUD) Tag: " ACCESS_AUD
  fi
  [[ "$ACCESS_AUD" =~ ^[A-Za-z0-9]{16,}$ ]] || { echo "   That doesn't look like an AUD tag (a long hex string on the app's page)." >&2; exit 1; }
  write_cfg "$PUBLIC_URL"
  echo "   team domain and AUD tag saved in $CFG"
fi

echo "5/6 Secrets"
existing=$(W secret list -c "$CFG" 2>/dev/null || true)
printf '%s' "$EMAIL" | W secret put ALLOWED_EMAIL -c "$CFG" >/dev/null 2>&1
echo "   ALLOWED_EMAIL set"
# Status-only page (connected? newest text when?) for the operator, who keeps
# the link after handing the accounts back. Status only, so it may live on disk.
STATUS_FILE=$HOME/.config/openmessage/status-$USER_NAME.url
if ! grep -q STATUS_KEY <<<"$existing" || [ ! -s "$STATUS_FILE" ]; then
  SKEY=$(openssl rand -hex 24)
  printf '%s' "$SKEY" | W secret put STATUS_KEY -c "$CFG" >/dev/null 2>&1
  mkdir -p "$(dirname "$STATUS_FILE")"
  (umask 077; printf '%s/status?key=%s\n' "$PUBLIC_URL" "$SKEY" > "$STATUS_FILE")
  unset SKEY
  echo "   status link saved in $STATUS_FILE"
fi
if [ "$RECONNECT" = yes ] && ! grep -q RECONNECT_SECRET <<<"$existing"; then
  openssl rand -hex 32 | tr -d '\n' | W secret put RECONNECT_SECRET -c "$CFG" >/dev/null 2>&1
  echo "   RECONNECT_SECRET set"
fi
if [ "$AUTH" = access ]; then
  yn=n
elif grep -q GOOGLE_CLIENT_SECRET <<<"$existing" && grep -q GOOGLE_CLIENT_ID <<<"$existing"; then
  read -rp "   Google OAuth client already set. Replace it? [y/N] " yn
else
  yn=y
fi
if [[ "$yn" == [yY]* ]]; then
  GC=https://console.cloud.google.com/auth
  Q=${PROJECT:+?project=$PROJECT}
  cat <<EOF

   One step by hand: Google sign-in for your connection (Google has no way to
   do this automatically). Open each link in a new tab; sign in as $EMAIL.

     a. Name it: $GC/overview$Q
        Click Get started. App name: OpenMessage. Support and contact email:
        $EMAIL. Audience: External. Agree and Create.
        (Older screen: APIs & Services > OAuth consent screen.)
     b. Allow yourself: $GC/audience$Q
        Under Test users, Add users: $EMAIL. Save.
     c. Create the client: $GC/clients/create$Q
        Type: Web application. Under Authorized redirect URIs, Add URI:
          $PUBLIC_URL/callback$( [ "$RECONNECT" = yes ] && printf '\n        Add URI again:\n          %s/reconnect/callback' "$PUBLIC_URL")
        Create. Leave that box open: it shows the client ID and secret.
     d. Paste them here (the secret won't show as you paste it).
EOF
  while :; do
    read -rp "   Client ID: " CID
    [[ "$CID" == *.apps.googleusercontent.com ]] && break
    echo "   That isn't a client ID: it ends in .apps.googleusercontent.com."
  done
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
how="sign in with $EMAIL"
if [ "$AUTH" = access ]; then
  access_probe
  [ "$PROBE" = managed ] || echo "   warning: Access with Managed OAuth isn't answering in front of the Worker now; re-run to check." >&2
  how="sign in with $EMAIL (Cloudflare emails a one-time PIN)"
fi

if [ "$RECONNECT" = yes ]; then
  RC_FILE=$HOME/.config/openmessage/reconnect-$USER_NAME.url
  mkdir -p "$(dirname "$RC_FILE")"
  echo "$PUBLIC_URL/reconnect" > "$RC_FILE"
  if [ "$AUTH" = google ] && [ "${yn:-y}" != y ] && [ "${yn:-y}" != Y ]; then
    echo "   Reconnect page: make sure the Google OAuth client also lists the redirect URI"
    echo "     $PUBLIC_URL/reconnect/callback"
  fi
  if [ "$AUTH" = access ]; then
    echo "   Reconnect page with Access: add a Bypass policy (Everyone) for the paths"
    echo "     /reconnect/upload, /reconnect/state and /status on this Worker's Access application;"
    echo "     /reconnect itself stays behind Access (that's the sign-in)."
  fi
  echo "   Reconnect page: $PUBLIC_URL/reconnect  (saved in $RC_FILE)"
fi

cat <<EOF

Done. In claude.ai (Settings > Connectors > Add custom connector):
  URL:  $PUBLIC_URL/mcp
then $how. Ask it for the last three texts to check.
EOF
