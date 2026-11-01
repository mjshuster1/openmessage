import type { OAuthHelpers } from "@cloudflare/workers-oauth-provider";

export interface Env {
  // Bindings
  OAUTH_KV: KVNamespace;
  /** Injected by OAuthProvider into the env its handlers receive. */
  OAUTH_PROVIDER: OAuthHelpers;
  /** Workers VPC Service: Cloudflare Tunnel to OpenMessage on the Mac (127.0.0.1:7007). */
  ORIGIN: Fetcher;
  // Vars (wrangler.toml)
  PUBLIC_URL: string;
  // Secrets (ALLOWED_EMAIL is a secret so the address stays out of the public repo)
  ALLOWED_EMAIL: string;
  GOOGLE_CLIENT_ID: string;
  GOOGLE_CLIENT_SECRET: string;
}

/** What completeAuthorization() stores and the API handler gets as ctx.props. */
export interface Props {
  email: string;
}
