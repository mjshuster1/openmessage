import { afterEach, describe, expect, it, vi } from "vitest";
import worker from "../src/index";
import { sign } from "../src/reconnect";
import { ALLOWED, PUBLIC_URL, jsonReply, makeEnv } from "./helpers";
import type { Env } from "../src/env";

const SECRET = "s".repeat(40);
const ctx = { waitUntil() {}, passThroughOnException() {} } as unknown as ExecutionContext;

function pairBinding(respond?: (url: string, init: RequestInit) => Response) {
  const calls: { url: string; init: RequestInit }[] = [];
  const f = {
    fetch: vi.fn(async (url: string, init: RequestInit) => {
      calls.push({ url, init });
      return respond ? respond(url, init) : jsonReply({ rules: { phrases: ["x y z"], numbers: [], mode: "log" }, recent: [] });
    }),
  } as unknown as Fetcher;
  return { calls, f };
}

const envWith = (pair: Fetcher | undefined, overrides: Partial<Env> = {}) =>
  makeEnv({ RECONNECT_SECRET: SECRET, PAIR: pair, ...overrides });

async function cookie(e: Env, email = ALLOWED) {
  return `om_rc=${await sign(e, { p: "session", e: email, x: Math.floor(Date.now() / 1000) + 600 })}`;
}
const get = (path: string, headers: Record<string, string> = {}) => new Request(`${PUBLIC_URL}${path}`, { headers });
const post = (path: string, body: unknown, headers: Record<string, string> = {}) =>
  new Request(`${PUBLIC_URL}${path}`, { method: "POST", headers: { "Content-Type": "application/json", Origin: new URL(PUBLIC_URL).origin, ...headers }, body: JSON.stringify(body) });

afterEach(() => vi.unstubAllGlobals());

describe("spam page", () => {
  it("is off without RECONNECT_SECRET", async () => {
    const res = await worker.fetch(get("/reconnect/spam"), makeEnv({ RECONNECT_SECRET: undefined }), ctx);
    expect(res.status).toBe(404);
  });

  it("sends strangers to Google, and returns them to the spam page", async () => {
    const e = envWith(pairBinding().f);
    const res = await worker.fetch(get("/reconnect/spam"), e, ctx);
    expect(res.status).toBe(302);
    expect(res.headers.get("Location")).toContain("accounts.google.com");
  });

  it("shows the owner the page, with a locked-down policy", async () => {
    const e = envWith(pairBinding().f);
    const res = await worker.fetch(get("/reconnect/spam", { Cookie: await cookie(e) }), e, ctx);
    expect(res.status).toBe(200);
    expect(res.headers.get("Content-Security-Policy")).toContain("default-src 'none'");
    expect(await res.text()).toContain("Your spam rules");
  });

  it("refuses data and changes without a sign-in, and doesn't reach the VM", async () => {
    const p = pairBinding();
    const e = envWith(p.f);
    expect((await worker.fetch(get("/reconnect/spam/data"), e, ctx)).status).toBe(401);
    expect((await worker.fetch(post("/reconnect/spam/rules", { phrases: [], numbers: [], mode: "log" }), e, ctx)).status).toBe(401);
    expect(p.calls).toHaveLength(0);
  });

  it("refuses another account's session", async () => {
    const p = pairBinding();
    const e = envWith(p.f);
    const res = await worker.fetch(get("/reconnect/spam/data", { Cookie: await cookie(e, "someone@else.example") }), e, ctx);
    expect(res.status).toBe(401);
    expect(p.calls).toHaveLength(0);
  });

  it("refuses a POST from another site, even signed in", async () => {
    const p = pairBinding();
    const e = envWith(p.f);
    const c = await cookie(e);
    for (const Origin of ["https://evil.example", ""]) {
      const res = await worker.fetch(post("/reconnect/spam/rules", { phrases: [], numbers: [], mode: "block" }, { Cookie: c, Origin }), e, ctx);
      expect(res.status).toBe(403);
    }
    expect(p.calls).toHaveLength(0);
  });

  it("passes only the known fields to the VM", async () => {
    const p = pairBinding(() => jsonReply({ ok: true }));
    const e = envWith(p.f);
    const res = await worker.fetch(post("/reconnect/spam/rules", { phrases: ["abc"], numbers: ["5551234567"], mode: "block", max_blocks_per_day: 9999 }, { Cookie: await cookie(e) }), e, ctx);
    expect(res.status).toBe(200);
    expect(p.calls[0]!.url).toBe("http://127.0.0.1:7011/spam");
    expect(JSON.parse(p.calls[0]!.init.body as string)).toEqual({ phrases: ["abc"], numbers: ["5551234567"], mode: "block" });
  });

  it("sends block and unblock to the action path", async () => {
    const p = pairBinding(() => jsonReply({ ok: true }));
    const e = envWith(p.f);
    const res = await worker.fetch(post("/reconnect/spam/action", { conversation_id: "c1", action: "unblock", extra: 1 }, { Cookie: await cookie(e) }), e, ctx);
    expect(res.status).toBe(200);
    expect(p.calls[0]!.url).toBe("http://127.0.0.1:7011/spam/action");
    expect(JSON.parse(p.calls[0]!.init.body as string)).toEqual({ conversation_id: "c1", action: "unblock" });
  });

  it("says plainly when the VM's helper is too old or missing", async () => {
    const old = envWith(pairBinding(() => new Response("{}", { status: 404 })).f);
    const r1 = await worker.fetch(get("/reconnect/spam/data", { Cookie: await cookie(old) }), old, ctx);
    expect(r1.status).toBe(501);
    expect(((await r1.json()) as { error: string }).error).toContain("update");
    const none = envWith(undefined);
    const r2 = await worker.fetch(get("/reconnect/spam/data", { Cookie: await cookie(none) }), none, ctx);
    expect(r2.status).toBe(501);
  });

  it("leaves the connector's read-only list alone", async () => {
    const tools = (await import("../readonly-tools.json")).tools;
    expect(tools.some((t: string) => /spam|block/.test(t))).toBe(false);
  });
});
