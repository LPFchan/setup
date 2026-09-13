#!/usr/bin/env bash
# Exercises the harnesses payload (files/harnesses) settings + mcp merge
# logic in a scratch HOME, so no real machine state is touched.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export HARNESSES_MANIFEST="$ROOT/files/harnesses-manifest.json"
mkdir -p "$HOME/.claude" "$HOME/.codex" "$HOME/.t3/userdata"

python3 - "$ROOT/files/harnesses" <<'PY'
import json, os, runpy, subprocess, sys, tempfile
from pathlib import Path

payload = sys.argv[1]
HOME = Path(os.environ["HOME"])
ns = runpy.run_path(payload, run_name="harnesses_payload_test")

# --- settings: additive claude allow-list, preserved custom keys, t3 models ---
claude = HOME/".claude/settings.json"
claude.write_text(json.dumps({
    "permissions": {"allow": ["Read", "mcp__custom__*", "Skill"]},
    "effortLevel": "low",
    "custom_key": "keepme",
}))
t3_path = HOME/".t3/userdata/settings.json"
t3_path.write_text(json.dumps({"providerInstances": {"claudeAgent": {"driver": "claudeAgent",
    "enabled": True, "config": {"customModels": [
        {"slug": "grimoire/qwen3.8-flash-next-uncensored-nvfp4", "name": "stale bare row"},
        {"slug": "operator/private-model", "name": "Operator model"},
        {"slug": "codex/gpt-6-astra", "name": "stale prefixed row"},
    ]}}}}))
ns["cmd_settings"]([])
d = json.loads(claude.read_text())
assert d["custom_key"] == "keepme", "custom key lost"
assert d["effortLevel"] == "high", "manifest scalar not applied"
allow = d["permissions"]["allow"]
for keep in ("Read", "mcp__custom__*", "Skill"):
    assert keep in allow, f"existing allow entry {keep} clobbered"
manifest = json.loads(Path(os.environ["HARNESSES_MANIFEST"]).read_text())
granted = set(manifest["settings"]["claude"]["permissionsAllowAdd"])
for srv in manifest["mcpServers"]:
    assert "mcp__%s__*" % srv["name"] in granted, \
        "mcp server %s enrolls under a name the allow-list does not grant" % srv["name"]
for added in ("mcp__obsidian-direct__*", "mcp__vaultwarden-secrets__*"):
    assert added in allow, f"manifest allow entry {added} missing"
assert len(allow) == len(set(allow)), "allow list has duplicates"

t3 = json.loads((HOME/".t3/userdata/settings.json").read_text())
models = t3["providerInstances"]["claudeAgent"]["config"]["customModels"]
slugs = {m["slug"] for m in models}
assert "kimicode/k3-256k" in slugs and "gpt-6-astra" in slugs
# a slug naming a provider the proxy does not have cannot route; the retired
# list is what removes one that an earlier release already wrote out
assert "codex/gpt-6-astra" not in slugs, "retired custom model slug survived"
# effort levels are read from the proxy catalog, never written down here: no
# proxy in the test environment means no descriptors, rather than a guess
for m in models:
    for d in (m.get("capabilities") or {}).get("optionDescriptors", []):
        assert d["id"] != "effort" or d["options"], "effort descriptor with no options"
# re-run is idempotent (no duplicate models)
ns["cmd_settings"]([])
models2 = json.loads((HOME/".t3/userdata/settings.json").read_text())["providerInstances"]["claudeAgent"]["config"]["customModels"]
assert len(models2) == len(models), "t3 customModels duplicated on re-run"
assert "operator/private-model" in slugs, "operator-added custom model was dropped"

# --- mcp: codex config blocks appended once, zshenv mirror idempotent ---
# claude is not on PATH in the test env, so enrollment is skipped; only the
# codex writer and zshenv mirror run. Tokens come from the environment.
os.environ["OBSIDIAN_MCP_TOKEN"] = "tok-obsidian"
os.environ["VAULTWARDEN_MCP_TOKEN"] = "tok-vault"
# stub the vault so unset tokens do not attempt a network call
ns["vault_get"] = lambda item: (_ for _ in ()).throw(ns["VaultError"]("no vault in test"))
g = ns["cmd_mcp"].__globals__
g["vault_get"] = ns["vault_get"]
ns["cmd_mcp"]([])
codex = (HOME/".codex/config.toml").read_text()
import tomllib
tomllib.loads(codex)  # a config codex cannot parse is a harness that will not start
assert "# BEGIN harnesses:mcp-servers" in codex, "managed region markers missing"

# An operator-declared server must win, and must not gain a second top-level
# table -- duplicate keys are invalid TOML and codex refuses to start at all.
cx = HOME/".codex/config.toml"
cx.write_text('[mcp_servers.comfyui]\nurl = "https://hand.example/mcp"\n'
              'bearer_token_env_var = "MINE"\n\n'
              '[mcp_servers.comfyui.tools.x]\napproval_mode = "approve"\n')
