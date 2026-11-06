"""Tests for om-pair-helper.py: python3 -I cloud/vm/tests/test_om_pair_helper.py"""

import importlib.util
import json
import os
import stat
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
TMP = tempfile.mkdtemp()

GOOD = {"SID": "a", "SAPISID": "b", "__Secure-1PSID": "c", "__Secure-1PSIDTS": "d", "HSID": "e"}


class FakeStatus(BaseHTTPRequestHandler):
    connected = False

    def log_message(self, *a):
        pass

    def do_GET(self):
        body = json.dumps({"google": {"connected": FakeStatus.connected}}).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


status_srv = ThreadingHTTPServer(("127.0.0.1", 0), FakeStatus)
threading.Thread(target=status_srv.serve_forever, daemon=True).start()


def fake_pair(script_body):
    path = os.path.join(TMP, f"pair-{time.time_ns()}.sh")
    with open(path, "w") as f:
        f.write("#!/bin/sh\n" + script_body)
    os.chmod(path, stat.S_IRWXU)
    return path


def load_helper(**env):
    os.environ.update({
        "OM_PAIR_PORT": "0",
        "OM_DATA_DIR": TMP,
        "OM_PAIR_STATE": os.path.join(TMP, f"state-{time.time_ns()}.json"),
        "OM_PAIR_RUN_DIR": os.path.join(TMP, "run"),
        "OM_STATUS_URL": f"http://127.0.0.1:{status_srv.server_port}/api/status",
        "OM_PAIR_SETTLE": "0.05",
        "OM_PAIR_TIMEOUT": "10",
        **env,
    })
    spec = importlib.util.spec_from_file_location("helper", os.path.join(HERE, "..", "om-pair-helper.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    calls = []
    mod.SYSTEMCTL = lambda *a: calls.append(a) or True
    srv = ThreadingHTTPServer(("127.0.0.1", 0), mod.Handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return mod, srv, calls


def req(srv, method, body=None, host=None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(f"http://127.0.0.1:{srv.server_port}/pair", data=data, method=method)
    if data:
        r.add_header("Content-Type", "application/json")
    if host:
        r.add_header("Host", host)
    try:
        with urllib.request.urlopen(r, timeout=5) as resp:
            return resp.status, json.load(resp)
    except urllib.error.HTTPError as e:
        return e.code, json.load(e)


def wait_state(srv, states, timeout=5):
    end = time.time() + timeout
    while time.time() < end:
        _, s = req(srv, "GET")
        if s["state"] in states:
            return s
        time.sleep(0.02)
    raise AssertionError(f"never reached {states}; last {s}")


class PairHelperTest(unittest.TestCase):
    def setUp(self):
        FakeStatus.connected = False

    def test_happy_path(self):
        seen = os.path.join(TMP, "seen.json")
        pair = fake_pair(f'cp "$1" {seen}\necho "EMOJI: 🦊"\nsleep 0.3\necho "Pairing successful"\n')
        mod, srv, calls = load_helper(OM_PAIR_CMD=pair)
        code, s = req(srv, "POST", {"cookies": GOOD})
        self.assertEqual(code, 202)
        s = wait_state(srv, {"waiting_for_tap"})
        self.assertEqual(s["emoji"], "🦊")
        FakeStatus.connected = True
        s = wait_state(srv, {"connected", "failed"})
        self.assertEqual(s["state"], "connected")
        self.assertEqual(calls, [("stop", "openmessage"), ("start", "openmessage")])
        with open(seen) as f:
            self.assertEqual(json.load(f), GOOD)
        self.assertEqual(os.listdir(os.path.join(TMP, "run")), [])  # login deleted
        self.assertEqual(s["tries_left_today"], 2)
        self.assertNotIn("SID", json.dumps(s))

    def test_failed_pair_restarts_and_deletes(self):
        pair = fake_pair('echo "EMOJI: 🐢"\nexit 1\n')
        mod, srv, calls = load_helper(OM_PAIR_CMD=pair)
        self.assertEqual(req(srv, "POST", {"cookies": GOOD})[0], 202)
        s = wait_state(srv, {"failed", "connected"})
        self.assertEqual(s["state"], "failed")
        self.assertIsNone(s["emoji"])
        self.assertIn(("start", "openmessage"), calls)
        self.assertEqual(os.listdir(os.path.join(TMP, "run")), [])

    def test_refusals(self):
        pair = fake_pair("sleep 1\n")
        mod, srv, calls = load_helper(OM_PAIR_CMD=pair, OM_PAIR_MAX_PER_DAY="1")
        self.assertEqual(req(srv, "POST", {"cookies": GOOD}, host="evil.example")[0], 403)
        self.assertEqual(req(srv, "GET", host="evil.example")[0], 403)
        self.assertEqual(req(srv, "POST", {"cookies": {"SID": "a"}})[0], 400)  # sign-in unfinished
        self.assertEqual(req(srv, "POST", {"cookies": dict(GOOD, SID="x;y")})[0], 400)
        self.assertEqual(req(srv, "POST", {"nope": 1})[0], 400)
        FakeStatus.connected = True
        self.assertEqual(req(srv, "POST", {"cookies": GOOD})[0], 409)  # connected already
        FakeStatus.connected = False
        self.assertEqual(req(srv, "POST", {"cookies": GOOD})[0], 202)
        self.assertEqual(req(srv, "POST", {"cookies": GOOD})[0], 409)  # one at a time
        wait_state(srv, {"failed", "connected"})
        self.assertEqual(req(srv, "POST", {"cookies": GOOD})[0], 429)  # daily cap
        self.assertEqual(calls.count(("stop", "openmessage")), 1)

    def test_force_when_connected(self):
        pair = fake_pair('echo "Pairing successful"\n')
        mod, srv, calls = load_helper(OM_PAIR_CMD=pair)
        FakeStatus.connected = True
        self.assertEqual(req(srv, "POST", {"cookies": GOOD, "force": True})[0], 202)
        self.assertEqual(wait_state(srv, {"connected", "failed"})["state"], "connected")


class FakeBlock(BaseHTTPRequestHandler):
    seen = []
    status = 200

    def log_message(self, *a):
        pass

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        FakeBlock.seen.append((self.headers.get("Authorization"), json.loads(self.rfile.read(n))))
        body = json.dumps({"ok": FakeBlock.status == 200, "error": "" if FakeBlock.status == 200 else "refused: saved contact"}).encode()
        self.send_response(FakeBlock.status)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


block_srv = ThreadingHTTPServer(("127.0.0.1", 0), FakeBlock)
threading.Thread(target=block_srv.serve_forever, daemon=True).start()


def spam_req(srv, method, path="/spam", body=None, host=None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(f"http://127.0.0.1:{srv.server_port}{path}", data=data, method=method)
    if host:
        r.add_header("Host", host)
    try:
        with urllib.request.urlopen(r, timeout=10) as resp:
            return resp.status, json.load(resp)
    except urllib.error.HTTPError as e:
        return e.code, json.load(e)


class SpamTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.rules = os.path.join(self.dir, "spam-rules.json")
        self.log = os.path.join(self.dir, "spam-watch.jsonl")
        self.token = os.path.join(self.dir, "control.token")
        self.mod, self.srv, _ = load_helper(
            OM_PAIR_CMD=fake_pair("true\n"), OM_SPAM_RULES=self.rules, OM_SPAM_LOG=self.log,
            OM_CONTROL_TOKEN_FILE=self.token, OM_BLOCK_URL=f"http://127.0.0.1:{block_srv.server_port}/api/spam/block")
        FakeBlock.seen = []
        FakeBlock.status = 200

    def test_no_file_means_log_mode_and_nothing_recent(self):
        code, d = spam_req(self.srv, "GET")
        self.assertEqual(code, 200)
        self.assertEqual(d, {"rules": {"phrases": [], "numbers": [], "mode": "log"}, "recent": []})

    def test_save_cleans_up_and_keeps_other_settings(self):
        with open(self.rules, "w") as f:
            json.dump({"phrases": ["old"], "max_blocks_per_day": 7, "no_report": True}, f)
        code, d = spam_req(self.srv, "POST", body={
            "phrases": [" Car Warranty ", "car warranty", ""], "numbers": ["+1 (555) 123-4567", "15551234567"], "mode": "block"})
        self.assertEqual(code, 200)
        self.assertEqual(d["phrases"], ["Car Warranty"])
        self.assertEqual(d["numbers"], ["15551234567"])
        saved = json.load(open(self.rules))
        self.assertEqual(saved["mode"], "block")
        self.assertEqual(saved["max_blocks_per_day"], 7)
        self.assertTrue(saved["no_report"])
        self.assertEqual(stat.S_IMODE(os.stat(self.rules).st_mode), 0o600)
        self.assertEqual(os.listdir(self.dir).count("spam-rules.json.tmp"), 0)

    def test_save_refuses_bad_rules_and_changes_nothing(self):
        for bad in (
            {"phrases": ["ok phrase"], "numbers": [], "mode": "delete-all"},
            {"phrases": "x", "numbers": [], "mode": "log"},
            {"phrases": ["ab"], "numbers": [], "mode": "block"},  # would match almost everything
            {"phrases": ["a" * 201], "numbers": [], "mode": "log"},
            {"phrases": ["line\nbreak"], "numbers": [], "mode": "log"},
            {"phrases": [], "numbers": ["call me"], "mode": "log"},
            {"phrases": [], "numbers": ["123"], "mode": "log"},
            {"phrases": ["abc"] * 501, "numbers": [], "mode": "log"},
        ):
            self.assertEqual(spam_req(self.srv, "POST", body=bad)[0], 400, bad)
        self.assertFalse(os.path.exists(self.rules))

    def test_recent_is_newest_first_and_skips_junk(self):
        with open(self.log, "w") as f:
            f.write(json.dumps({"time": "2026-11-01T10:00:00Z", "sender_number": "5551112222", "matched": ["abc"], "snippet": "first", "conversation_id": "c1"}) + "\n")
            f.write("not json\n")
            f.write(json.dumps({"time": "2026-11-02T10:00:00Z", "sender_name": "Bob", "action": "blocked", "conversation_id": "c2", "is_group": True}) + "\n")
        _, d = spam_req(self.srv, "GET")
        self.assertEqual([e["conversation_id"] for e in d["recent"]], ["c2", "c1"])
        self.assertEqual(d["recent"][0]["sender"], "Bob")
        self.assertTrue(d["recent"][0]["is_group"])
        self.assertEqual(d["recent"][1]["action"], "logged")  # old log lines have none

    def test_recent_is_capped(self):
        with open(self.log, "w") as f:
            for i in range(self.mod.RECENT_ENTRIES + 20):
                f.write(json.dumps({"conversation_id": f"c{i}"}) + "\n")
        _, d = spam_req(self.srv, "GET")
        self.assertEqual(len(d["recent"]), self.mod.RECENT_ENTRIES)

    def test_action_sends_the_token_and_passes_refusals_on(self):
        with open(self.token, "w") as f:
            f.write("tok\n")
        code, d = spam_req(self.srv, "POST", "/spam/action", {"conversation_id": "c1", "action": "unblock"})
        self.assertEqual((code, d["ok"]), (200, True))
        self.assertEqual(FakeBlock.seen[0], ("Bearer tok", {"conversation_id": "c1", "action": "unblock"}))
        FakeBlock.status = 422
        code, d = spam_req(self.srv, "POST", "/spam/action", {"conversation_id": "c1", "action": "block_and_report"})
        self.assertEqual(code, 422)
        self.assertIn("saved contact", d["error"])
        self.assertNotIn("tok", json.dumps(d))

    def test_action_refusals(self):
        self.assertEqual(spam_req(self.srv, "POST", "/spam/action", {"conversation_id": "c1", "action": "block"})[0], 400)
        self.assertEqual(spam_req(self.srv, "POST", "/spam/action", {"action": "unblock"})[0], 400)
        self.assertEqual(spam_req(self.srv, "POST", "/spam/action", {"conversation_id": "c1", "action": "unblock"})[0], 503)  # no token yet
        self.assertEqual(FakeBlock.seen, [])

    def test_only_loopback_hosts(self):
        self.assertEqual(spam_req(self.srv, "GET", host="evil.example")[0], 403)
        self.assertEqual(spam_req(self.srv, "POST", body={"phrases": [], "numbers": [], "mode": "log"}, host="evil.example")[0], 403)
        self.assertFalse(os.path.exists(self.rules))


if __name__ == "__main__":
    unittest.main(verbosity=1)
