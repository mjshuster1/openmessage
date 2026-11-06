#!/usr/bin/env python3
"""Re-pairs Google Messages on the VM from a Google login sent by the client.

This is the VM half of "reconnect without the operator": the client signs in
to Google in a throwaway Chrome on their own computer (the Reconnect app),
the app sends the login to the client's connector Worker, and the Worker
passes it here through its PAIR binding (Workers VPC, this port only). Then
this does what vm/reconnect.sh does over SSH: stop OpenMessage, run
`openmessage pair --google-file`, report the emoji to tap, delete the login,
start OpenMessage, and check the connection.

  POST /pair   {"cookies": {"SID": "...", ...}, "force": false}
               202 started; 409 already running, or connected and not force;
               429 too many tries today; 400 bad login; 403 non-loopback Host
  GET  /pair   {"state": ..., "emoji": ..., "message": ..., "started_ms": ...,
                "updated_ms": ..., "tries_left_today": N}
               state: idle | starting | waiting_for_tap | checking |
                      connected | failed

It also serves the client's spam page (Worker /reconnect/spam), so they can
change their own rules with no operator access:

  GET  /spam         {"rules": {"phrases", "numbers", "mode"}, "recent": [...]}
  POST /spam         {"phrases": [...], "numbers": [...], "mode": "log"|"block"}
                     replaces spam-rules.json; OpenMessage reloads it by itself
  POST /spam/action  {"conversation_id": "...", "action": "block_and_report"|"unblock"}

Runs as root (it stops and starts openmessage.service) on 127.0.0.1 only,
from om-pair.service. Status only in responses and logs: never cookie
values. At most MAX_PER_DAY tries a day, one at a time: repeated pairings can
get the Google account throttled.
"""

import json
import os
import re
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("OM_PAIR_PORT", "7011"))
DATA_DIR = os.environ.get("OM_DATA_DIR", "/var/lib/openmessage")
STATE_FILE = os.environ.get("OM_PAIR_STATE", os.path.join(DATA_DIR, "pair-helper.json"))
RUN_DIR = os.environ.get("OM_PAIR_RUN_DIR", "/run/om-pair")
OPENMESSAGE = os.environ.get("OM_BIN", "/usr/local/bin/openmessage")
SERVICE_USER = os.environ.get("OM_SERVICE_USER", "openmessage")
STATUS_URL = os.environ.get("OM_STATUS_URL", "http://127.0.0.1:7007/api/status")
MAX_PER_DAY = int(os.environ.get("OM_PAIR_MAX_PER_DAY", "3"))
SETTLE_SECONDS = float(os.environ.get("OM_PAIR_SETTLE", "25"))
PAIR_TIMEOUT = float(os.environ.get("OM_PAIR_TIMEOUT", "420"))
MAX_BODY = 64 * 1024
REQUIRED = ("SID", "SAPISID", "__Secure-1PSID", "__Secure-1PSIDTS")
COOKIE_NAME = re.compile(r"^[A-Za-z0-9_.\-]{1,128}$")
LOOPBACK_HOSTS = {"127.0.0.1", "localhost", "[::1]"}
SPAM_RULES = os.environ.get("OM_SPAM_RULES", os.path.join(DATA_DIR, "spam-rules.json"))
SPAM_LOG = os.environ.get("OM_SPAM_LOG", os.path.join(DATA_DIR, "spam-watch.jsonl"))
CONTROL_TOKEN = os.environ.get("OM_CONTROL_TOKEN_FILE", os.path.join(DATA_DIR, "control.token"))
BLOCK_URL = os.environ.get("OM_BLOCK_URL", "http://127.0.0.1:7007/api/spam/block")
MAX_PHRASES = 500
MAX_NUMBERS = 2000
MIN_PHRASE = 3    # shorter ones would match almost every text
MAX_PHRASE = 200
RECENT_ENTRIES = 50
LOG_TAIL_BYTES = 256 * 1024
SPAM_ACTIONS = ("block_and_report", "unblock")

# Commands, swappable for tests.
def _systemctl(*args):
    return subprocess.run(["systemctl", *args], capture_output=True, timeout=120).returncode == 0

SYSTEMCTL = _systemctl


