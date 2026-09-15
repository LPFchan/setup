#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export LOST_AUTH_STORE="$TMP/auth.json"

python3 - "$ROOT/files/auth" <<'PY'
import contextlib, io, json, os, runpy, sys

m = runpy.run_path(sys.argv[1], run_name="auth_client_test")
calls = []
server = {
    "subject": "42",
    "mode": "global",
    "tokens": {"*": "global-secret"},
    "active_scopes": ["*"],
    "unavailable_scopes": [],
    "session_expires_at": 9999999999,
}

def request(path, **kwargs):
    calls.append((path, kwargs))
    if path == "/api/setup/device":
        assert kwargs["form"] == {
            "client":"setup-auth", "device_name":m["DEVICE_NAME"],
        }
        return {"device_code":"device", "user_code":"FOX-1234",
                "verification_uri_complete":"https://auth.lost.plus/device?code=FOX-1234",
                "expires_in":30, "interval":1}
    if path == "/api/setup/device/token":
        return {**server, "session": {
            "id":"dev_one", "refresh_token":"refresh-secret", "expires_at":9999999999,
        }}
    if path == "/api/setup/session/token":
        assert kwargs["json_body"] == {
            "refresh_token":"refresh-secret", "device_name":m["DEVICE_NAME"],
        }
        return dict(server)
    raise AssertionError(path)

m["cmd_login"].__globals__["_request"] = request
m["_refresh"].__globals__["_request"] = request
m["cmd_login"].__globals__["_open_browser"] = lambda uri: None
m["cmd_login"].__globals__["time"].sleep = lambda _: None
login_output = io.StringIO()
with contextlib.redirect_stdout(login_output):
    m["cmd_login"]()
assert login_output.getvalue().splitlines()[:2] == [
    "Waiting for approval… Open :",
    "https://auth.lost.plus/device?code=FOX-1234",
]
saved = json.load(open(os.environ["LOST_AUTH_STORE"]))
assert saved["version"] == 2
assert saved["session"]["refresh_token"] == "refresh-secret"
assert saved["mode"] == "global" and saved["tokens"] == {"*":"global-secret"}
assert oct(os.stat(os.environ["LOST_AUTH_STORE"]).st_mode & 0o777) == "0o600"
context_output = io.StringIO()
with contextlib.redirect_stdout(context_output):
    m["cmd_context"]()
assert json.loads(context_output.getvalue()) == {
    "origin": "https://auth.lost.plus", "subject": "42",
}
expected_context = {"origin": "https://auth.lost.plus", "subject": "42"}

token_output = io.StringIO()
with contextlib.redirect_stdout(token_output):
    m["cmd_token"]("chat-v1", expected_context)
assert token_output.getvalue().strip() == "global-secret"

# Context validation and refresh share the store lock. A consumer that first
# read account A cannot bind a token from account B if login changes mid-sync.
requested = False
def context_must_not_request(path, **kwargs):
    global requested
    requested = True
    raise AssertionError("context-mismatched token lookup made a request")
m["_refresh"].__globals__["_request"] = context_must_not_request
try:
    m["cmd_token"]("chat-v1", {
        "origin": "https://auth.lost.plus", "subject": "84",
    })
except m["AuthError"] as exc:
    assert exc.exit_code == 5 and "changed during credential sync" in str(exc)
else:
    raise AssertionError("context-mismatched token lookup was accepted")
assert not requested
m["_refresh"].__globals__["_request"] = request

# Rotated server credentials replace the local bearer without another login.
server["tokens"] = {"*":"rotated-secret"}
with contextlib.redirect_stdout(io.StringIO()):
    m["cmd_token"]("obsidian")
assert json.load(open(os.environ["LOST_AUTH_STORE"]))["tokens"] == {"*":"rotated-secret"}

# Revocation removes the cached bearer while leaving the device session intact.
server["tokens"] = {}
server["active_scopes"] = []
try:
    m["cmd_token"]("chat-v1")
except m["AuthError"] as exc:
    assert "no active credential" in str(exc)
    assert exc.exit_code == 3
else:
    raise AssertionError("revoked bearer remained available")
saved = json.load(open(os.environ["LOST_AUTH_STORE"]))
assert saved["session"]["refresh_token"] == "refresh-secret" and saved["tokens"] == {}

# A temporarily unreadable active token preserves an existing last-known-good copy.
saved["tokens"] = {"*":"cached-secret"}
json.dump(saved, open(os.environ["LOST_AUTH_STORE"], "w"))
server["active_scopes"] = ["*"]
server["unavailable_scopes"] = ["*"]
with contextlib.redirect_stdout(io.StringIO()):
    m["cmd_refresh"]()
assert json.load(open(os.environ["LOST_AUTH_STORE"]))["tokens"] == {"*":"cached-secret"}

