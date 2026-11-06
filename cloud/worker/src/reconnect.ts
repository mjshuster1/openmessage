import { ACCESS_JWT_HEADER, accessConfig, verifyAccessJwt } from "./access";
import { isAllowedEmail, normalizeEmail } from "./auth";
import type { Env } from "./env";
import { handleSpam } from "./spam";

/**
 * The Reconnect page: lets the client re-pair Google Messages themselves,
 * with no operator access and no terminal.
 *
 *   GET  /reconnect            page (owner only: Google sign-in, or Access)
 *   GET  /reconnect/callback   Google sign-in return (Google mode)
 *   GET  /reconnect/state      connection + pairing state (owner session, or app token)
 *   POST /reconnect/upload     the Reconnect app sends the Google login (app token)
 *   /reconnect/spam...         the client's spam rules (spam.ts; same sign-in)
 *   POST /reconnect/server     restart, or go back a version (owner session, this page only)
 *
 * The page hands the client a short-lived "reconnect code" (the connector
 * URL plus an upload token signed with RECONNECT_SECRET, 20 minutes). The
 * Reconnect app on their computer reads it from the clipboard, opens a
 * throwaway Chrome for the Google sign-in, and posts the cookies to
 * /reconnect/upload, which passes them to the VM's om-pair-helper through
 * the PAIR binding. The page then shows the emoji to tap.
 *
 * Off unless RECONNECT_SECRET (32+ characters) and the PAIR binding are set.
 * Responses carry state only, never cookie values. In Access mode Access
 * guards the hostname: /reconnect is behind it (that is the sign-in), and
 * /reconnect/upload and /reconnect/state need a Bypass policy for the app.
 */
export const RECONNECT_PREFIX = "/reconnect";
const PAIR_URL = "http://127.0.0.1:7011/pair";
const SERVER_URL = "http://127.0.0.1:7011/server";
const ORIGIN_STATUS_URL = "http://127.0.0.1:7007/api/status";
const GOOGLE_AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth";
const GOOGLE_TOKEN_URL = "https://oauth2.googleapis.com/token";
const GOOGLE_USERINFO_URL = "https://openidconnect.googleapis.com/v1/userinfo";
const SESSION_COOKIE = "om_rc";
const LOGIN_COOKIE = "om_rc_login";
const SESSION_TTL_S = 30 * 60;
const UPLOAD_TTL_S = 20 * 60;
const LOGIN_TTL_S = 10 * 60;
const MAX_UPLOAD_BYTES = 64 * 1024;
const MIN_SECRET = 32;
export const CODE_PREFIX = "omrc1.";
const DEFAULT_DOWNLOAD = "https://github.com/mjshuster1/openmessage/releases/latest/download";

type Purpose = "session" | "upload" | "login";
interface Claims {
  p: Purpose;
  e?: string; // email
  x: number; // expiry, unix seconds
  n?: string; // nonce (login)
  v?: string; // PKCE verifier (login)
  f?: boolean; // force (upload)
  r?: string; // where to return after sign-in (login): a path under /reconnect
}

const enc = new TextEncoder();
const b64url = (bytes: Uint8Array) => {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
};
const fromB64url = (s: string) => {
  const t = s.replace(/-/g, "+").replace(/_/g, "/");
  const bin = atob(t + "=".repeat((4 - (t.length % 4)) % 4));
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
};

function secret(env: Pick<Env, "RECONNECT_SECRET">): string | null {
  const s = (env.RECONNECT_SECRET ?? "").trim();
  return s.length >= MIN_SECRET ? s : null;
}