def pair_command(cookie_file):
    if os.environ.get("OM_PAIR_CMD"):  # tests
        return [os.environ["OM_PAIR_CMD"], cookie_file]
    return [
        "runuser", "-u", SERVICE_USER, "--", "env", f"OPENMESSAGES_DATA_DIR={DATA_DIR}",
        "stdbuf", "-oL", "-eL", OPENMESSAGE, "pair", "--google-file", cookie_file,
    ]


def now_ms():
    return int(time.time() * 1000)


def log(msg):
    print(f"om-pair-helper: {msg}", file=sys.stderr, flush=True)


class State:
    """The current job, and the tries recorded today (persisted)."""

    def __init__(self):
        self.lock = threading.Lock()
        self.job = {"state": "idle", "emoji": None, "message": "", "started_ms": None, "updated_ms": now_ms()}
        self.tries = self._load_tries()

    def _load_tries(self):
        try:
            with open(STATE_FILE) as f:
                return [int(t) for t in json.load(f).get("tries_ms", [])]
        except (OSError, ValueError, TypeError, AttributeError):
            return []

    def _save_tries(self):
        tmp = STATE_FILE + ".tmp"
        try:
            with open(tmp, "w") as f:
                json.dump({"tries_ms": self.tries}, f)
            os.replace(tmp, STATE_FILE)
        except OSError as e:
            log(f"couldn't save tries: {e}")

    def tries_today(self):
        cutoff = now_ms() - 86_400_000
        self.tries = [t for t in self.tries if t > cutoff]
        return len(self.tries)

    def snapshot(self):
        with self.lock:
            out = dict(self.job)
            out["tries_left_today"] = max(0, MAX_PER_DAY - self.tries_today())
            return out

    def set(self, **kw):
        with self.lock:
            self.job.update(kw, updated_ms=now_ms())

    def busy(self):
        return self.job["state"] in ("starting", "waiting_for_tap", "checking")


STATE = State()


def google_connected():
    try:
        with urllib.request.urlopen(STATUS_URL, timeout=5) as r:
            return json.load(r).get("google", {}).get("connected") is True
    except Exception:
        return False


def validate_cookies(body):
    cookies = body.get("cookies") if isinstance(body, dict) else None
    if not isinstance(cookies, dict) or not cookies or len(cookies) > 200:
        return None, "no Google login in the request"
    for k, v in cookies.items():
        if not isinstance(k, str) or not COOKIE_NAME.match(k) or not isinstance(v, str) or not v or len(v) > 4096 \
                or any(c in v for c in "\r\n;"):
            return None, "the Google login looks malformed"
    missing = [n for n in REQUIRED if n not in cookies]
    if missing:
        return None, "the Google sign-in didn't finish (sign in until Google Messages opens, then try again)"
    return cookies, None


