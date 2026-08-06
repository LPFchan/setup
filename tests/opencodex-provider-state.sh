#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export PROVIDER_STATE_PATH="$TMP/providers/state.json"
mkdir -p "$(dirname "$PROVIDER_STATE_PATH")"

python3 - "$ROOT/files/opencodex" "$ROOT/files/provider-registry.json" <<'PY'
import copy
import json
import runpy
import sys
from pathlib import Path

launcher, registry_path = sys.argv[1:]
namespace = runpy.run_path(launcher, run_name="opencodex_provider_state_test")
globals_ = namespace["enabled_providers"].__globals__
registry = namespace["load_registry"](Path(registry_path))
state_path = Path(globals_["PROVIDER_STATE"])

# Missing state preserves registry defaults during bootstrap.
assert "commandcode" in namespace["enabled_providers"](registry)

state_path.write_text(json.dumps({
    "version": 1,
    "providers": {
        "commandcode": {"enabled": False},
        "codex": {"enabled": False},
        "anthropic": {"enabled": False},
    },
}))
effective = namespace["enabled_providers"](registry)
assert "commandcode" not in effective
assert "codex" in effective and "anthropic" in effective
assert namespace["provider_model_options"](
    "other",
    registry,
    {"commandcode/hidden": {"id": "commandcode/hidden", "efforts": []}},
) == []

# Local status reaches the OpenCodex config, which is what `ocx sync` filters on
# when it rebuilds the Codex model catalog the desktop picker reads.
auth = {"commandcode": {"key": "secret"}}
desired, _ = namespace["desired_opencodex_config"](registry, {}, auth)
assert desired["providers"]["commandcode"]["disabled"] is True
state_path.write_text(json.dumps({
    "version": 1,
    "providers": {"commandcode": {"enabled": True}},
}))
desired, _ = namespace["desired_opencodex_config"](registry, {}, auth)
assert desired["providers"]["commandcode"]["disabled"] is False

# A local enable never resurrects a provider whose key is gone.
desired, _ = namespace["desired_opencodex_config"](registry, {}, {})
assert desired["providers"]["commandcode"]["disabled"] is True

# Explicit local true overrides an OpenAI-compatible registry default.
registry_disabled = copy.deepcopy(registry)
registry_disabled["providers"]["commandcode"]["enabled"] = False
state_path.write_text(json.dumps({
    "version": 1,
    "providers": {"commandcode": {"enabled": True}},
}))
assert "commandcode" in namespace["enabled_providers"](registry_disabled)

# Disabled providers are neither probed nor accepted by direct run.
state_path.write_text(json.dumps({
    "version": 1,
    "providers": {"commandcode": {"enabled": False}},
}))
original_urlopen = namespace["urllib"].request.urlopen
try:
    namespace["urllib"].request.urlopen = lambda *args, **kwargs: (_ for _ in ()).throw(
        AssertionError("disabled provider was probed")
    )
    assert namespace["provider_support_index"](
        registry, {"commandcode": {"key": "secret"}}
    ) == {}
finally:
    namespace["urllib"].request.urlopen = original_urlopen

globals_["load_registry"] = lambda: registry
globals_["sys"].argv = [launcher, "run", "commandcode"]
try:
    namespace["main"]()
except namespace["UserError"] as exc:
    assert "provider is disabled: commandcode" in str(exc)
else:
    raise AssertionError("direct run accepted a disabled provider")

# A running proxy snapshots its config at startup, so applying enablement to
# disk alone leaves it answering `Provider is disabled` forever. Convergence is
# measured against the LIVE view, so a proxy that went stale on an earlier apply
# still gets restarted.
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

live_disabled = {"commandcode": True}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/healthz":
            body = json.dumps({"status": "ok"}).encode()
        elif self.path == "/api/providers":
            if self.headers.get("Authorization") != "Bearer test-token":
                self.send_response(401)
                self.end_headers()
                return
            body = json.dumps(
                # A raw control character in echoed model metadata must not
                # break the read; strict JSON would reject it.
                [{"name": name, "disabled": flag, "note": "a\nb"}
                 for name, flag in live_disabled.items()]
            ).encode().replace(b"\\n", b"\n")
        else:
            self.send_response(404)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
home = Path(globals_["HOME"])
port_file = home / "runtime-port.json"
port_file.parent.mkdir(parents=True, exist_ok=True)
port_file.write_text(json.dumps({"pid": 1, "port": server.server_address[1]}))
token_file = home / "admin-api-token"
token_file.write_text("test-token\n")
globals_["RUNTIME_PORT"] = port_file
globals_["ADMIN_TOKEN"] = token_file
ocx = home / "ocx"
ocx.write_text("#!/bin/sh\n")
ocx.chmod(0o700)
globals_["OCX"] = ocx

