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
| `capture-google-cookies.mjs` | Runs on your own computer (Node 22+, Chrome). Opens a throwaway Incognito Chrome, you sign in, and it writes the Google cookies pairing needs to a mode-600 JSON file. Prints names only. |

## Steps

Steps 1–3 run in a browser: Google Cloud console, Cloud Shell, and the
Cloudflare dashboard. Steps 4–5 need a computer with Chrome, Node 22+ and the
gcloud CLI (or Cloud Shell's upload, below), and the phone in hand. Setting
this up for someone else: start at [`../NEW-USER.md`](../NEW-USER.md).

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

### 4. Cookies (your computer, throwaway Incognito Chrome)

The VM needs a Google login that nothing else uses. Two things that don't
work, both found on 2026-11-03:

- **Cookies from a Chrome profile you keep using.** `pair --google-chrome`
  from the everyday profile paired fine, then Google returned 401 four
  minutes later and OpenMessage parked (`google_auth_expired`): Chrome kept
  refreshing that login and the copy on the VM fell behind.
- **DevTools' Copy as cURL.** Messages Web no longer makes a `config`
  request, and the Network panel shows "Provisional headers are shown" with no
  Cookie header on messages.google.com, so the copy carries no cookies.

What works: [`capture-google-cookies.mjs`](capture-google-cookies.mjs).

```bash
node cloud/vm/capture-google-cookies.mjs google-cookies.json
```

1. A separate Chrome window opens, in Incognito with a temporary profile.
   Sign in with the Google account linked to the phone's Google Messages, and
   let it continue to `messages.google.com/web`.
2. Press Enter in the terminal. The script writes the cookies Chrome would send
   to Messages Web (it checks that `SID`, `SAPISID`, `__Secure-1PSID` and
   `__Secure-1PSIDTS` are there), closes Chrome **without signing out** and
   deletes the temporary profile.
3. Don't sign that login out anywhere afterwards. Signing out ends the
   session OpenMessage will hold.

`google-cookies.json` is a full Google login: move it straight to the VM
(step 5) and delete every copy. `.gitignore` covers `google-cookies*.json`.

If Chrome's Application panel lists anything under "Device bound sessions" for
that window, the cookies are bound to the computer and won't survive on the
VM; stop and rethink (phase 2, headless Chromium on the VM). On 2026-11-03
the Incognito window listed none.

### 5. Cutover (at the phone)

1. Stop every other copy of OpenMessage that holds this phone's pairing (a
   second copy gets the first logged out). For the original Mac: if the
   autorun agents are installed (`scripts/mac-autorun/`), run
   `scripts/mac-autorun/uninstall.sh`; otherwise they restart `serve` within
   seconds. Also park the app's launchd watchdog and quit the app (runbook,
   "Parking the launchd watchdog"). Check with
   `lsof -nP -iTCP:7007 -sTCP:LISTEN` that nothing listens on port 7007.
2. Copy the cookies to the VM and delete the local file. From the computer
   that captured them (gcloud signed in to the VM's project):
   ```bash
   gcloud compute scp --zone us-east1-b google-cookies.json om-test:/tmp/google-cookies.json && rm google-cookies.json
   ```
   Without gcloud there: upload the file in Cloud Shell (⋮, Upload), run the
   same `scp` from Cloud Shell, and delete it on both machines.
3. In the VM (`gcloud compute ssh --zone us-east1-b om-test`). `pair` refuses
   while the service holds the session, so stop it first (a no-op on the first
   pairing):
   ```bash
   sudo systemctl stop openmessage
   sudo chown openmessage:openmessage /tmp/google-cookies.json && sudo chmod 600 /tmp/google-cookies.json
   sudo -u openmessage OPENMESSAGES_DATA_DIR=/var/lib/openmessage openmessage pair --google-file /tmp/google-cookies.json
   ```
   It prints an emoji. Tap the matching one in the phone's "pair another
   device" prompt within 5 minutes. If you're driving this through a script,
   keep its output unbuffered (`stdbuf -oL`, `grep --line-buffered`): the
   emoji line can otherwise sit in a pipe buffer while the 5 minutes run out.
   A prompt left over from a cancelled attempt won't complete; dismiss it.
   Then:
   ```bash
   sudo rm /tmp/google-cookies.json
   sudo systemctl start openmessage
   sleep 20; curl -s 127.0.0.1:7007/api/status | jq .google.connected
   ```
   Recheck after 10 minutes: a borrowed login shows up as a 401 and a park
   within minutes (`jq .google.supervisor` shows `blocked`).
4. Point the connector at the VM. The dashboard can't change an existing VPC
   service's tunnel (its Edit only changes the host); the CLI can, keeping the
   service id, so the Worker needs no redeploy:
   ```bash
   cd cloud/worker && npx wrangler vpc service get <service-id>    # note port and cert mode
   npx wrangler tunnel list                                          # om-vm's id
   npx wrangler vpc service update <service-id> --name <name> --type http \
     --tunnel-id <om-vm-tunnel-id> --ipv4 127.0.0.1 --http-port 7007 --cert-verification-mode verify_full
   ```
   Going back is the same command with the old tunnel id. A new user with no
   service yet creates one on `om-vm` instead (`../NEW-USER.md`).
5. claude.ai: ask for your last three texts through the connector. This
   answers from the VM's store even if Google has since parked, so check step
   3's status too.
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
