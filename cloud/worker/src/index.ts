import { OAuthProvider } from "@cloudflare/workers-oauth-provider";
import { ACCESS_JWT_HEADER, accessConfig, verifyAccessJwt } from "./access";
import { handleAuth, isAllowedEmail } from "./auth";
import type { Env, Props } from "./env";
import { handleMcp } from "./proxy";
import { RECONNECT_PREFIX, handleReconnect } from "./reconnect";
import { STATUS_PATH, handleStatus } from "./status";

/** apiHandler: only reached with a valid access token, props decrypted by the provider. */
const apiHandler = {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    // Re-check on every call, so changing ALLOWED_EMAIL also cuts off tokens already issued.
    const props = (ctx as { props?: Props }).props;
    if (!isAllowedEmail(props?.email, env)) return new Response("Forbidden", { status: 403 });
    return handleMcp(request, env);
  },
};

const defaultHandler = {
  fetch: (request: Request, env: Env) => handleAuth(request, env),
};

/**
 * The provider needs the Worker's public https URL (it becomes every token's
 * audience), which comes from a var, so it is built on first use.
 */
let cached: { publicUrl: string; provider: OAuthProvider<Env> } | undefined;

function providerFor(publicUrl: string): OAuthProvider<Env> {
  if (cached?.publicUrl === publicUrl) return cached.provider;
  const provider = new OAuthProvider<Env>({
    apiRoute: "/mcp",
    apiHandler,
    defaultHandler,
    authorizeEndpoint: "/authorize",
    tokenEndpoint: "/oauth/token",
    clientRegistrationEndpoint: "/oauth/register",
    clientIdMetadataDocumentEnabled: true,
    resourceMetadata: {
      resource: `${publicUrl}/mcp`,
      authorization_servers: [publicUrl],
      resource_name: "OpenMessage (read-only)",
    },
  });
  cached = { publicUrl, provider };
  return provider;
}

const plain = (body: string, status: number) =>
  new Response(body, { status, headers: { "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store" } });

/** AUTH_MODE = "access": Cloudflare Access did the sign-in; check its JWT, then proxy. */
async function accessFetch(request: Request, env: Env): Promise<Response> {
  const cfg = accessConfig(env);
  if (!cfg) return plain("Access mode is missing ACCESS_TEAM_DOMAIN or ACCESS_AUD.", 500);
  if (new URL(request.url).pathname !== "/mcp") return plain("Not found", 404);
  const check = await verifyAccessJwt(request.headers.get(ACCESS_JWT_HEADER), cfg, env);
  if (!check.ok) {
    console.log(JSON.stringify({ access: "refused", reason: check.reason }));
    return plain(check.status === 403 ? "Forbidden" : check.status === 502 ? "Bad gateway" : "Unauthorized", check.status);
  }
  return handleMcp(request, env);
}

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const publicUrl = (env.PUBLIC_URL ?? "").replace(/\/+$/, "");
    // Tokens are bound to PUBLIC_URL. Answer on no other hostname.
    if (!publicUrl || new URL(request.url).origin !== new URL(publicUrl).origin) {
      return new Response("Not found", { status: 404 });
    }
    // Status only (connected? newest text when?), behind its own key; no message data.
    const path = new URL(request.url).pathname;
    if (path === STATUS_PATH) return handleStatus(request, env);
    // The client re-pairs Google Messages themselves (owner sign-in; see reconnect.ts).
    if (path === RECONNECT_PREFIX || path.startsWith(`${RECONNECT_PREFIX}/`)) return handleReconnect(request, env);
    const mode = (env.AUTH_MODE ?? "google").trim().toLowerCase();
    if (mode === "access") return accessFetch(request, env);
    if (mode !== "google") return plain(`Unknown AUTH_MODE "${mode}".`, 500);
    return providerFor(publicUrl).fetch(request, env, ctx);
  },
};
