import { describe, expect, it } from "vitest";
import { ALLOWED_TOOLS } from "../src/allowlist";
import { MAX_BODY_BYTES, handleMcp } from "../src/proxy";
import readonlyRaw from "../readonly-tools.json?raw";
import {
  TOOLS_FIXTURE,
  VISIBLE_TOOLS,
  jsonReply,
  makeEnv,
  mockUpstream,
  post,
  rpc,
  sseStream,
} from "./helpers";

const env = makeEnv();
const ok = () => jsonReply({ jsonrpc: "2.0", id: 1, result: {} });

describe("allowlist source", () => {
  it("is exactly readonly-tools.json", () => {
    const file = (JSON.parse(readonlyRaw) as { tools: string[] }).tools;
    expect([...ALLOWED_TOOLS].sort()).toEqual([...file].sort());
    expect(file.length).toBeGreaterThan(0);
  });
  it("holds no write tools", () => {
    for (const bad of ["send_message", "draft_message", "import_messages", "download_media", "generate_viz"]) {
      expect(ALLOWED_TOOLS.has(bad)).toBe(false);
    }
  });
});

describe("method allowlist", () => {
  for (const method of ["initialize", "ping", "tools/list", "notifications/initialized", "notifications/cancelled"]) {
    it(`forwards ${method}`, async () => {
      const up = mockUpstream(ok);
      const res = await handleMcp(post(rpc(method)), env, up.fetchImpl);
      expect(res.status).toBe(200);
      expect(up.calls).toHaveLength(1);
    });
  }
  for (const method of [
    "resources/read",
    "resources/list",
    "prompts/get",
    "completion/complete",
    "logging/setLevel",
    "sampling/createMessage",
    "tasks/get",
    "Tools/list",
    "tools/call/",
    "notification/initialized",
    "",
  ]) {
    it(`refuses ${JSON.stringify(method)} with -32601 and no forward`, async () => {
      const up = mockUpstream(ok);
      const res = await handleMcp(post(rpc(method, {}, 7)), env, up.fetchImpl);
      const body = (await res.json()) as { id: number; error: { code: number } };
      expect(body.id).toBe(7);
      expect(body.error.code).toBe(-32601);
      expect(up.calls).toHaveLength(0);
    });
  }
  it("refuses a message with no method (a client response)", async () => {
    const up = mockUpstream(ok);
    const res = await handleMcp(post({ jsonrpc: "2.0", id: 3, result: {} }), env, up.fetchImpl);
    expect(((await res.json()) as { error: { code: number } }).error.code).toBe(-32600);
    expect(up.calls).toHaveLength(0);
  });
  it("answers PUT and PATCH with 405", async () => {
    const up = mockUpstream(ok);
    for (const method of ["PUT", "PATCH", "OPTIONS"]) {
      const res = await handleMcp(new Request(`${env.PUBLIC_URL}/mcp`, { method, body: method === "OPTIONS" ? null : "{}" }), env, up.fetchImpl);
      expect(res.status).toBe(405);
    }
    expect(up.calls).toHaveLength(0);
  });
  it("forwards GET and DELETE", async () => {
    const up = mockUpstream(() => new Response(null, { status: 202 }));
    for (const method of ["GET", "DELETE"]) {
      await handleMcp(new Request(`${env.PUBLIC_URL}/mcp`, { method, headers: { "Mcp-Session-Id": "s1" } }), env, up.fetchImpl);
    }
    expect(up.calls.map((c) => c.method)).toEqual(["GET", "DELETE"]);
    expect(up.calls[0]!.url).toBe("https://tunnel.test/mcp");
    expect(up.calls[0]!.headers.get("mcp-session-id")).toBe("s1");
  });
  it("answers any other path with 404", async () => {
    const up = mockUpstream(ok);
    const res = await handleMcp(new Request(`${env.PUBLIC_URL}/mcp/x`, { method: "POST", body: "{}" }), env, up.fetchImpl);
    expect(res.status).toBe(404);
    expect(up.calls).toHaveLength(0);
  });
});

