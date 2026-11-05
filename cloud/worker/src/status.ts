import type { Env } from "./env";

/**
 * GET /status?key=<STATUS_KEY>: a status-only page for the operator, so they
 * can check a client's connection without any access to the client's
 * accounts. It shows whether Google Messages is connected and how long ago
 * the newest text arrived. Never message text, names or numbers.
 *
 * Off unless the STATUS_KEY secret is set (at least 24 characters). A wrong
 * or missing key gets the same 404 as an unknown path. In Access mode,
 * Cloudflare Access guards the whole hostname, so /status needs a Bypass
 * policy for that path there.
 */
export const STATUS_PATH = "/status";
const ORIGIN_STATUS_URL = "http://127.0.0.1:7007/api/status";
const MIN_KEY_LENGTH = 24;

export interface StatusSummary {
  reachable: boolean;
  connected: boolean | null;
  needs_pairing: boolean | null;
  newest_text_ms: number | null;
  quieter_than_usual: boolean | null;
  checked_ms: number;
}

async function sameKey(a: string, b: string): Promise<boolean> {
  const enc = new TextEncoder();
  const [x, y] = await Promise.all([
    crypto.subtle.digest("SHA-256", enc.encode(a)),
    crypto.subtle.digest("SHA-256", enc.encode(b)),
  ]);
  const u = new Uint8Array(x), v = new Uint8Array(y);
  let diff = 0;
  for (let i = 0; i < u.length; i++) diff |= (u[i] ?? 0) ^ (v[i] ?? 0);
  return diff === 0;
}

export async function statusKeyOk(request: Request, env: Pick<Env, "STATUS_KEY">): Promise<boolean> {
  const want = (env.STATUS_KEY ?? "").trim();
  if (want.length < MIN_KEY_LENGTH) return false;
  const got = new URL(request.url).searchParams.get("key") ?? "";
  return sameKey(got, want);
}

const num = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) && v > 0 ? v : null);
const bool = (v: unknown): boolean | null => (typeof v === "boolean" ? v : null);

/** Keeps only the status fields; everything else in /api/status is dropped. */
export function summarize(status: unknown, now: number): StatusSummary {
  const s = (status ?? {}) as Record<string, any>;
  const google = (s.google ?? {}) as Record<string, any>;
  const fresh = (s.freshness?.google ?? {}) as Record<string, any>;
  return {
    reachable: true,
    connected: bool(google.connected),
    needs_pairing: bool(google.needs_pairing),
    newest_text_ms: num(fresh.latest_received_ms),
    quieter_than_usual: bool(fresh.silence?.stalled),
    checked_ms: now,
  };
}

export function ago(ms: number): string {
  const m = Math.max(0, Math.round(ms / 60000));
  if (m < 1) return "just now";
  if (m < 60) return `${m} min ago`;
  const h = Math.round(m / 60);
  if (h < 48) return `${h} hour${h === 1 ? "" : "s"} ago`;
  return `${Math.round(h / 24)} days ago`;
}

function verdict(s: StatusSummary): { ok: boolean; line: string } {
  if (!s.reachable) return { ok: false, line: "Not answering. The server or its tunnel is down." };
  if (s.needs_pairing) return { ok: false, line: "Needs reconnecting (Google signed it out)." };
  if (s.connected === false) return { ok: false, line: "Disconnected from Google Messages." };
  if (s.connected === true) return { ok: true, line: "Connected." };
  return { ok: false, line: "Running, but its Google state is unknown." };
}

function page(s: StatusSummary): string {
  const v = verdict(s);
  const newest = s.newest_text_ms ? `Newest text received ${ago(s.checked_ms - s.newest_text_ms)}.` : "";
  const quiet = s.quieter_than_usual ? " That's quieter than usual." : "";
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex"><title>Texts status</title>
<style>body{font:18px/1.5 system-ui,sans-serif;max-width:30rem;margin:2rem 16px}.s{font-size:1.4em;font-weight:600;color:${v.ok ? "#1a7f37" : "#b42318"}}small{color:#666}</style>
</head><body>
<p class="s">${v.ok ? "✓" : "✗"} ${v.line}</p>
<p>${newest}${quiet}</p>
<p><small>Status only: no messages, names or numbers. Checked ${new Date(s.checked_ms).toISOString().replace("T", " ").slice(0, 16)} UTC.</small></p>
</body></html>`;
}

const headers = (type: string) => ({
  "Content-Type": type,
  "Cache-Control": "no-store",
  "X-Robots-Tag": "noindex",
  "Referrer-Policy": "no-referrer",
});

export async function handleStatus(request: Request, env: Env, now = Date.now()): Promise<Response> {
  if (request.method !== "GET" || !(await statusKeyOk(request, env))) {
    return new Response("Not found", { status: 404, headers: headers("text/plain; charset=utf-8") });
  }
  let summary: StatusSummary;
  try {
    const up = await env.ORIGIN.fetch(ORIGIN_STATUS_URL, { method: "GET", headers: { Accept: "application/json" } });
    summary = up.ok ? summarize(await up.json(), now) : { ...summarize(null, now), reachable: false };
  } catch {
    summary = { ...summarize(null, now), reachable: false };
  }
  const wantsJson = new URL(request.url).searchParams.get("format") === "json";
  if (wantsJson) {
    return new Response(JSON.stringify({ ...summary, ok: verdict(summary).ok }), { status: 200, headers: headers("application/json") });
  }
  return new Response(page(summary), { status: 200, headers: headers("text/html; charset=utf-8") });
}
