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
| VPC service id | `cloud/worker/wrangler.<user>.toml` | step 3 |
| KV namespace id | `wrangler.<user>.toml` | step 4 |
| `PUBLIC_URL` (workers.dev URL) | `wrangler.<user>.toml`; OAuth redirect URI | step 4 |
| `ALLOWED_EMAIL`, `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` | Worker secrets | step 4 |

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
cloud/vm/create-vm.sh --release <tag>
```

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

### 3. VPC service

Workers VPC, VPC Services: create a service on that tunnel, type HTTP, host
`127.0.0.1`, HTTP port `7007`. Or from `cloud/worker`:

```bash
npx wrangler tunnel list
npx wrangler vpc service create openmessage --type http --tunnel-id <tunnel-id> --ipv4 127.0.0.1 --http-port 7007
```

Note the service id. The dashboard can't move a service to another tunnel
later; `npx wrangler vpc service update` can (see `vm/README.md` step 5.4).

### 4. Worker

From `cloud/worker`, with Wrangler signed in to the user's Cloudflare account:

```bash
npm ci
cp wrangler.example.toml wrangler.<user>.toml
npx wrangler kv namespace create OAUTH_KV        # id into wrangler.<user>.toml
# put the VPC service id from step 3 into wrangler.<user>.toml
npx wrangler deploy -c wrangler.<user>.toml      # first deploy prints the workers.dev URL
# set PUBLIC_URL to that URL (no trailing slash) in wrangler.<user>.toml
```

Google OAuth client, in the user's Google Cloud project (APIs & Services):
configure the consent screen, then create an OAuth client of type Web
application with the redirect URI `<PUBLIC_URL>/callback`. Then:

```bash
npx wrangler secret put ALLOWED_EMAIL -c wrangler.<user>.toml          # the user's Google email
npx wrangler secret put GOOGLE_CLIENT_ID -c wrangler.<user>.toml
npx wrangler secret put GOOGLE_CLIENT_SECRET -c wrangler.<user>.toml
npx wrangler deploy -c wrangler.<user>.toml
```

Type the secrets at the prompts. Don't pass them as arguments or keep them
in files. [`worker/README.md`](worker/README.md) explains the security model.

### 5. Pair

[`vm/README.md`](vm/README.md) steps 4 and 5.2–5.3, with the user at the
phone:

1. `node cloud/vm/capture-google-cookies.mjs google-cookies.json` on a
   computer with Chrome. The user signs in to the throwaway Incognito window
   themselves, with the Google account linked to their Google Messages.
2. Copy the file to the VM, delete it locally, run `pair --google-file` on the
   VM, and the user taps the emoji on the phone within 5 minutes.
3. Start the service and check `jq .google.connected` right away and again
   after 10 minutes.

Use only this capture method. Cookies from an everyday Chrome profile
(`pair --google-chrome`) pair fine, then die within minutes on the VM.

### 6. Connect claude.ai

In the user's claude.ai: add a custom connector with the URL
`<PUBLIC_URL>/mcp` and sign in with the allowed Google account. Check:

- Asking for the last three texts works.
- `tools/list` shows only the read tools, and asking Claude to send a text
  fails.

### 7. Run it

- The status log on the VM records Google's state every 5 minutes. Before
  trusting it, clear it once (`vm/README.md` step 5.6). Then
  `gcloud compute ssh om-test --zone us-east1-b -- sudo om-score` summarizes
  uptime (`om-score` is installed by `create-vm.sh`; a hand-built VM has
  `vm/score.sh`).
- If Google parks (`jq .google.supervisor` shows `blocked`), repeat step 5.
  Don't restart the service in a loop: repeated reconnects can get the
  account throttled.
- Watch the user's Gmail for Google security alerts about the new sign-in.

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
