import { ALLOWED_TOOLS, isMethodAllowed } from "./allowlist";
import type { Env } from "./env";
import { parseEvent, rebuildEvent, sseTransform } from "./sse";

export const MAX_BODY_BYTES = 1024 * 1024; // 1 MiB
const MAX_JSON_RESPONSE_BYTES = 4 * 1024 * 1024;

/** The only request headers that reach the origin. Everything else is dropped. */
const FORWARD_REQUEST_HEADERS = ["content-type", "accept", "mcp-session-id", "mcp-protocol-version", "last-event-id"];

const TOP_LEVEL_KEYS = new Set(["jsonrpc", "id", "method", "params"]);
const TOOL_CALL_PARAM_KEYS = new Set(["name", "arguments", "_meta"]);

type RpcId = string | number;
type FetchLike = (input: string, init: RequestInit) => Promise<Response>;

interface Rejection {
  id: RpcId | null;
  hasId: boolean;
  code: number;
  message: string;
}

type Screened = { ok: true; message: Record<string, unknown>; toolsListId?: RpcId } | ({ ok: false } & Rejection);

function isPlainObject(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

function idKey(id: RpcId): string {
  return `${typeof id}:${id}`;
}

function rpcError(id: RpcId | null, code: number, message: string): Record<string, unknown> {
  return { jsonrpc: "2.0", id, error: { code, message } };
}

function jsonResponse(body: unknown, status: number, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store", ...extra },
  });
}

/**
 * Check one JSON-RPC message and rebuild it from the fields we validated.
 *
 * The origin is a Go server whose JSON decoder matches object keys without
 * regard to case (and folds a few Unicode characters, such as the long s).
 * A message like {"method":"ping","Method":"tools/call"} would pass a
 * case-sensitive check here and run as tools/call there. So any message with
 * a key outside the four JSON-RPC names is refused, tools/call params are held
 * to name/arguments/_meta, and what we forward is the rebuilt message, not the
 * client's bytes.
 */
function screenMessage(raw: unknown): Screened {
  if (!isPlainObject(raw)) return { ok: false, id: null, hasId: false, code: -32600, message: "Invalid Request" };
  const hasId = Object.hasOwn(raw, "id");
  const rawId = raw["id"];
  const idValid = typeof rawId === "string" || (typeof rawId === "number" && Number.isFinite(rawId));
  const id: RpcId | null = idValid ? (rawId as RpcId) : null;
  const reject = (code: number, message: string): Screened => ({ ok: false, id, hasId: hasId && idValid, code, message });

  if (hasId && !idValid) return reject(-32600, "Invalid Request");
  for (const key of Object.keys(raw)) {
    if (!TOP_LEVEL_KEYS.has(key)) return reject(-32600, "Invalid Request");
  }
  const method = raw["method"];
  if (typeof method !== "string") return reject(-32600, "Invalid Request");
  if (!isMethodAllowed(method)) return reject(-32601, "Method not found");

  const params = raw["params"];
  if (method === "tools/call") {
    if (!isPlainObject(params)) return reject(-32602, "tool not allowed");
    for (const key of Object.keys(params)) {
      if (!TOOL_CALL_PARAM_KEYS.has(key)) return reject(-32602, "Invalid params");
    }
    const name = params["name"];
    if (typeof name !== "string" || !ALLOWED_TOOLS.has(name)) return reject(-32602, "tool not allowed");
  }

  const message: Record<string, unknown> = { jsonrpc: "2.0" };
  if (hasId) message["id"] = id;
  message["method"] = method;
  if (params !== undefined) message["params"] = params;
  return method === "tools/list" && idValid ? { ok: true, message, toolsListId: id as RpcId } : { ok: true, message };
}

