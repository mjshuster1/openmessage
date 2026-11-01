# OpenMessage connector (Cloudflare Worker)

A small Worker that lets claude.ai's custom MCP connector read from the OpenMessage MCP server on the Mac mini. Read-only. Nothing here is deployed yet.

## Request path

```
claude.ai
  -> this Worker (OAuth 2.1, Google sign-in, MCP filter)
  -> Cloudflare Tunnel hostname, behind a Cloudflare Access service token
  -> cloudflared on the Mac (rewrites Host to 127.0.0.1:7007)
  -> OpenMessage, /mcp on 127.0.0.1:7007
```

## Security model

Incoming texts are untrusted. The goal is that a malicious text cannot get Claude to send a message, and that nobody but the owner can connect.

- **Two filter layers.** This Worker only passes `initialize`, `ping`, `tools/list`, `tools/call` and `notifications/*`, and only the tools listed in `readonly-tools.json`. It also strips every other tool from `tools/list` results. OpenMessage runs with `--mcp-read-only` as the second layer, so a bug in one does not open a write path. `readonly-tools.json` is the single source of truth; a Go test checks the server's list against it, and a Worker test checks this code against it.
- **Fail closed.** Unknown methods, unknown tools, odd JSON keys, and any batch containing a bad message are refused without being forwarded. The Worker forwards a message it rebuilt from the fields it checked, not the client's bytes, because the Go decoder on the other side matches JSON keys without regard to case.
- **Header allowlist.** Only `Content-Type`, `Accept`, `Mcp-Session-Id`, `MCP-Protocol-Version` and `Last-Event-ID` go upstream. The claude.ai bearer token, cookies, `Origin` and `Referer` never do. Upstream errors come back as a generic 502 with no upstream body.
- **Access service token.** The tunnel hostname is protected by Cloudflare Access. The Worker adds `CF-Access-Client-Id` and `CF-Access-Client-Secret` from secrets. Without them the hostname does not answer.
- **One person.** Sign-in goes through Google and requires a verified email equal to `ALLOWED_EMAIL`. The Worker checks that email again on every `/mcp` call, so changing the variable cuts off tokens already issued. A consent page ("Allow ClientName") shows before the Google redirect, as the OAuth library requires, so a stranger's link cannot quietly connect their client to your account.
- **Host rewrite.** OpenMessage returns 403 unless the Host header is loopback, so cloudflared sets `httpHostHeader: 127.0.0.1:7007`. OpenMessage's own bearer check only logs, so it is not a layer.
- **Limits.** POST bodies over 1 MiB get a 413. The Worker answers only on `PUBLIC_URL`'s hostname.

## Local test

```
npm install
npm test          # vitest, offline
npx tsc --noEmit
```

The tests include a run through the real OAuth library with an in-memory KV: register a client, consent, mock Google, token, then a filtered `tools/list`.

## Deploy checklist

Not done; waits on the 24-hour pairing check. Do not start until that passes.

1. Create the KV namespace: `npx wrangler kv namespace create OAUTH_KV`. Put the id in `wrangler.toml`.
2. Google Cloud Console: create an OAuth client (Web application) with the redirect URI `https://<worker-hostname>/callback`. Keep the client id and secret.
3. Cloudflare Zero Trust: create a Tunnel and a public hostname for it. Create an Access service token. Add an Access application for that hostname with a Service Auth policy that names the token.
4. On the Mac, in the cloudflared config:

   ```yaml
   ingress:
     - hostname: <tunnel-hostname>
       service: http://127.0.0.1:7007
       originRequest:
         httpHostHeader: 127.0.0.1:7007
     - service: http_status:404
   ```

5. Start OpenMessage with `--mcp-read-only`.
6. Set the secrets, one at a time: `npx wrangler secret put GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `CF_ACCESS_CLIENT_ID`, `CF_ACCESS_CLIENT_SECRET`.
7. Set the vars in `wrangler.toml`: `PUBLIC_URL` (the Worker's https origin), `ORIGIN_URL` (`https://<tunnel-hostname>`), `ALLOWED_EMAIL`.
8. Deploy: `npx wrangler deploy`.
9. In claude.ai, add a custom connector with the URL `https://<worker-hostname>/mcp`, then sign in with the allowed Google account.
10. Check: `tools/list` shows only the read tools, and asking Claude to send a message fails.

## Files

- `src/index.ts`: builds the OAuth provider, checks the hostname and email, routes `/mcp`.
- `src/auth.ts`: `/authorize` (consent, Google redirect) and `/callback`.
- `src/proxy.ts`, `src/sse.ts`: the MCP filter and the event-stream rewrite.
- `src/allowlist.ts`: reads `readonly-tools.json`.