describe("tool allowlist on tools/call", () => {
  for (const name of ALLOWED_TOOLS) {
    it(`passes ${name}`, async () => {
      const up = mockUpstream(ok);
      await handleMcp(post(rpc("tools/call", { name, arguments: { query: "hi" } })), env, up.fetchImpl);
      expect(up.calls).toHaveLength(1);
      expect(JSON.parse(up.calls[0]!.body).params.arguments).toEqual({ query: "hi" });
    });
  }
  for (const name of ["send_message", "draft_message", "import_messages", "", "SEARCH_MESSAGES", "search_messages "]) {
    it(`rejects ${JSON.stringify(name)}`, async () => {
      const up = mockUpstream(ok);
      const res = await handleMcp(post(rpc("tools/call", { name }, 9)), env, up.fetchImpl);
      expect(await res.json()).toEqual({ jsonrpc: "2.0", id: 9, error: { code: -32602, message: "tool not allowed" } });
      expect(up.calls).toHaveLength(0);
    });
  }
  it("rejects a missing or non-string name", async () => {
    const up = mockUpstream(ok);
    for (const params of [undefined, {}, { name: 5 }, { name: ["send_message"] }, "send_message", null]) {
      const res = await handleMcp(post(rpc("tools/call", params)), env, up.fetchImpl);
      expect(((await res.json()) as { error: { code: number } }).error.code).toBe(-32602);
    }
    expect(up.calls).toHaveLength(0);
  });
  it("rejects the whole batch when one call is bad", async () => {
    const up = mockUpstream(ok);
    const batch = [
      rpc("tools/call", { name: "search_messages", arguments: {} }, 1),
      rpc("tools/call", { name: "send_message", arguments: {} }, 2),
      rpc("ping", undefined, 3),
    ];
    const res = await handleMcp(post(batch), env, up.fetchImpl);
    const body = (await res.json()) as { id: number; error: { code: number; message: string } }[];
    expect(up.calls).toHaveLength(0);
    expect(body.find((b) => b.id === 2)!.error).toEqual({ code: -32602, message: "tool not allowed" });
    expect(body.find((b) => b.id === 1)!.error.message).toBe("Batch rejected");
  });
  it("forwards a clean batch", async () => {
    const up = mockUpstream(() => jsonReply([]));
    await handleMcp(post([rpc("ping", undefined, 1), rpc("tools/call", { name: "get_status" }, 2)]), env, up.fetchImpl);
    expect(up.calls).toHaveLength(1);
    expect(JSON.parse(up.calls[0]!.body)).toHaveLength(2);
  });
  it("answers 202 and forwards nothing for a refused notification", async () => {
    const up = mockUpstream(ok);
    const res = await handleMcp(post({ jsonrpc: "2.0", method: "tools/call", params: { name: "send_message" } }), env, up.fetchImpl);
    expect(res.status).toBe(202);
    expect(up.calls).toHaveLength(0);
  });
});

describe("key tricks that a case-folding JSON decoder would honor", () => {
  const cases: [string, string][] = [
    ["capitalized Method", '{"jsonrpc":"2.0","id":1,"method":"ping","Method":"tools/call","params":{"name":"send_message"}}'],
    ["long-s paramſ", '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_status"},"paramſ":{"name":"send_message"}}'],
    ["capitalized Name in params", '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_status","Name":"send_message"}}'],
    ["__proto__ key", '{"jsonrpc":"2.0","id":1,"method":"ping","__proto__":{"method":"tools/call"}}'],
    ["extra top-level key", '{"jsonrpc":"2.0","id":1,"method":"ping","extra":1}'],
  ];
  for (const [label, body] of cases) {
    it(`refuses ${label}`, async () => {
      const up = mockUpstream(ok);
      const res = await handleMcp(post(body), env, up.fetchImpl);
      expect(((await res.json()) as { error?: unknown }).error).toBeDefined();
      expect(up.calls).toHaveLength(0);
    });
  }
  it("forwards the rebuilt message, not the client's bytes", async () => {
    const up = mockUpstream(ok);
    await handleMcp(post('{"id":1,"id":2,"method":"ping","jsonrpc":"2.0"}'), env, up.fetchImpl);
    expect(up.calls[0]!.body).toBe('{"jsonrpc":"2.0","id":2,"method":"ping"}');
  });
});