def run_job(cookies):
    """One pairing, start to finish. Always deletes the login and restarts OpenMessage."""
    os.makedirs(RUN_DIR, mode=0o700, exist_ok=True)
    cookie_file = os.path.join(RUN_DIR, f"cookies-{os.getpid()}-{now_ms()}.json")
    ok = False
    try:
        fd = os.open(cookie_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(cookies, f)
        if not os.environ.get("OM_PAIR_CMD"):
            import pwd
            pw = pwd.getpwnam(SERVICE_USER)
            os.chown(RUN_DIR, pw.pw_uid, pw.pw_gid)
            os.chown(cookie_file, pw.pw_uid, pw.pw_gid)
        del cookies

        STATE.set(state="starting", message="Stopping OpenMessage to pair")
        SYSTEMCTL("stop", "openmessage")
        proc = subprocess.Popen(pair_command(cookie_file), stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, bufsize=1)
        deadline = time.time() + PAIR_TIMEOUT
        timer = threading.Timer(PAIR_TIMEOUT, proc.kill)
        timer.start()
        paired = False
        try:
            for raw in proc.stdout:
                line = re.sub(r"\x1b\[[0-9;]*m", "", raw).strip()
                if "EMOJI:" in line:
                    emoji = line.split("EMOJI:", 1)[1].strip()[:16]
                    STATE.set(state="waiting_for_tap", emoji=emoji,
                              message="On the phone, tap the same emoji in Google Messages (5 minutes)")
                    log("waiting for the phone")
                elif "successful" in line.lower():
                    paired = True
                if time.time() > deadline:
                    break
            proc.stdout.close()
            rc = proc.wait(timeout=30)
        finally:
            timer.cancel()
        paired = paired and rc == 0
        log(f"pair exited {rc}")
        if not paired:
            STATE.set(state="failed", emoji=None,
                      message="Pairing didn't finish (the emoji wasn't tapped in time, or Google refused the sign-in). "
                              "OpenMessage is back on its previous connection. Try once more later; not in a loop.")
            return
        STATE.set(state="checking", emoji=None, message="Paired. Checking the connection")
        ok = True
    except Exception as e:  # never leave OpenMessage stopped or the login on disk
        log(f"job error: {type(e).__name__}")
        STATE.set(state="failed", emoji=None, message="Something went wrong on the server; OpenMessage was restarted.")
    finally:
        try:
            os.remove(cookie_file)
        except OSError:
            pass
        SYSTEMCTL("start", "openmessage")

    if ok:
        time.sleep(SETTLE_SECONDS)
        if google_connected():
            STATE.set(state="connected", message="Connected. You're done.")
            log("connected")
        else:
            STATE.set(state="failed", message="Paired, but it isn't connected yet. Wait 10 minutes; if alerts still say it's down, try once more.")


def read_rules():
    """The whole rules file, or {} if it's missing or broken."""
    try:
        with open(SPAM_RULES) as f:
            rules = json.load(f)
        return rules if isinstance(rules, dict) else {}
    except (OSError, ValueError):
        return {}


def clean_rules(body):
    """Validated (phrases, numbers, mode), or (None, None, an error for the client)."""
    if not isinstance(body, dict):
        return None, None, "bad request"
    phrases, numbers = body.get("phrases"), body.get("numbers")
    mode = body.get("mode")
    if not isinstance(phrases, list) or not isinstance(numbers, list) or mode not in ("log", "block"):
        return None, None, "bad request"
    if len(phrases) > MAX_PHRASES or len(numbers) > MAX_NUMBERS:
        return None, None, f"That's too many (up to {MAX_PHRASES} phrases and {MAX_NUMBERS} numbers)."
    out_phrases, out_numbers = [], []
    for p in phrases:
        if not isinstance(p, str):
            return None, None, "bad request"
        p = p.strip()
        if not p:
            continue
        if len(p) < MIN_PHRASE or len(p) > MAX_PHRASE or any(ord(c) < 32 for c in p):
            return None, None, f'"{p[:40]}" won\'t work as a phrase: use {MIN_PHRASE} to {MAX_PHRASE} characters.'
        if p.lower() not in (x.lower() for x in out_phrases):
            out_phrases.append(p)
    for n in numbers:
        if not isinstance(n, str):
            return None, None, "bad request"
        if not n.strip():
            continue
        digits = re.sub(r"[\s().+-]", "", n)
        if not re.fullmatch(r"[0-9]{5,15}", digits):
            return None, None, f'"{n[:40]}" doesn\'t look like a phone number.'
        if digits not in out_numbers:
            out_numbers.append(digits)
    return out_phrases, out_numbers, None


def write_rules(phrases, numbers, mode):
    """Replaces the file in one step, keeping settings the page doesn't show."""
    rules = read_rules()
    rules.update(phrases=phrases, numbers=numbers, mode=mode)
    tmp = SPAM_RULES + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(rules, f, indent=2)
    if not os.environ.get("OM_PAIR_CMD"):
        import pwd
        pw = pwd.getpwnam(SERVICE_USER)
        os.chown(tmp, pw.pw_uid, pw.pw_gid)
    os.replace(tmp, SPAM_RULES)


def recent_spam():
    """The newest log entries, newest first. The log holds message text; only the owner's page asks."""
    try:
        with open(SPAM_LOG, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - LOG_TAIL_BYTES))
            lines = f.read().decode("utf-8", "replace").splitlines()
        if size > LOG_TAIL_BYTES:
            lines = lines[1:]  # the first line is probably cut
    except OSError:
        return []
    out = []
    for line in reversed(lines):
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if not isinstance(e, dict):
            continue
        out.append({
            "time": e.get("time"),
            "sender": e.get("sender_name") or e.get("sender_number") or "",
            "matched": e.get("matched") or [],
            "snippet": e.get("snippet") or "",
            "action": e.get("action") or "logged",
            "note": e.get("note") or "",
            "conversation_id": e.get("conversation_id") or "",
            "is_group": e.get("is_group") is True,
        })
        if len(out) >= RECENT_ENTRIES:
            break
    return out


