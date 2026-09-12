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
ns["cmd_settings"]([])
d = json.loads(claude.read_text())
assert d["custom_key"] == "keepme", "custom key lost"
assert d["effortLevel"] == "high", "manifest scalar not applied"
allow = d["permissions"]["allow"]
for keep in ("Read", "mcp__custom__*", "Skill"):
    assert keep in allow, f"existing allow entry {keep} clobbered"
for added in ("mcp__obsidian-direct__*", "mcp__vaultwarden-secrets__*"):
    assert added in allow, f"manifest allow entry {added} missing"
assert len(allow) == len(set(allow)), "allow list has duplicates"

t3 = json.loads((HOME/".t3/userdata/settings.json").read_text())
models = t3["providerInstances"]["claudeAgent"]["config"]["customModels"]
slugs = {m["slug"] for m in models}
assert "kimicode/k3-256k" in slugs and "codex/gpt-6-astra" in slugs
# re-run is idempotent (no duplicate models)
ns["cmd_settings"]([])
models2 = json.loads((HOME/".t3/userdata/settings.json").read_text())["providerInstances"]["claudeAgent"]["config"]["customModels"]
assert len(models2) == len(models), "t3 customModels duplicated on re-run"

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
assert "[mcp_servers.obsidian]" in codex, "codex obsidian block missing"
assert "bearer_token_env_var = \"OBSIDIAN_MCP_TOKEN\"" in codex
assert "[mcp_servers.vaultwarden]" in codex, "codex vaultwarden block missing"
zshenv = (HOME/".zshenv").read_text()
assert "export OBSIDIAN_MCP_TOKEN=tok-obsidian" in zshenv
# re-run: codex blocks not duplicated, zshenv block replaced not stacked
ns["cmd_mcp"]([])
codex2 = (HOME/".codex/config.toml").read_text()
assert codex2.count("[mcp_servers.obsidian]") == 1, "codex block duplicated"
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

# inactive service -> export removed, nonzero rc
def run_inactive(argv, **kw):
    if argv[:3] == ["systemctl", "--user", "is-active"]:
        return FakeCompleted(3, "inactive\n")
    return FakeCompleted(0)
g["subprocess"] = type("P", (), {"run": staticmethod(run_inactive), "DEVNULL": subprocess.DEVNULL, "TimeoutExpired": subprocess.TimeoutExpired})
assert ns["cmd_proxy"]([]) == 1
zshenv2 = (HOME/".zshenv").read_text()
assert "ANTHROPIC_BASE_URL" not in zshenv2, "base-url export left behind on inactive proxy"
print("proxy ok")
PY
