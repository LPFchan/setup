#!/usr/bin/env bash
# fleet's harness pass: the three tiers rendered into claude, codex, t3 and
# hermes, tokens mirrored, and the takeover from the old harnesses client.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" FLEET_SSH_DIR="$TMP/home/.ssh"
export FLEET_AUTH_BIN="$TMP/auth" FLEET_SELF=grimoire FAKE="$TMP/fake" STATE_DIR="$TMP/state/setup"
export SCHEDULE_USER_DIR="$TMP/units" SCHEDULE_BIN="$TMP/schedule"
# Only the stubs below and the system basics: never a real harness.
export PATH="$TMP/bin:$(dirname "$(command -v python3)"):/usr/bin:/bin"
unset CLAUDE_CONFIG_DIR HERMES_CONFIG HERMES_ENV TODAY_KEEPOUT_EXEMPT
BIN="$HOME/.local/bin"
mkdir -p "$FLEET_SSH_DIR" "$FAKE" "$STATE_DIR" "$SCHEDULE_USER_DIR" "$TMP/bin" "$BIN" \
    "$HOME/.claude" "$HOME/.codex" "$HOME/.t3/userdata" "$HOME/.hermes" "$HOME/.config/harnesses"
printf '7' > "$FAKE/subject"
fail() { echo "FAIL: $*" >&2; exit 1; }
fleet() { python3 "$ROOT/files/fleet" "$@" </dev/null; }

# Auth: one account's config, the hub's service list, and scoped tokens.
cat > "$FLEET_AUTH_BIN" <<'PY'
#!/usr/bin/env python3
import json, os, sys
fake = os.environ["FAKE"]
def answer(status, value):
    if status != 200:
        print(json.dumps({"status": status, "error": value.get("error"), "retry_after": None}))
        sys.exit(6)
    print(json.dumps(value))
    sys.exit(0)
cmd = sys.argv[1]
if cmd == "refresh":
    sys.exit(0)
if cmd == "context":
    print(json.dumps({"origin": "https://auth.lost.plus", "subject": open(f"{fake}/subject").read()}))
    sys.exit(0)
if cmd == "token":
    open(f"{fake}/log", "a").write(f"token {sys.argv[2]}\n")
    sys.exit(4) if os.path.exists(f"{fake}/token-gone") else print(f"tok-{sys.argv[2]}")
    sys.exit(0)
method, path = sys.argv[2], sys.argv[3]
body = json.load(sys.stdin) if sys.argv[4:] == ["-"] else None
open(f"{fake}/log", "a").write(f"{method} {path}\n")
try:
    state = json.load(open(f"{fake}/server.json"))
except OSError:
    state = {"counter": 0, "version": 0, "files": {}}
if path == "/api/services":
    if os.path.exists(f"{fake}/services-down"):
        sys.exit(1)
    if os.path.exists(f"{fake}/switch-on-services"):
        # Another account signed in while the hub's list was coming down.
        os.remove(f"{fake}/switch-on-services")
        open(f"{fake}/subject", "w").write("9")
    answer(200, json.load(open(f"{fake}/services.json")))
if path == "/api/fleet":
    answer(200, {"version": "v", "self": {"served": True}, "keys": ["ssh-ed25519 AAAASelf"], "hosts": []})
if path == "/api/fleet/config":
    answer(200, {"counter": state["counter"], "version": state["version"],
                 "files": [{"path": p, "size": len(f["content"]), "sha256": f["sha256"],
                            "executable": f["executable"]} for p, f in sorted(state["files"].items())]})
if path == "/api/fleet/config/fetch":
    answer(200, {"counter": state["counter"], "version": state["version"],
                 "files": [{"path": p, **state["files"][p]} for p in body["paths"] if p in state["files"]],
                 "remaining": [], "missing": [p for p in body["paths"] if p not in state["files"]]})
