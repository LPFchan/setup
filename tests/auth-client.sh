#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export LOST_AUTH_STORE="$TMP/auth.json"

python3 - "$ROOT/files/auth" <<'PY'
import json, os, runpy, sys

m = runpy.run_path(sys.argv[1], run_name="auth_client_test")
calls = []

def global_request(path, **kwargs):
    calls.append((path, kwargs))
    if path == "/api/setup/device":
        return {"device_code":"device", "user_code":"FOX-1234",
                "verification_uri_complete":"https://auth.lost.plus/device?code=FOX-1234",
                "expires_in":30, "interval":1}
    if path == "/api/setup/device/token":
        return {"mode":"global", "tokens":{"*":"global-secret"}}
    raise AssertionError(path)

m["_request"].__globals__["_request"] = global_request
m["cmd_login"].__globals__["_request"] = global_request
m["cmd_login"].__globals__["_open_browser"] = lambda uri: None
m["cmd_login"].__globals__["time"].sleep = lambda _: None
m["cmd_login"]()
saved = json.load(open(os.environ["LOST_AUTH_STORE"]))
assert saved["mode"] == "global" and saved["tokens"] == {"*":"global-secret"}
assert oct(os.stat(os.environ["LOST_AUTH_STORE"]).st_mode & 0o777) == "0o600"

m["cmd_token"]("chat-v1")
m["cmd_token"]("obsidian")

json.dump({"version":1, "origin":"https://auth.lost.plus", "mode":"per-service",
           "tokens":{"chat-v1":"chat-secret", "obsidian":"obsidian-secret"}},
          open(os.environ["LOST_AUTH_STORE"], "w"))
m["cmd_token"]("chat-v1")
try:
    m["cmd_token"]("comfyui")
except m["AuthError"] as exc:
    assert "auth login" in str(exc)
else:
    raise AssertionError("missing per-service credential succeeded")

print("auth client tests passed")
PY
