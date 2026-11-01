import { describe, expect, it, vi, afterEach } from "vitest";
import worker from "../src/index";
import { ALLOWED, PUBLIC_URL, TOOLS_FIXTURE, VISIBLE_TOOLS, makeEnv } from "./helpers";
import type { Env } from "../src/env";

/** In-memory stand-in for the KV namespace (the parts the OAuth provider uses). */
function memoryKv() {
  const store = new Map<string, { value: string; metadata?: unknown }>();
  return {
    async get(key: string, opts?: string | { type?: string }) {
      const hit = store.get(key);
      if (!hit) return null;
      const type = typeof opts === "string" ? opts : opts?.type;
      return type === "json" ? JSON.parse(hit.value) : hit.value;
    },
    async getWithMetadata(key: string, opts?: string | { type?: string }) {
      const hit = store.get(key);
      return { value: hit ? await this.get(key, opts) : null, metadata: hit?.metadata ?? null };
    },
    async put(key: string, value: string, opts?: { metadata?: unknown }) {
      store.set(key, { value: String(value), metadata: opts?.metadata });
    },
    async delete(key: string) {
      store.delete(key);
    },
    async list(opts?: { prefix?: string }) {
      const keys = [...store.entries()]
        .filter(([k]) => k.startsWith(opts?.prefix ?? ""))
        .map(([name, v]) => ({ name, metadata: v.metadata }));
      return { keys, list_complete: true, cursor: undefined };
    },
  };
}

const ctx = { waitUntil() {}, passThroughOnException() {} } as unknown as ExecutionContext;
const env = (): Env => makeEnv({ OAUTH_KV: memoryKv() as unknown as KVNamespace });

