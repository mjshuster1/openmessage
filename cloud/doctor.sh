#!/usr/bin/env bash
# Checks an OpenMessage cloud deployment end to end and says what to fix.
# Read-only: it changes nothing anywhere.
#
#   cloud/doctor.sh [--name om-test] [--zone us-east1-b] [--project <id>]
#                   [--user <short-name> | --connector <https://…/mcp>]
#   cloud/doctor.sh --pre [--project <id>]   before a deploy: tools and logins only
#   cloud/doctor.sh --all                    one line per deployment in the fleet file
#   cloud/doctor.sh --save <label> [same options]   add/replace this deployment in the fleet file
#
# Checks: local tools and logins; the VM (running, release, OpenMessage,
# Google Messages, newest text, alerts, cloudflared, disk); the connector
# (answers 401 to strangers; which sign-in). --user reads the connector URL
# from cloud/worker/wrangler.<user>.toml.
#
# Fleet file: ~/.config/openmessage/fleet.tsv, one deployment per line:
#   label <TAB> vm-name <TAB> zone <TAB> project <TAB> connector-url
# deploy.sh adds each deployment it finishes.
# Exit status: 0 when nothing failed (warnings allowed), 1 otherwise.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
FLEET=${OM_FLEET_FILE:-$HOME/.config/openmessage/fleet.tsv}
NAME=om-test
ZONE=us-east1-b
PROJECT=
USER_NAME=
CONNECTOR=
MODE=full
SAVE=
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME=$2; shift 2 ;;
    --zone) ZONE=$2; shift 2 ;;
    --project) PROJECT=$2; shift 2 ;;
    --user) USER_NAME=$2; shift 2 ;;
    --connector) CONNECTOR=$2; shift 2 ;;
    --pre) MODE=pre; shift ;;
    --all) MODE=all; shift ;;
    --save) SAVE=$2; shift 2 ;;
    -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ -t 1 ]; then OK=$'\e[32m✓\e[0m'; WARN=$'\e[33m!\e[0m'; BAD=$'\e[31m✗\e[0m'; else OK='✓'; WARN='!'; BAD='✗'; fi
FAILS=0
ok()   { echo "  $OK $*"; }
warn() { echo "  $WARN $*"; }
bad()  { echo "  $BAD $*"; FAILS=$((FAILS + 1)); }
fix()  { echo "      → $*"; }

if [ -n "$USER_NAME" ] && [ -z "$CONNECTOR" ]; then
  cfg="$HERE/worker/wrangler.$USER_NAME.toml"
  [ -f "$cfg" ] && CONNECTOR=$(grep -E '^PUBLIC_URL = "' "$cfg" | head -1 | cut -d'"' -f2)/mcp
fi

G() { if [ -n "$PROJECT" ]; then gcloud --project "$PROJECT" "$@"; else gcloud "$@"; fi; }

ago() { # seconds -> "5m", "3h", "2d"
  local s=$1
  if [ "$s" -lt 3600 ]; then echo "$((s / 60))m"; elif [ "$s" -lt 172800 ]; then echo "$((s / 3600))h"; else echo "$((s / 86400))d"; fi
}

# ---------------------------------------------------------------- local
check_local() {
  echo "This computer"
  if ! command -v gcloud >/dev/null; then
    bad "gcloud isn't installed"; fix "https://cloud.google.com/sdk/docs/install (or run from Cloud Shell)"
  else
    local acct proj
    acct=$(gcloud config get-value account 2>/dev/null)
    proj=${PROJECT:-$(gcloud config get-value project 2>/dev/null)}
    if [ -z "$acct" ]; then bad "gcloud isn't signed in"; fix "gcloud auth login"; else ok "gcloud signed in as $acct"; fi
    if [ -z "$proj" ]; then bad "no Google Cloud project chosen"; fix "pass --project <id>, or gcloud config set project <id>"; else ok "project $proj"; fi
  fi
  [ "$MODE" = pre ] || return 0
  if command -v node >/dev/null && node -e 'process.exit(+process.versions.node.split(".")[0] >= 22 ? 0 : 1)'; then
    ok "Node $(node --version)"
  else
    bad "Node 22+ is needed (pairing and the connector setup use it)"; fix "https://nodejs.org"
  fi
  if [ -d "$HERE/worker/node_modules" ]; then
    local who
    if who=$( (cd "$HERE/worker" && npx --no-install wrangler whoami --json) 2>/dev/null); then
      ok "Cloudflare: $(node -e 'const d=JSON.parse(process.argv[1]);console.log(d.email+" ("+d.accounts.map(a=>a.name).join(", ")+")")' "$who" 2>/dev/null)"
    else
      bad "Wrangler isn't signed in to Cloudflare"; fix "cd cloud/worker && npx wrangler login (as the user)"
    fi
  else
    bad "cloud/worker dependencies aren't installed"; fix "cd cloud/worker && npm ci"
  fi
  local chrome=
  for c in "/Applications/Google Chrome.app" google-chrome google-chrome-stable chromium; do
    if [ -e "$c" ] || command -v "$c" >/dev/null 2>&1; then chrome=yes; break; fi
  done
  if [ -n "$chrome" ]; then ok "Chrome (for pairing)"; else warn "no Chrome found; pairing needs Chrome, or reconnect.sh --cookies"; fi
  for t in curl openssl; do command -v $t >/dev/null || bad "$t is missing"; done
}

