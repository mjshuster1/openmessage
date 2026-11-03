#!/usr/bin/env node
// Captures the Google cookies OpenMessage needs to pair with Google Messages,
// from a throwaway Incognito Chrome that nothing else uses.
//
//   node capture-google-cookies.mjs [output.json]    (default google-cookies.json)
//
// Needs Node 22+ and Google Chrome (or set CHROME to the browser binary).
// macOS, Windows and Linux.
//
// Why this way (see README step 4):
// - DevTools' Network panel no longer shows the Cookie header on
//   messages.google.com ("Provisional headers are shown"), so Copy as cURL
//   carries no cookies, and Messages Web no longer makes a `config` request.
// - Cookies copied from a Chrome profile you keep using die within minutes:
//   Chrome refreshes the login and Google drops the copy (2026-11-03: 401 and
//   a park 4 minutes after start). A fresh Incognito login that is closed
//   right after capture is used by nothing else.
//
// How: Chrome starts with a temporary profile, in Incognito, with the
// DevTools protocol on a random loopback port. You sign in and open Messages
// Web, then press Enter. The script asks Chrome for exactly the cookies it
// would send to https://messages.google.com/web/, writes them as a
// {"name": "value"} object (mode 600), closes Chrome without signing out and
// deletes the temporary profile. It prints cookie names, never values. While
// that Chrome is open, any local process could read its cookies through the
// port; keep the window short.
//
// Feed the file to `openmessage pair --google-file <file>` on the VM, then
// delete it: it is a full Google login.

import { spawn } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync, chmodSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline/promises";

const OUT = process.argv[2] || "google-cookies.json";
const TARGET = "https://messages.google.com/web/";
const START = "https://accounts.google.com/ServiceLogin?continue=" + encodeURIComponent(TARGET);
// Without these the session is useless to libgm; checked before writing.
const REQUIRED = ["SID", "SAPISID", "__Secure-1PSID", "__Secure-1PSIDTS"];

function findChrome() {
  if (process.env.CHROME) return process.env.CHROME;
  const env = process.env;
  const candidates = {
    darwin: ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"],
    win32: [env.PROGRAMFILES, env["PROGRAMFILES(X86)"], env.LOCALAPPDATA]
      .filter(Boolean)
      .map((base) => join(base, "Google", "Chrome", "Application", "chrome.exe")),
    linux: ["google-chrome", "google-chrome-stable", "chromium", "chromium-browser"]
      .flatMap((name) => (env.PATH || "").split(":").map((dir) => join(dir, name))),
  }[process.platform] || [];
  const found = candidates.find((p) => existsSync(p));
  if (!found) throw new Error("Google Chrome not found; set CHROME to its binary");
  return found;
}

// One DevTools protocol call over a fresh WebSocket.
async function cdp(wsUrl, method, params = {}) {
  const ws = new WebSocket(wsUrl);
  await new Promise((resolve, reject) => { ws.onopen = resolve; ws.onerror = () => reject(new Error("DevTools connection failed")); });
  try {
    return await new Promise((resolve, reject) => {
      ws.onmessage = (ev) => {
        const msg = JSON.parse(ev.data);
        if (msg.id !== 1) return;
        msg.error ? reject(new Error(msg.error.message)) : resolve(msg.result);
      };
      ws.send(JSON.stringify({ id: 1, method, params }));
    });
  } finally {
    ws.close();
  }
}

async function waitForPort(profile, chrome) {
  const file = join(profile, "DevToolsActivePort");
  for (let i = 0; i < 100; i++) {
    if (chrome.exitCode !== null) throw new Error(`Chrome exited (code ${chrome.exitCode}) before it was ready`);
    if (existsSync(file)) {
      const port = readFileSync(file, "utf8").split("\n")[0].trim();
      if (port) return port;
    }
    await new Promise((r) => setTimeout(r, 200));
  }
  throw new Error("Chrome did not open its DevTools port");
}

const profile = mkdtempSync(join(tmpdir(), "om-cookie-chrome-"));
let chrome;
let port;
try {
  chrome = spawn(findChrome(), [
    `--user-data-dir=${profile}`,
    "--remote-debugging-port=0",
    "--remote-debugging-address=127.0.0.1",
    "--incognito",
    "--no-first-run",
    "--no-default-browser-check",
    START,
  ], { stdio: "ignore" });
  port = await waitForPort(profile, chrome);

  const rl = createInterface({ input: process.stdin, output: process.stdout });
  await rl.question(
    "\nA separate Incognito Chrome window is open.\n" +
    "  1. Sign in with the Google account linked to the phone's Google Messages.\n" +
    "  2. Let it continue to messages.google.com/web and wait until it loads.\n" +
    "Then press Enter here. ");
  rl.close();

  const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
  const page = targets.find((t) => t.type === "page" && t.url.startsWith("https://messages.google.com/"));
  if (!page) {
    const hosts = targets.filter((t) => t.type === "page").map((t) => new URL(t.url).host);
    throw new Error(`no messages.google.com tab is open (tabs: ${hosts.join(", ") || "none"})`);
  }
  const { cookies } = await cdp(page.webSocketDebuggerUrl, "Network.getCookies", { urls: [TARGET] });
  const map = Object.fromEntries(cookies.map((c) => [c.name, c.value]));
  const missing = REQUIRED.filter((name) => !(name in map));
  if (missing.length) throw new Error(`not signed in: missing ${missing.join(", ")}; nothing written`);

  writeFileSync(OUT, JSON.stringify(map), { mode: 0o600 });
  chmodSync(OUT, 0o600);
  console.log(`\nWrote ${cookies.length} cookies to ${OUT} (mode 600): ${Object.keys(map).sort().join(", ")}`);
  console.log("Closing Chrome without signing out. Don't sign this login out anywhere: the VM will hold it.");
} catch (err) {
  console.error(`\nError: ${err.message}`);
  process.exitCode = 1;
} finally {
  if (port) {
    try {
      const { webSocketDebuggerUrl } = await (await fetch(`http://127.0.0.1:${port}/json/version`)).json();
      await cdp(webSocketDebuggerUrl, "Browser.close");
    } catch { /* Chrome already gone */ }
  }
  if (chrome && chrome.exitCode === null) {
    await Promise.race([new Promise((r) => chrome.once("exit", r)), new Promise((r) => setTimeout(r, 5000))]);
    if (chrome.exitCode === null) chrome.kill();
  }
  rmSync(profile, { recursive: true, force: true });
}