answer(404, {"error": "not found"})
PY
chmod +x "$FLEET_AUTH_BIN"
server_put() {
    python3 - "$1" "$2" <<'PY'
import base64, hashlib, json, os, sys
f = f"{os.environ['FAKE']}/server.json"
state = json.load(open(f)) if os.path.exists(f) else {"counter": 0, "version": 0, "files": {}}
data = sys.argv[2].encode()
state["files"][sys.argv[1]] = {"content": base64.b64encode(data).decode(),
                               "sha256": hashlib.sha256(data).hexdigest(), "executable": False}
state["counter"] += 1; state["version"] += 1
json.dump(state, open(f, "w"))
PY
}
cat > "$FAKE/services.json" <<'JSON'
[{"key": "heatmap.lost.plus", "label": "Heatmap", "group": "tools", "url": "https://heatmap.lost.plus",
  "mcp_url": "https://heatmap.lost.plus/mcp", "token_key": "heatmap", "admin_only": false, "alias": ""},
 {"key": "wiki.lost.plus", "label": "Wiki", "group": "tools", "url": "https://wiki.lost.plus",
  "mcp_url": "https://wiki.lost.plus/mcp", "token_key": "", "admin_only": false, "alias": ""},
 {"key": "today.lost.plus", "label": "Today", "group": "tools", "url": "https://today.lost.plus",
  "mcp_url": "", "token_key": "today", "admin_only": false, "alias": ""}]
JSON

# A claude that keeps its user-scope MCP servers in ~/.claude.json.
cat > "$BIN/claude" <<'PY'
#!/usr/bin/env python3
import json, os, sys
args, path = sys.argv[1:], os.path.join(os.environ["HOME"], ".claude.json")
open(os.environ["FAKE"] + "/claude.log", "a").write(" ".join(args[:3]) + "\n")
if args in (["--version"], ["update"]):
    print("2.0.0 (Claude Code)")
    sys.exit(0)
try:
    data = json.load(open(path))
except OSError:
    data = {}
servers = data.setdefault("mcpServers", {})
if args[:2] == ["mcp", "get"]:
    if args[2] in servers:
        print(f"{args[2]}:\n  Scope: User config (available in all your projects)")
        sys.exit(0)
    print(f"No MCP server named {args[2]} found.")
    sys.exit(1)
if args[:2] == ["mcp", "add-json"]:
    servers[args[4]] = json.loads(args[5])
elif args[:2] == ["mcp", "remove"]:
    servers.pop(args[2], None)
else:
    sys.exit(2)
json.dump(data, open(path, "w"))
PY
# A codex whose app-server lists ~/.codex/hooks.json and records trust.
cat > "$BIN/codex" <<'PY'
#!/usr/bin/env python3
import hashlib, json, os, sys
fake, home = os.environ["FAKE"], os.environ["HOME"]
if sys.argv[1:] in (["--version"], ["update"]):
    open(fake + "/claude.log", "a").write("codex " + sys.argv[1] + "\n")
    print("codex-cli 1.0.0")
    sys.exit(0)
trusted_path, hooks_path = fake + "/codex-trust.json", home + "/.codex/hooks.json"
def load(path):
    try:
        return json.load(open(path))
    except OSError:
        return {}
for line in sys.stdin:
    message = json.loads(line)
    if "id" not in message:
        continue
    result = {}
    if message["method"] == "hooks/list":
        hooks = []
        for group in load(hooks_path).get("hooks", {}).get("UserPromptSubmit", []):
            for hook in group.get("hooks", []):
                digest = hashlib.sha256(hook["command"].encode()).hexdigest()
                key = "ups:" + digest[:8]
                status = "trusted" if load(trusted_path).get(key) == digest else "untrusted"
                hooks.append({"key": key, "command": hook["command"], "sourcePath": hooks_path,
                              "currentHash": digest, "trustStatus": status})
        result = {"data": [{"cwd": home, "hooks": hooks}]}
    elif message["method"] == "config/batchWrite":
        trusted = load(trusted_path)
        for edit in message["params"]["edits"]:
            trusted.update({k: v["trusted_hash"] for k, v in edit["value"].items()})
        json.dump(trusted, open(trusted_path, "w"))
    print(json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": result}), flush=True)
PY
printf '#!/bin/sh\necho "$*" >> "$FAKE/systemctl.log"\n' > "$TMP/bin/systemctl"
cat > "$SCHEDULE_BIN" <<'SH'
#!/bin/sh
echo "$*" >> "$FAKE/schedule.log"
case "$1" in
    status) [ -f "$SCHEDULE_USER_DIR/$3.timer" ] ;;
    install-timer) printf 'ExecStart=%s\n' "$5" > "$SCHEDULE_USER_DIR/$3.service"
                   printf 'OnCalendar=%s\n' "$6" > "$SCHEDULE_USER_DIR/$3.timer" ;;
    uninstall-timer) rm -f "$SCHEDULE_USER_DIR/$3.timer" "$SCHEDULE_USER_DIR/$3.service" ;;
