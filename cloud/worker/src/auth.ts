import { AuthorizationError, CimdFetchError, authorizationErrorRedirect } from "@cloudflare/workers-oauth-provider";
import type { ConsentDescription } from "@cloudflare/workers-oauth-provider";
import type { Env, Props } from "./env";

const GOOGLE_AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth";
const GOOGLE_TOKEN_URL = "https://oauth2.googleapis.com/token";
const GOOGLE_USERINFO_URL = "https://openidconnect.googleapis.com/v1/userinfo";

export function normalizeEmail(value: unknown): string {
  return typeof value === "string" ? value.trim().toLowerCase() : "";
}

/** True only for the one configured address. An empty or missing ALLOWED_EMAIL allows nobody. */
export function isAllowedEmail(email: unknown, env: Pick<Env, "ALLOWED_EMAIL">): boolean {
  const allowed = normalizeEmail(env.ALLOWED_EMAIL);
  return allowed !== "" && normalizeEmail(email) === allowed;
}

const escapeHtml = (value: string) => value.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);

function text(body: string, status: number, headers?: Headers): Response {
  const h = new Headers(headers);
  h.set("Content-Type", "text/plain; charset=utf-8");
  h.set("Cache-Control", "no-store");
  return new Response(body, { status, headers: h });
}

