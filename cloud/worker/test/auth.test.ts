import { AuthorizationError } from "@cloudflare/workers-oauth-provider";
import type { AuthRequest, OAuthHelpers } from "@cloudflare/workers-oauth-provider";
import { afterEach, describe, expect, it, vi } from "vitest";
import { handleAuth } from "../src/auth";
import type { Env } from "../src/env";
import { ALLOWED, PUBLIC_URL, makeEnv } from "./helpers";

const authRequest: AuthRequest = {
  responseType: "code",
  clientId: "client-1",
  redirectUri: "https://claude.ai/api/mcp/auth_callback",
  scope: [],
  state: "client-state",
  resource: `${PUBLIC_URL}/mcp`,
};

/** A stand-in for env.OAUTH_PROVIDER whose finishUpstream accepts each state once. */
function makeProvider(overrides: Partial<Record<keyof OAuthHelpers, unknown>> = {}) {
  const live = new Set(["good-state"]);
  const base = {
    parseAuthRequest: vi.fn(async () => authRequest),
    describeConsent: vi.fn(async () => ({
      clientId: "client-1",
      clientName: "Claude",
      redirectUri: authRequest.redirectUri,
      redirectHost: "claude.ai",
      redirectIsLoopback: false,
      scope: [],
    })),
    beginConsent: vi.fn(async () => ({ handle: "handle-1", headers: new Headers({ "Set-Cookie": "__Host-oauth-consent-x=1" }) })),
    approveConsent: vi.fn(async () => ({ request: authRequest, headers: new Headers({ "Set-Cookie": "__Host-oauth-consent-x=; Max-Age=0" }) })),
    denyConsent: vi.fn(async () => ({
      request: authRequest,
      redirectTo: "https://claude.ai/api/mcp/auth_callback?error=access_denied",
      headers: new Headers({ Location: "https://claude.ai/api/mcp/auth_callback?error=access_denied" }),
    })),
    beginUpstream: vi.fn(async (_r: AuthRequest, opts?: { headers?: Headers }) => ({
      state: "good-state",
      headers: opts?.headers ?? new Headers(),
    })),
    finishUpstream: vi.fn(async (req: Request) => {
      const state = new URL(req.url).searchParams.get("state") ?? "";
      if (!live.delete(state)) throw new AuthorizationError("invalid_request", { description: "state not found" });
      return { request: authRequest, data: { verifier: "verifier-1" }, headers: new Headers({ "Set-Cookie": "__Host-oauth-upstream-x=; Max-Age=0" }) };
    }),
    completeAuthorization: vi.fn(async (_o: unknown) => ({ redirectTo: "https://claude.ai/api/mcp/auth_callback?code=abc&state=client-state" })),
  };
  return { ...base, ...overrides } as typeof base;
}

function envWith(provider: ReturnType<typeof makeProvider>, extra: Partial<Env> = {}): Env {
  return makeEnv({ OAUTH_PROVIDER: provider as unknown as OAuthHelpers, ...extra });
}

/** Mock Google: token endpoint, then userinfo. */
function mockGoogle(userinfo: unknown, tokenStatus = 200) {
  const fetchMock = vi.fn(async (input: string | URL | Request, init?: RequestInit) => {
    const url = String(input instanceof Request ? input.url : input);
    if (url === "https://oauth2.googleapis.com/token") {
      return tokenStatus === 200
        ? Response.json({ access_token: "g-access", id_token: "ignored" })
        : new Response("{}", { status: tokenStatus });
    }
    if (url === "https://openidconnect.googleapis.com/v1/userinfo") {
      expect(new Headers(init?.headers).get("authorization")).toBe("Bearer g-access");
      return Response.json(userinfo);
    }
    throw new Error(`unexpected fetch ${url}`);
  });
  vi.stubGlobal("fetch", fetchMock);
  return fetchMock;
}

const callbackReq = (qs = "code=g-code&state=good-state") => new Request(`${PUBLIC_URL}/callback?${qs}`);

afterEach(() => vi.unstubAllGlobals());

