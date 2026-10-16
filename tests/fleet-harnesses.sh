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
    if os.path.exists(f"{fake}/token-down-{sys.argv[2]}"):
        sys.exit(1)
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
 {"key": "odd.example.com", "label": "Odd", "group": "tools", "url": "https://odd.example.com",
  "mcp_url": "https://odd.example.com/mcp", "token_key": "", "admin_only": false, "alias": ""},
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
    if os.path.exists(os.environ["FAKE"] + "/claude-add-fail"):
        print("could not write the config", file=sys.stderr)
        sys.exit(1)
    servers[args[4]] = json.loads(args[5])
elif args[:2] == ["mcp", "remove"]:
    if os.path.exists(os.environ["FAKE"] + "/claude-remove-fail"):
        print("could not write the config", file=sys.stderr)
        sys.exit(1)
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
printf '#!/bin/sh\necho "$*" >> "$FAKE/systemctl.log"\n[ -e "$FAKE/systemctl-fail" ] && exit 1\nexit 0\n' > "$TMP/bin/systemctl"
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
grep -q 'odd' "$codex" "$HOME/.claude.json" && fail "a hub service with a dotted name was rendered"
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
# A harness installed since the last render reads as outdated.
mv "$HOME/.hermes/config.yaml" "$TMP/hermes.away"
fleet sync --check >/dev/null 2>&1 && fail "check missed a harness gone since the render"
mv "$TMP/hermes.away" "$HOME/.hermes/config.yaml"
fleet sync --check >/dev/null 2>&1 || fail "check after the harness came back"

# A server claude failed to add is tried again on the next run.
server_put mcp.json '{"mcpServers": [
  {"name": "mine", "url": "https://mine.example/mcp", "auth": "bearer", "credentialSource": "env", "env": "MINE_TOKEN"},
  {"name": "open", "url": "https://open.example/mcp"},
  {"name": "extra", "url": "https://extra.example/mcp"},
  {"name": "vault", "url": "https://v.example/mcp", "auth": "bearer", "credentialSource": "passage"}]}'
touch "$FAKE/claude-add-fail"
fleet sync --pull >/dev/null 2>&1 && fail "a failed claude add went unreported"
rm "$FAKE/claude-add-fail"
fleet sync --check >/dev/null 2>&1 && fail "check missed a failed render"
[[ "$(json "$HOME/.claude.json" '"extra" in v["mcpServers"]')" == False ]] || fail "the failing claude added a server"
fleet sync --pull >/dev/null 2>&1 || fail "pass after claude recovered"
[[ "$(json "$HOME/.claude.json" '"extra" in v["mcpServers"]')" == True ]] || fail "a failed claude add was not retried"

# A server claude failed to remove stays fleet's, so the next run removes it.
server_put mcp.json '{"mcpServers": [
  {"name": "mine", "url": "https://mine.example/mcp", "auth": "bearer", "credentialSource": "env", "env": "MINE_TOKEN"},
  {"name": "open", "url": "https://open.example/mcp"},
  {"name": "vault", "url": "https://v.example/mcp", "auth": "bearer", "credentialSource": "passage"}]}'
touch "$FAKE/claude-remove-fail"
fleet sync --pull >/dev/null 2>&1 && fail "a failed claude remove went unreported"
rm "$FAKE/claude-remove-fail"
[[ "$(json "$HOME/.claude.json" '"extra" in v["mcpServers"]')" == True ]] || fail "the failing claude removed a server"
fleet sync --pull >/dev/null 2>&1 || fail "pass after claude recovered"
[[ "$(json "$HOME/.claude.json" '"extra" in v["mcpServers"]')" == False ]] || fail "a failed claude remove was not retried"

# A server dropped while claude is missing stays fleet's, so the run that
# finds claude again removes it.
with_extra='{"mcpServers": [
  {"name": "mine", "url": "https://mine.example/mcp", "auth": "bearer", "credentialSource": "env", "env": "MINE_TOKEN"},
  {"name": "open", "url": "https://open.example/mcp"},
  {"name": "extra", "url": "https://extra.example/mcp"},
  {"name": "vault", "url": "https://v.example/mcp", "auth": "bearer", "credentialSource": "passage"}]}'
server_put mcp.json "$with_extra"
fleet sync --pull >/dev/null 2>&1 || fail "pass adding extra back"
[[ "$(json "$HOME/.claude.json" '"extra" in v["mcpServers"]')" == True ]] || fail "extra was not added back"
mv "$BIN/claude" "$TMP/claude.away"
server_put mcp.json '{"mcpServers": [
  {"name": "mine", "url": "https://mine.example/mcp", "auth": "bearer", "credentialSource": "env", "env": "MINE_TOKEN"},
  {"name": "open", "url": "https://open.example/mcp"},
  {"name": "vault", "url": "https://v.example/mcp", "auth": "bearer", "credentialSource": "passage"}]}'
