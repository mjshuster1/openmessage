#!/usr/bin/env bash
# Removes one person's OpenMessage setup: the reverse of deploy.sh. Shows what
# it will delete and asks you to type the user name before deleting anything.
#
#   cloud/teardown.sh --user <short-name> [--project <id>] [--zone us-east1-b] [--name openmessage]
#                     [--tunnel <name>] [--delete-project] [--dry-run] [--yes]
#
# Deletes, where it finds them:
#   - the VM (its disk and everything on it: messages, pairing, alerts)
#   - the connector Worker, its VPC service and KV namespace (from
#     cloud/worker/wrangler.<user>.toml), and the Cloudflare tunnel the VPC
#     service used, unless another VPC service still uses that tunnel
#   - with --delete-project: the whole Google Cloud project (Google keeps it
#     recoverable for 30 days) and its budget alert. That also removes the
#     Google OAuth client.
#   - the local records: wrangler.<user>.toml, the deploy state file, the
#     fleet entry
# VM name, zone and project come from the fleet entry if there is one
# (doctor.sh --all); flags override. Wrangler must be signed in to the user's
# Cloudflare account. It then lists what to remove by hand (the claude.ai
# connector, a Cloudflare Access app, the ntfy subscription).
# --tunnel deletes that tunnel even without a Worker config (same in-use check).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
USER_NAME= PROJECT= ZONE= NAME= TUNNEL= DELETE_PROJECT=no DRY=no YES=no
while [ $# -gt 0 ]; do
  case "$1" in
    --user) USER_NAME=$2; shift 2 ;;
    --project) PROJECT=$2; shift 2 ;;
    --zone) ZONE=$2; shift 2 ;;
    --name) NAME=$2; shift 2 ;;
    --tunnel) TUNNEL=$2; shift 2 ;;
    --delete-project) DELETE_PROJECT=yes; shift ;;
    --dry-run) DRY=yes; shift ;;
    --yes) YES=yes; shift ;;
    -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[[ "$USER_NAME" =~ ^[a-z0-9-]+$ ]] || { echo "--user <short-name> is required (lowercase letters, digits, -)" >&2; exit 2; }

STATE_DIR=$HOME/.config/openmessage
FLEET=${OM_FLEET_FILE:-$STATE_DIR/fleet.tsv}
DONE=$STATE_DIR/deploy-$USER_NAME.done
WDIR=$HERE/worker
CFG=$WDIR/wrangler.$USER_NAME.toml
UUID='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
W() { (cd "$WDIR" && npx --no-install wrangler "$@"); }

# Fleet entry: label name zone project connector
if [ -s "$FLEET" ]; then
  IFS=$'\t' read -r _ f_name f_zone f_project _ < <(awk -F'\t' -v l="$USER_NAME" '$1 == l' "$FLEET") || true
  NAME=${NAME:-${f_name:-}} ZONE=${ZONE:-${f_zone:-}} PROJECT=${PROJECT:-${f_project:-}}
fi
NAME=${NAME:-openmessage} ZONE=${ZONE:-us-east1-b}

cfg_val() { { grep -E "^$1 = \"" "$CFG" 2>/dev/null || true; } | head -1 | sed -E 's/^[A-Za-z_]+ = "(.*)"$/\1/'; }
WORKER= VPC_ID= KV_ID= AUTH= URL=
if [ -f "$CFG" ]; then
  WORKER=$(cfg_val name)
  AUTH=$(cfg_val AUTH_MODE)
  URL=$(cfg_val PUBLIC_URL)
  VPC_ID=$(grep -oE "service_id = \"$UUID\"" "$CFG" | grep -oE "$UUID" | head -1 || true)
  KV_ID=$(grep -oE '^id = "[0-9a-f]{32}"' "$CFG" | grep -oE '[0-9a-f]{32}' | head -1 || true)
fi

# --- what exists -----------------------------------------------------------
echo "Looking up $USER_NAME's setup ..."
VM=no
if [ -n "$PROJECT" ] && gcloud compute instances describe "$NAME" --zone "$ZONE" --project "$PROJECT" --format='value(name)' >/dev/null 2>&1; then
  VM=yes