describe("/authorize", () => {
  it("shows a consent page with escaped client details and the binding cookie", async () => {
    const p = makeProvider({
      describeConsent: vi.fn(async () => ({
        clientId: "c",
        clientName: "<script>alert(1)</script>",
        redirectUri: "https://x.test/cb",
        redirectHost: "x.test",
        redirectIsLoopback: false,
        scope: [],
      })),
    });
    const res = await handleAuth(new Request(`${PUBLIC_URL}/authorize?client_id=c`), envWith(p));
    const html = await res.text();
    expect(res.status).toBe(200);
    expect(res.headers.get("set-cookie")).toContain("__Host-oauth-consent");
    expect(html).toContain('value="handle-1"');
    expect(html).not.toContain("<script>");
    expect(html).toContain("&#60;script&#62;");
  });
  it("redirects a validated-client error to the client, renders any other", async () => {
    const withRedirect = new AuthorizationError("invalid_scope", { description: "bad", redirectUri: authRequest.redirectUri, state: "s" });
    const a = await handleAuth(
      new Request(`${PUBLIC_URL}/authorize`),
      envWith(makeProvider({ parseAuthRequest: vi.fn(async () => { throw withRedirect; }) })),
    );
    expect(a.status).toBe(302);
    expect(a.headers.get("location")).toBe(withRedirect.redirectTo);
    const b = await handleAuth(
      new Request(`${PUBLIC_URL}/authorize`),
      envWith(makeProvider({ parseAuthRequest: vi.fn(async () => { throw new AuthorizationError("invalid_request", { description: "bad" }); }) })),
    );
    expect(b.status).toBe(400);
  });
  it("on Allow, sends the owner to Google with the stored state", async () => {
    const p = makeProvider();
    const form = new URLSearchParams({ handle: "handle-1", decision: "approve" });
    const res = await handleAuth(
      new Request(`${PUBLIC_URL}/authorize`, { method: "POST", body: form, headers: { "Content-Type": "application/x-www-form-urlencoded" } }),
      envWith(p),
    );
    expect(res.status).toBe(302);
    const loc = new URL(res.headers.get("location")!);
    expect(loc.origin + loc.pathname).toBe("https://accounts.google.com/o/oauth2/v2/auth");
    expect(loc.searchParams.get("response_type")).toBe("code");
    expect(loc.searchParams.get("scope")).toBe("openid email");
    expect(loc.searchParams.get("state")).toBe("good-state");
    expect(loc.searchParams.get("client_id")).toBe("test-google-client-id");
    expect(loc.searchParams.get("redirect_uri")).toBe(`${PUBLIC_URL}/callback`);
    expect(loc.searchParams.get("code_challenge_method")).toBe("S256");
    expect(loc.searchParams.get("login_hint")).toBe(ALLOWED);
    expect(res.headers.get("set-cookie")).toContain("__Host-oauth-consent");
    expect(p.approveConsent).toHaveBeenCalledWith(expect.any(Request), "handle-1");
    expect(p.beginUpstream.mock.calls[0]![1]).toMatchObject({ data: { verifier: expect.any(String) } });
  });
  it("on Deny, goes back to the client and never to Google", async () => {
    const p = makeProvider();
    const form = new URLSearchParams({ handle: "handle-1", decision: "deny" });
    const res = await handleAuth(
      new Request(`${PUBLIC_URL}/authorize`, { method: "POST", body: form, headers: { "Content-Type": "application/x-www-form-urlencoded" } }),
      envWith(p),
    );
    expect(res.headers.get("location")).toContain("error=access_denied");
    expect(p.beginUpstream).not.toHaveBeenCalled();
  });
  it("refuses a replayed or foreign handle", async () => {
    const p = makeProvider({ approveConsent: vi.fn(async () => { throw new AuthorizationError("invalid_request", { description: "used" }); }) });
    const form = new URLSearchParams({ handle: "stale", decision: "approve" });
    const res = await handleAuth(
      new Request(`${PUBLIC_URL}/authorize`, { method: "POST", body: form, headers: { "Content-Type": "application/x-www-form-urlencoded" } }),
      envWith(p),
    );
    expect(res.status).toBe(400);
    expect(p.beginUpstream).not.toHaveBeenCalled();
  });
});