fleet sync --pull >/dev/null 2>&1 || fail "pass without claude"
mv "$TMP/claude.away" "$BIN/claude"
fleet sync --pull >/dev/null 2>&1 || fail "pass after claude came back"
[[ "$(json "$HOME/.claude.json" '"extra" in v["mcpServers"]')" == False ]] || fail "a server dropped while claude was missing stayed"

# An entry the user already had, matching ours, stays theirs: dropping the
# server from the account does not remove it.
python3 - "$HOME/.claude.json" "$HOME/.hermes/config.yaml" <<'EOF'
import json, sys
v = json.load(open(sys.argv[1])); v["mcpServers"]["theirs"] = {"type": "http", "url": "https://t.example/mcp"}
json.dump(v, open(sys.argv[1], "w"))
text = open(sys.argv[2]).read().replace("mcp_servers:\n", "mcp_servers:\n  theirs:\n    type: remote\n"
                                         "    url: https://t.example/mcp\n    oauth: false\n", 1)
open(sys.argv[2], "w").write(text)
EOF
server_put mcp.json '{"mcpServers": [
  {"name": "mine", "url": "https://mine.example/mcp", "auth": "bearer", "credentialSource": "env", "env": "MINE_TOKEN"},
  {"name": "open", "url": "https://open.example/mcp"},
  {"name": "theirs", "url": "https://t.example/mcp"},
  {"name": "vault", "url": "https://v.example/mcp", "auth": "bearer", "credentialSource": "passage"}]}'
fleet sync --pull >/dev/null 2>&1 || fail "pass with the user's own matching entry"
fleet sync --pull >/dev/null 2>&1 || fail "second pass with the user's own matching entry"
server_put mcp.json "$with_extra"
fleet sync --pull >/dev/null 2>&1 || fail "pass dropping the user's matching server"
[[ "$(json "$HOME/.claude.json" '"theirs" in v["mcpServers"]')" == True ]] || fail "claude lost the user's own entry"
grep -q '^  theirs:' "$HOME/.hermes/config.yaml" || fail "hermes lost the user's own entry"
python3 - "$HOME/.claude.json" "$HOME/.hermes/config.yaml" <<'EOF'
import json, sys
v = json.load(open(sys.argv[1])); del v["mcpServers"]["theirs"]; json.dump(v, open(sys.argv[1], "w"))
text = open(sys.argv[2]).read().replace("  theirs:\n    type: remote\n    url: https://t.example/mcp\n    oauth: false\n", "", 1)
open(sys.argv[2], "w").write(text)
EOF
server_put mcp.json '{"mcpServers": [
  {"name": "mine", "url": "https://mine.example/mcp", "auth": "bearer", "credentialSource": "env", "env": "MINE_TOKEN"},
  {"name": "open", "url": "https://open.example/mcp"},
  {"name": "vault", "url": "https://v.example/mcp", "auth": "bearer", "credentialSource": "passage"}]}'
fleet sync --pull >/dev/null 2>&1 || fail "pass after the user's own entry test"

# A hermes key written on one line is left alone, not followed by a second
# block that would replace it.
cp "$HOME/.hermes/config.yaml" "$TMP/hermes.keep"
printf 'model: x\nmcp_servers: {personal: {url: https://p.example/mcp}}\n' > "$HOME/.hermes/config.yaml"
cp "$HOME/.hermes/config.yaml" "$TMP/hermes.flow"
server_put mcp.json "$with_extra"
fleet sync --pull > "$TMP/out" 2>&1 && fail "rendered into a one-line hermes mcp_servers"
cmp -s "$HOME/.hermes/config.yaml" "$TMP/hermes.flow" || fail "edited a one-line hermes mcp_servers"
grep -q 'written on one line' "$TMP/out" || fail "a one-line hermes mcp_servers went unreported"
mv "$TMP/hermes.keep" "$HOME/.hermes/config.yaml"
server_put mcp.json '{"mcpServers": [
  {"name": "mine", "url": "https://mine.example/mcp", "auth": "bearer", "credentialSource": "env", "env": "MINE_TOKEN"},
  {"name": "open", "url": "https://open.example/mcp"},
  {"name": "vault", "url": "https://v.example/mcp", "auth": "bearer", "credentialSource": "passage"}]}'
fleet sync --pull >/dev/null 2>&1 || fail "pass after the one-line hermes test"

