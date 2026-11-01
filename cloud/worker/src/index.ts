import { OAuthProvider } from "@cloudflare/workers-oauth-provider";
import { handleAuth, isAllowedEmail } from "./auth";
import type { Env, Props } from "./env";
import { handleMcp } from "./proxy";

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

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const publicUrl = (env.PUBLIC_URL ?? "").replace(/\/+$/, "");
    // Tokens are bound to PUBLIC_URL. Answer on no other hostname.
    if (!publicUrl || new URL(request.url).origin !== new URL(publicUrl).origin) {
      return new Response("Not found", { status: 404 });
    }
    return providerFor(publicUrl).fetch(request, env, ctx);
  },
};