ns["cmd_mcp"]([])
hand = cx.read_text()
tomllib.loads(hand)
assert hand.count("[mcp_servers.comfyui]") == 1, "operator block was duplicated"
assert "hand.example" in hand, "operator block was overwritten"
assert "tools.x" in hand, "operator tool rule was dropped"

# A file that is already broken must be left alone rather than edited further.
cx.write_text('[mcp_servers.a]\nurl = "x"\n\n[mcp_servers.a]\nurl = "y"\n')
broken_before = cx.read_text()
ns["cmd_mcp"]([])
assert cx.read_text() == broken_before, "edited a config that does not parse"

cx.write_text(codex)

assert "[mcp_servers.obsidian-direct]" in codex, "codex obsidian block missing"
assert "bearer_token_env_var = \"OBSIDIAN_MCP_TOKEN\"" in codex
assert "[mcp_servers.vaultwarden-secrets]" in codex, "codex vaultwarden block missing"
zshenv = (HOME/".zshenv").read_text()
assert "export OBSIDIAN_MCP_TOKEN=tok-obsidian" in zshenv
# re-run: codex blocks not duplicated, zshenv block replaced not stacked
ns["cmd_mcp"]([])
codex2 = (HOME/".codex/config.toml").read_text()
assert codex2.count("[mcp_servers.obsidian-direct]") == 1, "codex block duplicated"
zshenv2 = (HOME/".zshenv").read_text()
assert zshenv2.count("# BEGIN harnesses:mcp-tokens") == 1, "zshenv block stacked"

print("payload ok")
PY

# --- proxy: base-url export written only when the service is active, removed otherwise ---
python3 - "$ROOT/files/harnesses" <<'PY'
import json, os, runpy, subprocess, sys
from pathlib import Path
payload = sys.argv[1]
HOME = Path(os.environ["HOME"])
ns = runpy.run_path(payload, run_name="harnesses_proxy_test")
g = ns["cmd_proxy"].__globals__

class FakeCompleted:
    def __init__(self, rc=0, out=""):
        self.returncode, self.stdout, self.stderr = rc, out, ""

# Pin the resolved proxy port: _proxy_port() probes real loopback ports, and
# the test machine's own ocx must not decide what this asserts.
os.environ["HARNESSES_PROXY_PORT"] = "10101"

# stub ocx + systemctl: active service -> export written
g["shutil"] = type("S", (), {"which": staticmethod(lambda c: "/fake/ocx" if c == "ocx" else None)})
def run_active(argv, **kw):
    if argv[:3] == ["systemctl", "--user", "is-active"]:
        return FakeCompleted(0, "active\n")
    return FakeCompleted(0)
g["subprocess"] = type("P", (), {"run": staticmethod(run_active), "DEVNULL": subprocess.DEVNULL, "TimeoutExpired": subprocess.TimeoutExpired})
assert ns["cmd_proxy"]([]) == 0
zshenv = (HOME/".zshenv").read_text()
assert "export ANTHROPIC_BASE_URL=http://127.0.0.1:10101" in zshenv
# Shells read .zshenv; systemd user services do not. T3 Code's claudeAgent is
# spawned by t3code.service, so the var has to reach the user manager too.
envd = HOME/".config/environment.d/10-harnesses-anthropic.conf"
assert envd.exists(), "no environment.d drop-in written for systemd user units"
assert envd.read_text().strip() == "ANTHROPIC_BASE_URL=http://127.0.0.1:10101"

# inactive service -> export removed, nonzero rc
def run_inactive(argv, **kw):
    if argv[:3] == ["systemctl", "--user", "is-active"]:
        return FakeCompleted(3, "inactive\n")
    return FakeCompleted(0)
g["subprocess"] = type("P", (), {"run": staticmethod(run_inactive), "DEVNULL": subprocess.DEVNULL, "TimeoutExpired": subprocess.TimeoutExpired})
assert ns["cmd_proxy"]([]) == 1
zshenv2 = (HOME/".zshenv").read_text()
assert "ANTHROPIC_BASE_URL" not in zshenv2, "base-url export left behind on inactive proxy"
assert not envd.exists(), "environment.d drop-in left behind on inactive proxy"

# macOS: ocx registers a launchd agent, not a systemd unit, and the systemd
# half of the export has no equivalent there.
g["_is_macos"] = lambda: True
def run_mac(argv, **kw):
    if argv[:2] == ["launchctl", "list"]:
        return FakeCompleted(0, "4321\t0\tcom.opencodex.proxy\n")
    return FakeCompleted(0)
