# OpenMessage connector (Cloudflare Worker)

A small Worker that lets claude.ai's custom MCP connector read from an OpenMessage MCP server: first the Mac mini, since 2026-11-03 the Google Cloud VM in `../vm/`. Read-only. Deployed 2026-11-02 at `https://openmessage-connector.mjshuster1.workers.dev` (claude.ai connector URL: `/mcp`). Setting one up for another person: [`../NEW-USER.md`](../NEW-USER.md), with `wrangler.example.toml` as their config.

## Request path

```
claude.ai
  -> this Worker on workers.dev (OAuth 2.1, Google sign-in, MCP filter)
  -> Workers VPC Service binding (ORIGIN)
  -> Cloudflare Tunnel, cloudflared on the host (the VM; earlier the Mac), no public hostname
  -> OpenMessage, /mcp on 127.0.0.1:7007
```

The host has no public address. Only a Worker bound to the VPC Service can reach it. Workers VPC is in beta (free on all plans during the beta, per Cloudflare's docs as of Nov 2026).

## Security model

Incoming texts are untrusted. The goal is that a malicious text cannot get Claude to send a message, and that nobody but the owner can connect.

- **Two filter layers.** This Worker only passes `initialize`, `ping`, `tools/list`, `tools/call` and `notifications/*`, and only the tools listed in `readonly-tools.json`. It also strips every other tool from `tools/list` results. OpenMessage runs with `--mcp-read-only` as the second layer, so a bug in one does not open a write path. `readonly-tools.json` is the single source of truth; a Go test checks the server's list against it, and a Worker test checks this code against it.
- **Fail closed.** Unknown methods, unknown tools, odd JSON keys, and any batch containing a bad message are refused without being forwarded. The Worker forwards a message it rebuilt from the fields it checked, not the client's bytes, because the Go decoder on the other side matches JSON keys without regard to case.
- **Header allowlist.** Only `Content-Type`, `Accept`, `Mcp-Session-Id`, `MCP-Protocol-Version` and `Last-Event-ID` go upstream. The claude.ai bearer token, cookies, `Origin` and `Referer` never do. Upstream errors come back as a generic 502 with no upstream body.
- **No public origin.** The tunnel has no public hostname, so there is nothing on the internet to attack directly. Workers VPC always connects to the host and port set on the VPC Service, whatever URL the Worker passes.
- **One person.** Sign-in goes through Google and requires a verified email equal to `ALLOWED_EMAIL`. The Worker checks that email again on every `/mcp` call, so changing the variable cuts off tokens already issued. A consent page ("Allow ClientName") shows before the Google redirect, as the OAuth library requires, so a stranger's link cannot quietly connect their client to your account.
- **Access mode (`AUTH_MODE = "access"`).** Cloudflare Access with Managed OAuth sits in front of the workers.dev route and handles discovery, client registration, sign-in (one-time PIN) and tokens; the Worker serves only `/mcp` and none of its own OAuth endpoints, and needs no KV or Google client. It still verifies the `Cf-Access-Jwt-Assertion` JWT on every call (signature against the team's published keys, issuer, the app's AUD tag, expiry, email equal to `ALLOWED_EMAIL`), so Access switched off, a loose policy, or a preview URL Access doesn't cover fails closed. `src/access.ts`; `setup-connector.sh --auth access` sets it up.
- **Host header.** OpenMessage returns 403 unless the Host header is loopback. The Worker fetches `http://127.0.0.1:7007/mcp` through the binding; Workers VPC uses that URL's host only for the Host header. OpenMessage's own bearer check only logs, so it is not a layer.
- **Limits.** POST bodies over 1 MiB get a 413. The Worker answers only on `PUBLIC_URL`'s hostname.
- **Status link (`GET /status?key=…`).** Off unless the `STATUS_KEY` secret is set (24+ characters; `setup-connector.sh` makes one and saves the link in `~/.config/openmessage/status-<user>.url`). With the right key it fetches OpenMessage's `/api/status` and returns only: connected, needs pairing, the newest received text's time, quieter than usual, and when it checked. No message text, names, numbers or counts. A wrong key gets the same 404 as an unknown path, and nothing is fetched. It lets the operator watch a client-owned setup after handing the accounts back. In Access mode, Access guards the whole hostname, so `/status` needs a Bypass policy for that path.

## Local test

```
npm install
npm test          # vitest, offline
npx tsc --noEmit
```

The tests include a run through the real OAuth library with an in-memory KV: register a client, consent, mock Google, token, then a filtered `tools/list`.

## Deploy checklist

This is the original Mac setup, editing `wrangler.toml`. For anyone else, copy `wrangler.example.toml` to `wrangler.<name>.toml` (git ignores it) and add `-c wrangler.<name>.toml` to every wrangler command; `../NEW-USER.md` has the full order for a VM host.

1. Workers VPC dashboard, Tunnels tab: create a tunnel. Install `cloudflared` on the Mac with the commands the dashboard shows, including the service install with the token. No public hostname.
2. Workers VPC dashboard, VPC Services tab: create a service on that tunnel, host `127.0.0.1`, HTTP port `7007`. Put its service id in `wrangler.toml`.
3. Create a KV namespace named `OAUTH_KV`. Put its id in `wrangler.toml`.
4. Deploy the Worker once to learn its `workers.dev` hostname. Set `PUBLIC_URL` to it in `wrangler.toml`.
5. Google Cloud Console: create an OAuth client (Web application) with the redirect URI `<PUBLIC_URL>/callback`. Keep the client id and secret.
6. Set the secrets: `ALLOWED_EMAIL`, `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`.
7. On the Mac, run `scripts/mac-autorun/install.sh`, which keeps `./openmessage serve --web --mcp-sse --mcp-read-only` running (or start that command by hand). Plain `serve` turns on only the web UI; without `--mcp-sse` there is no `/mcp` and claude.ai reports "no MCP server found".
8. Deploy again.
9. In claude.ai, add a custom connector with the URL `<PUBLIC_URL>/mcp`, then sign in with the allowed Google account.
10. Check: `tools/list` shows only the read tools, and asking Claude to send a message fails.

## Files

- `src/index.ts`: builds the OAuth provider, checks the hostname and email, routes `/mcp`.
- `src/auth.ts`: `/authorize` (consent, Google redirect) and `/callback`.
- `src/access.ts`: Access mode's JWT check.
- `src/status.ts`: the status-only page.
- `src/proxy.ts`, `src/sse.ts`: the MCP filter and the event-stream rewrite.
- `src/allowlist.ts`: reads `readonly-tools.json`.
