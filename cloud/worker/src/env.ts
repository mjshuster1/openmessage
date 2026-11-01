import type { OAuthHelpers } from "@cloudflare/workers-oauth-provider";

export interface Env {
  // Bindings
  OAUTH_KV: KVNamespace;
  /** Injected by OAuthProvider into the env its handlers receive. */
  OAUTH_PROVIDER: OAuthHelpers;
  // Vars (wrangler.toml)
  PUBLIC_URL: string;
  ORIGIN_URL: string;
  ALLOWED_EMAIL: string;
  // Secrets
  GOOGLE_CLIENT_ID: string;
  GOOGLE_CLIENT_SECRET: string;
  CF_ACCESS_CLIENT_ID: string;
  CF_ACCESS_CLIENT_SECRET: string;
}

/** What completeAuthorization() stores and the API handler gets as ctx.props. */
export interface Props {
  email: string;
}