async function hmac(key: string, data: string): Promise<Uint8Array> {
  const k = await crypto.subtle.importKey("raw", enc.encode(key), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return new Uint8Array(await crypto.subtle.sign("HMAC", k, enc.encode(data)));
}

export async function sign(env: Pick<Env, "RECONNECT_SECRET">, claims: Claims): Promise<string> {
  const key = secret(env);
  if (!key) throw new Error("RECONNECT_SECRET is not set");
  const body = b64url(enc.encode(JSON.stringify(claims)));
  return `${body}.${b64url(await hmac(key, `${claims.p}.${body}`))}`;
}

export async function verify(
  env: Pick<Env, "RECONNECT_SECRET">,
  token: string | null | undefined,
  purpose: Purpose,
  now = Date.now(),
): Promise<Claims | null> {
  const key = secret(env);
  if (!key || !token) return null;
  const [body, sig, extra] = token.split(".");
  if (!body || !sig || extra !== undefined) return null;
  let want: Uint8Array, got: Uint8Array;
  try {
    want = await hmac(key, `${purpose}.${body}`);
    got = fromB64url(sig);
  } catch {
    return null;
  }
  if (got.length !== want.length) return null;
  let diff = 0;
  for (let i = 0; i < want.length; i++) diff |= (want[i] ?? 0) ^ (got[i] ?? 0);
  if (diff !== 0) return null;
  let claims: Claims;
  try {
    claims = JSON.parse(new TextDecoder().decode(fromB64url(body))) as Claims;
  } catch {
    return null;
  }
  if (claims.p !== purpose || typeof claims.x !== "number" || claims.x * 1000 < now) return null;
  return claims;
}

function cookie(request: Request, name: string): string | null {
  for (const part of (request.headers.get("Cookie") ?? "").split(";")) {
    const [k, ...v] = part.trim().split("=");
    if (k === name) return v.join("=");
  }
  return null;
}

const setCookie = (name: string, value: string, maxAge: number, path = RECONNECT_PREFIX) =>
  `${name}=${value}; Path=${path}; Max-Age=${maxAge}; HttpOnly; Secure; SameSite=Lax`;

export const baseHeaders = (type: string): Record<string, string> => ({
  "Content-Type": type,
  "Cache-Control": "no-store",
  "X-Robots-Tag": "noindex",
  "Referrer-Policy": "no-referrer",
  "X-Frame-Options": "DENY",
});
export const json = (body: unknown, status = 200, extra: Record<string, string> = {}) =>
  new Response(JSON.stringify(body), { status, headers: { ...baseHeaders("application/json"), ...extra } });
export const plain = (body: string, status: number) => new Response(body, { status, headers: baseHeaders("text/plain; charset=utf-8") });

export const isAccess = (env: Env) => (env.AUTH_MODE ?? "google").trim().toLowerCase() === "access";

/** The signed-in owner's email for page requests, or null. */
export async function owner(request: Request, env: Env): Promise<string | null> {
  if (isAccess(env)) {
    const cfg = accessConfig(env);
    if (!cfg) return null;
    const check = await verifyAccessJwt(request.headers.get(ACCESS_JWT_HEADER), cfg, env);
    return check.ok ? check.email : null;
  }
  const claims = await verify(env, cookie(request, SESSION_COOKIE), "session");
  return claims?.e && isAllowedEmail(claims.e, env) ? claims.e : null;
}

async function pkce(): Promise<{ verifier: string; challenge: string }> {
  const verifier = b64url(crypto.getRandomValues(new Uint8Array(32)));
  const digest = await crypto.subtle.digest("SHA-256", enc.encode(verifier));
  return { verifier, challenge: b64url(new Uint8Array(digest)) };
}

/** Google mode: send the owner to Google, binding the round trip to this browser. */
export async function startLogin(env: Env, returnTo?: string): Promise<Response> {
  const nonce = b64url(crypto.getRandomValues(new Uint8Array(16)));
  const { verifier, challenge } = await pkce();
  const login = await sign(env, { p: "login", n: nonce, v: verifier, r: returnTo, x: Math.floor(Date.now() / 1000) + LOGIN_TTL_S });
  const google = new URL(GOOGLE_AUTH_URL);
  google.search = new URLSearchParams({
    client_id: env.GOOGLE_CLIENT_ID,
    redirect_uri: `${env.PUBLIC_URL}${RECONNECT_PREFIX}/callback`,
    response_type: "code",
    scope: "openid email",
    state: nonce,
    code_challenge: challenge,
    code_challenge_method: "S256",
    login_hint: env.ALLOWED_EMAIL,
    prompt: "select_account",
  }).toString();
  return new Response(null, {
    status: 302,
    headers: { ...baseHeaders("text/plain"), Location: google.toString(), "Set-Cookie": setCookie(LOGIN_COOKIE, login, LOGIN_TTL_S) },
  });
}

async function finishLogin(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  const login = await verify(env, cookie(request, LOGIN_COOKIE), "login");
  const state = url.searchParams.get("state");
  const code = url.searchParams.get("code");
  if (!login || !login.n || !login.v || !state || state !== login.n || !code) {
    return plain("This sign-in expired or came from another browser. Open the Reconnect link again.", 403);
  }
  let email: string | null = null;
  try {
    const tokenRes = await fetch(GOOGLE_TOKEN_URL, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        code,
        client_id: env.GOOGLE_CLIENT_ID,
        client_secret: env.GOOGLE_CLIENT_SECRET,
        redirect_uri: `${env.PUBLIC_URL}${RECONNECT_PREFIX}/callback`,
        grant_type: "authorization_code",
        code_verifier: login.v,
      }),
    });
    const token = tokenRes.ok ? ((await tokenRes.json()) as { access_token?: unknown }) : {};
    if (typeof token.access_token === "string" && token.access_token) {
      const info = await fetch(GOOGLE_USERINFO_URL, { headers: { Authorization: `Bearer ${token.access_token}` } });
      const who = info.ok ? ((await info.json()) as { email?: unknown; email_verified?: unknown }) : {};
      const verified = who.email_verified === true || who.email_verified === "true";
      if (verified && isAllowedEmail(who.email, env)) email = normalizeEmail(who.email);
    }
  } catch {
    return plain("Sign-in is unavailable right now. Try again in a few minutes.", 502);
  }
  if (!email) return plain("That Google account isn't the one this connection belongs to.", 403);
  const session = await sign(env, { p: "session", e: email, x: Math.floor(Date.now() / 1000) + SESSION_TTL_S });
  const h = new Headers(baseHeaders("text/plain"));
  h.set("Location", `${env.PUBLIC_URL}${RECONNECT_PREFIX}${login.r === "/spam" ? "/spam" : ""}`);
  h.append("Set-Cookie", setCookie(SESSION_COOKIE, session, SESSION_TTL_S));
  h.append("Set-Cookie", setCookie(LOGIN_COOKIE, "", 0));
  return new Response(null, { status: 302, headers: h });
}