function consentPage(details: ConsentDescription, handle: string): string {
  const name = escapeHtml(details.clientName);
  const origin = details.clientDomain
    ? `Published by <strong>${escapeHtml(details.clientDomain)}</strong>.`
    : "This app registered itself, so its name is not verified.";
  const loopback = details.redirectIsLoopback
    ? "<p><strong>This sends access to an app on your computer.</strong> Continue only if you just started signing in from it.</p>"
    : "";
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Authorize ${name}</title>
<style>body{font:16px/1.5 system-ui,sans-serif;max-width:32rem;margin:2rem 16px;padding:0}button{font:inherit;padding:.5rem 1rem;margin-right:.5rem}</style>
</head><body>
<h1>Allow ${name} to read your messages?</h1>
<p>${origin} Access will be sent to <strong>${escapeHtml(details.redirectHost)}</strong>. It is read-only. Next you will sign in with Google.</p>
${loopback}
<form method="post">
<input type="hidden" name="handle" value="${escapeHtml(handle)}">
<button name="decision" value="approve">Allow</button><button name="decision" value="deny">Deny</button>
</form>
</body></html>`;
}

function base64url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function pkcePair(): Promise<{ verifier: string; challenge: string }> {
  const verifier = base64url(crypto.getRandomValues(new Uint8Array(32)));
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier));
  return { verifier, challenge: base64url(new Uint8Array(digest)) };
}

/** GET /authorize: validate the request, then ask the owner to allow this client. */
async function showConsent(request: Request, env: Env): Promise<Response> {
  const oauth = env.OAUTH_PROVIDER;
  let authRequest;
  try {
    authRequest = await oauth.parseAuthRequest(request);
  } catch (error) {
    if (error instanceof AuthorizationError && error.redirectTo) {
      return new Response(null, { status: 302, headers: { Location: error.redirectTo } });
    }
    if (error instanceof AuthorizationError || error instanceof CimdFetchError) {
      return text("Invalid authorization request.", 400);
    }
    throw error;
  }
  const details = await oauth.describeConsent(authRequest);
  const consent = await oauth.beginConsent(authRequest);
  const headers = new Headers(consent.headers);
  headers.set("Content-Type", "text/html; charset=utf-8");
  headers.set("Cache-Control", "no-store");
  return new Response(consentPage(details, consent.handle), { headers });
}

/** POST /authorize: Allow starts the Google sign-in. Deny goes back to the client. */
async function decideConsent(request: Request, env: Env): Promise<Response> {
  const oauth = env.OAUTH_PROVIDER;
  try {
    const form = await request.formData();
    const handle = String(form.get("handle") ?? "");
    if (form.get("decision") !== "approve") {
      const denied = await oauth.denyConsent(request, handle);
      return new Response(null, { status: 302, headers: denied.headers });
    }
    const approved = await oauth.approveConsent(request, handle);
    const { verifier, challenge } = await pkcePair();
    const upstream = await oauth.beginUpstream(approved.request, { data: { verifier }, headers: approved.headers });
    const google = new URL(GOOGLE_AUTH_URL);
    google.search = new URLSearchParams({
      client_id: env.GOOGLE_CLIENT_ID,
      redirect_uri: `${env.PUBLIC_URL}/callback`,
      response_type: "code",
      scope: "openid email",
      state: upstream.state,
      code_challenge: challenge,
      code_challenge_method: "S256",
      login_hint: env.ALLOWED_EMAIL,
    }).toString();
    upstream.headers.set("Location", google.toString());
    upstream.headers.set("Cache-Control", "no-store");
    return new Response(null, { status: 302, headers: upstream.headers });
  } catch (error) {
    if (error instanceof AuthorizationError || error instanceof TypeError) {
      return text("This sign-in page expired or was already used. Start again from the app.", 400);
    }
    throw error;
  }
}

/** Trade the code for a Google access token and read the verified email. null means Google said no. */
async function googleIdentity(
  code: string,
  verifier: string,
  env: Env,
): Promise<{ email: unknown; verified: unknown } | null> {
  const tokenRes = await fetch(GOOGLE_TOKEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      code,
      client_id: env.GOOGLE_CLIENT_ID,
      client_secret: env.GOOGLE_CLIENT_SECRET,
      redirect_uri: `${env.PUBLIC_URL}/callback`,
      grant_type: "authorization_code",
      code_verifier: verifier,
    }),
  });
  if (!tokenRes.ok) return null;
  const token = (await tokenRes.json()) as { access_token?: unknown };
  if (typeof token.access_token !== "string" || token.access_token === "") return null;
  const infoRes = await fetch(GOOGLE_USERINFO_URL, { headers: { Authorization: `Bearer ${token.access_token}` } });
  if (!infoRes.ok) return null;
  const info = (await infoRes.json()) as { email?: unknown; email_verified?: unknown };
  return { email: info.email, verified: info.email_verified };
}

/** GET /callback: Google sent the owner back. Only the allowed, verified email gets a grant. */
async function callback(request: Request, env: Env): Promise<Response> {
  const oauth = env.OAUTH_PROVIDER;
  const url = new URL(request.url);
  let resumed;
  try {
    // Checks the state and its browser-bound cookie, and consumes it: it works once.
    resumed = await oauth.finishUpstream<{ verifier: string }>(request);
  } catch (error) {
    if (error instanceof AuthorizationError) return text("Forbidden", 403);
    throw error;
  }
  const { request: original, data, headers } = resumed;

  if (url.searchParams.get("error")) {
    headers.set("Location", authorizationErrorRedirect(original, "access_denied"));
    return new Response(null, { status: 302, headers });
  }
  const code = url.searchParams.get("code");
  if (!code || typeof data?.verifier !== "string") return text("Forbidden", 403, headers);

  let identity;
  try {
    identity = await googleIdentity(code, data.verifier, env);
  } catch {
    return text("Sign-in is unavailable. Try again later.", 502, headers);
  }
  const verified = identity?.verified === true || identity?.verified === "true";
  if (!identity || !verified || !isAllowedEmail(identity.email, env)) return text("Forbidden", 403, headers);

  const email = normalizeEmail(identity.email);
  const props: Props = { email };
  const { redirectTo } = await oauth.completeAuthorization({
    request: original,
    userId: email,
    metadata: {},
    scope: original.scope,
    props,
  });
  headers.set("Location", redirectTo);
  headers.set("Cache-Control", "no-store");
  return new Response(null, { status: 302, headers });
}

/** defaultHandler: everything the OAuth provider does not own. */
export async function handleAuth(request: Request, env: Env): Promise<Response> {
  const { pathname } = new URL(request.url);
  if (pathname === "/authorize") {
    if (request.method === "GET") return showConsent(request, env);
    if (request.method === "POST") return decideConsent(request, env);
    return text("Method not allowed", 405);
  }
  if (pathname === "/callback" && request.method === "GET") return callback(request, env);
  return text("Not found", 404);
}