restarts = []


class FakeRun:
    def __init__(self):
        self.returncode = 0
        self.stdout = ""
        self.stderr = ""


globals_["subprocess"].run = lambda argv, *a, **k: restarts.append(argv) or FakeRun()
# Version drift is exercised on its own below; until then both sides agree so
# only routing convergence is under test.
globals_["installed_ocx_version"] = lambda: "2.0.0"
globals_["live_proxy_version"] = lambda port: "2.0.0"

# Live view stale (disabled) against a desired enable -> restart.
namespace["converge_live_proxy"]({"providers": {"commandcode": {"disabled": False}}})
assert restarts == [[str(ocx), "restart"]], restarts

# Live view already matches -> no restart.
restarts.clear()
namespace["converge_live_proxy"]({"providers": {"commandcode": {"disabled": True}}})
assert restarts == [], restarts

# No healthy proxy -> nothing to converge.
port_file.write_text(json.dumps({"pid": 1, "port": 1}))
namespace["converge_live_proxy"]({"providers": {"commandcode": {"disabled": False}}})
assert restarts == [], restarts

# An unreadable live view never triggers a blind restart.
port_file.write_text(json.dumps({"pid": 1, "port": server.server_address[1]}))
token_file.write_text("wrong-token\n")
namespace["converge_live_proxy"]({"providers": {"commandcode": {"disabled": False}}})
assert restarts == [], restarts

# The reported deepseek bug: a provider in the stored config but MISSING from
# the live view (the proxy snapshots config at startup) must restart even when
# no field can be compared — a live-only row is never the reason.
restarts.clear()
token_file.write_text("test-token\n")
live_disabled = {"openai": True}
namespace["converge_live_proxy"]({"providers": {"commandcode": {"disabled": True}}})
assert restarts == [[str(ocx), "restart"]], restarts

# Field tolerance: a minimal live row (name+disabled only) whose disabled flag
# matches must not falsely restart, however richly the desired entry is set —
# fields absent from the live row are not compared.
restarts.clear()
live_disabled = {"commandcode": True}
namespace["converge_live_proxy"]({
    "providers": {
        "commandcode": {
            "disabled": True,
            "adapter": "openai-chat",
            "authMode": "key",
            "liveModels": True,
            "baseUrl": "https://example.com/v1",
            "apiKey": "secret",
        }
    }
})
assert restarts == [], restarts

# The invocation path restarts a stale proxy instead of plain-ensuring, and a
# fresh proxy is plain-ensured as before.
config_path = Path(globals_["OPENCODEX_CONFIG"])
config_path.parent.mkdir(parents=True, exist_ok=True)
token_file.write_text("test-token\n")
restarts.clear()
config_path.write_text(json.dumps({"providers": {"commandcode": {"disabled": False}}}))
live_disabled = {"commandcode": True}
namespace["launch"]("commandcode", "codex", [], "commandcode/some-model")
assert [str(ocx), "restart"] in restarts, restarts
assert [str(ocx), "ensure"] not in restarts, restarts
restarts.clear()
config_path.write_text(json.dumps({"providers": {"commandcode": {"disabled": True}}}))
namespace["launch"]("commandcode", "codex", [], "commandcode/some-model")
assert [str(ocx), "restart"] not in restarts, restarts
assert [str(ocx), "ensure"] in restarts, restarts

# An update swaps the runtime out from under the running proxy, which keeps
# serving the old build until it restarts. Routing agrees on both sides here,
# so the version is the only thing that can force the restart.
globals_["live_proxy_version"] = lambda port: "2.0.0"
globals_["installed_ocx_version"] = lambda: "2.1.0"
assert namespace["proxy_version_drift"](1) == [
    "proxy is running ocx 2.0.0 but 2.1.0 is installed"
]
restarts.clear()
namespace["converge_live_proxy"]({"providers": {"commandcode": {"disabled": True}}})
assert restarts == [[str(ocx), "restart"]], restarts
restarts.clear()
namespace["launch"]("commandcode", "codex", [], "commandcode/some-model")
assert [str(ocx), "restart"] in restarts, restarts
assert [str(ocx), "ensure"] not in restarts, restarts

