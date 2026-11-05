import { afterEach, describe, expect, it, vi } from "vitest";
import worker from "../src/index";
import { CODE_PREFIX, sign, verify } from "../src/reconnect";
import { ALLOWED, PUBLIC_URL, jsonReply, makeEnv } from "./helpers";
import type { Env } from "../src/env";

const SECRET = "s".repeat(40);
const ctx = { waitUntil() {}, passThroughOnException() {} } as unknown as ExecutionContext;

function binding(respond: (url: string, init: RequestInit) => Response | Promise<Response>) {
  const calls: { url: string; init: RequestInit }[] = [];
  const f = { fetch: vi.fn(async (url: string, init: RequestInit) => (calls.push({ url, init }), respond(url, init))) } as unknown as Fetcher;
  return { calls, f };
}

function env(overrides: Partial<Env> = {}) {
  const origin = binding(() => jsonReply({ google: { connected: false, needs_pairing: true } }));
  const pair = binding((_u, init) =>
    init.method === "POST"
      ? new Response(JSON.stringify({ state: "starting" }), { status: 202 })
      : jsonReply({ state: "waiting_for_tap", emoji: "🦊", message: "tap it", tries_left_today: 2 }),
  );
  return {
    origin,
    pair,
    env: makeEnv({ RECONNECT_SECRET: SECRET, ORIGIN: origin.f, PAIR: pair.f, ...overrides }),
  };
}

const get = (path: string, headers: Record<string, string> = {}) => new Request(`${PUBLIC_URL}${path}`, { headers });
const cookieFrom = (res: Response, name: string) =>
  (res.headers.get("Set-Cookie") ?? "").split(/,(?=\s*om_)/).map((c) => c.trim()).find((c) => c.startsWith(`${name}=`))?.split(";")[0];

afterEach(() => vi.unstubAllGlobals());

async function session(e: Env) {
  const tok = await sign(e, { p: "session", e: ALLOWED, x: Math.floor(Date.now() / 1000) + 600 });
  return `om_rc=${tok}`;
}

describe("reconnect: off by default", () => {
  it("404s without RECONNECT_SECRET or with a short one", async () => {
    for (const RECONNECT_SECRET of [undefined, "short"]) {
      const res = await worker.fetch(get("/reconnect"), makeEnv({ RECONNECT_SECRET }), ctx);
      expect(res.status).toBe(404);
    }
  });
});

describe("reconnect: sign-in (Google mode)", () => {
  it("sends a stranger to Google with a browser-bound login cookie", async () => {
    const { env: e } = env();
    const res = await worker.fetch(get("/reconnect"), e, ctx);
    expect(res.status).toBe(302);
    const loc = new URL(res.headers.get("Location")!);
    expect(loc.origin).toBe("https://accounts.google.com");
    expect(loc.searchParams.get("redirect_uri")).toBe(`${PUBLIC_URL}/reconnect/callback`);
    expect(loc.searchParams.get("code_challenge_method")).toBe("S256");
    const login = cookieFrom(res, "om_rc_login");
    expect(login).toBeTruthy();
    expect(res.headers.get("Set-Cookie")).toContain("HttpOnly; Secure; SameSite=Lax");
  });

  it("finishes sign-in for the allowed account only", async () => {
    const { env: e } = env();
    const start = await worker.fetch(get("/reconnect"), e, ctx);
    const state = new URL(start.headers.get("Location")!).searchParams.get("state")!;
    const login = cookieFrom(start, "om_rc_login")!;
    for (const [email, want] of [[ALLOWED, 302], ["someone@else.com", 403]] as const) {
      vi.stubGlobal("fetch", vi.fn(async (url: string) =>
        url.includes("token") ? jsonReply({ access_token: "at" }) : jsonReply({ email, email_verified: true })));
      const res = await worker.fetch(get(`/reconnect/callback?state=${state}&code=c`, { Cookie: login }), e, ctx);
      expect(res.status).toBe(want);
      if (want === 302) {
        expect(res.headers.get("Location")).toBe(`${PUBLIC_URL}/reconnect`);
        expect(res.headers.get("Set-Cookie")).toContain("om_rc=");
      }
    }
  });

  it("refuses a callback with the wrong state or no login cookie", async () => {
    const { env: e } = env();
    const start = await worker.fetch(get("/reconnect"), e, ctx);
    const login = cookieFrom(start, "om_rc_login")!;
    expect((await worker.fetch(get(`/reconnect/callback?state=nope&code=c`, { Cookie: login }), e, ctx)).status).toBe(403);
    const state = new URL(start.headers.get("Location")!).searchParams.get("state")!;
    expect((await worker.fetch(get(`/reconnect/callback?state=${state}&code=c`), e, ctx)).status).toBe(403);
  });
});