# ---------------------------------------------------------------- VM
# Runs on the VM as the SSH user. Prints KEY=VALUE lines only.
REMOTE='
st=$(curl -s -m 5 127.0.0.1:7007/api/status 2>/dev/null)
echo "release=$(cat /var/lib/openmessage-release 2>/dev/null)"
echo "om_active=$(systemctl is-active openmessage 2>/dev/null)"
echo "cf_active=$(systemctl is-active cloudflared 2>/dev/null)"
echo "log_timer=$(systemctl is-active om-status-log.timer 2>/dev/null)"
echo "update_timer=$(systemctl is-active om-update.timer 2>/dev/null)"
echo "origin=$(systemctl is-active om-origin.socket 2>/dev/null)"
echo "origin_listen=$(systemctl show -p Listen --value om-origin.socket 2>/dev/null | grep -oE "[0-9.]+:[0-9]+")"
if [ -n "$st" ]; then
  printf "%s" "$st" | jq -r "\"g_connected=\(.google.connected)\", \"g_pairing=\(.google.needs_pairing)\", \"g_state=\(.google.supervisor.state // \"\")\", \"g_block=\(.google.supervisor.block_reason // \"\")\""
fi
js=$(sudo -u openmessage OPENMESSAGES_DATA_DIR=/var/lib/openmessage timeout 20 /usr/local/bin/openmessage status --json 2>/dev/null)
if [ -n "$js" ]; then
  printf "%s" "$js" | jq -r "\"newest_recv_ms=\([.platforms[].latest_received_ms] | max // 0)\", \"stalled=\([.platforms[] | select(.silence.stalled == true) | .platform] | unique | join(\",\"))\", \"total=\(.total_messages)\""
fi
echo "alerts=$(sudo test -s /etc/openmessage/alert.env && echo on || echo off)"
log=/var/lib/openmessage/test-status.jsonl
if [ -r "$log" ] || sudo test -r "$log"; then
  echo "down_24h=$(sudo tail -n 288 "$log" | jq -s "map(select(.up != true or .connected != true)) | length")"
fi
echo "disk_pct=$(df --output=pcent / | tail -1 | tr -dc 0-9)"
echo "now_ms=$(($(date +%s) * 1000))"
'