export interface ReconnectState {
  reachable: boolean;
  connected: boolean | null;
  needs_pairing: boolean | null;
  helper: boolean;
  pair: { state: string; emoji: string | null; message: string; tries_left_today: number | null } | null;
}

async function readState(env: Env): Promise<ReconnectState> {
  const out: ReconnectState = { reachable: false, connected: null, needs_pairing: null, helper: false, pair: null };
  try {
    const r = await env.ORIGIN.fetch(ORIGIN_STATUS_URL, { method: "GET", headers: { Accept: "application/json" } });
    if (r.ok) {
      const s = (await r.json()) as { google?: { connected?: unknown; needs_pairing?: unknown } };
      out.reachable = true;
      out.connected = typeof s.google?.connected === "boolean" ? s.google.connected : null;
      out.needs_pairing = typeof s.google?.needs_pairing === "boolean" ? s.google.needs_pairing : null;
    }
  } catch {
    /* not reachable */
  }
  if (env.PAIR) {
    try {
      const r = await env.PAIR.fetch(PAIR_URL, { method: "GET", headers: { Accept: "application/json" } });
      if (r.ok) {
        const p = (await r.json()) as Record<string, unknown>;
        out.helper = true;
        out.pair = {
          state: typeof p.state === "string" ? p.state : "unknown",
          emoji: typeof p.emoji === "string" ? p.emoji.slice(0, 16) : null,
          message: typeof p.message === "string" ? p.message.slice(0, 300) : "",
          tries_left_today: typeof p.tries_left_today === "number" ? p.tries_left_today : null,
        };
      }
    } catch {
      /* helper missing */
    }
  }
  return out;
}