describe("/callback", () => {
  it("accepts the allowed, verified email", async () => {
    const p = makeProvider();
    const google = mockGoogle({ email: ALLOWED, email_verified: true });
    const res = await handleAuth(callbackReq(), envWith(p));
    expect(res.status).toBe(302);
    expect(res.headers.get("location")).toBe("https://claude.ai/api/mcp/auth_callback?code=abc&state=client-state");
    expect(res.headers.get("set-cookie")).toContain("__Host-oauth-upstream");
    expect(p.completeAuthorization).toHaveBeenCalledWith({
      request: authRequest,
      userId: ALLOWED,
      metadata: {},
      scope: [],
      props: { email: ALLOWED },
    });
    const tokenCall = google.mock.calls.find((c) => String(c[0]) === "https://oauth2.googleapis.com/token")!;
    const sent = new URLSearchParams(String(tokenCall[1]!.body));
    expect(sent.get("code")).toBe("g-code");
    expect(sent.get("code_verifier")).toBe("verifier-1");
    expect(sent.get("grant_type")).toBe("authorization_code");
    expect(sent.get("redirect_uri")).toBe(`${PUBLIC_URL}/callback`);
    expect(sent.get("client_secret")).toBe("test-google-client-secret");
  });
  it("compares case-insensitively and trimmed", async () => {
    const p = makeProvider();
    mockGoogle({ email: "  Owner@Example.COM ", email_verified: true });
    const res = await handleAuth(callbackReq(), envWith(p, { ALLOWED_EMAIL: " OWNER@example.com " }));
    expect(res.status).toBe(302);
    expect(p.completeAuthorization.mock.calls[0]![0]).toMatchObject({ userId: ALLOWED });
  });
  it("rejects a different email with a bare 403", async () => {
    const p = makeProvider();
    mockGoogle({ email: "someone@example.com", email_verified: true });
    const res = await handleAuth(callbackReq(), envWith(p));
    expect(res.status).toBe(403);
    expect(await res.text()).toBe("Forbidden");
    expect(res.headers.has("location")).toBe(false);
    expect(p.completeAuthorization).not.toHaveBeenCalled();
  });
  it("rejects an unverified email, including the right address", async () => {
    for (const verified of [false, undefined, "false", 1]) {
      const p = makeProvider();
      mockGoogle({ email: ALLOWED, email_verified: verified });
      const res = await handleAuth(callbackReq(), envWith(p));
      expect(res.status).toBe(403);
      expect(p.completeAuthorization).not.toHaveBeenCalled();
    }
  });
  it("rejects an unknown state and does not call Google", async () => {
    const p = makeProvider();
    const google = mockGoogle({ email: ALLOWED, email_verified: true });
    const res = await handleAuth(callbackReq("code=g-code&state=made-up"), envWith(p));
    expect(res.status).toBe(403);
    expect(await res.text()).toBe("Forbidden");
    expect(google).not.toHaveBeenCalled();
    expect(p.completeAuthorization).not.toHaveBeenCalled();
  });
  it("rejects a reused state: the second callback fails", async () => {
    const p = makeProvider();
    mockGoogle({ email: ALLOWED, email_verified: true });
    expect((await handleAuth(callbackReq(), envWith(p))).status).toBe(302);
    expect((await handleAuth(callbackReq(), envWith(p))).status).toBe(403);
    expect(p.completeAuthorization).toHaveBeenCalledTimes(1);
  });
  it("rejects a missing state", async () => {
    const p = makeProvider();
    const res = await handleAuth(callbackReq("code=g-code"), envWith(p));
    expect(res.status).toBe(403);
  });
  it("rejects when Google refuses the code", async () => {
    const p = makeProvider();
    mockGoogle({ email: ALLOWED, email_verified: true }, 400);
    expect((await handleAuth(callbackReq(), envWith(p))).status).toBe(403);
    expect(p.completeAuthorization).not.toHaveBeenCalled();
  });
  it("answers 502 when Google is unreachable", async () => {
    const p = makeProvider();
    vi.stubGlobal("fetch", vi.fn(async () => { throw new Error("network down"); }));
    const res = await handleAuth(callbackReq(), envWith(p));
    expect(res.status).toBe(502);
    expect(p.completeAuthorization).not.toHaveBeenCalled();
  });
  it("allows nobody when ALLOWED_EMAIL is empty", async () => {
    const p = makeProvider();
    mockGoogle({ email: "", email_verified: true });
    expect((await handleAuth(callbackReq(), envWith(p, { ALLOWED_EMAIL: "" }))).status).toBe(403);
    expect(p.completeAuthorization).not.toHaveBeenCalled();
  });
  it("sends a Google error back to the client as access_denied", async () => {
    const p = makeProvider();
    const google = mockGoogle({});
    const res = await handleAuth(callbackReq("error=access_denied&state=good-state"), envWith(p));
    expect(res.status).toBe(302);
    expect(res.headers.get("location")).toContain("error=access_denied");
    expect(google).not.toHaveBeenCalled();
    expect(p.completeAuthorization).not.toHaveBeenCalled();
  });
});

describe("other paths", () => {
  it("answers 404", async () => {
    const env = envWith(makeProvider());
    for (const path of ["/", "/admin", "/callback/x", "/authorize/x", "/.env"]) {
      expect((await handleAuth(new Request(`${PUBLIC_URL}${path}`), env)).status).toBe(404);
    }
    expect((await handleAuth(new Request(`${PUBLIC_URL}/callback`, { method: "POST" }), env)).status).toBe(404);
  });
});