const b64url = (bytes: ArrayBuffer) =>
  btoa(String.fromCharCode(...new Uint8Array(bytes))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

afterEach(() => vi.unstubAllGlobals());

describe("OAuthProvider wiring (real library, in-memory KV)", () => {
  it("builds with our options and serves discovery", async () => {
    const e = env();
    const meta = await worker.fetch(new Request(`${PUBLIC_URL}/.well-known/oauth-authorization-server`), e, ctx);
    expect(meta.status).toBe(200);
    const doc = (await meta.json()) as Record<string, unknown>;
    expect(doc["issuer"]).toBe(PUBLIC_URL);
    expect(doc["authorization_endpoint"]).toBe(`${PUBLIC_URL}/authorize`);
    expect(doc["token_endpoint"]).toBe(`${PUBLIC_URL}/oauth/token`);
    expect(doc["registration_endpoint"]).toBe(`${PUBLIC_URL}/oauth/register`);

    const prm = await worker.fetch(new Request(`${PUBLIC_URL}/.well-known/oauth-protected-resource/mcp`), e, ctx);
    expect(((await prm.json()) as { resource: string }).resource).toBe(`${PUBLIC_URL}/mcp`);

    const noToken = await worker.fetch(new Request(`${PUBLIC_URL}/mcp`, { method: "POST", body: "{}" }), e, ctx);
    expect(noToken.status).toBe(401);
    expect(noToken.headers.get("www-authenticate")).toContain("resource_metadata=");
  });

  it("answers 404 on any other hostname, and for unknown paths", async () => {
    const e = env();
    expect((await worker.fetch(new Request("https://other.test/mcp"), e, ctx)).status).toBe(404);
    expect((await worker.fetch(new Request(`${PUBLIC_URL}/nope`), e, ctx)).status).toBe(404);
  });

  it("runs the whole flow: register, consent, Google, token, then a filtered tools/list", async () => {
    const e = env();
    const redirectUri = "https://claude.ai/api/mcp/auth_callback";

    // Dynamic client registration, as claude.ai does it.
    const reg = await worker.fetch(
      new Request(`${PUBLIC_URL}/oauth/register`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ client_name: "Claude", redirect_uris: [redirectUri], token_endpoint_auth_method: "none", grant_types: ["authorization_code", "refresh_token"], response_types: ["code"] }),
      }),
      e,
      ctx,
    );
    expect(reg.status).toBe(201);
    const { client_id } = (await reg.json()) as { client_id: string };

    const verifier = "v".repeat(64);
    const challenge = b64url(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier)));
    const authUrl = new URL(`${PUBLIC_URL}/authorize`);
    authUrl.search = new URLSearchParams({
      response_type: "code",
      client_id,
      redirect_uri: redirectUri,
      state: "client-state",
      code_challenge: challenge,
      code_challenge_method: "S256",
      resource: `${PUBLIC_URL}/mcp`,
    }).toString();

    // 1. Consent page.
    const page = await worker.fetch(new Request(authUrl), e, ctx);
    expect(page.status).toBe(200);
    const html = await page.text();
    const handle = /name="handle" value="([^"]+)"/.exec(html)![1]!;
    const cookie1 = page.headers.get("set-cookie")!.split(";")[0]!;

    // 2. Allow -> Google.
    const allow = await worker.fetch(
      new Request(`${PUBLIC_URL}/authorize`, {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded", Cookie: cookie1 },
        body: new URLSearchParams({ handle, decision: "approve" }),
      }),
      e,
      ctx,
    );
    expect(allow.status).toBe(302);
    const google = new URL(allow.headers.get("location")!);
    expect(google.host).toBe("accounts.google.com");
    const state = google.searchParams.get("state")!;
    const upstreamCookie = allow.headers
      .getSetCookie()
      .map((c) => c.split(";")[0]!)
      .find((c) => c.startsWith("__Host-oauth-upstream"))!;

    // 3. Google calls back; the wrong person is refused.
    const upstreamMock = (email: string) =>
      vi.stubGlobal(
        "fetch",
        vi.fn(async (input: string | URL | Request) => {
          const url = String(input);
          if (url.includes("oauth2.googleapis.com")) return Response.json({ access_token: "g" });
          return Response.json({ email, email_verified: true });
        }),
      );
    upstreamMock("intruder@example.com");
    const denied = await worker.fetch(
      new Request(`${PUBLIC_URL}/callback?code=c&state=${state}`, { headers: { Cookie: upstreamCookie } }),
      e,
      ctx,
    );
    expect(denied.status).toBe(403);
    // The state is spent: the right person cannot reuse it either.
    upstreamMock(ALLOWED);
    const replay = await worker.fetch(
      new Request(`${PUBLIC_URL}/callback?code=c&state=${state}`, { headers: { Cookie: upstreamCookie } }),
      e,
      ctx,
    );
    expect(replay.status).toBe(403);

    // Start over for the owner.
    const page2 = await worker.fetch(new Request(authUrl), e, ctx);
    const handle2 = /name="handle" value="([^"]+)"/.exec(await page2.text())![1]!;
    const allow2 = await worker.fetch(
      new Request(`${PUBLIC_URL}/authorize`, {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded", Cookie: page2.headers.get("set-cookie")!.split(";")[0]! },
        body: new URLSearchParams({ handle: handle2, decision: "approve" }),
      }),
      e,
      ctx,
    );
    const state2 = new URL(allow2.headers.get("location")!).searchParams.get("state")!;
    const cookie2 = allow2.headers.getSetCookie().map((c) => c.split(";")[0]!).find((c) => c.startsWith("__Host-oauth-upstream"))!;
    const ok = await worker.fetch(
      new Request(`${PUBLIC_URL}/callback?code=c&state=${state2}`, { headers: { Cookie: cookie2 } }),
      e,
      ctx,
    );
    expect(ok.status).toBe(302);
    const back = new URL(ok.headers.get("location")!);
    expect(back.origin + back.pathname).toBe(redirectUri);
    expect(back.searchParams.get("state")).toBe("client-state");
    const code = back.searchParams.get("code")!;

    // 4. Token exchange.
    const tokenRes = await worker.fetch(
      new Request(`${PUBLIC_URL}/oauth/token`, {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({ grant_type: "authorization_code", code, client_id, redirect_uri: redirectUri, code_verifier: verifier, resource: `${PUBLIC_URL}/mcp` }),
      }),
      e,
      ctx,
    );
    expect(tokenRes.status).toBe(200);
    const { access_token } = (await tokenRes.json()) as { access_token: string };

    // 5. tools/call of a write tool is refused; tools/list is filtered; the bearer token never reaches the origin.
    let seenHeaders: Headers | undefined;
    vi.stubGlobal(
      "fetch",
      vi.fn(async (_url: string, init: RequestInit) => {
        seenHeaders = new Headers(init.headers);
        return Response.json({ jsonrpc: "2.0", id: 1, result: { tools: TOOLS_FIXTURE } });
      }),
    );
    const mcp = (body: unknown) =>
      worker.fetch(
        new Request(`${PUBLIC_URL}/mcp`, {
          method: "POST",
          headers: { Authorization: `Bearer ${access_token}`, "Content-Type": "application/json", Origin: "https://claude.ai" },
          body: JSON.stringify(body),
        }),
        e,
        ctx,
      );
    const list = await mcp({ jsonrpc: "2.0", id: 1, method: "tools/list" });
    expect(list.status).toBe(200);
    const tools = ((await list.json()) as { result: { tools: { name: string }[] } }).result.tools.map((t) => t.name);
    expect(tools.sort()).toEqual([...VISIBLE_TOOLS].sort());
    expect(seenHeaders!.has("authorization")).toBe(false);
    expect(seenHeaders!.has("origin")).toBe(false);
    expect(seenHeaders!.get("cf-access-client-id")).toBe("test-access-id");

    const send = await mcp({ jsonrpc: "2.0", id: 4, method: "tools/call", params: { name: "send_message", arguments: {} } });
    expect(((await send.json()) as { error: { message: string } }).error.message).toBe("tool not allowed");

    // 6. Change ALLOWED_EMAIL and the already-issued token stops working.
    const locked = await worker.fetch(
      new Request(`${PUBLIC_URL}/mcp`, {
        method: "POST",
        headers: { Authorization: `Bearer ${access_token}`, "Content-Type": "application/json" },
        body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "ping" }),
      }),
      { ...e, ALLOWED_EMAIL: "someone-else@example.com" } as Env,
      ctx,
    );
    expect(locked.status).toBe(403);
  });
});