fi
PROJ=no BILLING= BUDGET=
if [ -n "$PROJECT" ] && [ "$DELETE_PROJECT" = yes ] && gcloud projects describe "$PROJECT" --format='value(projectId)' >/dev/null 2>&1; then
  PROJ=yes
  BILLING=$(gcloud billing projects describe "$PROJECT" --format='value(billingAccountName)' 2>/dev/null | sed 's|billingAccounts/||' || true)
  [ -z "$BILLING" ] || BUDGET=$(gcloud billing budgets list --billing-account "$BILLING" \
    --filter="displayName=\"openmessage $PROJECT\"" --format='value(name)' 2>/dev/null | head -1 || true)
fi

CF=no
if [ -n "$WORKER$TUNNEL" ]; then
  [ -d "$WDIR/node_modules" ] || { echo "Run npm ci in cloud/worker first." >&2; exit 1; }
  who=$(W whoami --json 2>/dev/null) || { echo "Wrangler isn't signed in: cd cloud/worker && npx wrangler login (as the user)." >&2; exit 1; }
  CF_ACCT=$(node -e 'const d=JSON.parse(process.argv[1]);console.log(d.accounts.map(a=>a.name).join(", ")+" ("+d.email+")")' "$who")
  CF=yes
  vpcs=$(W vpc service list 2>/dev/null || true)
  tunnels=$(W tunnel list 2>/dev/null || true)
  [ -z "$VPC_ID" ] || grep -q "$VPC_ID" <<<"$vpcs" || VPC_ID=
  TUNNEL_ID=
  if [ -n "$VPC_ID" ]; then
    TUNNEL_ID=$(W vpc service get "$VPC_ID" 2>/dev/null | grep -oE "Tunnel ID: $UUID" | grep -oE "$UUID" || true)
  fi
  if [ -n "$TUNNEL" ]; then
    TUNNEL_ID=$(grep -E "│ *$UUID *│ *$TUNNEL *│" <<<"$tunnels" | grep -oE "$UUID" | head -1 || true)
  fi
  TUNNEL_NAME= TUNNEL_SHARED=
  if [ -n "$TUNNEL_ID" ]; then
    TUNNEL_NAME=$(grep -E "│ *$TUNNEL_ID *│" <<<"$tunnels" | awk -F'│' '{gsub(/ /,"",$3); print $3}' | head -1)
    # The list shows a tunnel id's first 8 characters. Other services on it keep it alive.
    TUNNEL_SHARED=$(grep -E "│ *${TUNNEL_ID:0:8}\.\.\. *│" <<<"$vpcs" | { [ -n "$VPC_ID" ] && grep -v "$VPC_ID" || cat; } \
      | awk -F'│' '{gsub(/ /,"",$3); print $3}' | paste -sd, - || true)
  fi
  WORKER_EXISTS=no
  [ -z "$WORKER" ] || { W deployments list --name "$WORKER" >/dev/null 2>&1 && WORKER_EXISTS=yes; }
  [ -z "$KV_ID" ] || W kv namespace list 2>/dev/null | grep -q "\"$KV_ID\"" || KV_ID=
fi

# --- plan ------------------------------------------------------------------
echo
echo "This will delete:"
n=0
item() { echo "  - $*"; n=$((n + 1)); }
[ "$VM" = no ] || item "VM $NAME ($ZONE, project $PROJECT) and its disk"
if [ "$PROJ" = yes ]; then
  item "Google Cloud project $PROJECT (recoverable for 30 days)"
  [ -z "$BUDGET" ] || item "its budget alert \"openmessage $PROJECT\""
fi
if [ "$CF" = yes ]; then
  [ "${WORKER_EXISTS:-no}" = no ] || item "Worker $WORKER ($URL)"
  [ -z "$VPC_ID" ] || item "VPC service $VPC_ID"
  [ -z "$KV_ID" ] || item "KV namespace $KV_ID"
  if [ -n "${TUNNEL_ID:-}" ]; then
    if [ -n "$TUNNEL_SHARED" ]; then
      echo "  (keeping tunnel $TUNNEL_NAME: VPC service(s) $TUNNEL_SHARED still use it)"
    else
      item "Cloudflare tunnel $TUNNEL_NAME ($TUNNEL_ID)"
    fi
  fi
  echo "  Cloudflare account: $CF_ACCT"