def spam_action(conversation_id, action):
    """Asks OpenMessage to block or unblock. Returns (status, reply)."""
    try:
        with open(CONTROL_TOKEN) as f:
            token = f.read().strip()
    except OSError:
        return 503, {"error": "OpenMessage isn't ready yet. Try again in a few minutes."}
    req = urllib.request.Request(
        BLOCK_URL, method="POST",
        data=json.dumps({"conversation_id": conversation_id, "action": action}).encode(),
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {token}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=50) as r:
            reply = json.load(r)
    except urllib.error.HTTPError as e:
        try:
            reply = json.load(e)
        except ValueError:
            reply = {}
        return e.code, {"error": str(reply.get("error") or "That didn't work.")[:300]}
    except (OSError, ValueError):
        return 502, {"error": "OpenMessage isn't answering. Try again in a few minutes."}
    return 200, {"ok": reply.get("ok") is True, "action": action}


class Handler(BaseHTTPRequestHandler):
    server_version = "om-pair-helper"
    sys_version = ""

    def log_message(self, fmt, *args):  # no request lines with paths or bodies
        pass

    def _send(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _host_ok(self):
        host = (self.headers.get("Host") or "").strip().lower()
        host = re.sub(r":\d+$", "", host)
        return host in LOOPBACK_HOSTS

    def do_GET(self):
        if not self._host_ok():
            return self._send(403, {"error": "forbidden"})
        path = self.path.split("?")[0]
        if path == "/spam":
            rules = read_rules()
            return self._send(200, {
                "rules": {
                    "phrases": rules.get("phrases") or [],
                    "numbers": rules.get("numbers") or [],
                    "mode": "block" if str(rules.get("mode", "")).strip().lower() == "block" else "log",
                },
                "recent": recent_spam(),
            })
        if path != "/pair":
            return self._send(404, {"error": "not found"})
        self._send(200, STATE.snapshot())

    def do_POST(self):
        if not self._host_ok():
            return self._send(403, {"error": "forbidden"})
        path = self.path.split("?")[0]
        if path not in ("/pair", "/spam", "/spam/action"):
            return self._send(404, {"error": "not found"})
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            n = -1
        if n <= 0 or n > MAX_BODY:
            return self._send(413 if n > MAX_BODY else 400, {"error": "bad request"})
        try:
            body = json.loads(self.rfile.read(n))
        except ValueError:
            return self._send(400, {"error": "bad request"})
        if path == "/spam":
            phrases, numbers, err = clean_rules(body)
            if err:
                return self._send(400, {"error": err})
            try:
                write_rules(phrases, numbers, body["mode"])
            except OSError as e:
                log(f"couldn't save spam rules: {type(e).__name__}")
                return self._send(500, {"error": "Couldn't save the rules."})
            log("spam rules changed")
            return self._send(200, {"ok": True, "phrases": phrases, "numbers": numbers, "mode": body["mode"]})
        if path == "/spam/action":
            conv = body.get("conversation_id") if isinstance(body, dict) else None
            action = body.get("action") if isinstance(body, dict) else None
            if not isinstance(conv, str) or not conv.strip() or len(conv) > 300 or action not in SPAM_ACTIONS:
                return self._send(400, {"error": "bad request"})
            code, reply = spam_action(conv.strip(), action)
            return self._send(code, reply)
        cookies, err = validate_cookies(body)
        if err:
            return self._send(400, {"error": err})
        with STATE.lock:
            if STATE.busy():
                return self._send(409, {"error": "a reconnect is already running"})
            if STATE.tries_today() >= MAX_PER_DAY:
                return self._send(429, {"error": f"already tried {MAX_PER_DAY} times today; try again tomorrow"})
        if google_connected() and body.get("force") is not True:
            return self._send(409, {"error": "it's connected already; nothing to do"})
        with STATE.lock:
            if STATE.busy():
                return self._send(409, {"error": "a reconnect is already running"})
            STATE.tries.append(now_ms())
            STATE._save_tries()
            STATE.job.update(state="starting", emoji=None, message="Starting", started_ms=now_ms(), updated_ms=now_ms())
        threading.Thread(target=run_job, args=(cookies,), daemon=True).start()
        self._send(202, STATE.snapshot())


def main():
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    log(f"listening on 127.0.0.1:{PORT}")
    srv.serve_forever()


if __name__ == "__main__":
    main()
