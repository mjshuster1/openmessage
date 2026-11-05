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
  /** "google" (default): this Worker runs OAuth with Google sign-in. "access": Cloudflare Access does. */
  AUTH_MODE?: string;
  /** Access mode only: team domain (xxx.cloudflareaccess.com) and the Access application's AUD tag. */
  ACCESS_TEAM_DOMAIN?: string;
  ACCESS_AUD?: string;
  // Secrets (ALLOWED_EMAIL is a secret so the address stays out of the public repo)
  ALLOWED_EMAIL: string;
  // Google mode only
  GOOGLE_CLIENT_ID: string;
  GOOGLE_CLIENT_SECRET: string;
  /** Optional: turns on the status-only page GET /status?key=<STATUS_KEY> (status.ts). */
  STATUS_KEY?: string;
  /** Optional: turns on the Reconnect page (reconnect.ts) with PAIR; signs its cookies and codes. 32+ chars. */
  RECONNECT_SECRET?: string;
  /** Optional: where the Reconnect page's Download button points. */
  RECONNECT_DOWNLOAD_URL?: string;
  /** Optional Workers VPC Service: the VM's om-pair-helper (127.0.0.1:7011). */
  PAIR?: Fetcher;
}

/** What completeAuthorization() stores and the API handler gets as ctx.props. */
export interface Props {
  email: string;
}