fi
local_files=()
for f in "$CFG" "$DONE"; do [ -f "$f" ] && local_files+=("$f"); done
in_fleet=no
[ -s "$FLEET" ] && awk -F'\t' -v l="$USER_NAME" '$1 == l {f=1} END {exit !f}' "$FLEET" && in_fleet=yes
[ ${#local_files[@]} -eq 0 ] || item "local files: ${local_files[*]/#$HOME/~}"
[ "$in_fleet" = no ] || item "the $USER_NAME line in ${FLEET/#$HOME/~}"
[ -n "$PROJECT" ] || echo "  (no project known for $USER_NAME, so no VM: pass --project to include it)"
if [ $n -eq 0 ]; then echo "  nothing found for $USER_NAME."; exit 0; fi
[ "$DRY" = no ] || { echo "(--dry-run: nothing deleted)"; exit 0; }

if [ "$YES" = no ]; then
  read -rp "Type $USER_NAME to delete all of this: " answer
  [ "$answer" = "$USER_NAME" ] || { echo "Stopped; nothing deleted."; exit 1; }
fi

# --- delete ----------------------------------------------------------------
fail=0
run() { local what=$1; shift; if out=$("$@" 2>&1); then echo "  ✓ $what"; else echo "  ✗ $what:"; tail -3 <<<"$out" | sed 's/^/      /'; fail=1; fi; }
echo
if [ "$VM" = yes ]; then
  run "VM $NAME deleted" gcloud compute instances delete "$NAME" --zone "$ZONE" --project "$PROJECT" --quiet
fi
if [ "$CF" = yes ]; then
  [ "$WORKER_EXISTS" = no ] || run "Worker $WORKER deleted" bash -c "yes | (cd '$WDIR' && npx --no-install wrangler delete --name '$WORKER' --force)"
  [ -z "$VPC_ID" ] || run "VPC service deleted" W vpc service delete "$VPC_ID"
  [ -z "$KV_ID" ] || run "KV namespace deleted" W kv namespace delete --namespace-id "$KV_ID" -y
  if [ -n "${TUNNEL_ID:-}" ] && [ -z "$TUNNEL_SHARED" ]; then
    # The VM's connection takes a moment to drop after the VM is gone.
    for try in 1 2 3 4 5 6; do
      W tunnel delete "$TUNNEL_ID" -y >/dev/null 2>&1 && break
      [ $try -lt 6 ] && sleep 10
    done
    if W tunnel list 2>/dev/null | grep -q "$TUNNEL_ID"; then
      echo "  ✗ tunnel $TUNNEL_NAME still there: npx wrangler tunnel delete $TUNNEL_ID -y (from cloud/worker)"; fail=1
    else
      echo "  ✓ tunnel $TUNNEL_NAME deleted"
    fi
  fi
fi
if [ "$PROJ" = yes ]; then
  [ -z "$BUDGET" ] || run "budget alert deleted" gcloud billing budgets delete "$BUDGET" --quiet
  run "project $PROJECT deleted" gcloud projects delete "$PROJECT" --quiet
fi
if [ $fail -eq 0 ]; then
  rm -f "$CFG" "$DONE"
  if [ "$in_fleet" = yes ]; then
    tmp=$(mktemp); awk -F'\t' -v l="$USER_NAME" '$1 != l' "$FLEET" > "$tmp" && mv "$tmp" "$FLEET"
  fi
  [ ${#local_files[@]} -eq 0 ] && [ "$in_fleet" = no ] || echo "  ✓ local records removed"
else
  echo "  (local records kept so you can re-run after fixing the ✗ above)"
fi

echo
echo "By hand:"
echo "  - $USER_NAME removes the connector: claude.ai > Settings > Connectors > ... > Remove"
if [ "$AUTH" = access ]; then
  echo "  - Cloudflare Zero Trust > Access controls > Applications: delete the $WORKER app"
fi
if [ "$AUTH" = google ] && [ "$PROJ" = no ] && [ -n "$PROJECT" ]; then
  echo "  - Google Cloud > APIs & Services > Credentials (project $PROJECT): delete the connector's OAuth client"
fi
echo "  - $USER_NAME can unsubscribe from the alert topic in the ntfy app"
exit $fail
