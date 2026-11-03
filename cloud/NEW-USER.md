# Setting up OpenMessage for a new user (cloud VM + claude.ai connector)

The end state: OpenMessage runs around the clock on the user's own Google
Cloud e2-micro, paired to their Android phone's Google Messages, and their
claude.ai account reads their texts through their own Cloudflare Worker.
Read-only: no tool can send. No computer of theirs needs to stay on.

Everything is **per person**: their VM, their Cloudflare tunnel, VPC service
and Worker, their Google OAuth client, their pairing. Never point a second
person's connector at someone else's VM. The VM holds a full copy of the
user's message history and a live Google login.

This page puts the steps in order and lists what changes per user. The
detailed commands are in [`vm/README.md`](vm/README.md) (VM, pairing) and
[`worker/README.md`](worker/README.md) (Worker); the steps below point to them.

## Before you start

**The user needs:**
- An **Android phone with Google Messages** as the SMS/RCS app. The Google
  account pairing uses is the one linked in Google Messages (Settings, Device
  pairing). iPhone won't work.
- A **Google Cloud** project with billing turned on (needed even for the free
  tier). The e2-micro and its disk are free in us-east1, us-central1 and
  us-west1. The external IPv4 address costs about $3.65/month.
- A **Cloudflare** account (Workers VPC is free during its beta).
- A **claude.ai** account that can add custom connectors.
- About an hour at a computer with Chrome and Node 22+, with the phone in hand
  for the emoji tap.

**Who operates it.** Whoever has admin on the user's GCP project can read
their messages and their Google login on the VM. The cleanest setup: the
user owns every account, and a helper drives the steps over a call (screen
share), with the user signing in and tapping. If a helper does run it from
their own machine, the user should know and agree, and the helper's CLIs must
be signed in to the **user's** accounts for those steps:

- gcloud: `gcloud config configurations create <user>`, then
  `gcloud auth login <user's email>` and `gcloud config set project <project>`.
  Switch back with `gcloud config configurations activate default`.
- Wrangler: `npx wrangler whoami` must show the user's account before every
  change. Signing in again replaces the helper's login (see `--profile` in
  `npx wrangler --help` to keep both).
- Delete the user's cookie file and sign the CLIs out of their accounts when
  done.

## Per-user values

| Value | Where it goes | From |
|---|---|---|
| GCP project, zone, VM name | `create-vm.sh` options (defaults `om-test`, `us-east1-b`) | step 1 |
| Tunnel id | VPC service | step 1 |
| VPC service id, KV namespace id, `PUBLIC_URL` | `cloud/worker/wrangler.<user>.toml` (written by `setup-connector.sh`) | step 3 |
| `ALLOWED_EMAIL`, `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` | Worker secrets (set by `setup-connector.sh`) | step 3 |
| ntfy topic | `/etc/openmessage/alert.env` on the VM (set by `set-alerts.sh`) | step 5 |

`cloud/worker/wrangler.toml` is the original owner's live config. Don't edit
it for anyone else. Copy `wrangler.example.toml` to `wrangler.<user>.toml`
instead (git ignores it) and pass `-c wrangler.<user>.toml` to every wrangler
command.

## Steps

### 1. VM and tunnel

First create the tunnel in the user's Cloudflare account (Workers VPC,
Tunnels, no public hostname) and keep its install page open. Then, in the
user's Cloud Shell (it has gcloud, signed in as them):

```bash
git clone https://github.com/mjshuster1/openmessage && cd openmessage
gcloud config set project <their project>
cloud/vm/create-vm.sh --release <tag> --timezone <user's zone, e.g. America/New_York>
```

Cloud Shell's clock is UTC, so pass `--timezone`: the VM uses it for alert
times and the connector's "synced through" line.

`<tag>` is the newest release on the fork (`gh release list --repo
mjshuster1/openmessage`; publish one with `cloud/vm/release-vm.sh` if `main`
has moved on). The script creates the e2-micro, installs the release after
checking its checksums, then asks for the tunnel token: paste the long string
after `service install` from the tunnel's install command. Input is hidden and
the token goes straight to the VM. The dashboard should then show the tunnel
as Healthy. The manual route is in [`vm/README.md`](vm/README.md) steps 1–3.

### 2. Make sure no other copy holds the phone