# An active-but-unreadable credential is unavailable, not revoked. Consumers
# must not interpret it as permission to delete another last-known-good copy.
unreadable = json.load(open(os.environ["LOST_AUTH_STORE"]))
unreadable["tokens"] = {}
json.dump(unreadable, open(os.environ["LOST_AUTH_STORE"], "w"))
try:
    m["cmd_token"]("chat-v1")
except m["AuthError"] as exc:
    assert exc.exit_code == 1
    assert "cannot currently be retrieved" in str(exc)
else:
    raise AssertionError("unreadable active bearer was reported as available")

# A different account never inherits a cached token that the server cannot reveal.
server["subject"] = "84"
with contextlib.redirect_stdout(io.StringIO()):
    m["cmd_login"]()
switched = json.load(open(os.environ["LOST_AUTH_STORE"]))
assert switched["account_sub"] == "84" and switched["tokens"] == {}
server["subject"] = "42"
with contextlib.redirect_stdout(io.StringIO()):
    m["cmd_login"]()
saved = json.load(open(os.environ["LOST_AUTH_STORE"]))
saved["tokens"] = {"*":"cached-secret"}
json.dump(saved, open(os.environ["LOST_AUTH_STORE"], "w"))

# A configured-origin change must never disclose the renewable session secret.
requested = False
def must_not_request(path, **kwargs):
    global requested
    requested = True
    raise AssertionError("origin-mismatched refresh made a request")
m["_refresh"].__globals__["ORIGIN"] = "https://replacement.invalid"
m["_refresh"].__globals__["_request"] = must_not_request
try:
    m["cmd_token"]("chat-v1")
except m["AuthError"] as exc:
    assert "saved login belongs to" in str(exc)
else:
    raise AssertionError("origin-mismatched login was accepted")
assert not requested
m["_refresh"].__globals__["ORIGIN"] = "https://auth.lost.plus"

# An invalidated device session fails closed instead of returning cached credentials.
def revoked(path, **kwargs):
    raise m["AuthError"]("setup session is invalid, expired, or revoked", 401)
m["_refresh"].__globals__["_request"] = revoked
try:
    m["cmd_token"]("chat-v1")
except m["AuthError"] as exc:
    assert exc.status == 401
else:
    raise AssertionError("revoked device session used cached credentials")
invalid = json.load(open(os.environ["LOST_AUTH_STORE"]))
assert invalid["session_state"] == "invalid" and invalid["tokens"] == {}

# A later network outage cannot revive credentials after confirmed invalidation.
def offline(path, **kwargs):
    raise m["AuthError"]("cannot reach Auth", transient=True)
m["_refresh"].__globals__["_request"] = offline
try:
    m["cmd_token"]("chat-v1")
except m["AuthError"] as exc:
    assert exc.exit_code == 4
else:
    raise AssertionError("invalidated setup session revived during outage")

# A network outage still permits a last-known-good bearer for an active session.
saved["session_state"] = "active"
saved["tokens"] = {"*":"cached-secret"}
json.dump(saved, open(os.environ["LOST_AUTH_STORE"], "w"))
stdout, stderr = io.StringIO(), io.StringIO()
with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
    m["cmd_token"]("chat-v1")
assert stdout.getvalue().strip() == "cached-secret"
assert "using cached credential" in stderr.getvalue()

# Cached bearers stop working at the server-provided session deadline, even
# when Auth is offline and cannot reject the session itself.
expired = json.load(open(os.environ["LOST_AUTH_STORE"]))
expired["session"]["expires_at"] = 1
json.dump(expired, open(os.environ["LOST_AUTH_STORE"], "w"))
try:
    m["cmd_token"]("chat-v1")
except m["AuthError"] as exc:
    assert exc.exit_code == 4 and "expired" in str(exc)
else:
    raise AssertionError("expired device session used a cached credential")
expired = json.load(open(os.environ["LOST_AUTH_STORE"]))
assert expired["session_state"] == "invalid" and expired["tokens"] == {}

# Version-one stores remain usable long enough to reauthorize, but status requests renewal.
json.dump({"version":1, "origin":"https://auth.lost.plus", "mode":"per-service",
           "tokens":{"chat-v1":"legacy-secret"}},
          open(os.environ["LOST_AUTH_STORE"], "w"))
legacy_out, legacy_err = io.StringIO(), io.StringIO()
with contextlib.redirect_stdout(legacy_out), contextlib.redirect_stderr(legacy_err):
    m["cmd_token"]("chat-v1")
assert legacy_out.getvalue().strip() == "legacy-secret"
assert "cannot refresh" in legacy_err.getvalue()
status_output = io.StringIO()
with contextlib.redirect_stdout(status_output):
    assert m["cmd_status"]() == 1
assert "needs renewal" in status_output.getvalue()

print("auth client tests passed")
PY
