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
import io, json, os, runpy, subprocess, sys, tempfile
from pathlib import Path
from unittest import mock

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
catalog = {"data": [{
    "id": "grimoire/qwen3.8-flash-next",
    "reasoning_efforts": [
        {"value": "low", "label": "Low Effort"},
        {"value": "medium", "label": "Medium Effort", "default": True},
        {"value": "xhigh", "label": "Xhigh Effort"},
    ],
}]}
os.environ["HARNESSES_PROXY_PORT"] = "10100"
with mock.patch.object(
    ns["urllib"].request,
    "urlopen",
    side_effect=lambda *_args, **_kwargs: io.BytesIO(json.dumps(catalog).encode()),
) as catalog_request:
    descriptors = ns["_effort_descriptors_by_slug"]()
catalog_request.assert_called_once_with(
    "http://127.0.0.1:10100/v1/models",
    timeout=15,
)
ns["_write_t3_settings"].__globals__["_effort_descriptors_by_slug"] = lambda: descriptors
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
# A renamed server must lose its old wildcard: the allow list is union-merged,
# so nothing else would ever drop it.
retired = {"mcp__%s__*" % n for n in manifest.get("retiredMcpServers", [])}
assert not (retired & set(allow)), "a retired server kept its permission grant"
# A connector granted per tool leaves many rows, not one wildcard; dropping only
# the wildcard would leave every per-tool grant behind.
for namespace in manifest.get("retiredMcpGrants", []):
    leftover = [x for x in allow if x.startswith("mcp__%s__" % namespace)]
    assert not leftover, "retired grant namespace %s kept %d entries" % (namespace, len(leftover))
assert not (retired & {"mcp__%s__*" % s["name"] for s in manifest["mcpServers"]}), \
    "a server is declared and retired at the same time"
for added in ("mcp__obsidian__*", "mcp__vaultwarden-secrets__*"):
    assert added in allow, f"manifest allow entry {added} missing"
assert len(allow) == len(set(allow)), "allow list has duplicates"

t3 = json.loads((HOME/".t3/userdata/settings.json").read_text())
models = t3["providerInstances"]["claudeAgent"]["config"]["customModels"]
by_slug = {m["slug"]: m for m in models}
slugs = set(by_slug)
assert "kimicode/k3-256k" in slugs and "gpt-6-astra" in slugs
assert by_slug["kimicode/k3-256k"]["name"] == "kimi-k3-256k"
assert by_slug["grimoire/qwen3.8-flash-next"]["name"] == "qwen3.8-flash-next"
qwen_options = by_slug["grimoire/qwen3.8-flash-next"]["capabilities"]["optionDescriptors"][0]["options"]
assert [option["id"] for option in qwen_options] == ["low", "medium", "xhigh"]
assert next(option for option in qwen_options if option["id"] == "medium")["isDefault"] is True
# a slug naming a provider the proxy does not have cannot route; the retired
# list is what removes one that an earlier release already wrote out
assert "codex/gpt-6-astra" not in slugs, "retired custom model slug survived"
assert "grimoire/qwen3.8-flash-next-uncensored-nvfp4" not in slugs, "retired qwen slug survived"
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

# A vault item may record how to send the token ("<url> | <Header>: <tok>")
# rather than holding it bare. Exported whole it is a credential no server
# accepts, and unquoted it turned .zshenv into a pipeline on every machine.
tok = ns["mcp_token_value"]
assert tok("plaintoken123") == "plaintoken123", "a bare token must pass through"
assert tok("https://x/y | x-api-key: abc123") == "abc123"
assert tok("https://x/y | Authorization: Bearer tok99") == "tok99"
assert tok("https://only-a-url/mcp") == "https://only-a-url/mcp", "a url is not a header"

# --- mcp: codex config blocks appended once, zshenv mirror idempotent ---
# claude is not on PATH in the test env, so enrollment is skipped; only the
# codex writer and zshenv mirror run. Tokens come from the environment.
for server in manifest["mcpServers"]:
    os.environ.pop(ns["mcp_env_var"](server), None)
os.environ["OBSIDIAN_MCP_TOKEN"] = "tok-obsidian"
os.environ["VAULTWARDEN_MCP_TOKEN"] = "tok-vault"
os.environ["JINA_MCP_TOKEN"] = "stale-jina"
# Authoritative sources replace stale pre-Common-Auth environment values. A
# failed external lookup still keeps its previous value as an offline fallback.
vault_calls = []
def fake_vault_get(item):
    vault_calls.append(item)
    assert g["VAULT_TOKEN"] == "auth-vaultwarden-secrets"
    if item == "JINA_MCP_TOKEN":
        return "fresh-jina"
    raise ns["VaultError"]("no vault in test")