/** Read a request body, giving up (null) once it passes the limit. */
async function readLimited(request: Request, limit: number): Promise<Uint8Array | null> {
  const declared = request.headers.get("content-length");
  if (declared !== null && Number(declared) > limit) return null;
  if (!request.body) return new Uint8Array(0);
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > limit) {
      await reader.cancel().catch(() => {});
      return null;
    }
    chunks.push(value);
  }
  const out = new Uint8Array(total);
  let offset = 0;
  for (const c of chunks) {
    out.set(c, offset);
    offset += c.byteLength;
  }
  return out;
}

/** Remove disallowed tools from a tools/list result. Matched by request id, or by shape. */
function filterPayload(payload: unknown, ids: Set<string>): { value: unknown; changed: boolean } {
  if (Array.isArray(payload)) {
    let changed = false;
    const value = payload.map((item) => {
      const r = filterPayload(item, ids);
      changed ||= r.changed;
      return r.value;
    });
    return { value, changed };
  }
  if (!isPlainObject(payload)) return { value: payload, changed: false };
  const result = payload["result"];
  if (!isPlainObject(result)) return { value: payload, changed: false };
  const rid = payload["id"];
  const idMatch = (typeof rid === "string" || typeof rid === "number") && ids.has(idKey(rid));
  const isList = Array.isArray(result["tools"]);
  if (!idMatch && !isList) return { value: payload, changed: false };
  const tools = isList
    ? (result["tools"] as unknown[]).filter((t) => isPlainObject(t) && typeof t["name"] === "string" && ALLOWED_TOOLS.has(t["name"]))
    : []; // matched a tools/list id but the shape is wrong: fail closed
  const changed = !isList || tools.length !== (result["tools"] as unknown[]).length;
  if (!changed) return { value: payload, changed: false };
  return { value: { ...payload, result: { ...result, tools } }, changed: true };
}

function rewriteSseEvent(raw: string, ids: Set<string>): string {
  const parsed = parseEvent(raw);
  if (!parsed) return raw;
  let payload: unknown;
  try {
    payload = JSON.parse(parsed.data);
  } catch {
    return ""; // cannot inspect it while a tools/list is in flight: drop
  }
  const { value, changed } = filterPayload(payload, ids);
  return changed ? rebuildEvent(parsed, JSON.stringify(value)) : raw;
}

function upstreamHeaders(request: Request, env: Env): Headers {
  const headers = new Headers();
  for (const name of FORWARD_REQUEST_HEADERS) {
    const v = request.headers.get(name);
    if (v !== null) headers.set(name, v);
  }
  headers.set("CF-Access-Client-Id", env.CF_ACCESS_CLIENT_ID);
  headers.set("CF-Access-Client-Secret", env.CF_ACCESS_CLIENT_SECRET);
  return headers;
}

function responseHeaders(up: Response, contentType: boolean): Headers {
  const h = new Headers({ "Cache-Control": "no-store" });
  const session = up.headers.get("mcp-session-id");
  if (session !== null) h.set("Mcp-Session-Id", session);
  const ct = up.headers.get("content-type");
  if (contentType && ct !== null) h.set("Content-Type", ct);
  return h;
}

function badGateway(): Response {
  return jsonResponse(rpcError(null, -32000, "Upstream unavailable"), 502);
}

/** Answer for a POST the filter refused: JSON-RPC errors, nothing forwarded. */
function rejectionResponse(screened: Screened[], isBatch: boolean): Response {
  const errors: Record<string, unknown>[] = [];
  for (const s of screened) {
    if (s.ok) {
      if (isBatch && "id" in s.message) errors.push(rpcError(s.message["id"] as RpcId, -32600, "Batch rejected"));
    } else if (s.hasId) {
      errors.push(rpcError(s.id, s.code, s.message));
    } else if (!isBatch && s.code === -32600) {
      errors.push(rpcError(null, s.code, s.message));
    }
  }
  if (errors.length === 0) return new Response(null, { status: 202 }); // only notifications refused
  return jsonResponse(isBatch ? errors : errors[0], 200);
}

