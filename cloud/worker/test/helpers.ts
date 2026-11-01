import { vi } from "vitest";
import type { Env } from "../src/env";

export const PUBLIC_URL = "https://connector.test";
export const ALLOWED = "owner@example.com";

export function makeEnv(overrides: Partial<Env> = {}): Env {
  return {
    PUBLIC_URL,
    // Stand-in VPC binding: goes through global fetch, which tests stub.
    ORIGIN: { fetch: (input: RequestInfo | URL, init?: RequestInit) => fetch(input, init) } as unknown as Fetcher,
    ALLOWED_EMAIL: ALLOWED,
    GOOGLE_CLIENT_ID: "test-google-client-id",
    GOOGLE_CLIENT_SECRET: "test-google-client-secret",
    ...overrides,
  } as Env;
}

export interface Seen {
  url: string;
  method: string;
  headers: Headers;
  body: string;
}

/** A fetch stand-in for the origin: records each call and answers with `respond`. */
export function mockUpstream(respond: (seen: Seen) => Response | Promise<Response>) {
  const calls: Seen[] = [];
  const fetchImpl = vi.fn(async (input: string, init: RequestInit) => {
    const seen: Seen = {
      url: input,
      method: String(init.method),
      headers: new Headers(init.headers),
      body: typeof init.body === "string" ? init.body : "",
    };
    calls.push(seen);
    return respond(seen);
  });
  return { calls, fetchImpl };
}

export function jsonReply(body: unknown, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { "Content-Type": "application/json", ...headers },
  });
}

export function post(body: unknown, headers: Record<string, string> = {}): Request {
  return new Request(`${PUBLIC_URL}/mcp`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Accept: "application/json, text/event-stream", ...headers },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

export function rpc(method: string, params?: unknown, id: number | string = 1) {
  return { jsonrpc: "2.0", id, method, ...(params === undefined ? {} : { params }) };
}

export function sseStream(chunks: string[]): ReadableStream<Uint8Array> {
  const enc = new TextEncoder();
  return new ReadableStream({
    start(controller) {
      for (const c of chunks) controller.enqueue(enc.encode(c));
      controller.close();
    },
  });
}

export const TOOLS_FIXTURE = [
  { name: "search_messages", description: "search" },
  { name: "send_message", description: "send" },
  { name: "get_status", description: "status" },
  { name: "draft_message", description: "draft" },
  { name: "list_conversations", description: "list" },
  { name: "import_messages", description: "import" },
];
export const VISIBLE_TOOLS = ["search_messages", "get_status", "list_conversations"];
