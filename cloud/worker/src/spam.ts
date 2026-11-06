import type { Env } from "./env";
import { RECONNECT_PREFIX, baseHeaders, isAccess, json, owner, plain, startLogin } from "./reconnect";

/**
 * The client's spam page, so changing rules needs neither the operator nor a
 * terminal. It writes through the VM's om-pair-helper, never through the MCP
 * connector, which stays read-only for Claude.
 *
 *   GET  /reconnect/spam         the page (owner only, same sign-in as Reconnect)
 *   GET  /reconnect/spam/data    rules and recent matches
 *   POST /reconnect/spam/rules   replace the rules
 *   POST /reconnect/spam/action  block or unblock one conversation
 *
 * POSTs must come from this page (Origin check) and carry JSON.
 */
const SPAM_URL = "http://127.0.0.1:7011/spam";
const MAX_BODY = 256 * 1024;
const NOT_ON = "Spam rules aren't switched on for this server yet. Contact whoever set it up.";
const NEEDS_UPDATE = "Your server needs its next software update for this page. It updates itself within a day; try again tomorrow.";
const DOWN = "Your server isn't answering. Try again in a few minutes.";

async function helper(env: Env, path: string, init: RequestInit): Promise<Response> {
  if (!env.PAIR) return json({ error: NOT_ON }, 501);
  try {
    const up = await env.PAIR.fetch(`${SPAM_URL}${path}`, init);
    if (up.status === 404) return json({ error: NEEDS_UPDATE }, 501);
    const reply = (await up.json().catch(() => ({}))) as Record<string, unknown>;
    return json(reply, up.status);
  } catch {
    return json({ error: DOWN }, 502);
  }
}

/** Reads a small JSON body, or returns the response refusing it. */
async function readBody(request: Request): Promise<Record<string, unknown> | Response> {
  const raw = new Uint8Array(await request.arrayBuffer());
  if (raw.byteLength === 0) return json({ error: "bad request" }, 400);
  if (raw.byteLength > MAX_BODY) return json({ error: "That's too much text." }, 413);
  try {
    const body = JSON.parse(new TextDecoder().decode(raw)) as unknown;
    if (body && typeof body === "object" && !Array.isArray(body)) return body as Record<string, unknown>;
  } catch {
    /* fall through */
  }
  return json({ error: "bad request" }, 400);
}

