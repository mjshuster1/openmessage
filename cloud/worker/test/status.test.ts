import { describe, expect, it, vi } from "vitest";
import worker from "../src/index";
import { ago, handleStatus, summarize } from "../src/status";
import { PUBLIC_URL, jsonReply, makeEnv } from "./helpers";

const KEY = "k".repeat(32);
const ctx = { waitUntil() {}, passThroughOnException() {} } as unknown as ExecutionContext;
const NOW = Date.UTC(2026, 10, 5, 15, 0);

const STATUS = {
  google: { connected: true, needs_pairing: false, supervisor: { state: "connected" } },
  freshness: { google: { latest_received_ms: NOW - 12 * 60000, silence: { stalled: false } } },
  // Things that must never leave: a preview, a name, a number.
  conversations: [{ name: "Bob Smith", preview: "secret text", phone: "+15085551234" }],
  total_messages: 12345,
};

function origin(respond: () => Response | Promise<Response>) {
  const calls: string[] = [];
  const ORIGIN = {
    fetch: vi.fn(async (url: string) => {
      calls.push(url);
      return respond();
    }),
  } as unknown as Fetcher;
  return { calls, ORIGIN };
}

const req = (q: string, method = "GET") => new Request(`${PUBLIC_URL}/status${q}`, { method });

describe("status page", () => {
  it("is off without a STATUS_KEY", async () => {
    const o = origin(() => jsonReply(STATUS));
    const res = await worker.fetch(req(`?key=${KEY}`), makeEnv({ ORIGIN: o.ORIGIN }), ctx);
    expect(res.status).toBe(404);
    expect(o.calls).toHaveLength(0);
  });

  it("is off with a short STATUS_KEY", async () => {
    const o = origin(() => jsonReply(STATUS));
    const res = await handleStatus(req("?key=short"), makeEnv({ ORIGIN: o.ORIGIN, STATUS_KEY: "short" }));
    expect(res.status).toBe(404);
  });

  it("refuses a wrong or missing key without asking the origin", async () => {
    const o = origin(() => jsonReply(STATUS));
    const env = makeEnv({ ORIGIN: o.ORIGIN, STATUS_KEY: KEY });
    for (const q of ["", "?key=", `?key=${"x".repeat(32)}`, `?key=${KEY}x`]) {
      expect((await worker.fetch(req(q), env, ctx)).status).toBe(404);
    }
    expect((await worker.fetch(req(`?key=${KEY}`, "POST"), env, ctx)).status).toBe(404);
    expect(o.calls).toHaveLength(0);
  });

  it("shows connected and the newest text's age, and nothing else", async () => {
    const o = origin(() => jsonReply(STATUS));
    const res = await handleStatus(req(`?key=${KEY}`), makeEnv({ ORIGIN: o.ORIGIN, STATUS_KEY: KEY }), NOW);
    expect(res.status).toBe(200);
    expect(res.headers.get("Cache-Control")).toBe("no-store");
    const html = await res.text();
    expect(html).toContain("Connected.");
    expect(html).toContain("12 min ago");
    for (const leak of ["Bob", "secret", "5085551234", "12345"]) expect(html).not.toContain(leak);
    expect(o.calls).toEqual(["http://127.0.0.1:7007/api/status"]);
  });

  it("answers JSON with only the summary fields", async () => {
    const o = origin(() => jsonReply(STATUS));
    const res = await handleStatus(req(`?key=${KEY}&format=json`), makeEnv({ ORIGIN: o.ORIGIN, STATUS_KEY: KEY }), NOW);
    const body = (await res.json()) as Record<string, unknown>;
    expect(Object.keys(body).sort()).toEqual(
      ["checked_ms", "connected", "needs_pairing", "newest_text_ms", "ok", "quieter_than_usual", "reachable"],
    );
    expect(body.ok).toBe(true);
  });

  it("says when it needs reconnecting", async () => {
    const o = origin(() => jsonReply({ google: { connected: false, needs_pairing: true } }));
    const html = await (await handleStatus(req(`?key=${KEY}`), makeEnv({ ORIGIN: o.ORIGIN, STATUS_KEY: KEY }), NOW)).text();
    expect(html).toContain("Needs reconnecting");
  });

  it("says when the server isn't answering", async () => {
    for (const respond of [() => new Response("bad gateway", { status: 502 }), () => Promise.reject(new Error("down"))]) {
      const o = origin(respond);
      const res = await handleStatus(req(`?key=${KEY}&format=json`), makeEnv({ ORIGIN: o.ORIGIN, STATUS_KEY: KEY }), NOW);
      const body = (await res.json()) as Record<string, unknown>;
      expect(body.reachable).toBe(false);
      expect(body.ok).toBe(false);
    }
  });

  it("works in Access mode too (the Worker doesn't gate it; Access may)", async () => {
    const o = origin(() => jsonReply(STATUS));
    const env = makeEnv({ ORIGIN: o.ORIGIN, STATUS_KEY: KEY, AUTH_MODE: "access" });
    expect((await worker.fetch(req(`?key=${KEY}`), env, ctx)).status).toBe(200);
  });
});

describe("summarize / ago", () => {
  it("ignores junk", () => {
    expect(summarize({ google: { connected: "yes" }, freshness: { google: { latest_received_ms: -1 } } }, 1)).toMatchObject({
      connected: null,
      newest_text_ms: null,
    });
  });
  it("formats ages", () => {
    expect(ago(10_000)).toBe("just now");
    expect(ago(5 * 60000)).toBe("5 min ago");
    expect(ago(60 * 60000)).toBe("1 hour ago");
    expect(ago(3 * 86400000)).toBe("3 days ago");
  });
});