esac
SH
chmod +x "$BIN/claude" "$BIN/codex" "$TMP/bin/systemctl" "$SCHEDULE_BIN"

# A machine the old harnesses client set up: its binary, manifest and timer,
# and settings it wrote next to the user's own.
printf '#!/bin/sh\necho old harnesses\n' > "$BIN/harnesses"; chmod +x "$BIN/harnesses"
printf '{}\n' > "$HOME/.config/harnesses/manifest.json"
printf 'OnCalendar=daily\n' > "$SCHEDULE_USER_DIR/harnesses-update.timer"
cat > "$HOME/.claude/settings.json" <<'JSON'
{"theme": "light", "myKey": 1, "attribution": {"commit": "", "pr": ""},
 "permissions": {"defaultMode": "auto", "allow": ["Read", "mcp__jina__*"]}}
JSON
cat > "$HOME/.claude.json" <<'JSON'
{"mcpServers": {"jina": {"type": "http", "url": "https://mcp.jina.ai/v1"},
                "personal": {"type": "http", "url": "https://p.example/mcp"}}}
JSON
printf 'model = "gpt"\n\n[mcp_servers.open]\nurl = "https://elsewhere.example/mcp"\n' > "$HOME/.codex/config.toml"
printf 'model: x\nmcp_servers:\n  personal:\n    url: https://p.example/mcp\n' > "$HOME/.hermes/config.yaml"

# The account's tier.
server_put settings/claude.json '{"json": {"theme": "dark", "effortLevel": "high"}, "permissionsAllowAdd": ["Bash(ls:*)"]}'
server_put settings/keepout.json '{"enabled": true}'
server_put settings/t3.json '{"claudeCustomModels": [{"slug": "my-model", "name": "Mine"}]}'
server_put mcp.json '{"mcpServers": [
  {"name": "mine", "url": "https://mine.example/mcp", "auth": "bearer", "credentialSource": "env", "env": "MINE_TOKEN"},
  {"name": "open", "url": "https://open.example/mcp"},
  {"name": "vault", "url": "https://v.example/mcp", "auth": "bearer", "credentialSource": "passage"}]}'
