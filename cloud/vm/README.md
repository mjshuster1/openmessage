# OpenMessage on a cloud VM (phase 1 test)

Runs OpenMessage on a Google Cloud e2-micro instead of the Mac, behind the same
claude.ai connector Worker (`cloud/worker/`). Phase 1 answers one question:
does Google-account pairing stay connected for 72 hours with no Mac and no
browser?

**Why no browser.** libgm rotates Google's cookies itself and saves them to
`session.json` about every 5 minutes (`internal/client/events.go`). A browser
is only the repair path when Google rejects the session: on macOS that heals
from Chrome; on Linux it parks with `google_cookie_refresh_unavailable`
(`internal/googlecookies/secret_other.go`). The expiries logged on the Mac all
happened while desktop Chrome was using the same login, so this test gives libgm
a login session that nothing else uses.

**Pass:** 72 hours, under 15 minutes disconnected, no park. `score.sh` reads it
from the status log.
**Fail:** a park, or a Google security action on the account. Then either
phase 2 (headless Chromium on the VM) or back to the Mac with
`scripts/mac-autorun/`.

Only one copy may hold the credentials at a time: a second copy gets the first
logged out (`docs/agent-runbook.md`, "MCP serving"). The Mac app stays off for
the whole test.

## Files

| File | What it does |
|---|---|
| `setup-vm.sh` | One-time root setup: curl and jq, 1 GB swap, `openmessage` system user, data dir `/var/lib/openmessage` (mode 700), binary, units. Enables but does not start OpenMessage. |
| `openmessage.service` | `serve --web --mcp-sse --mcp-read-only` on 127.0.0.1:7007 (`--web` serves `/api/status` for the status log), sandboxed, restarts on failure. |
| `om-status-log.sh`, `.service`, `.timer` | Every 5 minutes, one line of `/api/status` (connected, state, block reason) to `/var/lib/openmessage/test-status.jsonl`. |
| `score.sh` | Hours covered, minutes disconnected, park samples, and each down sample. |

## Steps

Everything runs in a browser: Google Cloud console, Cloud Shell, and the
Cloudflare dashboard. The Mac is needed only to quit the app and for the
Incognito sign-in.

### 1. VM (Google Cloud console)

1. Create project `openmessage-test` under mjshuster1@gmail.com and turn on
   billing (needed even for the free tier). Read cloud.google.com/free first;
   the free-tier terms below come from third-party guides.
2. Compute Engine, Create instance: name `om-test`, region `us-east1`, zone
   `us-east1-b`, machine `e2-micro`, Debian 12, 30 GB **standard** persistent
   disk. Leave the HTTP and HTTPS firewall boxes off. Whether the external IPv4
   address is billed is not confirmed; it is needed for outbound traffic.

### 2. Build and install (Cloud Shell)

```bash
git clone https://github.com/mjshuster1/openmessage && cd openmessage
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -o cloud/vm/openmessage .
gcloud compute scp --zone us-east1-b --recurse cloud/vm om-test:~/vm
gcloud compute ssh --zone us-east1-b om-test -- sudo sh vm/setup-vm.sh
```

### 3. Tunnel (Cloudflare dashboard)

Workers VPC, Tunnels: create tunnel `om-vm`, no public hostname. Copy its
Debian install command and run it in the VM
(`gcloud compute ssh --zone us-east1-b om-test`). Leave the VPC service alone
for now.

### 4. Cookies (Mac, Chrome Incognito)

1. Open an Incognito window and sign in to mjshuster1@gmail.com.
2. Open `messages.google.com/web`. In DevTools, Network tab, right-click the
   `config` request and choose Copy, Copy as cURL.
3. Paste it into a new file `cookies.txt` in Cloud Shell's editor.
4. Close the Incognito window **without signing out**. Signing out ends the
   session OpenMessage will hold. That closing the window leaves it valid is an
   inference; the 72 hours test it.

### 5. Cutover (at the Pixel)

1. Mac: stop everything that runs OpenMessage. If the autorun agents are
   installed (`scripts/mac-autorun/`), run `scripts/mac-autorun/uninstall.sh`;
   otherwise they restart `serve` within seconds. Also park the app's launchd
   watchdog and quit the app (runbook, "Parking the launchd watchdog"). Check
   with `lsof -nP -iTCP:7007 -sTCP:LISTEN` that nothing listens on port 7007.
2. Cloud Shell:
   ```bash
   gcloud compute scp --zone us-east1-b cookies.txt om-test:/tmp/cookies.txt && rm cookies.txt
   gcloud compute ssh --zone us-east1-b om-test
   ```
3. In the VM:
   ```bash
   sudo chown openmessage /tmp/cookies.txt
   sudo -u openmessage OPENMESSAGES_DATA_DIR=/var/lib/openmessage openmessage pair --google-file /tmp/cookies.txt
   ```
   Tap the matching emoji on the Pixel within 5 minutes. Then:
   ```bash
   sudo rm /tmp/cookies.txt
   sudo systemctl start openmessage
   curl -s 127.0.0.1:7007/api/status | jq .google.connected
   ```
4. Cloudflare, Workers VPC, VPC Services: point the existing service at tunnel
   `om-vm`, host `127.0.0.1`, port `7007`. If a service can't change tunnels,
   create a new one, put its id in `cloud/worker/wrangler.toml` and redeploy
   the Worker.
5. claude.ai: ask for your last three texts through the connector.
6. Start the clock: clear the samples logged before pairing, which would
   otherwise count as downtime:
   `gcloud compute ssh --zone us-east1-b om-test -- sudo truncate -s0 /var/lib/openmessage/test-status.jsonl`

### 6. Watch

At about 24, 48 and 72 hours:

```bash
gcloud compute ssh --zone us-east1-b om-test -- sudo sh vm/score.sh
```

Also watch mjshuster1@gmail.com for a Google security alert.

### 7. End

- **Pass:** leave it running. Next is the thread allowlist and drafts (ledger
  A59 in `consultant-workspace`).
- **Fail:** `sudo systemctl stop openmessage` on the VM, then on the Mac run
  `scripts/mac-autorun/install.sh` again (or start the app). If the Mac's
  session no longer works, re-pair it with `openmessage pair --google-chrome`
  (emoji again).
- **Tear down** when decided: delete the VM and the `om-vm` tunnel.