// A function, not a constant: this module and reconnect.ts import each other.
const page = () => `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex"><title>Your spam rules</title>
<style>
body{font:17px/1.5 system-ui,sans-serif;max-width:38rem;margin:1.5rem 16px;color:#1d1d1f}
h1{font-size:1.5em}h2{font-size:1.15em;margin-top:1.6em}
textarea{font:inherit;width:100%;box-sizing:border-box;min-height:8rem;padding:.5rem;border:1px solid #888;border-radius:8px}
button{font:inherit;padding:.5rem 1rem;border-radius:8px;border:1px solid #888;background:#fff;cursor:pointer}
label{display:block;margin:.4em 0}small{color:#666}.warn{color:#b42318}
.item{border-top:1px solid #ddd;padding:.7em 0}.quote{color:#444;overflow-wrap:anywhere}
</style></head><body>
<h1>Your spam rules</h1>
<p id="msg"></p>
<div id="main" hidden>
<h2>What should happen to a match?</h2>
<label><input type="radio" name="mode" value="log"> Just list it below. Nothing gets blocked.</label>
<label><input type="radio" name="mode" value="block"> Block it and report it as spam automatically.</label>
<p><small>Saved contacts and group chats are never blocked automatically, and a day's automatic blocks are capped. Common political-text phrases, such as "paid for by" and "reply stop", are always included.</small></p>
<h2>Words and phrases</h2>
<p><small>One per line. A text from a stranger that contains one is a match.</small></p>
<textarea id="phrases" spellcheck="false"></textarea>
<h2>Numbers</h2>
<p><small>One per line.</small></p>
<textarea id="numbers" spellcheck="false"></textarea>
<p><button id="save">Save</button> <span id="saved"></span></p>
<h2>Recent matches</h2>
<div id="recent"></div>
</div>
<script>
const $ = (id) => document.getElementById(id);
const lines = (id) => $(id).value.split("\\n").map((s) => s.trim()).filter(Boolean);
const post = (path, body) => fetch("${RECONNECT_PREFIX}/spam/" + path, { method: "POST", credentials: "same-origin", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
const WORDS = { logged: "Matched, not blocked", blocked: "Blocked", block_failed: "Block failed", manual_block: "Blocked by you", manual_block_failed: "Block failed", manual_unblock: "Unblocked by you", manual_unblock_failed: "Unblock failed" };
function showRecent(items) {
  const box = $("recent");
  box.textContent = items.length ? "" : "Nothing yet.";
  for (const e of items) {
    const row = document.createElement("div"); row.className = "item";
    const head = document.createElement("div");
    const when = e.time ? new Date(e.time).toLocaleString() : "";
    head.textContent = [WORDS[e.action] || e.action, e.sender, when].filter(Boolean).join(" · ");
    row.append(head);
    if (e.snippet) { const q = document.createElement("div"); q.className = "quote"; q.textContent = e.snippet; row.append(q); }
    if (e.matched && e.matched.length) { const m = document.createElement("small"); m.textContent = "Matched: " + e.matched.join(", "); row.append(m); }
    const action = e.action === "blocked" || e.action === "manual_block" ? "unblock" : e.action === "logged" && !e.is_group ? "block_and_report" : null;
    if (action && e.conversation_id) {
      const b = document.createElement("button");
      b.textContent = action === "unblock" ? "Unblock" : "Block and report";
      b.style.display = "block"; b.style.marginTop = ".4em";
      b.onclick = async () => {
        b.disabled = true; b.textContent = "Working…";
        const r = await post("action", { conversation_id: e.conversation_id, action });
        const d = await r.json().catch(() => ({}));
        if (r.ok) { load(); } else { b.disabled = false; b.textContent = d.error || "That didn't work."; }
      };
      row.append(b);
    }
    box.append(row);
  }
}
async function load() {
  const r = await fetch("${RECONNECT_PREFIX}/spam/data", { credentials: "same-origin", cache: "no-store" });
  if (r.status === 401) { location.reload(); return; }
  const d = await r.json().catch(() => ({}));
  if (!r.ok) { $("msg").textContent = d.error || "Couldn't load your rules."; $("msg").className = "warn"; return; }
  if ($("main").hidden) {
    $("phrases").value = d.rules.phrases.join("\\n");
    $("numbers").value = d.rules.numbers.join("\\n");
    document.querySelector('input[name=mode][value=' + d.rules.mode + ']').checked = true;
    $("main").hidden = false;
  }
  showRecent(d.recent);
}
$("save").onclick = async () => {
  $("saved").textContent = "Saving…"; $("saved").className = "";
  const mode = document.querySelector("input[name=mode]:checked").value;
  const r = await post("rules", { phrases: lines("phrases"), numbers: lines("numbers"), mode });
  const d = await r.json().catch(() => ({}));
  if (r.ok) {
    $("phrases").value = d.phrases.join("\\n"); $("numbers").value = d.numbers.join("\\n");
    $("saved").textContent = "Saved. It takes effect on the next text.";
  } else { $("saved").textContent = d.error || "That didn't save."; $("saved").className = "warn"; }
};
load();
</script>
</body></html>`;

/** sub is the path after /reconnect/spam: "/", "/data", "/rules" or "/action". */
export async function handleSpam(request: Request, env: Env, sub: string): Promise<Response> {
  if (sub === "/") {
    if (request.method !== "GET") return plain("Method not allowed", 405);
    if (!(await owner(request, env))) {
      if (isAccess(env)) return plain("Forbidden", 403);
      return startLogin(env, "/spam");
    }
    return new Response(page(), {
      status: 200,
      headers: {
        ...baseHeaders("text/html; charset=utf-8"),
        "Content-Security-Policy": "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
      },
    });
  }
  if (sub !== "/data" && sub !== "/rules" && sub !== "/action") return plain("Not found", 404);
  if (!(await owner(request, env))) return json({ error: "sign in again" }, 401);

  if (sub === "/data") {
    if (request.method !== "GET") return plain("Method not allowed", 405);
    return helper(env, "", { method: "GET", headers: { Accept: "application/json" } });
  }

  if (request.method !== "POST") return plain("Method not allowed", 405);
  // Only this page may change anything: the cookie alone isn't enough.
  if (request.headers.get("Origin") !== new URL(env.PUBLIC_URL).origin) return json({ error: "forbidden" }, 403);
  const body = await readBody(request);
  if (body instanceof Response) return body;
  // Rebuild: only the known fields reach the VM.
  const forward = sub === "/rules"
    ? { path: "", data: { phrases: body.phrases, numbers: body.numbers, mode: body.mode } }
    : { path: "/action", data: { conversation_id: body.conversation_id, action: body.action } };
  return helper(env, forward.path, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(forward.data) });
}