export const escapeHtml = (v: string) => v.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);

interface ServerInfo {
  version: string;
  previous_version: string;
  actions_left_today: number | null;
}

/** The fix-it buttons' facts, or null if the helper is missing or too old to have them. */
async function serverInfo(env: Env): Promise<ServerInfo | null> {
  if (!env.PAIR) return null;
  try {
    const r = await env.PAIR.fetch(SERVER_URL, { method: "GET", headers: { Accept: "application/json" } });
    if (!r.ok) return null;
    const s = (await r.json()) as Record<string, unknown>;
    return {
      version: typeof s.version === "string" ? s.version.slice(0, 60) : "",
      previous_version: typeof s.previous_version === "string" ? s.previous_version.slice(0, 60) : "",
      actions_left_today: typeof s.actions_left_today === "number" ? s.actions_left_today : null,
    };
  } catch {
    return null;
  }
}

function fixSection(info: ServerInfo | null): string {
  if (!info) return "";
  const back = info.previous_version
    ? `<p><button class="fix" data-action="go_back" data-ask="Go back to version ${escapeHtml(info.previous_version)}?">Go back to the previous version</button><br><small>Only if it stopped working right after an update.</small></p>`
    : "";
  return `<h2 style="font-size:1.15em;margin-top:1.6em">Something else not working?</h2>
<p><button class="fix" data-action="restart" data-ask="Restart your server? It takes about a minute.">Restart my server</button><br><small>Safe to try. No texts are lost; it catches up afterwards.</small></p>
${back}
<p id="fixed"></p>
<p><small>Version ${escapeHtml(info.version || "unknown")}.</small></p>`;
}