ns["vault_get"] = fake_vault_get
g = ns["cmd_mcp"].__globals__
g["vault_get"] = ns["vault_get"]
g["common_auth_token"] = lambda scope, context=None: "auth-" + scope
g["common_auth_context"] = lambda: {
    "origin": "https://auth.lost.plus", "subject": "account-a",
}
g["VAULT_TOKEN"] = "stale-vault-access"
g["shutil"].which = lambda command: None
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

# Approval rules with no settings are not a declaration -- they are rules for a
# server whose address we still owe it. Treating them as one stripped the url
# and token and left codex with rules pointing at nothing.
cx.write_text('[mcp_servers.comfyui.tools.only_a_rule]\napproval_mode = "approve"\n')
ns["cmd_mcp"]([])
rules_only = tomllib.loads(cx.read_text())["mcp_servers"]["comfyui"]
assert "url" in rules_only, "server lost its url to a bare tool rule"
assert "only_a_rule" in rules_only.get("tools", {}), "operator tool rule was dropped"

# TOML treats [mcp_servers."x"] and [mcp_servers.x] as one key; a header regex
# does not. Reading the quoted spelling as undeclared is what emitted a second
# bare table on oci and left codex unable to start.
cx.write_text('[mcp_servers."comfyui"]\nurl = "https://quoted.example/mcp"\n'
              'bearer_token_env_var = "MINE"\n')
ns["cmd_mcp"]([])
quoted = cx.read_text()
tomllib.loads(quoted)
assert len(tomllib.loads(quoted)["mcp_servers"]) == len(set(tomllib.loads(quoted)["mcp_servers"]))
assert "quoted.example" in quoted, "quoted operator block was overwritten"

# A file that is already broken must be left alone rather than edited further.
cx.write_text('[mcp_servers.a]\nurl = "x"\n\n[mcp_servers.a]\nurl = "y"\n')
broken_before = cx.read_text()
ns["cmd_mcp"]([])
assert cx.read_text() == broken_before, "edited a config that does not parse"

cx.write_text(codex)

assert "[mcp_servers.obsidian]" in codex, "codex obsidian block missing"
assert "bearer_token_env_var = \"OBSIDIAN_MCP_TOKEN\"" in codex
assert "[mcp_servers.vaultwarden-secrets]" in codex, "codex vaultwarden block missing"
zshenv = (HOME/".zshenv").read_text()
assert "export OBSIDIAN_MCP_TOKEN=auth-obsidian" in zshenv
assert "export VAULTWARDEN_MCP_TOKEN=auth-vaultwarden-secrets" in zshenv
assert "export TWEET_FETCH_MCP_TOKEN=auth-tweet-fetch" in zshenv
assert "export JINA_MCP_TOKEN=fresh-jina" in zshenv
assert "JINA_MCP_TOKEN" in vault_calls

# If either authority is temporarily unavailable later, preserve the freshly
# reconciled managed values rather than falling back to stale process exports.
fresh_zshenv = zshenv
def common_unavailable(scope, context=None):
    raise ns["CommonAuthError"]("auth offline in test")
def vault_unavailable(item):
    raise ns["VaultError"]("vault offline in test")
g["common_auth_token"] = common_unavailable
g["vault_get"] = vault_unavailable
ns["cmd_mcp"]([])
assert (HOME/".zshenv").read_text() == fresh_zshenv

# A failed context lookup must make no unbound token or Vaultwarden reads.
unbound_calls = []
vault_call_count = len(vault_calls)
g["common_auth_context"] = lambda: (_ for _ in ()).throw(
    ns["CommonAuthError"]("context timed out in test")
)
def contextless_common(scope, context=None):
    unbound_calls.append(scope)
    return "wrong-account-" + scope
g["common_auth_token"] = contextless_common
ns["cmd_mcp"]([])
assert unbound_calls == [], "token lookup ran without an account context"
assert len(vault_calls) == vault_call_count, "vault read ran without an account context"
assert (HOME/".zshenv").read_text() == fresh_zshenv
g["common_auth_context"] = lambda: {
    "origin": "https://auth.lost.plus", "subject": "account-a",
}

# An authoritative Common Auth rejection removes its managed mirrors. It is
# distinct from an outage, so stale process or on-disk values cannot survive.
def common_rejected(scope, context=None):
    raise ns["CommonAuthError"]("credential revoked in test", authoritative=True)
g["common_auth_token"] = common_rejected
# A selective sync removes the rejected selected credential without erasing or
# relying on unrelated entries to make the old managed block win wholesale.
ns["cmd_mcp"](["obsidian"])
selective_zshenv = (HOME/".zshenv").read_text()
assert "OBSIDIAN_MCP_TOKEN" not in selective_zshenv
assert "TWEET_FETCH_MCP_TOKEN=auth-tweet-fetch" in selective_zshenv
assert "JINA_MCP_TOKEN=fresh-jina" in selective_zshenv

