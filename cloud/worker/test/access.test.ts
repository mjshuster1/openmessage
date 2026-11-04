import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import worker from "../src/index";
import { accessConfig, clearAccessKeyCache, teamHost, verifyAccessJwt } from "../src/access";
import { ALLOWED, PUBLIC_URL, jsonReply, makeEnv, post, rpc } from "./helpers";
import type { Env } from "../src/env";

const TEAM = "team.cloudflareaccess.com";
const AUD = "a".repeat(64);
const ctx = { waitUntil() {}, passThroughOnException() {} } as unknown as ExecutionContext;

const b64url = (bytes: Uint8Array | ArrayBuffer) =>
  btoa(String.fromCharCode(...new Uint8Array(bytes))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const enc = (obj: unknown) => b64url(new TextEncoder().encode(JSON.stringify(obj)));

let signing: CryptoKeyPair;
let other: CryptoKeyPair;
let jwks: { keys: Record<string, unknown>[] };

async function rsa() {
  return (await crypto.subtle.generateKey(
    { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
    true,
    ["sign", "verify"],
  )) as CryptoKeyPair;
}

beforeAll(async () => {
  signing = await rsa();
  other = await rsa();
  const pub = await crypto.subtle.exportKey("jwk", signing.publicKey);
  jwks = { keys: [{ ...pub, kid: "k1", alg: "RS256", use: "sig" }] };
});

const now = () => Math.floor(Date.now() / 1000);

async function jwt(
  claims: Record<string, unknown> = {},
  opts: { kid?: string; key?: CryptoKey; alg?: string } = {},
): Promise<string> {
  const header = enc({ alg: opts.alg ?? "RS256", kid: opts.kid ?? "k1", typ: "JWT" });
  const body = enc({ iss: `https://${TEAM}`, aud: [AUD], email: ALLOWED, exp: now() + 600, iat: now(), ...claims });
  const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", opts.key ?? signing.privateKey, new TextEncoder().encode(`${header}.${body}`));
  return `${header}.${body}.${b64url(sig)}`;
}

/** One fetch stub for both the team's certs and the origin. */
function stubFetch(origin: () => Response = () => jsonReply({ jsonrpc: "2.0", id: 1, result: {} })) {
  const certs = vi.fn(async () => Response.json(jwks));
  const upstream = vi.fn(async (_url: string, _init?: RequestInit) => origin());
  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: string | URL | Request, init?: RequestInit) => {
      const url = String(input instanceof Request ? input.url : input);
      if (url === `https://${TEAM}/cdn-cgi/access/certs`) return certs();
      return upstream(url, init);
    }),
  );
  return { certs, upstream };
}

const env = (o: Partial<Env> = {}): Env =>
  makeEnv({ AUTH_MODE: "access", ACCESS_TEAM_DOMAIN: TEAM, ACCESS_AUD: AUD, GOOGLE_CLIENT_ID: "", GOOGLE_CLIENT_SECRET: "", ...o });

beforeEach(() => clearAccessKeyCache());
afterEach(() => vi.unstubAllGlobals());

describe("config", () => {
  it("normalizes the team domain and refuses junk", () => {
    expect(teamHost("https://Team.cloudflareaccess.com/")).toBe(TEAM);
    expect(teamHost("not a host")).toBe("");
    expect(teamHost("evil.com/path")).toBe("");
    expect(accessConfig({ ACCESS_TEAM_DOMAIN: TEAM, ACCESS_AUD: AUD })).toEqual({ teamDomain: TEAM, aud: AUD });
    expect(accessConfig({ ACCESS_TEAM_DOMAIN: TEAM, ACCESS_AUD: "" })).toBeNull();
    expect(accessConfig({ ACCESS_TEAM_DOMAIN: "", ACCESS_AUD: AUD })).toBeNull();
  });
});

