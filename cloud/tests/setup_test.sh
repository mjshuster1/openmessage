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
  *"config get-value account"*) echo Mike@Example.com ;;
  *"billing accounts list"*) for ((i = 0; i < BILLING_ACCOUNTS; i++)); do echo "billingAccounts/$i"; done ;;
  *"compute ssh"*"api/status"*) echo "$VM_CONNECTED" ;;
  *"compute ssh"*) [ "${SSH_FAILS:-no}" = no ] || exit 1 ;;
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
  for s in vm/setup-project.sh vm/create-vm.sh vm/set-email-alerts.sh vm/set-alerts.sh vm/reconnect.sh vm/set-spam-rules.sh; do
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
has "shows the links instead" "Copy these and keep them" "$out"
has "same address only mailed once" "--project openmessage-mike-ab12 --email mike@example.com" "$(grep set-email-alerts "$LOG")"
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