If the phone is already paired to another OpenMessage (a Mac app, an earlier
VM), stop that copy for good. Two copies log each other out.

### 3. Connector Worker

From `cloud/worker`, with Wrangler signed in to the user's Cloudflare account
(`npx wrangler login`, then check `npx wrangler whoami`):

```bash
npm ci
./setup-connector.sh --user <short-name> --email <user's google email>
```

It finds the tunnel, creates the VPC service and the KV namespace, writes
`wrangler.<user>.toml`, deploys, learns the workers.dev URL and sets the
secrets. It stops once to walk you through the one manual step: a Google
OAuth client (consent screen, then a Web application client with the redirect
URI it prints). It asks for the client id and secret at hidden prompts. It's
safe to re-run; it reuses what exists. Cloudflare allows one VPC service per
`127.0.0.1:<port>` per account, which only matters if the account already has
one. [`worker/README.md`](worker/README.md) explains the security model.

### 4. Pair

With the user at a computer with Chrome, Node 22+ and gcloud, and the phone
in hand:

```bash
cloud/vm/reconnect.sh
```

It opens a throwaway Incognito Chrome. The user signs in there with the
Google account linked to their Google Messages and presses Enter. The script
moves the login to the VM (deleting the local copy), pairs, and shows the
emoji large: the user taps the same one on the phone within 5 minutes. Then
it starts OpenMessage and watches the connection for 10 minutes. The same
command reconnects later. Details and the manual route: `vm/README.md`
steps 4–5.

Don't capture cookies any other way. Cookies from an everyday Chrome profile
(`pair --google-chrome`) pair fine, then die within minutes on the VM. On
Windows, Chrome may bind cookies to the computer ("Device bound sessions" in
DevTools' Application panel); if pairing works but drops within minutes,
that's the likely cause.

### 5. Alerts

```bash
cloud/vm/set-alerts.sh
```

It turns on push notifications through ntfy and sends a test one. The user
installs the ntfy app and subscribes to the printed topic (keep it private).
They get "disconnected" after 10 minutes down, "needs reconnecting" at once
on a park, and "back online" on recovery. Status only, never message text.

### 6. Connect claude.ai

In the user's claude.ai: add a custom connector with the URL
`<PUBLIC_URL>/mcp` and sign in with the allowed Google account. Then create
the **Texts** Project with the instructions in
[`CLAUDE-PROJECT.md`](CLAUDE-PROJECT.md). Check:

- Asking for the last three texts works, and the answer starts with a sync
  line.
- `tools/list` shows only the read tools, and asking Claude to send a text
  fails.

Give the user [`USER-GUIDE.md`](USER-GUIDE.md).

### 7. Run it, and hand over

- `gcloud compute ssh om-test --zone us-east1-b -- sudo om-score` summarizes
  uptime from the 5-minute status log. Clear the log once after pairing
  (`vm/README.md` step 5.6) so setup time doesn't count.
- If Google parks, the user gets an alert; run `reconnect.sh` once. Don't
  loop it: repeated reconnects can get the account throttled.
- If you set this up from your own machine: remove your SSH key from the
  user's project (`gcloud compute project-info describe` shows `ssh-keys`;
  remove yours in the console under Compute Engine, Metadata, SSH keys), sign
  gcloud and Wrangler out of the user's accounts, and delete any cookie file.

## Things that cost time on 2026-11-03

- **`serve --mcp-sse` alone turns the web API off**, so `/api/status`
  returns 404 and the status log records every sample as down. The unit now
  passes `--web`.
- **Dashboard VPC service edit can't change the tunnel.** Use
  `wrangler vpc service update` (same id, no Worker redeploy).
- **DevTools won't give you the cookies**: no `config` request any more, and
  "Provisional headers are shown" hides the Cookie header. Use
  `capture-google-cookies.mjs`.
- **A borrowed login dies.** Cookies from a Chrome profile that stays in use
  got a 401 and a park four minutes after start. The throwaway Incognito
  login held.
- **Buffered output hides the emoji** when `pair` runs behind a pipe. Keep it
  line-buffered. A prompt from a cancelled attempt won't complete.
- **This repo's `wrangler.toml` holds the original owner's ids.** Use
  `wrangler.<user>.toml` for anyone else.
