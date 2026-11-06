#!/usr/bin/env bash
# Puts a starting spam rules file on a VM, before the client takes over (they
# change it themselves afterwards on their spam page, <connector>/reconnect/spam).
# It refuses to replace rules already there unless you pass --force.
#
#   cloud/vm/set-spam-rules.sh --rules <file.json> --name <vm> --zone <zone> --project <id> [--force]
#
# File format: {"phrases": ["..."], "numbers": ["..."], "mode": "log"}. Mode
# "log" only lists matches; "block" blocks and reports them. OpenMessage
# reloads the file by itself, with no restart.
set -euo pipefail

RULES= NAME= ZONE=us-east1-b PROJECT= FORCE=no
while [ $# -gt 0 ]; do
  case "$1" in
    --rules) RULES=$2; shift 2 ;;
    --name) NAME=$2; shift 2 ;;
    --zone) ZONE=$2; shift 2 ;;
    --project) PROJECT=$2; shift 2 ;;
    --force) FORCE=yes; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[ -n "$RULES" ] && [ -n "$NAME" ] && [ -n "$PROJECT" ] || { echo "--rules, --name and --project are required (see --help)" >&2; exit 2; }
[ -f "$RULES" ] || { echo "No such file: $RULES" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq is needed" >&2; exit 1; }
jq -e '
  (.phrases // [] | type == "array" and all(type == "string" and length >= 3)) and
  (.numbers // [] | type == "array" and all(type == "string")) and
  ((.mode // "log") == "log" or .mode == "block")
' "$RULES" >/dev/null || { echo "$RULES isn't valid: phrases need 3 or more characters, mode is log or block" >&2; exit 2; }

# On the VM: refuse to overwrite unless forced; replace in one step.
REMOTE='set -e
F=/var/lib/openmessage/spam-rules.json
if [ "$1" != yes ] && sudo test -e "$F"; then echo "Rules are already there; left as they were (--force replaces them)."; cat >/dev/null; exit 0; fi
T=$(mktemp); cat > "$T"
sudo install -m 600 -o openmessage -g openmessage "$T" "$F.tmp"; sudo mv "$F.tmp" "$F"; rm -f "$T"
echo "Rules saved."'
gcloud compute ssh --quiet "$NAME" --zone "$ZONE" --project "$PROJECT" -- "bash -c $(printf '%q' "$REMOTE") _ $FORCE" < "$RULES"