# A full authoritative rejection then removes every Common Auth entry while
# preserving the independently managed Vaultwarden entry.
ns["cmd_mcp"]([])
revoked_zshenv = (HOME/".zshenv").read_text()
for server in manifest["mcpServers"]:
    if server.get("credentialSource") == "common-auth":
        assert ns["mcp_env_var"](server) not in revoked_zshenv
assert "export JINA_MCP_TOKEN=fresh-jina" in revoked_zshenv

g["common_auth_token"] = lambda scope, context=None: "auth-" + scope
g["common_auth_context"] = lambda: {
    "origin": "https://auth.lost.plus", "subject": "account-a",
}
g["vault_get"] = fake_vault_get
# re-run: codex blocks not duplicated, zshenv block replaced not stacked
ns["cmd_mcp"]([])
codex2 = (HOME/".codex/config.toml").read_text()
assert codex2.count("[mcp_servers.obsidian]") == 1, "codex block duplicated"
zshenv2 = (HOME/".zshenv").read_text()
assert zshenv2.count("# BEGIN harnesses:mcp-tokens") == 1, "zshenv block stacked"

# A selective external-server sync still refreshes its Vaultwarden dependency.
# If that Common Auth bearer was revoked, its managed export must disappear
# even though the Vaultwarden MCP server was not itself selected.
def vault_access_rejected(scope, context=None):
    if scope == "vaultwarden-secrets":
        raise ns["CommonAuthError"]("vault access revoked in test", authoritative=True)
    return "auth-" + scope
g["common_auth_token"] = vault_access_rejected
g["vault_get"] = vault_unavailable
ns["cmd_mcp"](["jina"])
selective_vault_rejection = (HOME/".zshenv").read_text()
assert "VAULTWARDEN_MCP_TOKEN" not in ns["_existing_block"](selective_vault_rejection)
assert "JINA_MCP_TOKEN=fresh-jina" in selective_vault_rejection

# A new account context cannot inherit account A's exported Common Auth
# credentials when account B's active values are currently unreadable.
g["common_auth_context"] = lambda: {
    "origin": "https://auth.lost.plus", "subject": "account-b",
}
g["common_auth_token"] = common_unavailable
g["VAULT_TOKEN"] = "account-a-vaultwarden-access"
g["vault_get"] = vault_unavailable
ns["cmd_mcp"]([])
switched_zshenv = (HOME/".zshenv").read_text()
assert not g["VAULT_TOKEN"]
for server in manifest["mcpServers"]:
    if server.get("credentialSource") == "common-auth":
        assert ns["mcp_env_var"](server) not in switched_zshenv
assert "JINA_MCP_TOKEN=fresh-jina" in switched_zshenv
assert '"subject":"account-b"' in switched_zshenv

# A later invocation from account A's already-open shell is still unbound and
# cannot override account B's persisted context.
os.environ["OBSIDIAN_MCP_TOKEN"] = "account-a-old-shell"
g["VAULT_TOKEN"] = "account-a-old-shell-vault"
ns["cmd_mcp"]([])
later_zshenv = (HOME/".zshenv").read_text()
assert "account-a-old-shell" not in later_zshenv
assert not g["VAULT_TOKEN"]

# Only values inside the context-tagged managed block are eligible fallbacks.
# An unrelated export elsewhere in .zshenv has no account binding.
outside = HOME/".zshenv"
outside.write_text("export OBSIDIAN_MCP_TOKEN=unbound-outside\n" + outside.read_text())
ns["cmd_mcp"](["obsidian"])
managed = ns["_existing_block"](outside.read_text())
assert "unbound-outside" not in managed

# If login changes between the context read and a token read, retry the entire
# reconciliation and bind only the new account's values.
contexts = [
    {"origin": "https://auth.lost.plus", "subject": "account-a"},
    {"origin": "https://auth.lost.plus", "subject": "account-b"},
]
g["common_auth_context"] = lambda: contexts.pop(0) if contexts else {
    "origin": "https://auth.lost.plus", "subject": "account-b",
}
def raced_common(scope, context=None):
    if context["subject"] == "account-a":
        raise ns["CommonAuthContextChanged"]("login changed in test")
    return "account-b-" + scope
g["common_auth_token"] = raced_common
ns["cmd_mcp"](["obsidian"])
raced_block = ns["_existing_block"](outside.read_text())
assert "account-b-obsidian" in raced_block
assert '"subject":"account-b"' in raced_block
assert "account-a-obsidian" not in raced_block

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