describe("verifyAccessJwt", () => {
  const cfg = { teamDomain: TEAM, aud: AUD };
  const e = { ALLOWED_EMAIL: ALLOWED };
  const fetchCerts = async () => Response.json(jwks);

  it("accepts a good token and returns the email", async () => {
    expect(await verifyAccessJwt(await jwt({ email: "Owner@Example.com" }), cfg, e, fetchCerts)).toEqual({ ok: true, email: ALLOWED });
  });

  it.each([
    ["missing", async () => null, 401],
    ["malformed", async () => "a.b", 401],
    ["signed by another key", async () => jwt({}, { key: other.privateKey }), 401],
    ["unknown kid", async () => jwt({}, { kid: "nope" }), 401],
    ["alg none", async () => jwt({}, { alg: "none" }), 401],
    ["wrong issuer", async () => jwt({ iss: "https://other.cloudflareaccess.com" }), 401],
    ["another app's audience", async () => jwt({ aud: ["b".repeat(64)] }), 401],
    ["expired", async () => jwt({ exp: now() - 3600 }), 401],
    ["not yet valid", async () => jwt({ nbf: now() + 3600 }), 401],
    ["another email", async () => jwt({ email: "intruder@example.com" }), 403],
    ["no email (service token)", async () => jwt({ email: undefined }), 403],
  ])("refuses a token that is %s", async (_name, make, status) => {
    const r = await verifyAccessJwt(await make(), cfg, e, fetchCerts);
    expect(r.ok).toBe(false);
    expect(r.ok === false && r.status).toBe(status);
  });

  it("refuses everyone when ALLOWED_EMAIL is empty", async () => {
    const r = await verifyAccessJwt(await jwt(), cfg, { ALLOWED_EMAIL: "" }, fetchCerts);
    expect(r.ok === false && r.status).toBe(403);
  });

  it("reports 502 when the keys can't be fetched", async () => {
    const r = await verifyAccessJwt(await jwt(), cfg, e, async () => new Response("down", { status: 503 }));
    expect(r.ok === false && r.status).toBe(502);
  });

  it("caches the keys", async () => {
    const f = vi.fn(fetchCerts);
    await verifyAccessJwt(await jwt(), cfg, e, f);
    await verifyAccessJwt(await jwt(), cfg, e, f);
    expect(f).toHaveBeenCalledTimes(1);
  });
});

describe("Worker in access mode", () => {
  it("proxies an MCP call with a valid Access token, without forwarding Access headers", async () => {
    const { upstream } = stubFetch();
    const token = await jwt();
    const res = await worker.fetch(post(rpc("ping"), { "Cf-Access-Jwt-Assertion": token, Authorization: "Bearer x" }), env(), ctx);
    expect(res.status).toBe(200);
    expect(upstream).toHaveBeenCalledTimes(1);
    const init = upstream.mock.calls[0]![1] as RequestInit;
    const sent = new Headers(init.headers);
    expect(sent.get("cf-access-jwt-assertion")).toBeNull();
    expect(sent.get("authorization")).toBeNull();
  });

  it("still applies the read-only filter", async () => {
    const { upstream } = stubFetch();
    const res = await worker.fetch(
      post(rpc("tools/call", { name: "send_message", arguments: {} }), { "Cf-Access-Jwt-Assertion": await jwt() }),
      env(),
      ctx,
    );
    expect(upstream).not.toHaveBeenCalled();
    expect(JSON.stringify(await res.json())).toContain("error");
  });

  it("refuses without a token (Access not in front) and never reaches the origin", async () => {
    const { upstream } = stubFetch();
    expect((await worker.fetch(post(rpc("ping")), env(), ctx)).status).toBe(401);
    expect(upstream).not.toHaveBeenCalled();
  });

  it("refuses another email with 403", async () => {
    const { upstream } = stubFetch();
    const res = await worker.fetch(post(rpc("ping"), { "Cf-Access-Jwt-Assertion": await jwt({ email: "x@example.com" }) }), env(), ctx);
    expect(res.status).toBe(403);
    expect(upstream).not.toHaveBeenCalled();
  });

  it("serves nothing but /mcp, and no OAuth endpoints", async () => {
    stubFetch();
    const h = { "Cf-Access-Jwt-Assertion": await jwt() };
    for (const p of ["/authorize", "/callback", "/oauth/register", "/.well-known/oauth-authorization-server"]) {
      expect((await worker.fetch(new Request(`${PUBLIC_URL}${p}`, { headers: h }), env(), ctx)).status).toBe(404);
    }
  });

  it("answers 404 on other hostnames (preview URLs Access may not cover)", async () => {
    stubFetch();
    const r = new Request("https://abc123-connector.test/mcp", { method: "POST", headers: { "Cf-Access-Jwt-Assertion": await jwt() } });
    expect((await worker.fetch(r, env(), ctx)).status).toBe(404);
  });

  it("fails closed when misconfigured", async () => {
    stubFetch();
    const h = { "Cf-Access-Jwt-Assertion": await jwt() };
    expect((await worker.fetch(post(rpc("ping"), h), env({ ACCESS_AUD: "" }), ctx)).status).toBe(500);
    expect((await worker.fetch(post(rpc("ping"), h), env({ AUTH_MODE: "acess" }), ctx)).status).toBe(500);
  });
});
