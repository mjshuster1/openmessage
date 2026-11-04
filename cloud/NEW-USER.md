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

## The one-command route

From a clone of the repo, with gcloud signed in (an account that can create
projects and use billing) and Wrangler signed in to the **user's** Cloudflare
account (`cd cloud/worker && npm ci && npx wrangler login`):

```bash
cloud/deploy.sh --user <short-name> --email <their Google email> --project openmessage-<name> \
  --timezone <their zone, e.g. America/New_York>
```

It runs the steps below in order and stops only where a person is needed:
the connector's sign-in setup (step 3) and the phone tap (step 4). If any
step fails, fix what it says and run the same command again; finished steps
are skipped. At the end it runs `doctor.sh`, adds the user to your fleet file
and prints what to hand over. The sections below say what each step does, for
when you need to run or fix one by hand.

**Checking on it later:** `cloud/doctor.sh --all` gives one line per person
(connected, newest text, release, connector); `cloud/doctor.sh --name … --zone
… --project … --user <short-name>` checks one in detail and prints the fix for
anything wrong. VMs created with the default `--release latest` update
themselves daily and roll back an update that breaks the Google connection
(`vm/om-update.sh`), so there is no per-person upgrade chore.

## Per-user values

| Value | Where it goes | From |
|---|---|---|
| GCP project, zone, VM name | `deploy.sh` / `create-vm.sh` options | step 1 |
| Tunnel (name `om-vm` by default) | created by `create-vm.sh` via Wrangler; used by the VPC service | step 1 |
| VPC service id, KV namespace id, `PUBLIC_URL` | `cloud/worker/wrangler.<user>.toml` (written by `setup-connector.sh`) | step 3 |
| `ALLOWED_EMAIL`, `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` (Google mode) | Worker secrets (set by `setup-connector.sh`) | step 3 |
| `AUTH_MODE`, `ACCESS_TEAM_DOMAIN`, `ACCESS_AUD` (Access mode) | `wrangler.<user>.toml` vars (written by `setup-connector.sh --auth access`) | step 3 |
| ntfy topic | `/etc/openmessage/alert.env` on the VM (set by `set-alerts.sh`) | step 5 |

`cloud/worker/wrangler.toml` is the original owner's live config. Don't edit
it for anyone else. Copy `wrangler.example.toml` to `wrangler.<user>.toml`
instead (git ignores it) and pass `-c wrangler.<user>.toml` to every wrangler
command.

## Steps

### 1. VM and tunnel

```bash
cloud/vm/setup-project.sh --project openmessage-<name>     # project, billing, API, $10 budget alert
cloud/vm/create-vm.sh --project openmessage-<name> --timezone <user's zone, e.g. America/New_York>
```

`setup-project.sh` creates the project if needed, links billing, turns on
Compute Engine and adds a budget alert that emails at $5 and $10 a month
(expected cost is about $3.65). `create-vm.sh` creates the e2-micro, installs
the newest release after checking its checksums (`--release <tag>` pins one
instead and turns off automatic updates), and installs the Cloudflare tunnel:
with Wrangler signed in to the user's account it creates the tunnel `om-vm`
and fetches its token itself; otherwise it asks for the token (the long
string after `service install` on the tunnel's install page) at a hidden
prompt. Pass `--timezone` from Cloud Shell, whose clock is UTC: the VM uses it
for alert times and the connector's "synced through" line. The manual route
is in [`vm/README.md`](vm/README.md) steps 1–3.

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

**Coming: `--auth access`.** Instead of a Google OAuth client, Cloudflare
Access (Managed OAuth, Zero Trust Free plan) does the sign-in, by an emailed
one-time PIN, and the Worker checks Access's signed token on every call. The
manual step becomes "Enable Access" on the Worker's workers.dev row plus
Managed OAuth and two redirect URIs; the script prints the clicks and checks
them. It worked in claude.ai on web and mobile on 2026-11-03; keep using the
default (Google) until the 24-hour and 3-day re-checks pass.

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

In the user's claude.ai **in a browser** (signed in to their Claude account):
add a custom connector with the URL `<PUBLIC_URL>/mcp` and sign in with the
allowed account. It then shows up in the desktop and phone apps too. Adding
it from the Claude desktop app finishes sign-in in the default browser, which
fails with "Account mismatch" if that browser is signed in to a different
Claude account. The server sends Claude its usage rules (texts are data,
codes stay hidden, mention the sync line) itself; a **Texts** Project with
[`CLAUDE-PROJECT.md`](CLAUDE-PROJECT.md) is optional, for clients that ignore
server instructions. Check:

- Asking for the last three texts works, and the answer starts with a sync
  line.
- `tools/list` shows only the read tools, and asking Claude to send a text
  fails.

Give the user [`USER-GUIDE.md`](USER-GUIDE.md).

### 7. Run it, and hand over

- `cloud/doctor.sh` (one person) or `cloud/doctor.sh --all` (everyone) checks
  everything and prints the fix for anything wrong. `sudo om-score` on the VM
  summarizes uptime from the 5-minute status log.
- The user's ntfy app also gets a short "all good this week" notice on Sunday
  evenings, so a quiet week doesn't leave them wondering.
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