export async function handleMcp(
  request: Request,
  env: Env,
  fetchImpl: FetchLike = (input, init) => fetch(input, init),
): Promise<Response> {
  const url = new URL(request.url);
  if (url.pathname !== "/mcp") return new Response("Not found", { status: 404 });

  const method = request.method.toUpperCase();
  if (method !== "POST" && method !== "GET" && method !== "DELETE") {
    return new Response("Method not allowed", { status: 405, headers: { Allow: "POST, GET, DELETE" } });
  }

  let body: string | undefined;
  const toolsListIds = new Set<string>();
  if (method === "POST") {
    const bytes = await readLimited(request, MAX_BODY_BYTES);
    if (bytes === null) return jsonResponse(rpcError(null, -32600, "Request too large"), 413);
    let parsed: unknown;
    try {
      parsed = JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes));
    } catch {
      return jsonResponse(rpcError(null, -32700, "Parse error"), 400);
    }
    const isBatch = Array.isArray(parsed);
    const items: unknown[] = Array.isArray(parsed) ? parsed : [parsed];
    if (isBatch ? items.length === 0 : !isPlainObject(parsed)) {
      return jsonResponse(rpcError(null, -32600, "Invalid Request"), 400);
    }
    const screened = items.map(screenMessage);
    if (screened.some((s) => !s.ok)) return rejectionResponse(screened, isBatch);
    const messages = screened.map((s) => (s as { ok: true; message: Record<string, unknown> }).message);
    for (const s of screened) {
      if (s.ok && s.toolsListId !== undefined) toolsListIds.add(idKey(s.toolsListId));
    }
    body = JSON.stringify(isBatch ? messages : messages[0]);
  }

  const hasToolsList = toolsListIds.size > 0;
  if (!env.ORIGIN_URL || !env.CF_ACCESS_CLIENT_ID || !env.CF_ACCESS_CLIENT_SECRET) return badGateway();
  const headers = upstreamHeaders(request, env);
  if (body !== undefined && !headers.has("content-type")) headers.set("Content-Type", "application/json");

  let up: Response;
  try {
    up = await fetchImpl(`${env.ORIGIN_URL.replace(/\/+$/, "")}/mcp`, {
      method,
      headers,
      body,
      redirect: "manual",
    });
  } catch {
    return badGateway();
  }

  const status = up.status;
  if (status === 202 || status === 204) {
    await up.body?.cancel().catch(() => {});
    return new Response(null, { status, headers: responseHeaders(up, false) });
  }
  if (status === 400 || status === 404 || status === 405) {
    await up.body?.cancel().catch(() => {});
    const text = status === 404 ? "Session not found" : status === 405 ? "Method not allowed" : "Bad request";
    return jsonResponse(rpcError(null, -32000, text), status);
  }
  if (!up.ok) {
    await up.body?.cancel().catch(() => {});
    return badGateway();
  }

  const mime = (up.headers.get("content-type") ?? "").split(";")[0]!.trim().toLowerCase();
  if (!hasToolsList) {
    return new Response(up.body, { status, headers: responseHeaders(up, true) });
  }

  if (mime === "application/json") {
    try {
      const declared = Number(up.headers.get("content-length") ?? 0);
      if (declared > MAX_JSON_RESPONSE_BYTES) throw new Error("too large");
      const text = await up.text();
      if (text.length > MAX_JSON_RESPONSE_BYTES) throw new Error("too large");
      const { value } = filterPayload(JSON.parse(text), toolsListIds);
      return new Response(JSON.stringify(value), { status, headers: responseHeaders(up, true) });
    } catch {
      return badGateway();
    }
  }
  if (mime === "text/event-stream" && up.body) {
    const filtered = up.body.pipeThrough(sseTransform((raw) => rewriteSseEvent(raw, toolsListIds)));
    return new Response(filtered, { status, headers: responseHeaders(up, true) });
  }
  await up.body?.cancel().catch(() => {});
  return badGateway();
}
