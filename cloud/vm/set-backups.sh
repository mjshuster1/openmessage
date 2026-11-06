#!/usr/bin/env bash
# Turns on nightly disk backups for a VM, kept 7 days. Safe to re-run.
#
#   cloud/vm/set-backups.sh --name <vm> --zone <zone> --project <id> [--check]
#
# They're Google disk snapshots in the same project, so they belong to whoever
# owns the project. They hold the same things as the disk: stored texts and the
# Google sign-in. Deleting the project deletes them. After a VM alone is
# deleted they expire on the same 7-day schedule. Cost: a few cents a month
# per GB stored. To restore: vm/README.md, "Restoring from a backup".
set -euo pipefail

NAME= ZONE=us-east1-b PROJECT= CHECK=no
POLICY=om-nightly
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME=$2; shift 2 ;;
    --zone) ZONE=$2; shift 2 ;;
    --project) PROJECT=$2; shift 2 ;;
    --check) CHECK=yes; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[ -n "$NAME" ] && [ -n "$PROJECT" ] || { echo "--name and --project are required" >&2; exit 2; }
REGION=${ZONE%-*}
G=(gcloud --project "$PROJECT" --quiet)

if "${G[@]}" compute disks describe "$NAME" --zone "$ZONE" --format='value(resourcePolicies)' 2>/dev/null | grep -q "/$POLICY"; then
  echo "   nightly backups are on"
  exit 0
fi
if [ "$CHECK" = yes ]; then echo "   missing: nightly backups"; exit 1; fi

if ! "${G[@]}" compute resource-policies describe "$POLICY" --region "$REGION" --format='value(name)' >/dev/null 2>&1; then
  "${G[@]}" compute resource-policies create snapshot-schedule "$POLICY" --region "$REGION" \
    --description "OpenMessage nightly backups" --max-retention-days 7 \
    --on-source-disk-delete apply-retention-policy --daily-schedule --start-time 08:00 >/dev/null
fi
"${G[@]}" compute disks add-resource-policies "$NAME" --zone "$ZONE" --resource-policies "$POLICY" >/dev/null
echo "   nightly backups turned on (kept 7 days)"