check_vm() {
  echo "VM $NAME ($ZONE${PROJECT:+, $PROJECT})"
  local desc status
  if ! desc=$(G compute instances describe "$NAME" --zone "$ZONE" --format='value(status,metadata.items.om-release,metadata.items.om-auto-update)' 2>/dev/null); then
    bad "no VM named $NAME in $ZONE"; fix "check --name/--zone/--project, or create it: cloud/vm/create-vm.sh"
    return
  fi
  status=$(cut -f1 <<<"$desc")
  if [ "$status" != RUNNING ]; then
    bad "VM is $status"; fix "gcloud compute instances start $NAME --zone $ZONE"
    return
  fi
  ok "running"

  local out
  out=$(G compute ssh --quiet "$NAME" --zone "$ZONE" --command "bash -c $(printf %q "$REMOTE")" 2>/dev/null | tr -d '\r')
  if ! grep -q '^now_ms=' <<<"$out"; then
    bad "couldn't run the check over SSH"; fix "gcloud compute ssh $NAME --zone $ZONE (fix what it says), then re-run"
    return
  fi
  v() { grep -E "^$1=" <<<"$out" | head -1 | cut -d= -f2-; }

  local rel; rel=$(v release)
  if [ -n "$rel" ]; then ok "release ${rel#*@}"; else warn "no release stamp (installed by hand, so it can't be upgraded by metadata)"; fi

  if [ "$(v om_active)" != active ]; then
    bad "OpenMessage isn't running ($(v om_active))"
    if [ -z "$(v g_connected)" ]; then fix "if it was never paired: cloud/vm/reconnect.sh --name $NAME --zone $ZONE; else: sudo systemctl start openmessage, and check journalctl -u openmessage"; fi
  elif [ "$(v g_connected)" = true ]; then
    ok "Google Messages connected"
  elif [ "$(v g_pairing)" = true ] || [ -n "$(v g_block)" ] || [ "$(v g_state)" = blocked ]; then
    local why; why=$(v g_state); [ -n "$(v g_block)" ] && why="$why, $(v g_block)"
    bad "Google Messages needs reconnecting ($why)"
    fix "with the phone in hand: cloud/vm/reconnect.sh --name $NAME --zone $ZONE (once, not in a loop)"
  else
    warn "Google Messages disconnected right now ($(v g_state)); it usually recovers by itself"
    fix "if this persists for an hour: cloud/vm/reconnect.sh --name $NAME --zone $ZONE"
  fi

  local newest now
  newest=$(v newest_recv_ms); now=$(v now_ms)
  if [ -n "$newest" ] && [ "$newest" != 0 ]; then
    local age=$(( (now - newest) / 1000 ))
    if [ -n "$(v stalled)" ]; then
      warn "newest text received $(ago $age) ago; quieter than usual for: $(v stalled)"
      fix "check the phone is on and online with Google Messages as the texting app"
    else
      ok "newest text received $(ago $age) ago ($(v total) stored)"
    fi
  elif [ "$(v om_active)" = active ]; then
    warn "no received texts stored yet"
  fi

  local down; down=$(v down_24h)
  if [ -n "$down" ]; then
    if [ "$down" -le 3 ]; then ok "disconnected $((down * 5)) min in the last 24h"; else warn "disconnected $((down * 5)) min in the last 24h"; fi
  fi

  if [ "$(v alerts)" = on ]; then ok "alerts on"; else warn "alerts off"; fix "cloud/vm/set-email-alerts.sh --project ${PROJECT:-<id>}, then cloud/vm/set-alerts.sh --name $NAME --zone $ZONE${PROJECT:+ --project $PROJECT} --email"; fi
  case "$(v cf_active)" in
    active) ok "cloudflared running" ;;
    *) bad "cloudflared isn't running ($(v cf_active)): claude.ai can't reach the VM"; fix "install the tunnel: cloud/vm/create-vm.sh's tunnel step, or sudo systemctl start cloudflared" ;;
  esac
  local ol; ol=$(v origin_listen)
  if [ -n "$ol" ]; then
    if [ "$(v origin)" = active ] || [ "$(v origin)" = listening ]; then
      ok "tunnel entry $ol forwards to OpenMessage"
    else
      bad "tunnel entry $ol isn't listening ($(v origin)): claude.ai can't reach OpenMessage"
      fix "cloud/vm/create-vm.sh --name $NAME --zone $ZONE --origin-port ${ol##*:}"
    fi
  fi
  [ "$(v log_timer)" = active ] || warn "status log timer isn't running (alerts depend on it)"
  if [ "$(v update_timer)" = active ]; then ok "automatic updates on"; fi
  local disk; disk=$(v disk_pct)
  if [ -n "$disk" ] && [ "$disk" -ge 85 ]; then warn "disk ${disk}% full"; fi

  # Summary for --all
  SUMMARY_G=$( [ "$(v g_connected)" = true ] && echo connected || echo "NOT connected")
  SUMMARY_NEW=$( [ -n "$newest" ] && [ "$newest" != 0 ] && echo "text $(ago $(( (now - newest) / 1000 ))) ago" || echo "no texts")
  SUMMARY_REL=${rel#*@}; [ -n "$SUMMARY_REL" ] || SUMMARY_REL=unversioned
}

