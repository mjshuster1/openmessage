/**
 * Cloudflare Access mode (AUTH_MODE = "access").
 *
 * Access sits in front of the Worker's workers.dev route and does the whole
 * OAuth dance with claude.ai itself (Managed OAuth: discovery, client
 * registration, sign-in, tokens). A request that gets through carries a
 * Cf-Access-Jwt-Assertion header, a JWT Access signed for this application.
 *
 * The Worker still checks that JWT on every call, and refuses without it,
 * so that turning Access off, a misconfigured policy, or a URL Access does
 * not cover (a preview URL) fails closed instead of open: signature against
 * the team's published keys, issuer, this application's audience tag,
 * expiry, and the email equal to ALLOWED_EMAIL.
 */
import { isAllowedEmail, normalizeEmail } from "./auth";
import type { Env } from "./env";

export const ACCESS_JWT_HEADER = "Cf-Access-Jwt-Assertion";
const CLOCK_SKEW_S = 60;
const KEYS_TTL_MS = 10 * 60 * 1000;
const KEYS_MIN_REFETCH_MS = 60 * 1000;

type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;

export interface AccessConfig {
  /** e.g. "myteam.cloudflareaccess.com" (https:// and trailing slash tolerated). */
  teamDomain: string;
  /** The Access application's Audience (AUD) tag. */
  aud: string;
}

export type AccessCheck = { ok: true; email: string } | { ok: false; status: 401 | 403 | 500 | 502; reason: string };

/** Team domain as a bare lowercase host, or "" if it isn't one. */
export function teamHost(value: unknown): string {
  if (typeof value !== "string") return "";
  const host = value.trim().toLowerCase().replace(/^https:\/\//, "").replace(/\/+$/, "");
  return /^[a-z0-9-]+(\.[a-z0-9-]+)+$/.test(host) ? host : "";
}

export function accessConfig(env: Pick<Env, "ACCESS_TEAM_DOMAIN" | "ACCESS_AUD">): AccessConfig | null {
  const teamDomain = teamHost(env.ACCESS_TEAM_DOMAIN);
  const aud = typeof env.ACCESS_AUD === "string" ? env.ACCESS_AUD.trim() : "";
  if (!teamDomain || !/^[A-Za-z0-9]{16,}$/.test(aud)) return null;
  return { teamDomain, aud };
}

function b64urlDecode(part: string): Uint8Array {
  const s = part.replace(/-/g, "+").replace(/_/g, "/");
  const bin = atob(s + "=".repeat((4 - (s.length % 4)) % 4));
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function b64urlJson(part: string): Record<string, unknown> | null {
  try {
    const v: unknown = JSON.parse(new TextDecoder().decode(b64urlDecode(part)));
    return typeof v === "object" && v !== null && !Array.isArray(v) ? (v as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

interface KeySet {
  fetchedAt: number;
  keys: Map<string, CryptoKey>;
}
/** Per-isolate cache of each team's signing keys. */
const keyCache = new Map<string, KeySet>();

/** For tests. */
export function clearAccessKeyCache(): void {
  keyCache.clear();
}

async function loadKeys(teamDomain: string, fetchImpl: FetchLike): Promise<KeySet> {
  const res = await fetchImpl(`https://${teamDomain}/cdn-cgi/access/certs`, { headers: { Accept: "application/json" } });
  if (!res.ok) throw new Error(`certs ${res.status}`);
  const body = (await res.json()) as { keys?: unknown };
  const keys = new Map<string, CryptoKey>();
  for (const jwk of Array.isArray(body.keys) ? body.keys : []) {
    const k = jwk as JsonWebKey & { kid?: unknown };
    if (typeof k.kid !== "string" || k.kty !== "RSA") continue;
    try {
      const key = await crypto.subtle.importKey(
        "jwk",
        { kty: "RSA", n: k.n, e: k.e, alg: "RS256", ext: true },
        { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
        false,
        ["verify"],
      );
      keys.set(k.kid, key);
    } catch {
      // skip a key we can't import; the others may still verify
    }
  }
  const set = { fetchedAt: Date.now(), keys };
  keyCache.set(teamDomain, set);
  return set;
}

async function keyFor(teamDomain: string, kid: string, fetchImpl: FetchLike): Promise<CryptoKey | undefined> {
  let set = keyCache.get(teamDomain);
  const age = set ? Date.now() - set.fetchedAt : Infinity;
  if (!set || age > KEYS_TTL_MS || (!set.keys.has(kid) && age > KEYS_MIN_REFETCH_MS)) {
    set = await loadKeys(teamDomain, fetchImpl);
  }
  return set.keys.get(kid);
}

/** Verify an Access JWT for this application and return the allowed email, or why not. */
export async function verifyAccessJwt(
  token: string | null,
  cfg: AccessConfig,
  env: Pick<Env, "ALLOWED_EMAIL">,
  fetchImpl: FetchLike = (input, init) => fetch(input, init),
  nowS: number = Math.floor(Date.now() / 1000),
): Promise<AccessCheck> {
  if (!token) return { ok: false, status: 401, reason: "no Access token (is Cloudflare Access in front of this Worker?)" };
  const parts = token.split(".");
  if (parts.length !== 3) return { ok: false, status: 401, reason: "malformed token" };
  const [h, p, s] = parts as [string, string, string];
  const header = b64urlJson(h);
  const claims = b64urlJson(p);
  if (!header || !claims) return { ok: false, status: 401, reason: "malformed token" };
  if (header["alg"] !== "RS256" || typeof header["kid"] !== "string") {
    return { ok: false, status: 401, reason: "unexpected token algorithm" };
  }

  let key: CryptoKey | undefined;
  try {
    key = await keyFor(cfg.teamDomain, header["kid"], fetchImpl);
  } catch {
    return { ok: false, status: 502, reason: "couldn't load Access signing keys" };
  }
  if (!key) return { ok: false, status: 401, reason: "unknown signing key" };
  let sig: Uint8Array;
  try {
    sig = b64urlDecode(s);
  } catch {
    return { ok: false, status: 401, reason: "malformed token" };
  }
  const valid = await crypto.subtle.verify("RSASSA-PKCS1-v1_5", key, sig, new TextEncoder().encode(`${h}.${p}`));
  if (!valid) return { ok: false, status: 401, reason: "bad signature" };

  if (claims["iss"] !== `https://${cfg.teamDomain}`) return { ok: false, status: 401, reason: "wrong issuer" };
  const aud = claims["aud"];
  const auds = Array.isArray(aud) ? aud : [aud];
  if (!auds.includes(cfg.aud)) return { ok: false, status: 401, reason: "token is for another Access application" };
  const exp = claims["exp"];
  if (typeof exp !== "number" || exp + CLOCK_SKEW_S < nowS) return { ok: false, status: 401, reason: "token expired" };
  const nbf = claims["nbf"];
  if (typeof nbf === "number" && nbf - CLOCK_SKEW_S > nowS) return { ok: false, status: 401, reason: "token not yet valid" };

  if (!isAllowedEmail(claims["email"], env)) return { ok: false, status: 403, reason: "email not allowed" };
  return { ok: true, email: normalizeEmail(claims["email"]) };
}
