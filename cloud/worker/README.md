# OpenMessage connector (Cloudflare Worker)

A small Worker that lets claude.ai's custom MCP connector read from the OpenMessage MCP server on the Mac mini. Read-only. Deployed 2026-11-02 at `https://openmessage-connector.mjshuster1.workers.dev` (claude.ai connector URL: `/mcp`).

## Request path

```
claude.ai
  -> this Worker on workers.dev (OAuth 2.1, Google sign-in, MCP filter)
  -> Workers VPC Service binding (ORIGIN)
  -> Cloudflare Tunnel, cloudflared on the Mac (no public hostname)
  -> OpenMessage, /mcp on 127.0.0.1:7007
```

The Mac has no public address. Only a Worker bound to the VPC Service can reach it. Workers VPC is in beta (free on all plans during the beta, per Cloudflare's docs as of Nov 2026).

## Security model

Incoming texts are untrusted. The goal is that a malicious text cannot get Claude to send a message, and that nobody but the owner can connect.

- **Two filter layers.** This Worker only passes `initialize`, `ping`, `tools/list`, `tools/call` and `notifications/*`, and only the tools listed in `readonly-tools.json`. It also strips every other tool from `tools/list` results. OpenMessage runs with `--mcp-read-only` as the second layer, so a bug in one does not open a write path. `readonly-tools.json` is the single source of truth; a Go test checks the server's list against it, and a Worker test checks this code against it.
- **Fail closed.** Unknown methods, unknown tools, odd JSON keys, and any batch containing a bad message are refused without being forwarded. The Worker forwards a message it rebuilt from the fields it checked, not the client's bytes, because the Go decoder on the other side matches JSON keys without regard to case.
- **Header allowlist.** Only `Content-Type`, `Accept`, `Mcp-Session-Id`, `MCP-Protocol-Version` and `Last-Event-ID` go upstream. The claude.ai bearer token, cookies, `Origin` and `Referer` never do. Upstream errors come back as a generic 502 with no upstream body.
- **No public origin.** The tunnel has no public hostname, so there is nothing on the internet to attack directly. Workers VPC always connects to the host and port set on the VPC Service, whatever URL the Worker passes.
- **One person.** Sign-in goes through Google and requires a verified email equal to `ALLOWED_EMAIL`. The Worker checks that email again on every `/mcp` call, so changing the variable cuts off tokens already issued. A consent page ("Allow ClientName") shows before the Google redirect, as the OAuth library requires, so a stranger's link cannot quietly connect their client to your account.
- **Host header.** OpenMessage returns 403 unless the Host header is loopback. The Worker fetches `http://127.0.0.1:7007/mcp` through the binding; Workers VPC uses that URL's host only for the Host header. OpenMessage's own bearer check only logs, so it is not a layer.
- **Limits.** POST bodies over 1 MiB get a 413. The Worker answers only on `PUBLIC_URL`'s hostname.

## Local test

```
npm install
npm test          # vitest, offline
npx tsc --noEmit
```

The tests include a run through the real OAuth library with an in-memory KV: register a client, consent, mock Google, token, then a filtered `tools/list`.

## Deploy checklist

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
- `src/proxy.ts`, `src/sse.ts`: the MCP filter and the event-stream rewrite.
- `src/allowlist.ts`: reads `readonly-tools.json`.