json() { python3 -c 'import json,sys; v=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$@"; }

# While setup still records the old modules, nothing of this runs.
printf 'harnesses\tclone\ta\tb\n' > "$STATE_DIR/script-state.tsv"
fleet sync --pull >/dev/null 2>&1 || fail "sync while gated"
grep -q 'old harnesses' "$BIN/harnesses" || fail "took over harnesses while gated"
[[ "$(json "$HOME/.claude/settings.json" 'v["theme"]')" == light ]] || fail "rendered while gated"
: > "$STATE_DIR/script-state.tsv"
fleet sync --check >/dev/null 2>&1 && fail "check missed the harnesses client"

# The first pass takes over and renders all three tiers.
MINE_TOKEN=mine-secret fleet sync --pull > "$TMP/out" 2>&1 || { cat "$TMP/out"; fail "first pass"; }
grep -q '^# fleet: harnesses alias' "$BIN/harnesses" || fail "harnesses not aliased"
[[ ! -e "$HOME/.config/harnesses" ]] || fail "harnesses manifest left"
[[ ! -e "$SCHEDULE_USER_DIR/harnesses-update.timer" ]] || fail "harnesses timer left"
grep -q 'fleet schedule run' "$SCHEDULE_USER_DIR/fleet-sync.service" || fail "fleet timer not installed"
settings="$HOME/.claude/settings.json"
[[ "$(json "$settings" 'v["theme"], v["effortLevel"], v["myKey"]')" == "('dark', 'high', 1)" ]] \
    || fail "claude settings: $(cat "$settings")"
[[ "$(json "$settings" '"attribution" in v, "defaultMode" in v["permissions"]')" == "(False, False)" ]] \
    || fail "seeded harnesses settings not removed: $(cat "$settings")"
allow=$(json "$settings" 'v["permissions"]["allow"]')
for grant in Read 'Bash(ls:*)' 'mcp__daiso__*' 'mcp__notion__*' 'mcp__heatmap__*' 'mcp__wiki__*' 'mcp__mine__*' 'mcp__open__*'; do
    [[ "$allow" == *"'$grant'"* ]] || fail "allow lacks $grant: $allow"
done
[[ "$allow" != *jina* && "$allow" != *vault* ]] || fail "allow kept a removed grant: $allow"
[[ "$(json "$settings" 'len(v["hooks"]["UserPromptSubmit"])')" == 1 ]] || fail "claude keepout hook"
servers=$(json "$HOME/.claude.json" 'sorted(v["mcpServers"])')
[[ "$servers" == "['daiso', 'heatmap', 'mine', 'notion', 'open', 'personal', 'wiki']" ]] || fail "claude MCP: $servers"
[[ "$(json "$HOME/.claude.json" 'v["mcpServers"]["heatmap"]["headersHelper"]')" == *"mcp-headers bearer HEATMAP_MCP_TOKEN" ]] \
    || fail "heatmap headersHelper"
grep -q "skipped vault" "$TMP/out" || fail "a passage server on another account was not reported"
grep -q "export HEATMAP_MCP_TOKEN=tok-heatmap" "$HOME/.zshenv" || fail "hub token not mirrored"
grep -q "export MINE_TOKEN=mine-secret" "$HOME/.zshenv" || fail "env token not mirrored"
[[ "$("$BIN/harnesses" mcp-headers bearer HEATMAP_MCP_TOKEN)" == '{"Authorization": "Bearer tok-heatmap"}' ]] \
    || fail "the harnesses alias does not forward mcp-headers"
codex="$HOME/.codex/config.toml"
grep -q '^\[mcp_servers.heatmap\]' "$codex" && grep -q 'bearer_token_env_var = "HEATMAP_MCP_TOKEN"' "$codex" \
    || fail "codex MCP: $(cat "$codex")"
[[ "$(grep -c '^\[mcp_servers.open\]' "$codex")" == 1 ]] || fail "codex emitted a server the user declared"
grep -q 'notion' "$codex" && fail "codex got a claude-only server"
python3 -c 'import sys,tomllib; tomllib.load(open(sys.argv[1],"rb"))' "$codex" || fail "codex config does not parse"
grep -q '^HEATMAP_MCP_TOKEN=tok-heatmap$' "$HOME/.codex/.env" || fail "codex .env"
[[ -s "$FAKE/codex-trust.json" ]] || fail "codex keepout hook not trusted"
[[ "$(json "$HOME/.t3/userdata/settings.json" '[m["slug"] for m in v["providerInstances"]["claudeAgent"]["config"]["customModels"]]')" == "['my-model']" ]] \
    || fail "t3 models"
hermes="$HOME/.hermes/config.yaml"
grep -q '^  heatmap:$' "$hermes" && grep -q 'Authorization: Bearer ${HEATMAP_MCP_TOKEN}' "$hermes" \
    && grep -q '^  personal:$' "$hermes" && grep -q '^  - ~/.agents/skills$' "$hermes" || fail "hermes: $(cat "$hermes")"
[[ -f "$XDG_STATE_HOME/fleet/hermes.restart" ]] || fail "hermes restart not queued"
fleet status | grep -q 'skipped: mcp.json: skipped vault' || fail "status does not show the skipped server"

# Unchanged inputs render nothing; a token already in the block counts as set.
: > "$FAKE/claude.log"
fleet sync --pull > "$TMP/out" 2>&1 || fail "second pass"
grep -q 'add-json\|remove' "$FAKE/claude.log" && fail "second pass touched claude's MCP"
grep -q 'wrote' "$TMP/out" && fail "second pass wrote: $(cat "$TMP/out")"
fleet sync --check >/dev/null 2>&1 || fail "check after the pass"

# What the account drops comes off; what the user added stays.
server_put settings/claude.json '{"json": {"effortLevel": "high"}}'
server_put mcp.json '{"mcpServers": [{"name": "mine", "url": "https://mine.example/mcp", "auth": "bearer", "credentialSource": "env", "env": "MINE_TOKEN"}]}'
fleet sync --pull >/dev/null 2>&1 || fail "pass after the tier changed"
[[ "$(json "$settings" '"theme" in v, v["myKey"]')" == "(False, 1)" ]] || fail "dropped key: $(cat "$settings")"
allow=$(json "$settings" 'v["permissions"]["allow"]')
[[ "$allow" != *Bash* && "$allow" != *mcp__open__* && "$allow" == *Read* ]] || fail "allow after drop: $allow"
servers=$(json "$HOME/.claude.json" 'sorted(v["mcpServers"])')
[[ "$servers" == "['daiso', 'heatmap', 'mine', 'notion', 'personal', 'wiki']" ]] || fail "claude MCP after drop: $servers"
grep -q '^  open:$' "$hermes" && fail "hermes kept a dropped server"
grep -q '^  personal:$' "$hermes" || fail "hermes lost the user's server"
grep -q 'elsewhere.example' "$codex" || fail "codex lost the user's server"

# Without the hub's list nothing renders, so nothing reads as removed.
touch "$FAKE/services-down"
server_put settings/keepout.json '{"enabled": false}'
rc=0; fleet sync --pull >/dev/null 2>&1 || rc=$?
[[ $rc == 3 ]] || fail "hub down returned $rc"
grep -q heatmap "$HOME/.claude.json" || fail "hub down removed a hub server"
grep -q UserPromptSubmit "$settings" || fail "hub down rendered the keepout change"
rm "$FAKE/services-down"
fleet sync --pull >/dev/null 2>&1 || fail "pass after the hub came back"
grep -q UserPromptSubmit "$settings" && fail "keepout hook left after it was turned off"
grep -q UserPromptSubmit "$HOME/.codex/hooks.json" && fail "codex keepout hook left"

# A sign-in while the hub's list comes down renders nothing for either account.
touch "$FAKE/switch-on-services"
server_put settings/keepout.json '{"enabled": true}'
rc=0; fleet sync --pull >/dev/null 2>&1 || rc=$?
[[ $rc == 3 ]] || fail "a sign-in during the hub fetch returned $rc"
grep -q UserPromptSubmit "$settings" && fail "rendered after the login changed"
printf '7' > "$FAKE/subject"
server_put settings/keepout.json '{"enabled": false}'
fleet sync --pull >/dev/null 2>&1 || fail "pass after the login came back"

# The nightly pass renders in full: a credential Auth withdrew leaves the
# block, each harness updates itself, and hermes restarts.
touch "$FAKE/token-gone"
: > "$FAKE/claude.log"
fleet schedule run >/dev/null 2>&1 || fail "nightly pass"
grep -q HEATMAP_MCP_TOKEN "$HOME/.zshenv" && fail "a withdrawn token stayed"
grep -q MINE_TOKEN "$HOME/.zshenv" || fail "the nightly pass dropped an env token"
grep -qx update "$FAKE/claude.log" && grep -qx 'codex update' "$FAKE/claude.log" || fail "harnesses not updated"
grep -q 'try-restart hermes-gateway.service' "$FAKE/systemctl.log" || fail "hermes not restarted"
[[ ! -e "$XDG_STATE_HOME/fleet/hermes.restart" ]] || fail "hermes restart left pending"

# Installing: retired and unknown harnesses are refused.
out=$(fleet install kimi 2>&1) && fail "installed a retired harness"
[[ "$out" == *retired* ]] || fail "retired harness message: $out"
fleet install nope >/dev/null 2>&1 && fail "installed an unknown harness"

# Uninstalling takes back what fleet rendered; the user's own entries stay.
fleet __unrender >/dev/null 2>&1 || fail "unrender"
servers=$(json "$HOME/.claude.json" 'sorted(v["mcpServers"])')
[[ "$servers" == "['personal']" ]] || fail "claude MCP after unrender: $servers"
grep -q "fleet" "$HOME/.claude.json" && fail "a claude entry still calls fleet"
[[ "$(json "$settings" 'v["myKey"]')" == 1 ]] || fail "unrender dropped the user's key"
grep -q MCP_TOKEN "$HOME/.zshenv" "$HOME/.codex/.env" && fail "tokens left after unrender"
grep -q heatmap "$codex" "$hermes" && fail "codex or hermes kept a fleet server"
grep -q 'elsewhere.example' "$codex" || fail "unrender took the user's codex server"
[[ ! -e "$XDG_STATE_HOME/fleet/applied.json" ]] || fail "applied record left"

echo "fleet harness tests passed"
