#!/usr/bin/env bash
# Tests the browser setup path (setup.sh, deploy.sh --from-browser, handback.sh
# --from-browser, doctor.sh --add-client) with stand-ins for gcloud, Wrangler,
# curl and the other setup scripts. Run: cloud/tests/setup_test.sh
# These check the scripts' own logic. They don't prove Google or Cloudflare
# behave as expected: only a real run can.
set -uo pipefail
SRC=$(cd "$(dirname "$0")/.." && pwd)
PASS=0 FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok: $1"; }
no() { FAIL=$((FAIL + 1)); echo "  FAILED: $1"; [ -z "${2:-}" ] || sed 's/^/      /' <<<"$2" | tail -25; }
has() { if grep -qF -- "$2" <<<"$3"; then ok "$1"; else no "$1 (wanted: $2)" "$3"; fi; }
hasnt() { if grep -qF -- "$2" <<<"$3"; then no "$1 (didn't want: $2)" "$3"; else ok "$1"; fi; }

# A fresh sandbox: copies of the scripts under test, stand-ins for the rest.
sandbox() {
  T=$(mktemp -d); H=$T/home; B=$T/bin; C=$T/cloud; LOG=$T/calls
  mkdir -p "$H" "$B" "$C/worker/node_modules" "$C/vm"; touch "$LOG"
  cp "$SRC/setup.sh" "$SRC/deploy.sh" "$SRC/handback.sh" "$SRC/doctor.sh" "$C/"
  export HOME=$H CLOUD_SHELL=true STUB_LOG=$LOG BILLING_ACCOUNTS=1 SUBDOMAIN=existing LOGGED_IN=yes VM_CONNECTED=true
  cat > "$B/gcloud" <<'EOF'
#!/usr/bin/env bash
echo "gcloud $*" >> "$STUB_LOG"
case "$*" in
  *"auth print-access-token"*) echo tok ;;
  *"projects list"*) [ -z "${EXISTING_PROJECT:-}" ] || echo "$EXISTING_PROJECT" ;;
  *"instances list"*) [ -z "${EXISTING_PROJECT:-}" ] || printf 'om-mike\tus-east1-b\n' ;;
  *"config get-value account"*) echo Mike@Example.com ;;
  *"billing accounts list"*) for ((i = 0; i < BILLING_ACCOUNTS; i++)); do echo "billingAccounts/$i"; done ;;
  *"compute ssh"*"api/status"*) echo "$VM_CONNECTED" ;;
  *"compute ssh"*) [ "${SSH_FAILS:-no}" = no ] || exit 1 ;;
  *"resource-policies describe"*) exit 1 ;;
  *"project-info describe"*) echo '{"commonInstanceMetadata":{"items":[]}}' ;;
  *"instances describe"*"format=json"*) echo '{"metadata":{"items":[]}}' ;;
  *"get-iam-policy"*) echo '{"bindings":[{"role":"roles/owner","members":["user:mike@example.com"]}]}' ;;
esac
EOF
  cat > "$B/npx" <<'EOF'
#!/usr/bin/env bash
echo "npx $*" >> "$STUB_LOG"
case "$*" in
  *"whoami --json"*) if [ "$LOGGED_IN" = yes ] || [ -e "$HOME/logged-in" ]; then echo '{"loggedIn":true,"email":"m@x.co","accounts":[{"id":"acct1","name":"Mike"}]}'; else echo '{"loggedIn":false}'; fi ;;
  *"login --device"*) touch "$HOME/logged-in" ;;
  *"auth token"*) echo cf-token ;;
  *"secret list"*) echo '[{"name":"ALLOWED_EMAIL"},{"name":"STATUS_KEY"},{"name":"RECONNECT_SECRET"},{"name":"GOOGLE_CLIENT_ID"},{"name":"GOOGLE_CLIENT_SECRET"}]' ;;
  *"tunnel delete"*) touch "$HOME/tunnel-gone" ;;
  *"tunnel list"*) [ -e "$HOME/tunnel-gone" ] || echo '│ 11111111-1111-1111-1111-111111111111 │ om-mike │ healthy │' ;;
  *"vpc service list"*) printf '│ 22222222-2222-2222-2222-222222222222 │ om-mike-origin │\n│ 33333333-3333-3333-3333-333333333333 │ om-mike-pair │\n' ;;
  *"vpc service get"*) echo 'Tunnel ID: 11111111-1111-1111-1111-111111111111' ;;
  *"kv namespace list"*) echo '[{"title":"om-mike-oauth","id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]' ;;
  *"deploy "*) echo 'https://om-mike.existing.workers.dev' ;;