function page(env: Env, code: string, st: ReconnectState, info: ServerInfo | null = null): string {
  const base = ((env.RECONNECT_DOWNLOAD_URL ?? "").trim() || DEFAULT_DOWNLOAD).replace(/\/+$/, "");
  const mac = escapeHtml(`${base}/om-reconnect-mac.zip`);
  const win = escapeHtml(`${base}/om-reconnect-windows.exe`);
  const now = st.connected
    ? "✓ Connected right now. You only need this if Claude or an alert says it's disconnected."
    : st.reachable || st.helper
      ? "✗ Not connected to Google Messages. Follow the steps below."
      : "✗ Your server isn't answering. Wait a few minutes and reload; if it stays like this, contact whoever set it up.";
  const helperNote = st.helper ? "" : `<p class="warn">Reconnecting from here isn't switched on for this server yet. Contact whoever set it up.</p>`;
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex"><title>Reconnect your texts</title>
<style>
body{font:17px/1.5 system-ui,sans-serif;max-width:34rem;margin:1.5rem 16px;color:#1d1d1f}
h1{font-size:1.5em}ol{padding-left:1.3em}li{margin:.7em 0}
button,.btn{font:inherit;padding:.55rem 1rem;border-radius:8px;border:1px solid #888;background:#fff;cursor:pointer;text-decoration:none;color:inherit;display:inline-block}
#emoji{font-size:5rem;text-align:center;margin:.5rem 0}#live{padding:1rem;border-radius:10px;background:#f2f2f7;min-height:2rem}
.warn{color:#b42318}small{color:#666}
</style></head><body>
<h1>Reconnect your texts</h1>
<p id="now">${escapeHtml(now)}</p>
${helperNote}
<ol>
<li>Have your <strong>phone</strong> nearby, unlocked.</li>
<li>Get the <strong>OpenMessage Reconnect</strong> app (once): <a class="btn" href="${mac}">Mac</a> <a class="btn" href="${win}">Windows</a><br>
<small>Needs Google Chrome. The first time, your computer may say it's from an unidentified developer. On a Mac: open the download, then right-click "OpenMessage Reconnect", choose Open, then Open. On Windows: More info, then Run anyway.</small></li>
<li><button id="copy">Copy reconnect code</button> <span id="copied"></span><br><small>The app reads it from your clipboard. It works for 20 minutes.</small></li>
<li>Open the app. It opens a private Chrome window. Sign in to the Google account your Google Messages uses, until Google Messages opens. The window then closes by itself.</li>
<li>Watch this page: when an emoji appears, tap the same one on your phone.</li>
</ol>
<div id="live">Waiting for the app…</div>
<div id="emoji"></div>
${fixSection(info)}
<p><small>Also here: <a href="${RECONNECT_PREFIX}/spam">your spam rules</a>.</small></p>
<p><small>Your Google sign-in goes from that private window straight to your own server, which uses it once to pair and then deletes it. Nobody else sees it. Up to 3 tries a day.</small></p>
<script>
const code = ${JSON.stringify(code)};
document.getElementById("copy").onclick = async () => {
  try { await navigator.clipboard.writeText(code); document.getElementById("copied").textContent = "Copied."; }
  catch { prompt("Copy this code:", code); }
};
for (const b of document.querySelectorAll("button.fix")) {
  b.onclick = async () => {
    if (!confirm(b.dataset.ask)) return;
    const out = document.getElementById("fixed");
    out.textContent = "Working on it…";
    try {
      const r = await fetch("${RECONNECT_PREFIX}/server", { method: "POST", credentials: "same-origin", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ action: b.dataset.action }) });
      const d = await r.json().catch(() => ({}));
      out.textContent = r.ok ? "Done. Give it a few minutes, then ask Claude for your latest texts." : (d.error || "That didn't work.");
    } catch { out.textContent = "That didn't work. Try again in a minute."; }
  };
}
async function poll() {
  try {
    const r = await fetch("${RECONNECT_PREFIX}/state", { credentials: "same-origin", cache: "no-store" });
    if (r.ok) {
      const s = await r.json();
      const p = s.pair || {};
      const live = document.getElementById("live"), emoji = document.getElementById("emoji");
      emoji.textContent = p.state === "waiting_for_tap" && p.emoji ? p.emoji : "";
      if (p.state && p.state !== "idle") live.textContent = p.message || p.state;
      if (p.state === "connected") { live.textContent = "✓ Connected. You're done; you can close this page."; document.getElementById("now").textContent = ""; }
    } else if (r.status === 401) { location.reload(); return; }
  } catch {}
  setTimeout(poll, 2000);
}
poll();
</script>
</body></html>`;
}

export async function handleReconnect(request: Request, env: Env): Promise<Response> {
  const { pathname } = new URL(request.url);
  if (!secret(env)) return plain("Not found", 404);
  const sub = pathname.slice(RECONNECT_PREFIX.length) || "/";

  if (sub === "/callback") {
    if (isAccess(env) || request.method !== "GET") return plain("Not found", 404);
    return finishLogin(request, env);
  }

  if (sub === "/spam" || sub.startsWith("/spam/")) return handleSpam(request, env, sub.slice("/spam".length) || "/");

  if (sub === "/server") {
    if (request.method !== "POST") return plain("Method not allowed", 405);
    if (!(await owner(request, env))) return json({ error: "sign in again" }, 401);
    // Only this page may do this: the cookie alone isn't enough.
    if (request.headers.get("Origin") !== new URL(env.PUBLIC_URL).origin) return json({ error: "forbidden" }, 403);
    if (!env.PAIR) return json({ error: "This isn't switched on for this server." }, 501);
    const raw = await request.text();
    if (raw.length > 1024) return json({ error: "bad request" }, 400);
    let action: unknown;
    try {
      action = (JSON.parse(raw) as { action?: unknown }).action;
    } catch {
      return json({ error: "bad request" }, 400);
    }
    if (action !== "restart" && action !== "go_back") return json({ error: "bad request" }, 400);
    try {
      const up = await env.PAIR.fetch(SERVER_URL, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ action }) });
      const reply = (await up.json().catch(() => ({}))) as Record<string, unknown>;
      return json(typeof reply.error === "string" ? { error: reply.error.slice(0, 300) } : { ok: true }, up.status);
    } catch {
      return json({ error: "Your server isn't answering. Try again in a few minutes." }, 502);
    }
  }

  if (sub === "/upload") {
    if (request.method !== "POST") return plain("Method not allowed", 405);
    const auth = request.headers.get("Authorization") ?? "";
    const claims = await verify(env, auth.startsWith("Bearer ") ? auth.slice(7) : null, "upload");
    if (!claims?.e || !isAllowedEmail(claims.e, env)) return json({ error: "This reconnect code expired. Copy a new one from the Reconnect page." }, 401);
    if (!env.PAIR) return json({ error: "Reconnecting isn't switched on for this server." }, 501);
    const len = Number(request.headers.get("Content-Length") ?? "0");
    if (len > MAX_UPLOAD_BYTES) return json({ error: "too large" }, 413);
    const raw = new Uint8Array(await request.arrayBuffer());
    if (raw.byteLength === 0 || raw.byteLength > MAX_UPLOAD_BYTES) return json({ error: "bad request" }, raw.byteLength ? 413 : 400);
    let body: { cookies?: unknown };
    try {
      body = JSON.parse(new TextDecoder().decode(raw)) as { cookies?: unknown };
    } catch {
      return json({ error: "bad request" }, 400);
    }
    // Rebuild: only the cookies (and force from the signed code) reach the VM.
    const forward = JSON.stringify({ cookies: body.cookies, force: claims.f === true });
    try {
      const up = await env.PAIR.fetch(PAIR_URL, { method: "POST", headers: { "Content-Type": "application/json" }, body: forward });
      const reply = (await up.json().catch(() => ({}))) as Record<string, unknown>;
      const msg = typeof reply.error === "string" ? reply.error.slice(0, 300) : undefined;
      return json(msg ? { error: msg } : { ok: true, state: reply.state ?? "starting" }, up.status);
    } catch {
      return json({ error: "Your server isn't answering. Try again in a few minutes." }, 502);
    }
  }

  if (sub === "/state") {
    if (request.method !== "GET") return plain("Method not allowed", 405);
    const auth = request.headers.get("Authorization") ?? "";
    const app = auth.startsWith("Bearer ") ? await verify(env, auth.slice(7), "upload") : null;
    const ok = (app?.e && isAllowedEmail(app.e, env)) || (await owner(request, env));
    if (!ok) return json({ error: "sign in again" }, 401);
    return json(await readState(env));
  }

  if (sub === "/") {
    if (request.method !== "GET") return plain("Method not allowed", 405);
    const email = await owner(request, env);
    if (!email) {
      if (isAccess(env)) return plain("Forbidden", 403);
      return startLogin(env);
    }
    const force = new URL(request.url).searchParams.get("force") === "1";
    const token = await sign(env, { p: "upload", e: email, f: force, x: Math.floor(Date.now() / 1000) + UPLOAD_TTL_S });
    const code = CODE_PREFIX + b64url(enc.encode(JSON.stringify({ u: env.PUBLIC_URL, t: token })));
    const [st, info] = await Promise.all([readState(env), serverInfo(env)]);
    return new Response(page(env, code, st, info), {
      status: 200,
      headers: {
        ...baseHeaders("text/html; charset=utf-8"),
        "Content-Security-Policy": "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
      },
    });
  }
  return plain("Not found", 404);
}