# A proxy or an install that reports no version is never drift, and matching
# versions leave a converged proxy alone.
for running, installed in (("2.0.0", None), (None, "2.1.0"), ("2.1.0", "2.1.0")):
    globals_["live_proxy_version"] = lambda port, v=running: v
    globals_["installed_ocx_version"] = lambda v=installed: v
    assert namespace["proxy_version_drift"](1) == [], (running, installed)
    restarts.clear()
    namespace["converge_live_proxy"]({"providers": {"commandcode": {"disabled": True}}})
    assert restarts == [], (running, installed, restarts)
globals_["live_proxy_version"] = lambda port: "2.0.0"
globals_["installed_ocx_version"] = lambda: "2.0.0"

# Pure comparison logic: absent providers flag, per-field diffs flag, and
# live-only / live-row-absent-field rows do not.
diff = namespace["provider_config_diff"]
assert diff(
    {"deepseek": {"disabled": False}},
    {"openai": {"disabled": False}},
) == ["provider 'deepseek' is not loaded by the running proxy"]
assert diff(
    {"commandcode": {"disabled": False}},
    {"commandcode": {"disabled": True}},
) == ["provider 'commandcode' disabled differs (config: False, proxy: True)"]
assert diff(
    {"commandcode": {"disabled": True, "adapter": "openai-chat"}},
    {"commandcode": {"disabled": True}},
) == []  # minimal live row: nothing beyond disabled to compare
assert diff(
    {"commandcode": {"disabled": True}},
    {"commandcode": {"disabled": True}, "user-added": {"disabled": False}},
) == []  # live-only providers are not setup-owned
assert diff(
    {"commandcode": {"disabled": True, "adapter": "anthropic"}},
    {"commandcode": {"disabled": True, "adapter": "openai-chat"}},
) == ["provider 'commandcode' adapter differs (config: anthropic, proxy: openai-chat)"]
assert diff(
    {"cc": {"disabled": True, "baseUrl": "https://example.com/v1/"}},
    {"cc": {"disabled": True, "baseUrl": "https://example.com/v1"}},
) == []  # a trailing slash is not routing drift
assert diff(
    {"cc": {"disabled": True, "baseUrl": "https://user:pass@example.com/v1"}},
    {"cc": {"disabled": True, "baseUrl": "https://example.com/v1"}},
) == []  # userinfo is stripped by the proxy, not routing drift
assert diff(
    {"cc": {"disabled": True, "apiKey": "secret"}},
    {"cc": {"disabled": True, "hasApiKey": True}},
) == []
assert diff(
    {"cc": {"disabled": True}},
    {"cc": {"disabled": True, "hasApiKey": True}},
) == ["provider 'cc' hasApiKey differs (config: False, proxy: True)"]

# proxy_restart_status: unreadable live never reports a pending restart, and a
# missing port is simply "not running" regardless of stored config.
orig_port = globals_["live_proxy_port"]
orig_view = globals_["live_provider_view"]
try:
    globals_["live_proxy_port"] = lambda: 10100
    config_path.write_text(json.dumps({"providers": {"deepseek": {"disabled": False}}}))
    globals_["live_provider_view"] = lambda port: {"openai": {"disabled": False}}
    assert namespace["proxy_restart_status"]() == (
        True,
        10100,
        ["provider 'deepseek' is not loaded by the running proxy"],
    )
    globals_["live_provider_view"] = lambda port: None
    assert namespace["proxy_restart_status"]() == (True, 10100, [])
    # An unreadable live view still surfaces version drift: it is read from
    # /healthz, not from the provider view.
    globals_["installed_ocx_version"] = lambda: "2.1.0"
    assert namespace["proxy_restart_status"]() == (
        True,
        10100,
        ["proxy is running ocx 2.0.0 but 2.1.0 is installed"],
    )
    globals_["installed_ocx_version"] = lambda: "2.0.0"
    globals_["live_proxy_port"] = lambda: None
    assert namespace["proxy_restart_status"]() == (False, None, [])
finally:
    globals_["live_proxy_port"] = orig_port
    globals_["live_provider_view"] = orig_view
server.shutdown()

for malformed in (
    [],
    {"version": 99, "providers": {}},
    {"version": 1, "providers": {"commandcode": {"enabled": "no"}}},
):
    state_path.write_text(json.dumps(malformed))
    try:
        namespace["enabled_providers"](registry)
    except namespace["UserError"] as exc:
        assert "provider state" in str(exc)
    else:
        raise AssertionError("malformed provider state was accepted")
PY

echo "opencodex provider-state tests passed"