describe("headers", () => {
  it("drops everything but the allowlist and adds the Access token", async () => {
    const up = mockUpstream(ok);
    const req = post(rpc("ping"), {
      Authorization: "Bearer claude-token",
      Cookie: "a=b",
      Origin: "https://claude.ai",
      Referer: "https://claude.ai/x",
      "CF-Connecting-IP": "1.2.3.4",
      "CF-Access-Client-Id": "evil",
      "CF-Access-Jwt-Assertion": "evil",
      "X-Forwarded-For": "1.2.3.4",
      "Mcp-Session-Id": "sess-1",
      "MCP-Protocol-Version": "2025-06-18",
      "Last-Event-ID": "42",
    });
    await handleMcp(req, env, up.fetchImpl);
    const h = up.calls[0]!.headers;
    for (const name of ["authorization", "cookie", "origin", "referer", "cf-connecting-ip", "cf-access-jwt-assertion", "x-forwarded-for"]) {
      expect(h.has(name)).toBe(false);
    }
    expect(h.get("cf-access-client-id")).toBe("test-access-id");
    expect(h.get("cf-access-client-secret")).toBe("test-access-secret");
    expect(h.get("mcp-session-id")).toBe("sess-1");
    expect(h.get("mcp-protocol-version")).toBe("2025-06-18");
    expect(h.get("last-event-id")).toBe("42");
    expect(h.get("content-type")).toBe("application/json");
    expect(h.get("accept")).toContain("text/event-stream");
    expect([...h.keys()].sort()).toEqual(
      ["accept", "cf-access-client-id", "cf-access-client-secret", "content-type", "last-event-id", "mcp-protocol-version", "mcp-session-id"],
    );
  });
  it("returns only Mcp-Session-Id and Content-Type from the origin", async () => {
    const up = mockUpstream(() =>
      jsonReply({ jsonrpc: "2.0", id: 1, result: {} }, { "Mcp-Session-Id": "abc", "Set-Cookie": "x=y", "X-Secret": "1" }),
    );
    const res = await handleMcp(post(rpc("ping")), env, up.fetchImpl);
    expect(res.headers.get("mcp-session-id")).toBe("abc");
    expect(res.headers.get("content-type")).toBe("application/json");
    expect(res.headers.has("set-cookie")).toBe(false);
    expect(res.headers.has("x-secret")).toBe(false);
  });
});

describe("body limit and JSON", () => {
  it("accepts a body at the limit and refuses one byte over", async () => {
    const up = mockUpstream(ok);
    const base = JSON.stringify(rpc("ping", { pad: "" }));
    const fill = (n: number) => JSON.stringify(rpc("ping", { pad: "x".repeat(n) }));
    const room = MAX_BODY_BYTES - (base.length);
    const atLimit = fill(room);
    expect(new TextEncoder().encode(atLimit).length).toBe(MAX_BODY_BYTES);
    expect((await handleMcp(post(atLimit), env, up.fetchImpl)).status).toBe(200);
    const over = fill(room + 1);
    expect((await handleMcp(post(over), env, up.fetchImpl)).status).toBe(413);
    expect(up.calls).toHaveLength(1);
  });
  it("refuses an oversized body with no Content-Length (chunked)", async () => {
    const up = mockUpstream(ok);
    const big = new Uint8Array(MAX_BODY_BYTES + 10).fill(32);
    const stream = new ReadableStream<Uint8Array>({
      start(c) {
        c.enqueue(big.slice(0, 1000));
        c.enqueue(big.slice(1000));
        c.close();
      },
    });
    const req = new Request(`${env.PUBLIC_URL}/mcp`, { method: "POST", body: stream, duplex: "half" } as RequestInit);
    expect((await handleMcp(req, env, up.fetchImpl)).status).toBe(413);
    expect(up.calls).toHaveLength(0);
  });
  it("refuses a large declared Content-Length without reading", async () => {
    const up = mockUpstream(ok);
    const req = post("{}", { "Content-Length": String(MAX_BODY_BYTES + 1) });
    expect((await handleMcp(req, env, up.fetchImpl)).status).toBe(413);
  });
  it("answers 400 for invalid JSON, bad UTF-8, primitives and empty batches", async () => {
    const up = mockUpstream(ok);
    for (const body of ["{nope", "", "123", '"x"', "null", "[]"]) {
      expect((await handleMcp(post(body), env, up.fetchImpl)).status).toBe(400);
    }
    const bad = new Request(`${env.PUBLIC_URL}/mcp`, { method: "POST", body: new Uint8Array([0x7b, 0xff, 0x7d]) });
    expect((await handleMcp(bad, env, up.fetchImpl)).status).toBe(400);
    expect(up.calls).toHaveLength(0);
  });
});

