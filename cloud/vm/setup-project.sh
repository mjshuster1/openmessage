#!/usr/bin/env bash
# Gets a Google Cloud project ready for the OpenMessage VM. Safe to re-run.
#
#   cloud/vm/setup-project.sh --project <id> [--billing-account <id>] [--budget 10] [--check]
#
# 1. creates the project if it doesn't exist (ids are global: lowercase,
#    6-30 characters, e.g. openmessage-mike);
# 2. links billing (needed even for the free tier); with one open billing
#    account it picks that one, otherwise pass --billing-account;
# 3. turns on the Compute Engine API (takes a minute the first time);
# 4. adds a monthly budget alert (default $10) that emails the billing
#    account's admins at 50% and 100%. It alerts, it doesn't stop anything.
#    Expected cost is about $4/month (the VM's IPv4 address, plus backups).
# --check only reports what's missing and changes nothing.
set -euo pipefail

PROJECT=
BILLING=
BUDGET=10
CHECK=no
while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT=$2; shift 2 ;;
    --billing-account) BILLING=$2; shift 2 ;;
    --budget) BUDGET=$2; shift 2 ;;
    --check) CHECK=yes; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[[ "$PROJECT" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || { echo "--project: 6-30 lowercase letters, digits and -, starting with a letter" >&2; exit 2; }
[[ "$BUDGET" =~ ^[0-9]+$ ]] || { echo "--budget: whole dollars" >&2; exit 2; }
todo=0
step() { echo "$*"; }
need() { echo "   missing: $*"; todo=$((todo + 1)); }

step "1/4 Project $PROJECT"
if gcloud projects describe "$PROJECT" --format='value(projectId)' >/dev/null 2>&1; then
  echo "   exists"
elif [ "$CHECK" = yes ]; then
  need "project (or no access to it as $(gcloud config get-value account 2>/dev/null))"
else
  gcloud projects create "$PROJECT" --name "OpenMessage" >/dev/null
  echo "   created"
fi

step "2/4 Billing"
linked=$(gcloud billing projects describe "$PROJECT" --format='value(billingAccountName)' 2>/dev/null || true)
if [ -n "$linked" ]; then
  BILLING=${linked#billingAccounts/}
  echo "   linked to $BILLING"
else
  if [ -z "$BILLING" ]; then
    accounts=$(gcloud billing accounts list --filter='open=true' --format='value(name)' 2>/dev/null || true)
    n=$(grep -c . <<<"$accounts" || true)
    if [ "$n" = 1 ]; then
      BILLING=${accounts#billingAccounts/}
    elif [ "$n" = 0 ]; then
      echo "   No open billing account. Create one at https://console.cloud.google.com/billing (a card is needed even for the free tier), then re-run." >&2
      exit 1
    else
      echo "   Several billing accounts; re-run with --billing-account <id>:" >&2
      gcloud billing accounts list --filter='open=true' --format='table(name,displayName)' >&2
      exit 1
    fi
  fi
  if [ "$CHECK" = yes ]; then
    need "billing link (would use $BILLING)"
  else
    gcloud billing projects link "$PROJECT" --billing-account "$BILLING" >/dev/null
    echo "   linked to $BILLING"
  fi
fi

step "3/4 Compute Engine API"
if gcloud services list --project "$PROJECT" --enabled --format='value(config.name)' 2>/dev/null | grep -qx compute.googleapis.com; then
  echo "   on"
elif [ "$CHECK" = yes ]; then
  need "Compute Engine API"
else
  gcloud services enable compute.googleapis.com billingbudgets.googleapis.com --project "$PROJECT"
  echo "   on"
fi

step "4/4 Budget alert (\$$BUDGET/month)"
NAME="openmessage $PROJECT"
if [ -z "$BILLING" ]; then
  need "budget (no billing account yet)"
elif gcloud billing budgets list --billing-account "$BILLING" --format='value(displayName)' 2>/dev/null | grep -qxF "$NAME"; then
  echo "   exists"
elif [ "$CHECK" = yes ]; then
  need "budget alert"
else
  gcloud services enable billingbudgets.googleapis.com --project "$PROJECT" >/dev/null 2>&1 || true
  # A just-enabled API can take a minute to answer, so try a few times.
  made=no
  for try in 1 2 3 4; do
    if err=$(gcloud billing budgets create --billing-account "$BILLING" --display-name "$NAME" \
        --budget-amount "${BUDGET}USD" --filter-projects "projects/$PROJECT" \
        --threshold-rule percent=0.5 --threshold-rule percent=1.0 2>&1); then
      made=yes; break
    fi
    [ $try -lt 4 ] && sleep 20
  done
  if [ "$made" = yes ]; then
    echo "   created (emails the billing account's admins)"
  else
    echo "   couldn't create it; optional, so continuing. Last error:"
    tail -2 <<<"$err" | sed 's/^/     /'
    echo "   By hand: https://console.cloud.google.com/billing/$BILLING/budgets"
  fi
fi

if [ "$CHECK" = yes ]; then
  [ $todo -eq 0 ] && echo "Ready." || { echo "$todo thing(s) to set up: re-run without --check."; exit 1; }
else
  gcloud config set project "$PROJECT" >/dev/null 2>&1 || true
  echo "Ready. (gcloud's default project is now $PROJECT.)"
fi
