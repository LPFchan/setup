#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export LOST_AUTH_STORE="$TMP/auth.json"
export LOST_AUTH_SSH_KEY="$TMP/ssh/id_ed25519"

# The machine report generates the key on first use and reports it bare.
python3 - "$ROOT/files/auth" <<'PY'
import os, runpy, sys
m = runpy.run_path(sys.argv[1], run_name="auth_client_test")
report = m["_machine_report"]()
key = report["key"].split(" ")
assert key[0] == "ssh-ed25519" and len(key) == 2, report
assert os.path.exists(os.environ["LOST_AUTH_SSH_KEY"])
assert m["_machine_report"]()["key"] == report["key"]
# A private key whose public half went missing still reports the same key.
os.unlink(os.environ["LOST_AUTH_SSH_KEY"] + ".pub")
assert m["_machine_report"]()["key"] == report["key"]
assert os.path.exists(os.environ["LOST_AUTH_SSH_KEY"] + ".pub")
# An undecodable public key reports no key instead of failing.
good = open(os.environ["LOST_AUTH_SSH_KEY"] + ".pub", "rb").read()
open(os.environ["LOST_AUTH_SSH_KEY"] + ".pub", "wb").write(b"\xff\xfe")
assert m["_machine_report"]()["key"] == ""
open(os.environ["LOST_AUTH_SSH_KEY"] + ".pub", "wb").write(good)
# A key directory that cannot be created reports no key instead of failing.
blocker = os.path.join(os.path.dirname(os.environ["LOST_AUTH_SSH_KEY"]), "file")
open(blocker, "w").close()
m["_machine_key"].__globals__["SSH_KEY"] = m["pathlib"].Path(blocker) / "ssh" / "id_ed25519"
assert m["_machine_report"]()["key"] == ""
assert report["hostname"] and "." not in report["hostname"]
assert isinstance(report["needs_term"], bool)
PY

python3 - "$ROOT/files/auth" <<'PY'
import contextlib, io, json, os, runpy, sys

m = runpy.run_path(sys.argv[1], run_name="auth_client_test")
REPORT = {"key":"ssh-ed25519 AAAA", "hostname":"fox", "tailnet":"fox.tail.ts.net",
          "user":"fox", "needs_term":False}