describe("tools/list filtering", () => {
  const listBody = (id: number | string = 1) => ({ jsonrpc: "2.0", id, result: { tools: TOOLS_FIXTURE } });
  const names = (tools: { name: string }[]) => tools.map((t) => t.name).sort();

  it("filters a JSON response", async () => {
    const up = mockUpstream(() => jsonReply(listBody(), { "Mcp-Session-Id": "s" }));
    const res = await handleMcp(post(rpc("tools/list")), env, up.fetchImpl);
    const body = (await res.json()) as { result: { tools: { name: string }[] } };
    expect(names(body.result.tools)).toEqual([...VISIBLE_TOOLS].sort());
    expect(res.headers.get("mcp-session-id")).toBe("s");
  });
  it("filters a batched JSON response by id", async () => {
    const up = mockUpstream(() => jsonReply([{ jsonrpc: "2.0", id: 2, result: {} }, listBody(1)]));
    const res = await handleMcp(post([rpc("tools/list", undefined, 1), rpc("ping", undefined, 2)]), env, up.fetchImpl);
    const body = (await res.json()) as { id: number; result: { tools?: { name: string }[] } }[];
    expect(names(body.find((b) => b.id === 1)!.result.tools!)).toEqual([...VISIBLE_TOOLS].sort());
  });
  it("fails closed when a tools/list result has no tools array", async () => {
    const up = mockUpstream(() => jsonReply({ jsonrpc: "2.0", id: 1, result: { tools: "oops" } }));
    const res = await handleMcp(post(rpc("tools/list")), env, up.fetchImpl);
    expect(((await res.json()) as { result: { tools: unknown[] } }).result.tools).toEqual([]);
  });
  it("answers 502 when a tools/list reply is not JSON", async () => {
    const up = mockUpstream(() => new Response("<html>nope", { headers: { "Content-Type": "application/json" } }));
    expect((await handleMcp(post(rpc("tools/list")), env, up.fetchImpl)).status).toBe(502);
  });

  const sseEvent = (payload: unknown, extra = "") => `${extra}event: message\ndata: ${JSON.stringify(payload)}\n\n`;
  const sseUp = (chunks: string[]) =>
    mockUpstream(() => new Response(sseStream(chunks), { headers: { "Content-Type": "text/event-stream", "Mcp-Session-Id": "s" } }));
  const eventPayloads = (text: string) =>
    text
      .split(/\r?\n\r?\n/)
      .filter(Boolean)
      .map((e) => JSON.parse(e.split(/\r?\n/).find((l) => l.startsWith("data:"))!.slice(5).trim()));

  it("filters an SSE response and keeps other events as they were", async () => {
    const progress = { jsonrpc: "2.0", method: "notifications/progress", params: { progress: 1 } };
    const text = sseEvent(progress) + sseEvent(listBody(), "id: 5\n");
    const up = sseUp([text]);
    const res = await handleMcp(post(rpc("tools/list")), env, up.fetchImpl);
    const out = await res.text();
    expect(out.startsWith(sseEvent(progress))).toBe(true); // byte for byte
    expect(out).toContain("id: 5\nevent: message\ndata: ");
    const payloads = eventPayloads(out);
    expect(names(payloads[1].result.tools)).toEqual([...VISIBLE_TOOLS].sort());
    expect(res.headers.get("content-type")).toBe("text/event-stream");
  });
  it("filters an SSE response split across chunks, down to single bytes", async () => {
    const text = sseEvent({ jsonrpc: "2.0", method: "notifications/message", params: {} }) + sseEvent(listBody());
    const bytes = new TextEncoder().encode(text);
    const tiny = Array.from(bytes, (b) => String.fromCharCode(b)); // ASCII only
    for (const chunks of [tiny, [text.slice(0, 30), text.slice(30, 90), text.slice(90)]]) {
      const up = sseUp(chunks);
      const res = await handleMcp(post(rpc("tools/list")), env, up.fetchImpl);
      const payloads = eventPayloads(await res.text());
      expect(payloads).toHaveLength(2);
      expect(names(payloads[1].result.tools)).toEqual([...VISIBLE_TOOLS].sort());
    }
  });
  it("handles CRLF framing and a multi-byte character split between chunks", async () => {
    const payload = listBody();
    (payload.result.tools[0] as { description: string }).description = "café \u{1F4AC}";
    const text = `event: message\r\ndata: ${JSON.stringify(payload)}\r\n\r\n`;
    const bytes = new TextEncoder().encode(text);
    const cut = bytes.indexOf(0xc3) + 1; // inside the two-byte e-acute
    const stream = new ReadableStream<Uint8Array>({
      start(c) {
        c.enqueue(bytes.slice(0, cut));
        c.enqueue(bytes.slice(cut));
        c.close();
      },
    });
    const up = mockUpstream(() => new Response(stream, { headers: { "Content-Type": "text/event-stream" } }));
    const res = await handleMcp(post(rpc("tools/list")), env, up.fetchImpl);
    const out = await res.text();
    const tools = eventPayloads(out)[0].result.tools as { name: string; description: string }[];
    expect(names(tools)).toEqual([...VISIBLE_TOOLS].sort());
    expect(tools[0]!.description).toBe("café \u{1F4AC}");
  });
  it("matches by request id and leaves a tools/call stream alone", async () => {
    const reply = sseEvent({ jsonrpc: "2.0", id: 1, result: { content: [{ type: "text", text: "send_message tools" }] } });
    const up = sseUp([reply]);
    const res = await handleMcp(post(rpc("tools/call", { name: "get_status" })), env, up.fetchImpl);
    expect(await res.text()).toBe(reply);
  });
  it("drops an uninspectable data event while a tools/list is in flight", async () => {
    const up = sseUp(["data: not json\n\n", sseEvent(listBody())]);
    const res = await handleMcp(post(rpc("tools/list")), env, up.fetchImpl);
    const out = await res.text();
    expect(out).not.toContain("not json");
    expect(eventPayloads(out)).toHaveLength(1);
  });
});