esac
EOF
  cat > "$B/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >> "$STUB_LOG"
case "$*" in
  *"-X PUT"*) echo '{"result":{"subdomain":"made-by-put"}}' ;;
  *workers/subdomain*) if [ "$SUBDOMAIN" = none ]; then echo '{"result":null}'; else echo "{\"result\":{\"subdomain\":\"$SUBDOMAIN\"}}"; fi ;;
esac
EOF
  cat > "$B/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$B"/*; export PATH="$B:$PATH"
}
stub_scripts() { # the scripts deploy.sh calls; each records its arguments
  for s in vm/setup-project.sh vm/create-vm.sh vm/set-email-alerts.sh vm/set-alerts.sh vm/reconnect.sh vm/set-spam-rules.sh vm/set-backups.sh; do
    printf '#!/usr/bin/env bash\necho "%s $*" >> "$STUB_LOG"\n' "$s" > "$C/$s"; chmod +x "$C/$s"
  done
  cat > "$C/worker/setup-connector.sh" <<'EOF'
#!/usr/bin/env bash
echo "setup-connector $*" >> "$STUB_LOG"
mkdir -p "$HOME/.config/openmessage"
echo https://om-mike.x.workers.dev/reconnect > "$HOME/.config/openmessage/reconnect-mike.url"
echo 'https://om-mike.x.workers.dev/status?key=abc123' > "$HOME/.config/openmessage/status-mike.url"
printf 'PUBLIC_URL = "https://om-mike.x.workers.dev"\n' > "$(dirname "$0")/wrangler.mike.toml"
EOF
  chmod +x "$C/worker/setup-connector.sh"
  cat > "$C/doctor.sh.stub" <<'EOF'
#!/usr/bin/env bash
echo "doctor $*" >> "$STUB_LOG"
EOF
  mv "$C/doctor.sh.stub" "$C/doctor.sh"; chmod +x "$C/doctor.sh"
}
stub_deploy() { printf '#!/usr/bin/env bash\necho "deploy $*" >> "$STUB_LOG"\n' > "$C/deploy.sh"; chmod +x "$C/deploy.sh"; }
done_sandbox() { rm -rf "$T"; }
ANSWERS='Mike Hurley
1
'

echo "setup.sh: stops before creating anything when there's no billing"
sandbox; stub_deploy
out=$(BILLING_ACCOUNTS=0 "$C/setup.sh" --helper-email h@x.co <<<"$ANSWERS" 2>&1); rc=$?
[ $rc = 1 ] && ok "exits with an error" || no "exits with an error" "$out"
has "says to add a card" "console.cloud.google.com/billing" "$out"
hasnt "deploy never started" "deploy " "$(cat "$LOG")"
done_sandbox

echo "setup.sh: normal run"
sandbox; stub_deploy
out=$("$C/setup.sh" --helper-email h@x.co <<<"$ANSWERS" 2>&1)
calls=$(cat "$LOG")
has "passes the browser flags" "deploy --client-owned --from-browser --user mikehurley --email mike@example.com" "$calls"
has "label keeps the space" "--label Mike Hurley" "$calls"
has "time zone" "--timezone America/New_York" "$calls"
has "helper gets alerts" "--alert-email h@x.co" "$calls"
has "project id has a suffix" "--project openmessage-mikehurley-" "$calls"
hasnt "no login needed when signed in" "login --device" "$calls"
hasnt "keeps an existing workers.dev address" "-X PUT" "$calls"
p1=$(grep -oE 'openmessage-mikehurley-[0-9a-f]{4}' "$LOG" | head -1)
: > "$LOG"
out=$("$C/setup.sh" --helper-email h@x.co </dev/null 2>&1)
has "second run asks nothing and keeps the project" "--project $p1" "$(cat "$LOG")"
has "second run keeps the name" "--label Mike Hurley" "$(cat "$LOG")"
done_sandbox

echo "setup.sh: new Cloudflare account"
sandbox; stub_deploy
out=$(LOGGED_IN=no SUBDOMAIN=none "$C/setup.sh" <<<"$ANSWERS" 2>&1)
calls=$(cat "$LOG")
has "uses device sign-in" "wrangler login --device" "$calls"
has "registers a workers.dev address" "-X PUT" "$calls"
has "no helper: alerts go to the client" "--alert-email mike@example.com" "$calls"
hasnt "never prints the Cloudflare token" "cf-token" "$out"
done_sandbox

echo "setup.sh: an existing setup is never built twice"
sandbox; stub_deploy
out=$(EXISTING_PROJECT=openmessage-mike-ab12 "$C/setup.sh" --helper-email h@x.co </dev/null 2>&1); rc=$?
[ $rc = 0 ] && ok "stops cleanly with its files gone" || no "stops cleanly with its files gone (rc $rc)" "$out"
has "says it found one" "You already have a setup" "$out"
hasnt "deploy never started" "deploy " "$(cat "$LOG")"
done_sandbox

echo "setup.sh --update"
sandbox; stub_deploy; cp "$SRC/worker/setup-connector.sh" "$SRC/worker/wrangler.example.toml" "$C/worker/"
out=$(EXISTING_PROJECT=openmessage-mike-ab12 "$C/setup.sh" --update </dev/null 2>&1); rc=$?
calls=$(cat "$LOG")
[ $rc = 0 ] && ok "finishes with its files gone, asking nothing" || no "finishes with its files gone (rc $rc)" "$out"
has "keeps the address" 'PUBLIC_URL = "https://om-mike.existing.workers.dev"' "$(cat "$C/worker/wrangler.mike.toml")"
hasnt "never deploys a placeholder" "placeholder.invalid" "$(cat "$C/worker/wrangler.mike.toml")"
has "redeploys" "wrangler deploy -c wrangler.mike.toml" "$calls"
hasnt "keeps the status key" "secret put STATUS_KEY" "$calls"
hasnt "keeps the allowed email" "secret put ALLOWED_EMAIL" "$calls"
hasnt "keeps the Google client" "secret put GOOGLE_CLIENT" "$calls"
hasnt "no new server" "deploy --client-owned" "$calls"
has "signs Cloudflare out after" "wrangler logout" "$calls"
done_sandbox

echo "setup.sh --update with nothing to update"
sandbox; stub_deploy
out=$("$C/setup.sh" --update </dev/null 2>&1); rc=$?
[ $rc = 1 ] && ok "refuses" || no "refuses (rc $rc)" "$out"
has "says why" "No setup found" "$out"
done_sandbox

echo "setup.sh --remove"
sandbox; stub_deploy; cp "$SRC/teardown.sh" "$C/"
out=$(EXISTING_PROJECT=openmessage-mike-ab12 "$C/setup.sh" --remove <<<"wrong" 2>&1); rc=$?
hasnt "the wrong word deletes nothing" "projects delete" "$(cat "$LOG")"
hasnt "nor the server" "instances delete" "$(cat "$LOG")"
: > "$LOG"
cat >> "$B/gcloud" <<'EOF'
case "$*" in *"projects describe"*) echo openmessage-mike-ab12 ;; *"instances describe"*) echo om-mike ;; esac
EOF
out=$(EXISTING_PROJECT=openmessage-mike-ab12 "$C/setup.sh" --remove <<<"mike" 2>&1); rc=$?
calls=$(cat "$LOG")
[ $rc = 0 ] && ok "finishes" || no "finishes (rc $rc)" "$out"
has "deletes the server" "compute instances delete om-mike" "$calls"
has "deletes the project" "projects delete openmessage-mike-ab12" "$calls"
has "finds the Worker by name" "wrangler delete --name om-mike" "$(cat "$LOG"; echo "$out")"
has "deletes the connection's services" "vpc service delete 22222222-2222-2222-2222-222222222222" "$calls"
has "deletes the Reconnect service" "vpc service delete 33333333-3333-3333-3333-333333333333" "$calls"
has "deletes the tunnel" "tunnel delete 11111111-1111-1111-1111-111111111111" "$calls"
done_sandbox

echo "set-backups.sh"
sandbox; cp "$SRC/vm/set-backups.sh" "$C/vm/"
out=$("$C/vm/set-backups.sh" --name om-mike --zone us-east1-b --project p-1 2>&1)
calls=$(cat "$LOG")
has "uses the VM's region" "--region us-east1" "$calls"
has "keeps 7 days" "--max-retention-days 7" "$calls"
has "attaches to the VM's disk" "disks add-resource-policies om-mike --zone us-east1-b --resource-policies om-nightly" "$calls"
cat >> "$B/gcloud" <<'EOF'
case "$*" in *"disks describe"*) echo 'https://x/regions/us-east1/resourcePolicies/om-nightly' ;; esac
EOF
: > "$LOG"
out=$("$C/vm/set-backups.sh" --name om-mike --zone us-east1-b --project p-1 2>&1)
has "second run says it's on" "backups are on" "$out"
hasnt "second run changes nothing" "add-resource-policies" "$(cat "$LOG")"
done_sandbox

echo "set-email-alerts.sh --status-url"
sandbox; cp "$SRC/vm/set-email-alerts.sh" "$C/vm/"
cat > "$B/curl" <<'EOF'
#!/usr/bin/env bash
args="$*"
echo "curl $args" >> "$STUB_LOG"
case "$args" in
  *"-X GET"*) echo '{}' ;;
  *"-X POST"*uptimeCheckConfigs*) echo '{"name":"projects/p-1/uptimeCheckConfigs/check-123"}' ;;
  *"-X POST"*notificationChannels*) echo '{"name":"projects/p-1/notificationChannels/9"}' ;;
  *"-X POST"*) echo '{"name":"projects/p-1/alertPolicies/5"}' ;;
esac
EOF
cat >> "$B/gcloud" <<'EOF'
case "$*" in *"services list"*) printf 'monitoring.googleapis.com
logging.googleapis.com
' ;; esac
EOF
out=$("$C/vm/set-email-alerts.sh" --project p-1 --email a@b.co --label "Mike H" --status-url 'https://om.x.workers.dev/status?key=abc123' 2>&1); rc=$?
calls=$(cat "$LOG")
[ $rc = 0 ] && ok "finishes" || no "finishes (rc $rc)" "$out"
has "checks the right address" '"host":"om.x.workers.dev"' "$(tr -d ' \n' <<<"$calls")"
has "checks the status link as JSON" '"path":"/status?key=abc123&format=json"' "$(tr -d ' \n' <<<"$calls")"
flat=$(tr -d ' \n' <<<"$calls")
has "requires the server to have answered" 'reachable' "$flat"
silent=$(grep -o 'OpenMessageserversilent.*' <<<"$(tr -d ' \n' <<<"$calls")")
has "alerts on that check" 'check-123' "$silent"
has "goes to the channel" 'notificationChannels/9' "$silent"
hasnt "doesn't print the key" "abc123" "$out"
: > "$LOG"
out=$("$C/vm/set-email-alerts.sh" --project p-1 --email a@b.co --status-url 'https://evil/status?key=a;b' 2>&1); rc=$?
[ $rc = 2 ] && ok "refuses a bad link" || no "refuses a bad link (rc $rc)" "$out"
done_sandbox

echo "om-update.sh: holding new releases"
ago() { python3 -I -c "import datetime,sys;print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(days=float(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$1"; }
update_run() { # $1 = releases JSON, $2 = wait-days metadata; prints what it did
  sandbox
  cat > "$B/curl" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *om-repo*) echo o/r ;;
  *om-release*) echo latest ;;
  *om-auto-update*) echo yes ;;
  *om-update-wait-days*) [ -z "$2" ] || echo "$2" ;;
  *api.github.com*) cat <<'J'
$1
J
  ;;
esac
EOF
  printf '#!/bin/sh\nexit 3\n' > "$B/systemctl"
  printf '#!/bin/sh\necho "installed $OM_TAG" >> "$STUB_LOG"\n' > "$B/install-release"
  chmod +x "$B"/*
  echo 'x@v1-vm5' > "$T/stamp"; echo binary > "$T/binary"
  OM_STAMP=$T/stamp OM_SKIP=$T/skip OM_PREV_DIR=$T/prev OM_BIN=$T/binary OM_INSTALL=$B/install-release sh "$SRC/vm/om-update.sh" 2>&1
  cat "$LOG"
  done_sandbox
}
rel() { printf '{"tag_name":"%s","name":"%s","draft":false,"prerelease":false,"published_at":"%s"}' "$1" "$2" "$(ago "$3")"; }
out=$(update_run "[$(rel v1-vm6 'x' 1),$(rel v1-vm5 'x' 30)]" "")
has "a day-old release waits" "up to date (v1-vm5)" "$out"
hasnt "and isn't installed" "installed" "$out"
out=$(update_run "[$(rel v1-vm6 'x' 4),$(rel v1-vm5 'x' 30)]" "")
has "a four-day-old release installs" "installed v1-vm6" "$out"
out=$(update_run "[$(rel v1-vm7 'x' 1),$(rel v1-vm6 'x' 4),$(rel v1-vm5 'x' 30)]" "")
has "skips to the newest one that has waited" "installed v1-vm6" "$out"
out=$(update_run "[$(rel v1-vm6 'x (urgent)' 0),$(rel v1-vm5 'x' 30)]" "")
has "an urgent one doesn't wait" "installed v1-vm6" "$out"
out=$(update_run "[$(rel v1-vm6 'x' 0),$(rel v1-vm5 'x' 30)]" "0")
has "the operator's server takes it at once" "installed v1-vm6" "$out"
out=$(update_run "[$(rel v1-vm6 'x' 1),$(rel v1-vm4 'x' 30)]" "")
hasnt "never goes backwards" "installed" "$out"
out=$(update_run "not json" "")
has "bad answer from GitHub changes nothing" "will retry tomorrow" "$out"

echo "deploy.sh --from-browser: start to finish"
sandbox; stub_scripts; cp "$SRC/handback.sh" "$C/handback.sh"
args=(--client-owned --from-browser --user mike --email mike@example.com --project openmessage-mike-ab12 --label "Mike H" --timezone America/New_York --alert-email h@x.co)
out=$("$C/deploy.sh" "${args[@]}" <<<$'\n\n\n\n' 2>&1); rc=$?
calls=$(cat "$LOG")
[ $rc = 0 ] && ok "finishes" || no "finishes (rc $rc)" "$out"
has "tells the client to open the Reconnect page" "https://om-mike.x.workers.dev/reconnect" "$out"
hasnt "doesn't open a local Chrome" "vm/reconnect.sh" "$calls"
has "starts OpenMessage so the page can see it" "sudo systemctl start openmessage" "$calls"
has "connector gets the project" "--project openmessage-mike-ab12" "$(grep setup-connector <<<"$calls")"
has "connector doesn't re-ask the account" "--account-confirmed" "$(grep setup-connector <<<"$calls")"
has "connector has Reconnect on" "--reconnect" "$(grep setup-connector <<<"$calls")"
has "mails both people" "--email h@x.co --email mike@example.com" "$calls"
has "emails the links" "om-notify" "$calls"
has "turns on backups" "vm/set-backups.sh --name om-mike" "$calls"
has "silent-server alert uses the status link" "--status-url https://om-mike.x.workers.dev/status?key=abc123" "$(grep set-email-alerts <<<"$calls")"
has "also shows them on screen" "Status link for your helper: https://om-mike.x.workers.dev/status?key=abc123" "$out"
has "links include the status link" "key=abc123" "$(grep om-notify <<<"$calls")"
has "links include the spam page" "reconnect/spam" "$(grep om-notify <<<"$calls")"
has "report says no other computer had the sign-ins" "no other computer ever had" "$out"
hasnt "leaves Cloud Shell's Google sign-in alone" "auth revoke" "$calls"
has "signs Wrangler out" "wrangler logout" "$calls"
has "says all done" "All done." "$out"
done_sandbox

echo "deploy.sh --from-browser: carries on after a stop"
sandbox; stub_scripts; cp "$SRC/handback.sh" "$C/handback.sh"
args=(--client-owned --from-browser --user mike --email mike@example.com --project openmessage-mike-ab12 --alert-email h@x.co)
VM_CONNECTED=false "$C/deploy.sh" "${args[@]}" <<<$'\n\n' >/dev/null 2>&1
: > "$LOG"
out=$("$C/deploy.sh" "${args[@]}" <<<$'\n\n\n' 2>&1); rc=$?
[ $rc = 0 ] && ok "finishes the second time" || no "finishes the second time (rc $rc)" "$out"
hasnt "skips finished steps" "vm/create-vm.sh" "$(cat "$LOG")"
done_sandbox

echo "setup.sh: run again after it finished"
sandbox; stub_deploy
"$C/setup.sh" <<<"$ANSWERS" >/dev/null 2>&1
echo mikehurley > "$H/.config/openmessage/handed-back"
: > "$LOG"
out=$("$C/setup.sh" </dev/null 2>&1); rc=$?
[ $rc = 0 ] && ok "exits cleanly" || no "exits cleanly (rc $rc)" "$out"
has "says it's finished" "already finished" "$out"
hasnt "changes nothing" "deploy " "$(cat "$LOG")"
done_sandbox

echo "deploy.sh --from-browser: phone never tapped"
sandbox; stub_scripts; cp "$SRC/handback.sh" "$C/handback.sh"
out=$(VM_CONNECTED=false "$C/deploy.sh" --client-owned --from-browser --user mike --email mike@example.com --project openmessage-mike-ab12 --alert-email h@x.co <<<$'\n\n' 2>&1); rc=$?
[ $rc = 1 ] && ok "stops rather than carrying on" || no "stops rather than carrying on (rc $rc)" "$out"
has "says how to carry on" "Paste the same line again" "$out"
hasnt "no hand-back" "wrangler logout" "$(cat "$LOG")"
done_sandbox

echo "deploy.sh --from-browser: email fails"
sandbox; stub_scripts; cp "$SRC/handback.sh" "$C/handback.sh"
cat >> "$B/gcloud" <<'EOF'
case "$*" in *"om-notify"*) exit 1 ;; esac
EOF
out=$("$C/deploy.sh" --client-owned --from-browser --user mike --email mike@example.com --project openmessage-mike-ab12 --alert-email mike@example.com <<<$'\n\n\n' 2>&1)
has "shows the links" "Copy these and keep them" "$out"
hasnt "doesn't claim an email went out" "should also reach you" "$out"
has "same address only mailed once" "--project openmessage-mike-ab12 --email mike@example.com --status-url" "$(grep set-email-alerts "$LOG")"
hasnt "not twice" "--email mike@example.com --email" "$(grep set-email-alerts "$LOG")"
done_sandbox

echo "deploy.sh: --from-browser needs --client-owned"
sandbox; stub_scripts
out=$("$C/deploy.sh" --from-browser --user mike --email m@x.co --project openmessage-mike </dev/null 2>&1); rc=$?
[ $rc = 2 ] && ok "refused" || no "refused (rc $rc)" "$out"
done_sandbox

echo "handback.sh: operator mode still asks and revokes"
sandbox
cat >> "$B/gcloud" <<'EOF'
case "$*" in *"auth list"*) echo mike@example.com ;; esac
EOF
out=$("$C/handback.sh" --user mike --email mike@example.com --project p-1 <<<"y" 2>&1)
has "revokes the sign-in on this computer" "auth revoke mike@example.com" "$(cat "$LOG")"
has "writes the report" "OpenMessage hand-back for mike@example.com" "$out"
: > "$LOG"
"$C/handback.sh" --user mike --email mike@example.com --project p-1 <<<"n" >/dev/null 2>&1
hasnt "asks before signing Wrangler out" "wrangler logout" "$(cat "$LOG")"
done_sandbox

echo "doctor.sh --add-client"
sandbox
out=$("$C/doctor.sh" --add-client mike --status-url 'https://om-mike.x.workers.dev/status?key=abc123' 2>&1)
has "adds the client" "Added mike" "$out"
has "fleet line" "$(printf 'mike\tom-mike\tus-east1-b\tunknown\thttps://om-mike.x.workers.dev/mcp')" "$(cat "$H/.config/openmessage/fleet.tsv")"
has "marked handed back" "mike" "$(cat "$H/.config/openmessage/handed-back")"
[ "$(stat -f %Lp "$H/.config/openmessage/status-mike.url" 2>/dev/null || stat -c %a "$H/.config/openmessage/status-mike.url")" = 600 ] && ok "link file is private" || no "link file is private"
"$C/doctor.sh" --add-client mike --status-url 'https://om-mike.x.workers.dev/status?key=abc123' >/dev/null 2>&1
[ "$(grep -c '^mike' "$H/.config/openmessage/fleet.tsv")" = 1 ] && ok "adding twice leaves one line" || no "adding twice leaves one line"
out=$("$C/doctor.sh" --add-client mike --status-url 'http://evil/status?key=a;rm' 2>&1); rc=$?
[ $rc = 2 ] && ok "refuses a bad link" || no "refuses a bad link" "$out"
done_sandbox

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