# ---------------------------------------------------------------- connector
check_connector() {
  [ -n "$CONNECTOR" ] || return 0
  echo "Connector $CONNECTOR"
  local hdrs code
  hdrs=$(curl -s -o /dev/null -D - -m 15 -X POST -H 'Content-Type: application/json' -d '{}' "$CONNECTOR" | tr -d '\r')
  code=$(head -1 <<<"$hdrs" | awk '{print $2}')
  if [ "$code" = 401 ] && grep -qi 'resource_metadata=' <<<"$hdrs"; then
    if grep -qi 'cloudflare-access-protected-resource' <<<"$hdrs"; then
      ok "refuses strangers (401); sign-in by Cloudflare Access"
    else
      ok "refuses strangers (401); sign-in by the Worker (Google)"
    fi
    SUMMARY_C=ok
  elif [ "$code" = 302 ] && grep -qiE '^location: https://[a-z0-9-]+\.cloudflareaccess\.com/' <<<"$hdrs"; then
    bad "Cloudflare Access is on, but Managed OAuth isn't, so claude.ai can't sign in"
    fix "Zero Trust > Access controls > Applications > the app > Managed OAuth (see cloud/worker/setup-connector.sh --auth access)"
    SUMMARY_C=broken
  elif [ -z "$code" ]; then
    bad "no answer"; fix "is the URL right? npx wrangler deployments list -c wrangler.<user>.toml"
    SUMMARY_C=down
  else
    bad "answered $code to a stranger (expected 401)"; fix "re-run cloud/worker/setup-connector.sh for this user"
    SUMMARY_C=broken
  fi
}

# ---------------------------------------------------------------- modes
if [ -n "$SAVE" ]; then
  [[ "$SAVE" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "--save: letters, digits, - and _" >&2; exit 2; }
  mkdir -p "$(dirname "$FLEET")"
  touch "$FLEET"
  tmp=$(mktemp)
  awk -F'\t' -v l="$SAVE" '$1 != l' "$FLEET" > "$tmp"
  printf '%s\t%s\t%s\t%s\t%s\n' "$SAVE" "$NAME" "$ZONE" "$PROJECT" "$CONNECTOR" >> "$tmp"
  mv "$tmp" "$FLEET"
  echo "Saved $SAVE to $FLEET"
  exit 0
fi

if [ "$MODE" = all ]; then
  [ -s "$FLEET" ] || { echo "No deployments in $FLEET yet (deploy.sh adds them; or doctor.sh --save <label> …)." >&2; exit 1; }
  rc=0
  while IFS=$'\t' read -r label NAME ZONE PROJECT CONNECTOR; do
    [ -n "$label" ] && [ "${label#\#}" = "$label" ] || continue
    SUMMARY_G='?'; SUMMARY_NEW='?'; SUMMARY_REL='?'; SUMMARY_C='-'; FAILS=0
    report=$( { check_vm; check_connector; echo "FAILS=$FAILS"; echo "SUM=$SUMMARY_G|$SUMMARY_NEW|$SUMMARY_REL|$SUMMARY_C"; } </dev/null 2>&1)
    f=$(grep '^FAILS=' <<<"$report" | cut -d= -f2)
    IFS='|' read -r sg sn sr sc <<<"$(grep '^SUM=' <<<"$report" | cut -d= -f2-)"
    mark=$OK; [ "${f:-1}" = 0 ] || { mark=$BAD; rc=1; }
    [ "${f:-1}" = 0 ] && grep -q "^  $WARN" <<<"$report" && mark=$WARN
    printf '%s %-12s %-14s %-16s %-14s connector %s\n' "$mark" "$label" "$sg" "$sn" "$sr" "$sc"
    if [ "${f:-1}" != 0 ]; then grep -E "^  $BAD|→" <<<"$report" | sed 's/^/    /'; fi
  done < "$FLEET"
  exit $rc
fi

check_local
if [ "$MODE" = full ]; then
  echo
  check_vm
  if [ -n "$CONNECTOR" ]; then echo; check_connector; fi
fi
echo
if [ $FAILS -eq 0 ]; then echo "No problems found."; else echo "$FAILS problem(s) found (see → for fixes)."; fi
[ $FAILS -eq 0 ]