describe("upstream errors", () => {
  it("answers 502 without echoing the origin body", async () => {
    for (const status of [401, 403, 500, 502, 503]) {
      const up = mockUpstream(() => new Response("SECRET-ORIGIN-DETAIL cf-access token invalid", { status }));
      const res = await handleMcp(post(rpc("ping")), env, up.fetchImpl);
      expect(res.status).toBe(502);
      expect(await res.text()).not.toContain("SECRET");
    }
  });
  it("does not follow a redirect (an Access login page)", async () => {
    const up = mockUpstream(() => new Response(null, { status: 302, headers: { Location: "https://login.example/x" } }));
    const res = await handleMcp(post(rpc("ping")), env, up.fetchImpl);
    expect(res.status).toBe(502);
    expect(res.headers.has("location")).toBe(false);
  });
  it("answers 502 when the fetch throws or the config is missing", async () => {
    const boom = mockUpstream(() => {
      throw new Error("connect refused 10.0.0.1");
    });
    const res = await handleMcp(post(rpc("ping")), env, boom.fetchImpl);
    expect(res.status).toBe(502);
    expect(await res.text()).not.toContain("10.0.0.1");
    const none = mockUpstream(ok);
    expect((await handleMcp(post(rpc("ping")), makeEnv({ CF_ACCESS_CLIENT_SECRET: "" }), none.fetchImpl)).status).toBe(502);
    expect(none.calls).toHaveLength(0);
  });
  it("passes 404 through as a generic body so clients start a new session", async () => {
    const up = mockUpstream(() => new Response("session abc not found in store", { status: 404 }));
    const res = await handleMcp(post(rpc("ping")), env, up.fetchImpl);
    expect(res.status).toBe(404);
    expect(await res.text()).not.toContain("abc");
  });
});