g["subprocess"] = type("P", (), {"run": staticmethod(run_mac), "DEVNULL": subprocess.DEVNULL, "TimeoutExpired": subprocess.TimeoutExpired})
assert ns["cmd_proxy"]([]) == 0, "macOS proxy check did not see the launchd agent"
assert "export ANTHROPIC_BASE_URL=http://127.0.0.1:10101" in (HOME/".zshenv").read_text()
assert not envd.exists(), "macOS wrote a systemd environment.d drop-in"

# A loaded-but-stopped agent carries "-" where the pid would be.
def run_mac_stopped(argv, **kw):
    if argv[:2] == ["launchctl", "list"]:
        return FakeCompleted(0, "-\t0\tcom.opencodex.proxy\n")
    return FakeCompleted(0)
g["subprocess"] = type("P", (), {"run": staticmethod(run_mac_stopped), "DEVNULL": subprocess.DEVNULL, "TimeoutExpired": subprocess.TimeoutExpired})
assert ns["cmd_proxy"]([]) == 1, "a stopped launchd agent was treated as running"
g["_is_macos"] = lambda: False
print("proxy ok")
PY

# --- CLI surface: --help prints help, unknown actions do not open the picker ---
help_out="$TMP/help.out"
if ! HOME="$HOME" python3 "$ROOT/files/harnesses" --help > "$help_out" 2>&1; then
    echo "FAIL: harnesses --help exited nonzero" >&2; exit 1
fi
grep -qi "usage: harnesses" "$help_out" || { echo "FAIL: --help did not print usage" >&2; exit 1; }
grep -q "proxy " "$help_out" || { echo "FAIL: --help did not list the actions" >&2; exit 1; }

bogus_out="$TMP/bogus.out"
if HOME="$HOME" python3 "$ROOT/files/harnesses" frobnicate > "$bogus_out" 2>&1; then
    echo "FAIL: unknown action exited zero" >&2; exit 1
fi
grep -q "unknown action" "$bogus_out" || { echo "FAIL: unknown action was not reported" >&2; exit 1; }

# The fzf menu must not capture stderr: fzf draws its interface there in
# --height mode, so capture_output would render the whole menu into a pipe.
grep -q "capture_output" <(sed -n '/^def menu/,/^def dispatch/p' "$ROOT/files/harnesses") \
    && { echo "FAIL: menu() captures fzf's stderr; its UI would never reach the terminal" >&2; exit 1; }

echo "cli surface ok"

# --- schedule: the module owns its own update cadence ------------------
sched_tmp="$TMP/sched"
mkdir -p "$sched_tmp/bin" "$sched_tmp/units"
cat > "$sched_tmp/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "systemctl $*" >> "$SCHED_LOG"
case "${2:-}" in
  is-enabled) echo enabled ;;
  is-active)  echo active ;;
esac
exit 0
STUB
chmod +x "$sched_tmp/bin/systemctl"
export SCHED_LOG="$sched_tmp/log"; : > "$SCHED_LOG"

SCHEDULE_USER_DIR="$sched_tmp/units" PATH="$sched_tmp/bin:$PATH" \
    SCHEDULE_BIN="$ROOT/bin/schedule" HOME="$HOME" \
    python3 "$ROOT/files/harnesses" schedule > "$sched_tmp/out" 2>&1 \
    || { echo "FAIL: harnesses schedule failed: $(cat "$sched_tmp/out")" >&2; exit 1; }

grep -Fqx 'OnCalendar=*-*-* 11:00:00' "$sched_tmp/units/harnesses-update.timer" \
    || { echo "FAIL: harnesses timer is not scheduled for 11:00" >&2; exit 1; }
grep -Fqx 'Persistent=true' "$sched_tmp/units/harnesses-update.timer" \
    || { echo "FAIL: harnesses timer is not persistent" >&2; exit 1; }
# The pass must be 'daily', not 'update': settings are rendered from what the
# proxy reports, so the proxy has to be converged first, in that order.
grep -Fqx 'ExecStart=%h/.local/bin/harnesses refresh' "$sched_tmp/units/harnesses-update.service" \
    || { echo "FAIL: harnesses timer does not run the full refresh pass" >&2; exit 1; }
grep -q 'enable --now harnesses-update.timer' "$SCHED_LOG" \
    || { echo "FAIL: harnesses timer was not enabled" >&2; exit 1; }

SCHEDULE_USER_DIR="$sched_tmp/units" PATH="$sched_tmp/bin:$PATH" \
    SCHEDULE_BIN="$ROOT/bin/schedule" HOME="$HOME" \
    python3 "$ROOT/files/harnesses" schedule disable > "$sched_tmp/out" 2>&1 \
    || { echo "FAIL: harnesses schedule disable failed: $(cat "$sched_tmp/out")" >&2; exit 1; }
[[ ! -f "$sched_tmp/units/harnesses-update.timer" ]] \
    || { echo "FAIL: harnesses timer left behind after disable" >&2; exit 1; }

echo "schedule ok"