m["cmd_login"].__globals__["_machine_report"] = lambda: dict(REPORT)
calls = []
previous_sessions = []
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
    if path == "/api/device":
        assert kwargs["form"] == {
            "client":"setup-auth", "device_name":m["DEVICE_NAME"],
            "machine":json.dumps(REPORT, separators=(",", ":")),
        }
        return {"device_code":"device", "user_code":"FOX-1234",
                "verification_uri_complete":"https://auth.lost.plus/device?code=FOX-1234",
                "expires_in":30, "interval":1}
    if path == "/api/device/token":
        previous_sessions.append(kwargs["form"]["previous_session"])
        return {**server, "session": {
            "id":"dev_one", "refresh_token":"refresh-secret", "expires_at":9999999999,
        }}
    if path == "/api/device/session/token":
        assert kwargs["json_body"] == {
            "refresh_token":"refresh-secret", "device_name":m["DEVICE_NAME"],
            "machine":REPORT,
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
assert previous_sessions == [""]
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

# An expired session, or a login from another origin, names no account here.
store_path = os.environ["LOST_AUTH_STORE"]
current = json.load(open(store_path))
for changed, wanted_exit in (
    ({**current, "session": {**current["session"], "expires_at": 1}}, 4),
    ({**current, "origin": "https://auth.example.test"}, 1),
    # A version-one store still serves its tokens: not a logout.
    ({**current, "version": 1}, 1),
):
    json.dump(changed, open(store_path, "w"))
    try:
        m["cmd_context"]()
    except m["AuthError"] as exc:
        assert exc.exit_code == wanted_exit, exc.exit_code
    else:
        raise AssertionError("context reported an account it no longer speaks for")
# No store at all is a definite logout (4); one that cannot be read is not (1).
for write, wanted_exit in ((lambda: os.remove(store_path), 4),
                           (lambda: open(store_path, "w").write("{broken"), 1)):
    write()
    try:
        m["cmd_context"]()
    except m["AuthError"] as exc:
        assert exc.exit_code == wanted_exit, exc.exit_code
    else:
        raise AssertionError("context answered without a readable login")
json.dump(current, open(store_path, "w"))
os.chmod(store_path, 0o600)

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

# --cached reads the saved token without touching the network.
m["_refresh"].__globals__["_request"] = context_must_not_request
cached_output = io.StringIO()
with contextlib.redirect_stdout(cached_output):
    m["cmd_token_cached"]("today")
assert cached_output.getvalue().strip() == "global-secret" and not requested
# It never hands out a token saved for another Auth origin.
saved_origin = m["cmd_token_cached"].__globals__["ORIGIN"]
m["cmd_token_cached"].__globals__["ORIGIN"] = "https://elsewhere.example"
try:
    m["cmd_token_cached"]("today")
except m["AuthError"] as exc:
    assert "another Auth origin" in str(exc)
else:
    raise AssertionError("cached token from another origin was accepted")
m["cmd_token_cached"].__globals__["ORIGIN"] = saved_origin
# Nor one whose session has expired.
expired_store = json.load(open(os.environ["LOST_AUTH_STORE"]))
live_store = json.dumps(expired_store)
expired_store["session"]["expires_at"] = 1
open(os.environ["LOST_AUTH_STORE"], "w").write(json.dumps(expired_store))
try:
    m["cmd_token_cached"]("today")
except m["AuthError"] as exc:
    assert exc.exit_code == 4
else:
    raise AssertionError("cached token from an expired session was accepted")
open(os.environ["LOST_AUTH_STORE"], "w").write(live_store)
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
# A new login names the session it replaces, so Auth can end it.
assert previous_sessions[-1] == "refresh-secret"
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
# An invalidated session no longer names an account.
try:
    m["cmd_context"]()
except m["AuthError"] as exc:
    assert exc.exit_code == 4
else:
    raise AssertionError("an invalidated session still reported its account")

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

# `auth request` sends the setup session itself, not a bearer token.
json.dump({**saved, "session_state":"active"}, open(os.environ["LOST_AUTH_STORE"], "w"))
sent = []
def fleet(path, **kwargs):
    sent.append((path, kwargs))
    return {"version":"v1", "keys":[]}
m["cmd_request"].__globals__["_request"] = fleet
request_output = io.StringIO()
with contextlib.redirect_stdout(request_output):
    m["cmd_request"]("GET", "/api/fleet")
assert json.loads(request_output.getvalue()) == {"version":"v1", "keys":[]}
assert sent == [("/api/fleet", {"json_body":None, "session":"refresh-secret", "method":"GET",
                                "timeout":m["REQUEST_TIMEOUT"]})]
# A body of "-" is read from stdin, since a config push outgrows an argument.
sent.clear()
real_stdin = sys.stdin
sys.stdin = io.StringIO('{"base":3,"put":[]}')
try:
    with contextlib.redirect_stdout(io.StringIO()):
        m["cmd_request"]("POST", "/api/fleet/config/push", "-")
finally:
    sys.stdin = real_stdin
assert sent[0][1]["json_body"] == {"base":3, "put":[]}
# A login saved for another origin than the pinned one is refused with exit
# 5 and nothing sent, so fleet never pushes to an account it did not pull.
sent.clear()
m["cmd_request"].__globals__["ORIGIN"] = "https://elsewhere.example"
try:
    m["cmd_request"]("POST", "/api/fleet/config/push", '{"base":1}')
except m["AuthError"] as exc:
    assert exc.exit_code == 5
else:
    raise AssertionError("request for another origin's login was sent")
assert sent == []
m["cmd_request"].__globals__["ORIGIN"] = saved_origin
# An error answer reaches the caller as JSON with its status and Retry-After,
# so a stale push or a rate limit is not mistaken for an outage.
def limited(path, **kwargs):
    raise m["AuthError"]("too many pushes", 429, retry_after=120)
m["cmd_request"].__globals__["_request"] = limited
error_output = io.StringIO()
try:
    with contextlib.redirect_stdout(error_output):
        m["cmd_request"]("POST", "/api/fleet/config/push", '{"base":1}')
except m["AuthError"] as exc:
    assert exc.exit_code == 6
else:
    raise AssertionError("error answer was not reported")
assert json.loads(error_output.getvalue()) == {"status":429, "error":"too many pushes", "retry_after":120}
assert json.load(open(os.environ["LOST_AUTH_STORE"]))["session_state"] == "active"
# An unreachable Auth keeps its plain failure and prints nothing.
def down(path, **kwargs):
    raise m["AuthError"]("cannot reach Auth", transient=True)
m["cmd_request"].__globals__["_request"] = down
down_output = io.StringIO()
try:
    with contextlib.redirect_stdout(down_output):
        m["cmd_request"]("GET", "/api/fleet")
except m["AuthError"] as exc:
    assert exc.exit_code == 1
assert down_output.getvalue() == ""
m["cmd_request"].__globals__["_request"] = fleet
for method, path in (("GET", "https://elsewhere.example/api/fleet"), ("TRACE", "/api/fleet")):
    try:
        m["cmd_request"](method, path)
    except m["AuthError"] as exc:
        assert exc.exit_code == 2
    else:
        raise AssertionError("bad request was sent")
# A rejected session is recorded, so setup offers the login again.
def gone(path, **kwargs):
    raise m["AuthError"]("setup session is invalid, expired, or revoked", 401)
m["cmd_request"].__globals__["_request"] = gone
try:
    m["cmd_request"]("GET", "/api/fleet")
except m["AuthError"] as exc:
    assert exc.exit_code == 4
else:
    raise AssertionError("rejected session was not reported")
assert json.load(open(os.environ["LOST_AUTH_STORE"]))["session_state"] == "invalid"
# A 401 for a session another login already replaced leaves the new one alone.
json.dump({**saved, "session_state":"active"}, open(os.environ["LOST_AUTH_STORE"], "w"))
def replaced(path, **kwargs):
    json.dump({**saved, "session_state":"active",
               "session":{**saved["session"], "refresh_token":"newer-secret"}},
              open(os.environ["LOST_AUTH_STORE"], "w"))
    raise m["AuthError"]("setup session is invalid, expired, or revoked", 401)
m["cmd_request"].__globals__["_request"] = replaced
try:
    m["cmd_request"]("GET", "/api/fleet")
except m["AuthError"] as exc:
    assert exc.exit_code == 4
assert json.load(open(os.environ["LOST_AUTH_STORE"]))["session_state"] == "active"

# _request reads Retry-After off an error answer.
import email.message, urllib.error
def answer_429(request, timeout):
    headers = email.message.Message()
    headers["Retry-After"] = "90"
    raise urllib.error.HTTPError(request.full_url, 429, "Too Many Requests", headers,
                                 io.BytesIO(b'{"error":"slow down"}'))
real_urlopen = m["_request"].__globals__["urllib"].request.urlopen
m["_request"].__globals__["urllib"].request.urlopen = answer_429
try:
    m["_request"]("/api/fleet")
except m["AuthError"] as exc:
    assert (exc.status, exc.retry_after, str(exc)) == (429, 90, "slow down")
else:
    raise AssertionError("429 was not raised")
finally:
    m["_request"].__globals__["urllib"].request.urlopen = real_urlopen

# A malformed saved session never blocks the login that would replace it.
broken = json.load(open(os.environ["LOST_AUTH_STORE"]))
broken["session"] = "garbage"
json.dump(broken, open(os.environ["LOST_AUTH_STORE"], "w"))
assert m["_previous_session"]() == ""
try:
    m["cmd_request"]("GET", "/api/fleet")
except m["AuthError"] as exc:
    assert exc.exit_code == 4
else:
    raise AssertionError("malformed session was used")

print("auth client tests passed")
PY