describe("reconnect: page, code, upload", () => {
  it("shows the page and a reconnect code to the signed-in owner", async () => {
    const { env: e } = env();
    const res = await worker.fetch(get("/reconnect", { Cookie: await session(e) }), e, ctx);
    expect(res.status).toBe(200);
    expect(res.headers.get("Content-Security-Policy")).toContain("frame-ancestors 'none'");
    const html = await res.text();
    expect(html).toContain("Not connected to Google Messages");
    const code = /"(omrc1\.[^"]+)"/.exec(html)![1]!;
    const payload = JSON.parse(atob(code.slice(CODE_PREFIX.length).replace(/-/g, "+").replace(/_/g, "/")));
    expect(payload.u).toBe(PUBLIC_URL);
    expect(await verify(e, payload.t, "upload")).toMatchObject({ e: ALLOWED, f: false });
    // a session token can't be used as an upload token, and the reverse
    expect(await verify(e, payload.t, "session")).toBeNull();
  });

  it("forwards only the cookies (and the signed force flag) to the VM", async () => {
    const { env: e, pair } = env();
    const t = await sign(e, { p: "upload", e: ALLOWED, f: true, x: Math.floor(Date.now() / 1000) + 600 });
    const res = await worker.fetch(
      new Request(`${PUBLIC_URL}/reconnect/upload`, {
        method: "POST",
        headers: { Authorization: `Bearer ${t}`, "Content-Type": "application/json" },
        body: JSON.stringify({ cookies: { SID: "x" }, force: false, extra: "dropped" }),
      }),
      e,
      ctx,
    );
    expect(res.status).toBe(202);
    const post = pair.calls.find((c) => c.init.method === "POST")!;
    expect(post.url).toBe("http://127.0.0.1:7011/pair");
    expect(JSON.parse(String(post.init.body))).toEqual({ cookies: { SID: "x" }, force: true });
    expect(JSON.stringify(await res.json())).not.toContain("SID");
  });

  it("refuses uploads without a valid, unexpired code", async () => {
    const { env: e, pair } = env();
    const expired = await sign(e, { p: "upload", e: ALLOWED, x: Math.floor(Date.now() / 1000) - 1 });
    const session_ = await sign(e, { p: "session", e: ALLOWED, x: Math.floor(Date.now() / 1000) + 600 });
    const wrongWho = await sign(e, { p: "upload", e: "x@y.com", x: Math.floor(Date.now() / 1000) + 600 });
    for (const auth of ["", "Bearer junk", `Bearer ${expired}`, `Bearer ${session_}`, `Bearer ${wrongWho}`]) {
      const res = await worker.fetch(
        new Request(`${PUBLIC_URL}/reconnect/upload`, { method: "POST", headers: { Authorization: auth }, body: "{}" }),
        e,
        ctx,
      );
      expect(res.status).toBe(401);
    }
    const other = makeEnv({ RECONNECT_SECRET: "o".repeat(40) });
    const forged = await sign(other, { p: "upload", e: ALLOWED, x: Math.floor(Date.now() / 1000) + 600 });
    expect(await verify(e, forged, "upload")).toBeNull();
    expect(pair.calls.filter((c) => c.init.method === "POST")).toHaveLength(0);
  });

  it("serves state to the owner or the app, not to strangers", async () => {
    const { env: e } = env();
    expect((await worker.fetch(get("/reconnect/state"), e, ctx)).status).toBe(401);
    const t = await sign(e, { p: "upload", e: ALLOWED, x: Math.floor(Date.now() / 1000) + 600 });
    const hs: Record<string, string>[] = [{ Authorization: `Bearer ${t}` }, { Cookie: await session(e) }];
    for (const h of hs) {
      const res = await worker.fetch(get("/reconnect/state", h), e, ctx);
      expect(res.status).toBe(200);
      const s = (await res.json()) as { pair: { emoji: string }; helper: boolean; needs_pairing: boolean };
      expect(s.helper).toBe(true);
      expect(s.pair.emoji).toBe("🦊");
      expect(s.needs_pairing).toBe(true);
    }
  });

  it("says reconnecting isn't on when there's no PAIR binding", async () => {
    const { env: e } = env({ PAIR: undefined });
    const html = await (await worker.fetch(get("/reconnect", { Cookie: await session(e) }), e, ctx)).text();
    expect(html).toContain("isn't switched on");
  });

  it("Access mode: the page needs Access's token, and has no callback", async () => {
    const { env: e } = env({ AUTH_MODE: "access", ACCESS_TEAM_DOMAIN: "team.cloudflareaccess.com", ACCESS_AUD: "aud" });
    expect((await worker.fetch(get("/reconnect"), e, ctx)).status).toBe(403);
    expect((await worker.fetch(get("/reconnect/callback?state=a&code=b"), e, ctx)).status).toBe(404);
  });
});
