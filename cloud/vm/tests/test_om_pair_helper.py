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


if __name__ == "__main__":
    unittest.main(verbosity=1)