# Node toolchains are tried newest version first, v20 ahead of v9.
mkdir -p "$TMP/nvm/.nvm/versions/node/v9.11.2/bin" "$TMP/nvm/.nvm/versions/node/v20.0.0/bin"
first=$(HOME="$TMP/nvm" python3 -c '
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("fleet_nvm", sys.argv[1])
fleet = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(fleet)
print(fleet._node_bin_dirs()[0])' "$ROOT/files/fleet")
[[ "$first" == */v20.0.0/bin ]] || fail "node toolchains in the wrong order: $first"

# A Passage outage before the first render keeps the token the environment holds.
kept=$(HOME="$TMP/nvm" VAULT_MCP_TOKEN=from-env python3 -c '
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("fleet_vault", sys.argv[1])
fleet = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(fleet)
fleet.common_auth_token = lambda scope, context: "passage-access"
def down(token, item): raise fleet.TokenError("passage unreachable")
fleet._vault_get = down
server = {"name": "vault", "url": "https://v.example/mcp", "auth": "bearer", "credentialSource": "passage"}
exports, drop, skipped, missing = fleet.resolve_tokens([server], {"origin": "o", "subject": "1"}, [])
print(exports.get(fleet.mcp_env_var(server)))' "$ROOT/files/fleet" 2>/dev/null)
[[ "$kept" == from-env ]] || fail "a Passage outage dropped the environment's token: $kept"

# With nothing to fall back on, the outage fails the render, so the next sync looks again.
missing=$(HOME="$TMP/nvm" python3 -c '
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("fleet_vault2", sys.argv[1])
fleet = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(fleet)
fleet.common_auth_token = lambda scope, context: "passage-access"
def down(token, item): raise fleet.TokenError("passage unreachable")
fleet._vault_get = down
server = {"name": "vault", "url": "https://v.example/mcp", "auth": "bearer", "credentialSource": "passage"}
exports, drop, skipped, missing = fleet.resolve_tokens([server], {"origin": "o", "subject": "1"}, [])
print(sorted(missing))' "$ROOT/files/fleet" 2>/dev/null)
[[ "$missing" == "['vault']" ]] || fail "a lookup with no fallback did not fail the render: $missing"

# A new hub service whose token cannot be fetched yet fails the render, and
# the next ordinary sync fetches it rather than taking the fast path.
cp "$FAKE/services.json" "$TMP/services.saved"
python3 - "$FAKE/services.json" <<'PY'
import json, sys
rows = json.load(open(sys.argv[1]))
rows.append({"key": "fresh.lost.plus", "label": "Fresh", "group": "tools", "url": "https://fresh.lost.plus",
             "mcp_url": "https://fresh.lost.plus/mcp", "token_key": "fresh", "admin_only": False, "alias": ""})
json.dump(rows, open(sys.argv[1], "w"))
PY
touch "$FAKE/token-down-fresh"
fleet sync --pull >/dev/null 2>&1 && fail "a token lookup with no fallback rendered as done"
rm "$FAKE/token-down-fresh"
fleet sync --pull >/dev/null 2>&1 || fail "pass after the token came back"
grep -q "tok-fresh" "$HOME/.zshenv" || fail "the missing token was not fetched again"
cp "$TMP/services.saved" "$FAKE/services.json"
fleet sync --pull >/dev/null 2>&1 || fail "pass after the service went"

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
printf 'HEATMAP_MCP_TOKEN=mine\n' >> "$HOME/.codex/.env"
touch "$FAKE/token-gone" "$FAKE/systemctl-fail"
: > "$FAKE/claude.log"
fleet schedule run >/dev/null 2>&1 && fail "a failed hermes restart went unreported"
[[ -e "$XDG_STATE_HOME/fleet/hermes.restart" ]] || fail "a failed hermes restart dropped its marker"
rm "$FAKE/systemctl-fail"
fleet schedule run >/dev/null 2>&1 || fail "nightly pass"
grep -q HEATMAP_MCP_TOKEN "$HOME/.zshenv" && fail "a withdrawn token stayed"
[[ "$(grep -c '^HEATMAP_MCP_TOKEN=' "$HOME/.codex/.env")" == 1 ]] && grep -qx 'HEATMAP_MCP_TOKEN=mine' "$HOME/.codex/.env" \
    || fail "a withdrawn token took the user's own line: $(cat "$HOME/.codex/.env")"
sed -i.bak '/^HEATMAP_MCP_TOKEN=mine$/d' "$HOME/.codex/.env" && rm -f "$HOME/.codex/.env.bak"
grep -q MINE_TOKEN "$HOME/.zshenv" || fail "the nightly pass dropped an env token"
grep -qx update "$FAKE/claude.log" && grep -qx 'codex update' "$FAKE/claude.log" || fail "harnesses not updated"
grep -q 'try-restart hermes-gateway.service' "$FAKE/systemctl.log" || fail "hermes not restarted"
# A proxy route the nightly pass could not export is reported too.
mkdir -p "$HOME/.local/bin"
printf 'import sys\nsys.exit(sys.argv[1:] == ["__export"])\n' > "$HOME/.local/bin/opencodex"
chmod +x "$HOME/.local/bin/opencodex"
fleet schedule run >/dev/null 2>&1 && fail "a failed route export went unreported"
rm "$HOME/.local/bin/opencodex"
[[ ! -e "$XDG_STATE_HOME/fleet/hermes.restart" ]] || fail "hermes restart left pending"

# Uninstalling takes back only the hermes skills folder fleet added.
skills=$(HERMES_CONFIG="$TMP/hermes-skills.yaml" python3 -c '
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("fleet_skills", sys.argv[1])
fleet = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(fleet)
out = []
for text in ["skills:\n  external_dirs:\n  - ~/.agents/skills\n", "skills:\n  external_dirs:\n  - ~/mine\n"]:
    fleet.HERMES_CONFIG.write_text(text)
    _, ours, _ = fleet.render_hermes([], {}, set())
    fleet.render_hermes([], {"hermesSkills": ours}, set(), clear=True)
    after = fleet.HERMES_CONFIG.read_text()
    out.append(after.startswith(text) and after.count("skills") == text.count("skills"))
open(sys.argv[2], "w").write(str(out))' "$ROOT/files/fleet" "$TMP/skills.out" >/dev/null 2>&1; cat "$TMP/skills.out")
[[ "$skills" == "[True, True]" ]] || fail "uninstall took the wrong hermes skills folder: $skills"

# Installing: retired and unknown harnesses are refused.
out=$(fleet install kimi 2>&1) && fail "installed a retired harness"
[[ "$out" == *retired* ]] || fail "retired harness message: $out"
fleet install nope >/dev/null 2>&1 && fail "installed an unknown harness"

# Uninstalling takes back what fleet rendered; the user's own entries stay.
# Neither a broken manifest nor a claude gone from PATH stops it: claude's
# files are edited directly.
printf '{' > "$TMP/broken-manifest.json"
# Hermes restarts there and then, and a failed restart fails the uninstall.
mv "$BIN/claude" "$TMP/claude.away"
: > "$FAKE/systemctl.log"
touch "$FAKE/systemctl-fail"
FLEET_MANIFEST="$TMP/broken-manifest.json" fleet __unrender >/dev/null 2>&1 && fail "unrender passed a failed hermes restart"
rm "$FAKE/systemctl-fail"
FLEET_MANIFEST="$TMP/broken-manifest.json" fleet __unrender > "$TMP/unrender.out" 2>&1 || fail "unrender: $(cat "$TMP/unrender.out")"
mv "$TMP/claude.away" "$BIN/claude"
[[ "$(grep -c 'try-restart hermes-gateway.service' "$FAKE/systemctl.log")" == 2 ]] || fail "unrender did not restart hermes"
[[ ! -e "$XDG_STATE_HOME/fleet/hermes.restart" ]] || fail "unrender left a hermes restart pending"
servers=$(json "$HOME/.claude.json" 'sorted(v["mcpServers"])')
[[ "$servers" == "['personal']" ]] || fail "claude MCP after unrender: $servers"
grep -q "fleet" "$HOME/.claude.json" && fail "a claude entry still calls fleet"
[[ "$(json "$settings" 'v["myKey"]')" == 1 ]] || fail "unrender dropped the user's key"
grep -q MCP_TOKEN "$HOME/.zshenv" "$HOME/.codex/.env" && fail "tokens left after unrender"
grep -q heatmap "$codex" "$hermes" && fail "codex or hermes kept a fleet server"
grep -q 'elsewhere.example' "$codex" || fail "unrender took the user's codex server"
grep -q 'skills' "$hermes" && fail "unrender left fleet's hermes skills folder: $(cat "$hermes")"
[[ "$(cat "$hermes")" == "$(printf 'model: x\nmcp_servers:\n  personal:\n    url: https://p.example/mcp')" ]] \
    || fail "hermes after unrender: $(cat -A "$hermes")"
[[ ! -e "$XDG_STATE_HOME/fleet/applied.json" ]] || fail "applied record left"
# With hermes' config gone, its .env still loses the tokens fleet wrote.
fleet sync --pull >/dev/null 2>&1 || fail "sync before the hermes .env test"
printf 'MINE=1\n# BEGIN harnesses:mcp-tokens\nHEATMAP_MCP_TOKEN=tok-old\n# END harnesses:mcp-tokens\n' > "$HOME/.hermes/.env"
mv "$hermes" "$TMP/hermes.away"
fleet __unrender >/dev/null 2>&1 || fail "unrender without hermes' config"
mv "$TMP/hermes.away" "$hermes"
grep -q tok-old "$HOME/.hermes/.env" && fail "tokens left in hermes .env without its config"
grep -qx MINE=1 "$HOME/.hermes/.env" || fail "unrender took the user's hermes .env line"

echo "fleet harness tests passed"
