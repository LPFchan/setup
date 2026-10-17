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
local_path = os.environ["FAKE"] + "/claude-local.json"
local = json.load(open(local_path)) if os.path.exists(local_path) else {}
if args[:2] == ["mcp", "get"]:
    if args[2] in local:
        print(f"{args[2]}:\n  Scope: Local config (private to you in this project)")
        sys.exit(0)
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
    if args[3:5] != ["-s", "user"] and args[2] in local:
        del local[args[2]]
        json.dump(local, open(local_path, "w"))
    else:
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
 "permissions": {"defaultMode": "auto", "allow": ["Read", "WebFetch", "mcp__jina__*"]}}
JSON
cat > "$HOME/.claude.json" <<'JSON'
{"mcpServers": {"jina": {"type": "http", "url": "https://mcp.jina.ai/v1"},
                "personal": {"type": "http", "url": "https://p.example/mcp"}}}
JSON
printf 'model = "gpt"\n\n[mcp_servers.open]\nurl = "https://elsewhere.example/mcp"\n' > "$HOME/.codex/config.toml"
printf 'model: x\nmcp_servers:\n  personal:\n    url: https://p.example/mcp\n' > "$HOME/.hermes/config.yaml"

# The account's tier.
server_put settings/claude.json '{"json": {"theme": "dark", "effortLevel": "high"}, "permissionsAllowAdd": ["Bash(ls:*)", "WebFetch"]}'
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
for grant in Read WebFetch 'Bash(ls:*)' 'mcp__daiso__*' 'mcp__notion__*' 'mcp__heatmap__*' 'mcp__wiki__*' 'mcp__mine__*' 'mcp__open__*'; do
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
# A staged copy standing in for the installed one renders the installed path.
self_path=$(FLEET_PATH=/opt/fleet python3 -c '
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("fleet_self", sys.argv[1])
fleet = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(fleet)
print(fleet._self_path())' "$ROOT/files/fleet")
[[ "$self_path" == /opt/fleet ]] || fail "FLEET_PATH not rendered: $self_path"
codex="$HOME/.codex/config.toml"
grep -q '^\[mcp_servers.heatmap\]' "$codex" && grep -q 'bearer_token_env_var = "HEATMAP_MCP_TOKEN"' "$codex" \
    || fail "codex MCP: $(cat "$codex")"
[[ "$(grep -c '^\[mcp_servers.open\]' "$codex")" == 1 ]] || fail "codex emitted a server the user declared"
grep -q 'notion' "$codex" && fail "codex got a claude-only server"
[[ "$(json "$XDG_STATE_HOME/fleet/applied.json" 'v.get("codexReclaimed")')" == True ]] \
    || fail "a codex render did not record that older releases' blocks were reclaimed"
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
# A server whose token variable already holds another server's token is
# left out, not handed that token.
server_put mcp.json '{"mcpServers": [
  {"name": "mine", "url": "https://mine.example/mcp", "auth": "bearer", "credentialSource": "env", "env": "MINE_TOKEN"},
  {"name": "open", "url": "https://open.example/mcp"},
  {"name": "grab", "url": "https://grab.example/mcp", "auth": "bearer", "credentialSource": "env", "env": "HEATMAP_MCP_TOKEN"},
  {"name": "vault", "url": "https://v.example/mcp", "auth": "bearer", "credentialSource": "passage"}]}'
fleet sync --pull > "$TMP/out" 2>&1 || fail "pass with a shared token variable: $(cat "$TMP/out")"
grep -q "grab: HEATMAP_MCP_TOKEN already holds another server's token" "$TMP/out" \
    || fail "a shared token variable was not reported: $(cat "$TMP/out")"
grep -q grab "$HOME/.claude.json" "$HOME/.codex/config.toml" "$HOME/.hermes/config.yaml" \
    && fail "rendered a server sharing another's token variable"
server_put mcp.json '{"mcpServers": [
  {"name": "mine", "url": "https://mine.example/mcp", "auth": "bearer", "credentialSource": "env", "env": "MINE_TOKEN"},
  {"name": "open", "url": "https://open.example/mcp"},
  {"name": "vault", "url": "https://v.example/mcp", "auth": "bearer", "credentialSource": "passage"}]}'
fleet sync --pull >/dev/null 2>&1 || fail "pass after the shared token variable"


# A record that cannot be saved stops the pass before any harness changes.
mkdir -p "$TMP/nosave"
cat > "$TMP/nosave/sitecustomize.py" <<'PY'
import os
real = os.replace
def replace(src, dst, *a, **k):
    if str(dst).endswith("applied.json"):
        raise OSError(28, "No space left on device", str(dst))
    return real(src, dst, *a, **k)
os.replace = replace
PY
server_put mcp.json '{"mcpServers": [
  {"name": "mine", "url": "https://mine.example/mcp", "auth": "bearer", "credentialSource": "env", "env": "MINE_TOKEN"},
  {"name": "open", "url": "https://open.example/mcp"},
  {"name": "extra", "url": "https://extra.example/mcp"},
  {"name": "vault", "url": "https://v.example/mcp", "auth": "bearer", "credentialSource": "passage"}]}'
rc=0; PYTHONPATH="$TMP/nosave" fleet sync --pull > "$TMP/out" 2>&1 || rc=$?
[[ $rc != 0 ]] || fail "a pass that cannot save its record succeeded"
grep -q extra "$HOME/.claude.json" "$HOME/.codex/config.toml" "$HOME/.hermes/config.yaml" \
    && fail "rendered a server without a saved record"

# A record that saves before the render but not after still owns what the
# render added, so dropping the server later takes it off.
cat > "$TMP/nosave/sitecustomize.py" <<'PY'
import os
real, saves = os.replace, []
def replace(src, dst, *a, **k):
    if str(dst).endswith("applied.json"):
        saves.append(dst)
        if len(saves) == 2:
            raise OSError(28, "No space left on device", str(dst))
    return real(src, dst, *a, **k)
os.replace = replace
PY
# The user's own matching entries, there before that render, stay theirs.
python3 - "$HOME/.claude.json" <<'PY'
import json, sys
v = json.load(open(sys.argv[1])); s = v["mcpServers"]
s["own"] = dict(s["open"], url="https://own.example/mcp")
json.dump(v, open(sys.argv[1], "w"))
PY
sed -i 's|^mcp_servers:$|mcp_servers:\n  own:\n    type: remote\n    url: https://own.example/mcp\n    oauth: false|' "$HOME/.hermes/config.yaml"
server_put mcp.json '{"mcpServers": [
  {"name": "mine", "url": "https://mine.example/mcp", "auth": "bearer", "credentialSource": "env", "env": "MINE_TOKEN"},
  {"name": "open", "url": "https://open.example/mcp"},
  {"name": "extra", "url": "https://extra.example/mcp"},
  {"name": "own", "url": "https://own.example/mcp"},
  {"name": "vault", "url": "https://v.example/mcp", "auth": "bearer", "credentialSource": "passage"}]}'
# As does the hermes skills folder, added by that render too.
sed -i '/^skills:$/,/^  - ~\/.agents\/skills$/d' "$HOME/.hermes/config.yaml"
python3 - "$XDG_STATE_HOME/fleet/applied.json" <<'PY'
import json, sys
v = json.load(open(sys.argv[1])); v["hermesSkills"] = False; json.dump(v, open(sys.argv[1], "w"))
PY
PYTHONPATH="$TMP/nosave" fleet sync --pull > "$TMP/out" 2>&1 && fail "a pass whose record was lost succeeded"
[[ "$(json "$HOME/.claude.json" '"extra" in v["mcpServers"]')" == True ]] && grep -q extra "$HOME/.hermes/config.yaml" \
    || fail "the render before a lost record did not add the server: $(cat "$TMP/out")"
fleet sync --pull >/dev/null 2>&1 || fail "pass after a lost record"
[[ "$(json "$XDG_STATE_HOME/fleet/applied.json" 'bool(v.get("hermesSkills"))')" == True ]] \
    || fail "a hermes skills folder added before a lost record was read as the user's"
server_put mcp.json '{"mcpServers": [
  {"name": "mine", "url": "https://mine.example/mcp", "auth": "bearer", "credentialSource": "env", "env": "MINE_TOKEN"},
  {"name": "open", "url": "https://open.example/mcp"},
  {"name": "vault", "url": "https://v.example/mcp", "auth": "bearer", "credentialSource": "passage"}]}'
fleet sync --pull >/dev/null 2>&1 || fail "pass dropping a server added before a lost record"
[[ "$(json "$HOME/.claude.json" '"extra" in v["mcpServers"]')" == False ]] && ! grep -q extra "$HOME/.hermes/config.yaml" \
    || fail "a server added before a lost record was read as the user's"
[[ "$(json "$HOME/.claude.json" '"own" in v["mcpServers"]')" == True ]] && grep -q own.example "$HOME/.hermes/config.yaml" \
    || fail "the user's own entries were taken off with a server added before a lost record"
python3 - "$HOME/.claude.json" <<'PY'
import json, sys
v = json.load(open(sys.argv[1])); del v["mcpServers"]["own"]
json.dump(v, open(sys.argv[1], "w"))
PY
sed -i '/^  own:$/,/^    oauth: false$/d' "$HOME/.hermes/config.yaml"

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

# A server claude failed to add is not fleet's on claude: the matching entry
# the user then adds by hand stays when the server is dropped.
touch "$FAKE/claude-add-fail"
server_put mcp.json '{"mcpServers": [
  {"name": "mine", "url": "https://mine.example/mcp", "auth": "bearer", "credentialSource": "env", "env": "MINE_TOKEN"},
  {"name": "open", "url": "https://open.example/mcp"},
  {"name": "extra", "url": "https://extra.example/mcp"},
  {"name": "vault", "url": "https://v.example/mcp", "auth": "bearer", "credentialSource": "passage"}]}'
fleet sync --pull >/dev/null 2>&1 && fail "a failed claude add went unreported"
rm "$FAKE/claude-add-fail"
python3 - "$HOME/.claude.json" <<'EOF'
import json, sys
v = json.load(open(sys.argv[1])); v["mcpServers"]["extra"] = {"type": "http", "url": "https://extra.example/mcp"}
json.dump(v, open(sys.argv[1], "w"))
EOF
fleet sync --pull >/dev/null 2>&1 || fail "pass after the user added the server claude failed on"
server_put mcp.json '{"mcpServers": [
  {"name": "mine", "url": "https://mine.example/mcp", "auth": "bearer", "credentialSource": "env", "env": "MINE_TOKEN"},
  {"name": "open", "url": "https://open.example/mcp"},
  {"name": "vault", "url": "https://v.example/mcp", "auth": "bearer", "credentialSource": "passage"}]}'
fleet sync --pull >/dev/null 2>&1 || fail "pass dropping the server claude failed on"
[[ "$(json "$HOME/.claude.json" '"extra" in v["mcpServers"]')" == True ]] || fail "claude lost the user's entry for a server it failed to add"
python3 - "$HOME/.claude.json" <<'EOF'
import json, sys
v = json.load(open(sys.argv[1])); del v["mcpServers"]["extra"]; json.dump(v, open(sys.argv[1], "w"))
EOF

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

# A retired name goes from the user scope, where the old harness wrote it,
# and is left alone at the user's other scopes.
printf '{"obsidian-direct": {"type": "http", "url": "https://mine.example/obs"}}' > "$FAKE/claude-local.json"
python3 - "$HOME/.claude.json" <<'PY'
import json, sys
v = json.load(open(sys.argv[1])); v["mcpServers"]["vaultwarden-secrets"] = {"type": "http", "url": "https://vault.example/mcp"}
json.dump(v, open(sys.argv[1], "w"))
PY
server_put mcp.json "$with_extra"
fleet sync --pull >/dev/null 2>&1 || fail "pass with retired names"
[[ "$(json "$HOME/.claude.json" '"vaultwarden-secrets" in v["mcpServers"]')" == False ]] || fail "a retired user-scope server stayed"
[[ "$(json "$FAKE/claude-local.json" '"obsidian-direct" in v')" == True ]] || fail "removed the user's local server with a retired name"
rm "$FAKE/claude-local.json"
server_put mcp.json '{"mcpServers": [
  {"name": "mine", "url": "https://mine.example/mcp", "auth": "bearer", "credentialSource": "env", "env": "MINE_TOKEN"},
  {"name": "open", "url": "https://open.example/mcp"},
  {"name": "vault", "url": "https://v.example/mcp", "auth": "bearer", "credentialSource": "passage"}]}'
fleet sync --pull >/dev/null 2>&1 || fail "pass dropping extra after the retired names"
# A server first met behind the user's local registration was never put at
# user scope by fleet: a matching one the user puts there later is theirs,
# and stays when the account drops the server.
printf '{"extra": {"type": "http", "url": "https://mine.example/extra"}}' > "$FAKE/claude-local.json"
server_put mcp.json "$with_extra"
fleet sync --pull >/dev/null 2>&1 || fail "pass with extra shadowed"
[[ "$(json "$HOME/.claude.json" '"extra" in v["mcpServers"]')" == False ]] || fail "added a server shadowed at local scope"
rm "$FAKE/claude-local.json"
python3 - "$HOME/.claude.json" <<'PY'
import json, sys
v = json.load(open(sys.argv[1])); s = v["mcpServers"]
s["extra"] = dict(s["open"], url="https://extra.example/mcp")
json.dump(v, open(sys.argv[1], "w"))
PY
fleet sync --pull >/dev/null 2>&1 || fail "pass with the user's own extra"
server_put mcp.json '{"mcpServers": [
  {"name": "mine", "url": "https://mine.example/mcp", "auth": "bearer", "credentialSource": "env", "env": "MINE_TOKEN"},
  {"name": "open", "url": "https://open.example/mcp"},
  {"name": "vault", "url": "https://v.example/mcp", "auth": "bearer", "credentialSource": "passage"}]}'
fleet sync --pull >/dev/null 2>&1 || fail "pass dropping the shadowed extra"
[[ "$(json "$HOME/.claude.json" '"extra" in v["mcpServers"]')" == True ]] || fail "removed the user's own entry for a server first met shadowed"
python3 - "$HOME/.claude.json" <<'PY'
import json, sys
v = json.load(open(sys.argv[1])); del v["mcpServers"]["extra"]
json.dump(v, open(sys.argv[1], "w"))
PY

# A server the account moves to another URL moves on every harness.
server_put mcp.json '{"mcpServers": [
  {"name": "mine", "url": "https://mine.example/mcp", "auth": "bearer", "credentialSource": "env", "env": "MINE_TOKEN"},
  {"name": "open", "url": "https://open2.example/mcp"},
  {"name": "vault", "url": "https://v.example/mcp", "auth": "bearer", "credentialSource": "passage"}]}'
fleet sync --pull >/dev/null 2>&1 || fail "pass moving open"
grep -q '^    url: https://open2.example/mcp$' "$HOME/.hermes/config.yaml" || fail "hermes kept open's old url"
[[ "$(json "$HOME/.claude.json" 'v["mcpServers"]["open"]["url"]')" == https://open2.example/mcp ]] \
    || fail "claude kept open's old url"
# Moved back while hermes refuses its file, hermes moves once it is fixed.
cp "$HOME/.hermes/config.yaml" "$TMP/hermes.keep"
sed -i 's/^mcp_servers:$/mcp_servers:\n odd: 1/' "$HOME/.hermes/config.yaml"
server_put mcp.json '{"mcpServers": [
  {"name": "mine", "url": "https://mine.example/mcp", "auth": "bearer", "credentialSource": "env", "env": "MINE_TOKEN"},
  {"name": "open", "url": "https://open.example/mcp"},
  {"name": "vault", "url": "https://v.example/mcp", "auth": "bearer", "credentialSource": "passage"}]}'
fleet sync --pull >/dev/null 2>&1 && fail "a refused hermes file went unreported"
grep -q '^    url: https://open2.example/mcp$' "$HOME/.hermes/config.yaml" || fail "wrote a hermes file it refused"
cp "$TMP/hermes.keep" "$HOME/.hermes/config.yaml"
fleet sync --pull >/dev/null 2>&1 || fail "pass moving open back"
grep -q '^    url: https://open.example/mcp$' "$HOME/.hermes/config.yaml" || fail "hermes stayed on a URL moved while it was refused"
# A move claude failed to make, then a drop, still takes fleet's old entry.
open2='{"mcpServers": [
  {"name": "mine", "url": "https://mine.example/mcp", "auth": "bearer", "credentialSource": "env", "env": "MINE_TOKEN"},
  {"name": "open", "url": "https://open2.example/mcp"},
  {"name": "vault", "url": "https://v.example/mcp", "auth": "bearer", "credentialSource": "passage"}]}'
noopen='{"mcpServers": [
  {"name": "mine", "url": "https://mine.example/mcp", "auth": "bearer", "credentialSource": "env", "env": "MINE_TOKEN"},
  {"name": "vault", "url": "https://v.example/mcp", "auth": "bearer", "credentialSource": "passage"}]}'
withopen='{"mcpServers": [
  {"name": "mine", "url": "https://mine.example/mcp", "auth": "bearer", "credentialSource": "env", "env": "MINE_TOKEN"},
  {"name": "open", "url": "https://open.example/mcp"},
  {"name": "vault", "url": "https://v.example/mcp", "auth": "bearer", "credentialSource": "passage"}]}'
server_put mcp.json "$open2"
touch "$FAKE/claude-remove-fail"
fleet sync --pull >/dev/null 2>&1 && fail "a failed claude re-enroll went unreported"
rm "$FAKE/claude-remove-fail"
# Even past a run without claude.
mv "$BIN/claude" "$TMP/claude.away"
fleet sync --pull >/dev/null 2>&1 || fail "pass without claude after a failed move"
mv "$TMP/claude.away" "$BIN/claude"
server_put mcp.json "$noopen"
fleet sync --pull >/dev/null 2>&1 || fail "pass dropping a server claude failed to move"
[[ "$(json "$HOME/.claude.json" '"open" in v["mcpServers"]')" == False ]] || fail "claude kept fleet's entry from before a failed move"
# So does a move hermes refused, once its file is fixed.
server_put mcp.json "$withopen"
fleet sync --pull >/dev/null 2>&1 || fail "pass adding open back"
cp "$HOME/.hermes/config.yaml" "$TMP/hermes.keep"
sed -i 's/^mcp_servers:$/mcp_servers:\n odd: 1/' "$HOME/.hermes/config.yaml"
server_put mcp.json "$open2"
fleet sync --pull >/dev/null 2>&1 && fail "a refused hermes file went unreported"
cp "$TMP/hermes.keep" "$HOME/.hermes/config.yaml"
server_put mcp.json "$noopen"
fleet sync --pull >/dev/null 2>&1 || fail "pass dropping a server hermes refused to move"
grep -q '^  open:' "$HOME/.hermes/config.yaml" && fail "hermes kept fleet's entry from before a refused move"
server_put mcp.json "$withopen"
fleet sync --pull >/dev/null 2>&1 || fail "pass adding open back after the move tests"
# A move both wrote before the run stopped short of its record, then a
# drop, still takes fleet's new entry off.
server_put mcp.json "$open2"
python3 -c '
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("fleet_crash", sys.argv[1])
fleet = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(fleet)
save = fleet._save_json
def stop(path, data):
    if path == fleet.APPLIED and data.get("hash"):
        raise OSError("disk gone")
    save(path, data)
fleet._save_json = stop
sys.argv = ["fleet", "sync", "--pull"]
sys.exit(fleet.main())' "$ROOT/files/fleet" </dev/null >/dev/null 2>&1 && fail "a run stopped before its record rendered as done"
grep -q '^    url: https://open2.example/mcp$' "$HOME/.hermes/config.yaml" || fail "the stopped run did not move hermes"
server_put mcp.json "$noopen"
fleet sync --pull >/dev/null 2>&1 || fail "pass dropping a server a stopped run moved"
[[ "$(json "$HOME/.claude.json" '"open" in v["mcpServers"]')" == False ]] || fail "claude kept the entry a stopped run moved"
grep -q '^  open:' "$HOME/.hermes/config.yaml" && fail "hermes kept the entry a stopped run moved"
server_put mcp.json "$withopen"
fleet sync --pull >/dev/null 2>&1 || fail "pass adding open back after the stopped move"

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
# Nor does a change to the account's definition replace it.
server_put mcp.json '{"mcpServers": [
  {"name": "mine", "url": "https://mine.example/mcp", "auth": "bearer", "credentialSource": "env", "env": "MINE_TOKEN"},
  {"name": "open", "url": "https://open.example/mcp"},
  {"name": "theirs", "url": "https://t2.example/mcp"},
  {"name": "vault", "url": "https://v.example/mcp", "auth": "bearer", "credentialSource": "passage"}]}'
fleet sync --pull >/dev/null 2>&1 || fail "pass changing the user's matching server"
[[ "$(json "$HOME/.claude.json" 'v["mcpServers"]["theirs"]["url"]')" == https://t.example/mcp ]] \
    || fail "claude re-enrolled the user's own entry"
# And a later render that finds it matching again leaves it theirs.
server_put mcp.json '{"mcpServers": [
  {"name": "mine", "url": "https://mine.example/mcp", "auth": "bearer", "credentialSource": "env", "env": "MINE_TOKEN"},
  {"name": "open", "url": "https://open.example/mcp"},
  {"name": "theirs", "url": "https://t.example/mcp"},
  {"name": "vault", "url": "https://v.example/mcp", "auth": "bearer", "credentialSource": "passage"}]}'
server_put settings/claude.json '{"json": {"theme": "dark", "effortLevel": "high", "nudge": 1}, "permissionsAllowAdd": ["Bash(ls:*)"]}'
fleet sync --pull >/dev/null 2>&1 || fail "pass matching the user's entry again"
server_put settings/claude.json '{"json": {"theme": "dark", "effortLevel": "high"}, "permissionsAllowAdd": ["Bash(ls:*)"]}'
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
# Once the user deletes their entry, the one fleet adds back is fleet's and
# goes with the server.
add_theirs() {
    python3 - "$HOME/.claude.json" "$HOME/.hermes/config.yaml" <<'EOF2'
import json, sys
v = json.load(open(sys.argv[1])); v["mcpServers"]["theirs"] = {"type": "http", "url": "https://t.example/mcp"}
json.dump(v, open(sys.argv[1], "w"))
text = open(sys.argv[2]).read().replace("mcp_servers:\n", "mcp_servers:\n  theirs:\n    type: remote\n"
                                         "    url: https://t.example/mcp\n    oauth: false\n", 1)
open(sys.argv[2], "w").write(text)
EOF2
}
add_theirs
with_theirs='{"mcpServers": [
  {"name": "mine", "url": "https://mine.example/mcp", "auth": "bearer", "credentialSource": "env", "env": "MINE_TOKEN"},
  {"name": "open", "url": "https://open.example/mcp"},
  {"name": "theirs", "url": "https://t.example/mcp"},
  {"name": "vault", "url": "https://v.example/mcp", "auth": "bearer", "credentialSource": "passage"}]}'
server_put mcp.json "$with_theirs"
fleet sync --pull >/dev/null 2>&1 || fail "pass taking the user's entry as theirs again"
python3 - "$HOME/.claude.json" "$HOME/.hermes/config.yaml" <<'EOF2'
import json, sys
v = json.load(open(sys.argv[1])); del v["mcpServers"]["theirs"]; json.dump(v, open(sys.argv[1], "w"))
text = open(sys.argv[2]).read().replace("  theirs:\n    type: remote\n    url: https://t.example/mcp\n    oauth: false\n", "", 1)
open(sys.argv[2], "w").write(text)
EOF2
server_put settings/claude.json '{"json": {"theme": "dark", "effortLevel": "high", "nudge": 1}, "permissionsAllowAdd": ["Bash(ls:*)"]}'
fleet sync --pull >/dev/null 2>&1 || fail "pass adding the deleted entry back"
[[ "$(json "$HOME/.claude.json" '"theirs" in v["mcpServers"]')" == True ]] && grep -q '^  theirs:' "$HOME/.hermes/config.yaml" \
    || fail "the deleted entry was not added back"
server_put mcp.json "$with_extra"
fleet sync --pull >/dev/null 2>&1 || fail "pass dropping the re-added server"
[[ "$(json "$HOME/.claude.json" '"theirs" in v["mcpServers"]')" == False ]] || fail "claude kept fleet's re-added entry as the user's"
grep -q '^  theirs:' "$HOME/.hermes/config.yaml" && fail "hermes kept fleet's re-added entry as the user's"
server_put settings/claude.json '{"json": {"theme": "dark", "effortLevel": "high"}, "permissionsAllowAdd": ["Bash(ls:*)"]}'
server_put mcp.json '{"mcpServers": [
  {"name": "mine", "url": "https://mine.example/mcp", "auth": "bearer", "credentialSource": "env", "env": "MINE_TOKEN"},
  {"name": "open", "url": "https://open.example/mcp"},
  {"name": "vault", "url": "https://v.example/mcp", "auth": "bearer", "credentialSource": "passage"}]}'
fleet sync --pull >/dev/null 2>&1 || fail "pass after the re-added entry test"

# A t3 model the user already had stays when the account stops naming it;
# one fleet added goes.
t3="$HOME/.t3/userdata/settings.json"
python3 - "$t3" <<'EOF2'
import json, sys
v = json.load(open(sys.argv[1]))
v["providerInstances"]["claudeAgent"]["config"]["customModels"].append({"slug": "own-model", "name": "Own"})
json.dump(v, open(sys.argv[1], "w"))
EOF2
server_put settings/t3.json '{"claudeCustomModels": [{"slug": "my-model", "name": "Mine"}, {"slug": "own-model", "name": "Fleet"}, {"slug": "new-model", "name": "New"}]}'
fleet sync --pull >/dev/null 2>&1 || fail "pass naming the user's t3 model"
[[ "$(json "$t3" '[m["name"] for m in v["providerInstances"]["claudeAgent"]["config"]["customModels"]]')" == "['Mine', 'Fleet', 'New']" ]] \
    || fail "t3 models not refreshed: $(cat "$t3")"
server_put settings/t3.json '{"claudeCustomModels": [{"slug": "my-model", "name": "Mine"}]}'
fleet sync --pull >/dev/null 2>&1 || fail "pass dropping the user's t3 model"
[[ "$(json "$t3" '[m["slug"] for m in v["providerInstances"]["claudeAgent"]["config"]["customModels"]]')" == "['my-model', 'own-model']" ]] \
    || fail "t3 dropped the user's own model or kept fleet's: $(cat "$t3")"
python3 - "$t3" <<'EOF2'
import json, sys
v = json.load(open(sys.argv[1]))
m = v["providerInstances"]["claudeAgent"]["config"]["customModels"]
m[:] = [r for r in m if r["slug"] != "own-model"]
json.dump(v, open(sys.argv[1], "w"))
EOF2
# A run stopped after writing a setting, a grant and a t3 model still owns
# them, so they come off when the account drops them.
server_put settings/claude.json '{"json": {"theme": "dark", "effortLevel": "high", "crashKey": 1}, "permissionsAllowAdd": ["Bash(ls:*)", "Grep"]}'
server_put settings/t3.json '{"claudeCustomModels": [{"slug": "my-model", "name": "Mine"}, {"slug": "crash-model", "name": "Crash"}]}'
python3 -c '
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("fleet_crash", sys.argv[1])
fleet = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(fleet)
def boom(*args): raise OSError("disk gone")
fleet.render_hermes = boom
sys.argv = ["fleet", "sync", "--pull"]
sys.exit(fleet.main())' "$ROOT/files/fleet" </dev/null >/dev/null 2>&1 && fail "a run stopped partway rendered as done"
[[ "$(json "$settings" 'v["permissions"]["allow"]')" == *Grep* ]] || fail "the stopped run wrote no grant"
[[ "$(json "$t3" '[m["slug"] for m in v["providerInstances"]["claudeAgent"]["config"]["customModels"]]')" == *crash-model* ]] \
    || fail "the stopped run wrote no t3 model"
server_put settings/claude.json '{"json": {"theme": "dark", "effortLevel": "high"}, "permissionsAllowAdd": ["Bash(ls:*)"]}'
server_put settings/t3.json '{"claudeCustomModels": [{"slug": "my-model", "name": "Mine"}]}'
fleet sync --pull >/dev/null 2>&1 || fail "pass after the stopped run"
[[ "$(json "$settings" 'v["permissions"]["allow"]')" != *Grep* ]] || fail "a stopped run's grant was left as the user's"
[[ "$(json "$settings" '"crashKey" in v')" == False ]] || fail "a stopped run's setting was left as the user's"
[[ "$(json "$t3" '[m["slug"] for m in v["providerInstances"]["claudeAgent"]["config"]["customModels"]]')" != *crash-model* ]] \
    || fail "a stopped run's t3 model was left as the user's"
# So does a t3 row a stopped run changed.
server_put settings/t3.json '{"claudeCustomModels": [{"slug": "my-model", "name": "Mine"}, {"slug": "crash-model", "name": "Crash"}]}'
fleet sync --pull >/dev/null 2>&1 || fail "pass adding the t3 model back"
server_put settings/t3.json '{"claudeCustomModels": [{"slug": "my-model", "name": "Mine"}, {"slug": "crash-model", "name": "Crash 2"}]}'
python3 -c '
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("fleet_crash", sys.argv[1])
fleet = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(fleet)
save = fleet._save_json
def stop(path, data):
    if path == fleet.APPLIED and data.get("hash"):
        raise OSError("disk gone")
    save(path, data)
fleet._save_json = stop
sys.argv = ["fleet", "sync", "--pull"]
sys.exit(fleet.main())' "$ROOT/files/fleet" </dev/null >/dev/null 2>&1 && fail "a run stopped before its record rendered as done"
[[ "$(json "$t3" '[m["name"] for m in v["providerInstances"]["claudeAgent"]["config"]["customModels"]]')" == *"Crash 2"* ]] \
    || fail "the stopped run did not change the t3 row"
server_put settings/t3.json '{"claudeCustomModels": [{"slug": "my-model", "name": "Mine"}]}'
fleet sync --pull >/dev/null 2>&1 || fail "pass dropping a t3 row a stopped run changed"
[[ "$(json "$t3" '[m["slug"] for m in v["providerInstances"]["claudeAgent"]["config"]["customModels"]]')" != *crash-model* ]] \
    || fail "a t3 row a stopped run changed was left as the user's"
[[ "$(json "$XDG_STATE_HOME/fleet/applied.json" 'v.get("t3Next")')" == "{}" ]] || fail "a completed render kept the pending t3 rows"
# With no models to add, T3 settings without a claude provider stay as they are.
mkdir -p "$TMP/t3home/.t3/userdata"
printf '{"theme": "dark"}' > "$TMP/t3home/.t3/userdata/settings.json"
HOME="$TMP/t3home" python3 -c '
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("fleet_t3", sys.argv[1])
fleet = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(fleet)
fleet.render_t3([], {})' "$ROOT/files/fleet" || fail "render_t3 with no models failed"
[[ "$(cat "$TMP/t3home/.t3/userdata/settings.json")" == '{"theme": "dark"}' ]] \
    || fail "created a t3 claude provider with no models: $(cat "$TMP/t3home/.t3/userdata/settings.json")"
# The provider fleet made to hold its models goes when they do; one the
# user then configured stays.
HOME="$TMP/t3home" python3 -c '
import importlib.machinery, importlib.util, json, sys
loader = importlib.machinery.SourceFileLoader("fleet_t3", sys.argv[1])
fleet = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(fleet)
fleet.manifest = lambda: {}
fleet._effort_descriptors = lambda: {}
record, made = fleet.render_t3([{"slug": "m", "name": "M"}], {})
assert made, "a provider fleet made was not recorded"
assert fleet.render_t3([], {"t3": record, "t3Provider": made}) == ({}, False)
assert json.load(open(fleet.T3_SETTINGS)) == {"theme": "dark"}, open(fleet.T3_SETTINGS).read()
record, made = fleet.render_t3([{"slug": "m", "name": "M"}], {})
v = json.load(open(fleet.T3_SETTINGS)); v["providerInstances"]["claudeAgent"]["config"]["binaryPath"] = "/x/claude"
json.dump(v, open(fleet.T3_SETTINGS, "w"))
fleet.render_t3([], {"t3": record, "t3Provider": made})
assert "claudeAgent" in json.load(open(fleet.T3_SETTINGS))["providerInstances"], "took a provider the user configured"
v = json.load(open(fleet.T3_SETTINGS)); del v["providerInstances"]["claudeAgent"]["config"]["binaryPath"]
v["providerInstances"]["claudeAgent"]["displayName"] = "Mine"
json.dump(v, open(fleet.T3_SETTINGS, "w"))
fleet.render_t3([], {"t3": record, "t3Provider": True})
assert "claudeAgent" in json.load(open(fleet.T3_SETTINGS))["providerInstances"], "took a provider the user named"
' "$ROOT/files/fleet" >/dev/null || fail "the t3 provider fleet made was not taken back"
# A reasoning ladder the catalog stops listing leaves fleet's row; one the
# catalog could not be asked for stays.
HOME="$TMP/t3home" python3 -c '
import importlib.machinery, importlib.util, json, pathlib, sys
loader = importlib.machinery.SourceFileLoader("fleet_t3", sys.argv[1])
fleet = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(fleet)
fleet.manifest = lambda: {}
fleet.OPENCODEX = pathlib.Path(sys.executable)
def rows():
    return json.load(open(fleet.T3_SETTINGS))["providerInstances"]["claudeAgent"]["config"]["customModels"]
fleet._effort_descriptors = lambda: {"m": {"id": "effort"}}
record, made = fleet.render_t3([{"slug": "m", "name": "M"}], {})
assert "capabilities" in rows()[0], rows()
previous = {"t3": record, "t3Provider": made}
fleet._effort_descriptors = lambda: None
record, made = fleet.render_t3([{"slug": "m", "name": "M"}], previous)
assert "capabilities" in rows()[0], "an unread catalog dropped a ladder"
fleet._effort_descriptors = lambda: {}
fleet.render_t3([{"slug": "m", "name": "M"}], previous)
assert "capabilities" not in rows()[0], rows()
' "$ROOT/files/fleet" >/dev/null || fail "a reasoning ladder the catalog dropped stayed"
rm -r "$TMP/t3home"

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
# Entries indented other than by two spaces are refused, not joined by ours.
cp "$HOME/.hermes/config.yaml" "$TMP/hermes.keep"
printf 'model: x\nmcp_servers:\n    personal:\n        url: https://p.example/mcp\n' > "$HOME/.hermes/config.yaml"
cp "$HOME/.hermes/config.yaml" "$TMP/hermes.wide"
server_put mcp.json "$with_extra"
fleet sync --pull > "$TMP/out" 2>&1 && fail "rendered into a four-space hermes mcp_servers: $(cat "$TMP/out")"
cmp -s "$HOME/.hermes/config.yaml" "$TMP/hermes.wide" || fail "edited a four-space hermes mcp_servers"
grep -q 'two-space' "$TMP/out" || fail "a four-space hermes mcp_servers went unreported"
mv "$TMP/hermes.keep" "$HOME/.hermes/config.yaml"
# The user's own entry at an account server's URL keeps its own fields, and
# stays when the account drops the server.
python3 - "$HOME/.hermes/config.yaml" <<'PY'
import sys
t = open(sys.argv[1]).read().replace("mcp_servers:\n", "mcp_servers:\n  cust:\n    url: https://c.example/mcp\n    headers:\n      X-Mine: y\n", 1)
open(sys.argv[1], "w").write(t)
PY
server_put mcp.json '{"mcpServers": [
  {"name": "mine", "url": "https://mine.example/mcp", "auth": "bearer", "credentialSource": "env", "env": "MINE_TOKEN"},
  {"name": "open", "url": "https://open.example/mcp"},
  {"name": "cust", "url": "https://c.example/mcp"},
  {"name": "vault", "url": "https://v.example/mcp", "auth": "bearer", "credentialSource": "passage"}]}'
fleet sync --pull >/dev/null 2>&1 || fail "pass with the user's own hermes entry"
grep -q '^      X-Mine: y$' "$HOME/.hermes/config.yaml" || fail "hermes replaced the user's own entry at our URL"
server_put mcp.json '{"mcpServers": [
  {"name": "mine", "url": "https://mine.example/mcp", "auth": "bearer", "credentialSource": "env", "env": "MINE_TOKEN"},
  {"name": "open", "url": "https://open.example/mcp"},
  {"name": "vault", "url": "https://v.example/mcp", "auth": "bearer", "credentialSource": "passage"}]}'
fleet sync --pull >/dev/null 2>&1 || fail "pass dropping cust"
grep -q '^  cust:$' "$HOME/.hermes/config.yaml" || fail "hermes removed the user's own entry"
python3 - "$HOME/.hermes/config.yaml" <<'PY'
import sys
t = open(sys.argv[1]).read().replace("  cust:\n    url: https://c.example/mcp\n    headers:\n      X-Mine: y\n", "", 1)
open(sys.argv[1], "w").write(t)
PY
# The same entry headed by a quoted name and a comment is still the user's
# cust, not a second key beside fleet's.
python3 - "$HOME/.hermes/config.yaml" <<'PY'
import sys
t = open(sys.argv[1]).read().replace("mcp_servers:\n", "mcp_servers:\n  \"cust\": # mine\n    url: https://c.example/mcp\n    headers:\n      X-Mine: y\n", 1)
open(sys.argv[1], "w").write(t)
PY
server_put mcp.json '{"mcpServers": [
  {"name": "mine", "url": "https://mine.example/mcp", "auth": "bearer", "credentialSource": "env", "env": "MINE_TOKEN"},
  {"name": "open", "url": "https://open.example/mcp"},
  {"name": "cust", "url": "https://c.example/mcp"},
  {"name": "vault", "url": "https://v.example/mcp", "auth": "bearer", "credentialSource": "passage"}]}'
fleet sync --pull >/dev/null 2>&1 || fail "pass with the user's quoted hermes entry"
grep -q '^  cust:' "$HOME/.hermes/config.yaml" && fail "hermes added cust beside the user's quoted cust"
grep -q '^      X-Mine: y$' "$HOME/.hermes/config.yaml" || fail "hermes replaced the user's quoted entry"
server_put mcp.json '{"mcpServers": [
  {"name": "mine", "url": "https://mine.example/mcp", "auth": "bearer", "credentialSource": "env", "env": "MINE_TOKEN"},
  {"name": "open", "url": "https://open.example/mcp"},
  {"name": "vault", "url": "https://v.example/mcp", "auth": "bearer", "credentialSource": "passage"}]}'
fleet sync --pull >/dev/null 2>&1 || fail "pass dropping the quoted cust"
grep -q '^  "cust": # mine$' "$HOME/.hermes/config.yaml" || fail "hermes removed the user's quoted entry"
python3 - "$HOME/.hermes/config.yaml" <<'PY'
import sys
t = open(sys.argv[1]).read().replace("  \"cust\": # mine\n    url: https://c.example/mcp\n    headers:\n      X-Mine: y\n", "", 1)
open(sys.argv[1], "w").write(t)
PY
# An entry head fleet cannot read is refused, not overlooked.
cp "$HOME/.hermes/config.yaml" "$TMP/hermes.keep"
sed -i 's/^mcp_servers:$/mcp_servers:\n  odd: {url: https:\/\/odd.example\/mcp}/' "$HOME/.hermes/config.yaml"
cp "$HOME/.hermes/config.yaml" "$TMP/hermes.flow"
server_put mcp.json "$with_extra"
fleet sync --pull > "$TMP/out" 2>&1 && fail "rendered past an unreadable hermes entry"
cmp -s "$HOME/.hermes/config.yaml" "$TMP/hermes.flow" || fail "edited a hermes file with an unreadable entry"
grep -q 'cannot read the mcp_servers entry' "$TMP/out" || fail "an unreadable hermes entry went unreported"
mv "$TMP/hermes.keep" "$HOME/.hermes/config.yaml"
fleet sync --pull >/dev/null 2>&1 || fail "pass after the unreadable hermes entry"
server_put mcp.json '{"mcpServers": [
  {"name": "mine", "url": "https://mine.example/mcp", "auth": "bearer", "credentialSource": "env", "env": "MINE_TOKEN"},
  {"name": "open", "url": "https://open.example/mcp"},
  {"name": "vault", "url": "https://v.example/mcp", "auth": "bearer", "credentialSource": "passage"}]}'
fleet sync --pull >/dev/null 2>&1 || fail "pass dropping extra after the unreadable hermes entry"
# A comment at the margin after fleet's last entry stays when it goes.
server_put mcp.json "$with_extra"
fleet sync --pull >/dev/null 2>&1 || fail "pass adding extra before a margin comment"
python3 - "$HOME/.hermes/config.yaml" <<'PY'
import sys
lines = open(sys.argv[1]).read().split("\n")
k = lines.index("  extra:")
while k + 1 < len(lines) and lines[k + 1].startswith("    "):
    k += 1
lines.insert(k + 1, "# keep me")
open(sys.argv[1], "w").write("\n".join(lines))
PY
server_put mcp.json '{"mcpServers": [
  {"name": "mine", "url": "https://mine.example/mcp", "auth": "bearer", "credentialSource": "env", "env": "MINE_TOKEN"},
  {"name": "open", "url": "https://open.example/mcp"},
  {"name": "vault", "url": "https://v.example/mcp", "auth": "bearer", "credentialSource": "passage"}]}'
fleet sync --pull >/dev/null 2>&1 || fail "pass dropping extra before a margin comment"
grep -q '^  extra:$' "$HOME/.hermes/config.yaml" && fail "hermes kept extra"
grep -q '^# keep me$' "$HOME/.hermes/config.yaml" || fail "hermes removed the user's margin comment with extra"
sed -i '/^# keep me$/d' "$HOME/.hermes/config.yaml"
# A quoted mcp_servers key is the same key, edited in place, not a second
# one beside it.
sed -i 's/^mcp_servers:$/"mcp_servers":/' "$HOME/.hermes/config.yaml"
server_put mcp.json "$with_extra"
fleet sync --pull >/dev/null 2>&1 || fail "pass with a quoted hermes mcp_servers key"
[[ $(grep -c 'mcp_servers' "$HOME/.hermes/config.yaml") == 1 ]] || fail "hermes added a second mcp_servers beside the quoted one"
grep -q '^  extra:$' "$HOME/.hermes/config.yaml" || fail "hermes did not edit the quoted mcp_servers"
sed -i 's/^"mcp_servers":$/mcp_servers:/' "$HOME/.hermes/config.yaml"
server_put mcp.json '{"mcpServers": [
  {"name": "mine", "url": "https://mine.example/mcp", "auth": "bearer", "credentialSource": "env", "env": "MINE_TOKEN"},
  {"name": "open", "url": "https://open.example/mcp"},
  {"name": "vault", "url": "https://v.example/mcp", "auth": "bearer", "credentialSource": "passage"}]}'
fleet sync --pull >/dev/null 2>&1 || fail "pass dropping extra after the quoted hermes key"

# A server fleet added while claude was missing is not fleet's on claude: an
# entry the user then adds there by hand stays when the server is dropped.
base='{"mcpServers": [
  {"name": "mine", "url": "https://mine.example/mcp", "auth": "bearer", "credentialSource": "env", "env": "MINE_TOKEN"},
  {"name": "open", "url": "https://open.example/mcp"},
  {"name": "vault", "url": "https://v.example/mcp", "auth": "bearer", "credentialSource": "passage"}]}'
mv "$BIN/claude" "$TMP/claude.away"
server_put mcp.json '{"mcpServers": [
  {"name": "mine", "url": "https://mine.example/mcp", "auth": "bearer", "credentialSource": "env", "env": "MINE_TOKEN"},
  {"name": "open", "url": "https://open.example/mcp"},
  {"name": "late", "url": "https://late.example/mcp"},
  {"name": "vault", "url": "https://v.example/mcp", "auth": "bearer", "credentialSource": "passage"}]}'
fleet sync --pull >/dev/null 2>&1 || fail "pass adding late without claude"
mv "$TMP/claude.away" "$BIN/claude"
python3 - "$HOME/.claude.json" <<'EOF'
import json, sys
v = json.load(open(sys.argv[1])); v["mcpServers"]["late"] = {"type": "http", "url": "https://late.example/mcp"}
json.dump(v, open(sys.argv[1], "w"))
EOF
fleet sync --pull >/dev/null 2>&1 || fail "pass after claude came back with the user's late entry"
server_put mcp.json "$base"
fleet sync --pull >/dev/null 2>&1 || fail "pass dropping late"
[[ "$(json "$HOME/.claude.json" '"late" in v["mcpServers"]')" == True ]] || fail "claude lost the user's own late entry"
python3 - "$HOME/.claude.json" <<'EOF'
import json, sys
v = json.load(open(sys.argv[1])); del v["mcpServers"]["late"]; json.dump(v, open(sys.argv[1], "w"))
EOF

# A server dropped while hermes refuses its config stays fleet's on hermes,
# so the run after the config is fixed removes it.
server_put mcp.json "$with_extra"
fleet sync --pull >/dev/null 2>&1 || fail "pass adding extra for the hermes refusal test"
grep -q '^  extra:' "$HOME/.hermes/config.yaml" || fail "hermes did not get extra"
cp "$HOME/.hermes/config.yaml" "$TMP/hermes.keep"
printf 'model: x\nmcp_servers: {personal: {url: https://p.example/mcp}}\n' > "$HOME/.hermes/config.yaml"
server_put mcp.json "$base"
fleet sync --pull >/dev/null 2>&1 && fail "rendered into a one-line hermes mcp_servers"
mv "$TMP/hermes.keep" "$HOME/.hermes/config.yaml"
fleet sync --pull >/dev/null 2>&1 || fail "pass after the hermes config was fixed"
grep -q '^  extra:' "$HOME/.hermes/config.yaml" && fail "a server dropped while hermes refused stayed"

# Node toolchains are tried newest version first, v20 ahead of v9.
mkdir -p "$TMP/nvm/.nvm/versions/node/v9.11.2/bin" "$TMP/nvm/.nvm/versions/node/v20.0.0/bin"
first=$(HOME="$TMP/nvm" python3 -c '
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("fleet_nvm", sys.argv[1])
fleet = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(fleet)
print(fleet._node_bin_dirs()[0])' "$ROOT/files/fleet")
[[ "$first" == */v20.0.0/bin ]] || fail "node toolchains in the wrong order: $first"

# nvm's default goes first, through its alias chain, as a login shell picks it.
mkdir -p "$TMP/nvm/.nvm/alias/lts" "$TMP/nvm/.nvm/versions/node/v9.2.0/bin"
echo 'lts/*' > "$TMP/nvm/.nvm/alias/default"
echo 'lts/old' > "$TMP/nvm/.nvm/alias/lts/*"
echo '9' > "$TMP/nvm/.nvm/alias/lts/old"
first=$(HOME="$TMP/nvm" python3 -c '
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("fleet_nvm2", sys.argv[1])
fleet = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(fleet)
print(" ".join(d.split("/")[-2] for d in fleet._node_bin_dirs() if "/.nvm/" in d))' "$ROOT/files/fleet")
[[ "$first" == "v9.11.2 v20.0.0 v9.2.0" ]] || fail "nvm's default was not first: $first"
# A timer's PATH puts it ahead of a system copy and of ~/.local/bin, as the
# login shell does once nvm's init prepends it.
mkdir -p "$TMP/nvm/.local/bin"
healed=$(HOME="$TMP/nvm" PATH="/usr/local/bin:/usr/bin" python3 -c '
import importlib.machinery, importlib.util, os, sys
loader = importlib.machinery.SourceFileLoader("fleet_nvm3", sys.argv[1])
fleet = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(fleet)
fleet._heal_path()
print(os.environ["PATH"].split(os.pathsep)[0])' "$ROOT/files/fleet")
[[ "$healed" == */v9.11.2/bin ]] || fail "nvm's default did not lead a timer's PATH: $healed"
rm -rf "$TMP/nvm/.nvm/alias" "$TMP/nvm/.nvm/versions/node/v9.2.0" "$TMP/nvm/.local"

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

# After another account's render, a Passage outage keeps none of its token,
# from the block or the environment.
mkdir -p "$TMP/switch"
printf '# BEGIN harnesses:mcp-tokens\n# common-auth-context {"origin":"old","subject":"1"}\nexport VAULT_MCP_TOKEN=old-secret\n# END harnesses:mcp-tokens\n' > "$TMP/switch/.zshenv"
switched=$(HOME="$TMP/switch" VAULT_MCP_TOKEN=old-secret python3 -c '
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("fleet_switch", sys.argv[1])
fleet = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(fleet)
fleet.common_auth_token = lambda scope, context: "passage-access"
def down(token, item): raise fleet.TokenError("passage unreachable")
fleet._vault_get = down
server = {"name": "vault", "url": "https://v.example/mcp", "auth": "bearer", "credentialSource": "passage"}
exports, drop, skipped, missing = fleet.resolve_tokens([server], {"origin": "new", "subject": "1"}, [])
print(sorted(exports), sorted(drop), sorted(skipped))' "$ROOT/files/fleet" 2>/dev/null)
rm -r "$TMP/switch"
[[ "$switched" == "[] ['PASSAGE_MCP_TOKEN', 'VAULT_MCP_TOKEN'] ['vault']" ]] \
    || fail "another account's Passage token carried over: $switched"

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
print(sorted(missing), sorted(skipped))' "$ROOT/files/fleet" 2>/dev/null)
[[ "$missing" == "['vault'] ['vault']" ]] || fail "a lookup with no fallback did not fail the render, skipping the server: $missing"

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
[[ "$(json "$HOME/.claude.json" '"fresh" in v["mcpServers"]')" == False ]] || fail "registered a server it has no token for"
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
# The user's own WebFetch grant, named by the account for a while, stays.
[[ "$allow" == *WebFetch* ]] || fail "took off the user's own grant: $allow"
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
# While setup still records the old harnesses module, it updates what it
# installed; a miniharness fleet installed beside it is fleet's to update.
printf 'agents\tclone\ta\tb\nharnesses\tscript\ta\tb\n' > "$STATE_DIR/script-state.tsv"
printf '#!/bin/sh\necho "npm $*" >> "$FAKE/claude.log"\n' > "$TMP/bin/npm"
printf '#!/bin/sh\necho 1.0\n' > "$TMP/bin/miniharness"
chmod +x "$TMP/bin/npm" "$TMP/bin/miniharness"
: > "$FAKE/claude.log"
fleet schedule run >/dev/null 2>&1 || fail "nightly pass beside the old modules"
grep -qx 'npm install -g miniharness@latest' "$FAKE/claude.log" || fail "a fleet-installed miniharness went without updates"
grep -qx update "$FAKE/claude.log" && fail "fleet updated a harness the old module still updates"
printf 'miniharness\tscript\ta\tb\n' >> "$STATE_DIR/script-state.tsv"
: > "$FAKE/claude.log"
fleet schedule run >/dev/null 2>&1 || fail "nightly pass beside the old miniharness module"
grep -q npm "$FAKE/claude.log" && fail "fleet updated a miniharness the old module still updates"
rm "$STATE_DIR/script-state.tsv" "$TMP/bin/npm" "$TMP/bin/miniharness"
# A fleet block with a stray begin marker is left alone: a block written
# after it would have the next removal take every line between them.
for f in .zshenv .codex/.env .codex/config.toml; do
    [[ -f "$HOME/$f" ]] || fail "no $f to test a stray marker in"
    cp "$HOME/$f" "$TMP/stray.keep"
    case $f in
        *.toml) printf '# BEGIN harnesses:mcp-servers\nmine = 1\n' ;;
        .zshenv) printf '# BEGIN harnesses:mcp-tokens\nexport MINE=1\n' ;;
        *) printf '# BEGIN harnesses:mcp-tokens\nMINE=1\n' ;;
    esac | cat - "$TMP/stray.keep" > "$HOME/$f"
    cp "$HOME/$f" "$TMP/stray.before"
    fleet schedule run >/dev/null 2>&1 && fail "a render passed a stray marker in $f"
    cmp -s "$HOME/$f" "$TMP/stray.before" || fail "a render wrote $f past a stray marker"
    cp "$TMP/stray.keep" "$HOME/$f"
done
fleet schedule run >/dev/null 2>&1 || fail "nightly pass after the stray markers"
# A setting the user already had at the tier's value stays theirs.
python3 - "$settings" <<'EOF'
import json, sys
v = json.load(open(sys.argv[1])); v["verbose"] = True; json.dump(v, open(sys.argv[1], "w"))
EOF
server_put settings/claude.json '{"json": {"theme": "dark", "effortLevel": "high", "verbose": true}, "permissionsAllowAdd": ["Bash(ls:*)"]}'
fleet sync --pull >/dev/null 2>&1 || fail "pass naming the user's own setting"
server_put settings/claude.json '{"json": {"theme": "dark", "effortLevel": "high"}, "permissionsAllowAdd": ["Bash(ls:*)"]}'
fleet sync --pull >/dev/null 2>&1 || fail "pass dropping the user's own setting"
[[ "$(json "$settings" 'v.get("verbose")')" == True ]] || fail "dropped a setting the user had before the tier named it"
# A setting changed by a render that stops before claude stays fleet's at
# its old value, so dropping it later still takes it off.
cp "$HOME/.zshenv" "$TMP/stray.keep"
{ printf '# BEGIN harnesses:mcp-tokens\nexport MINE=1\n'; cat "$TMP/stray.keep"; } > "$HOME/.zshenv"
server_put settings/claude.json '{"json": {"theme": "dark", "effortLevel": "low"}, "permissionsAllowAdd": ["Bash(ls:*)"]}'
fleet sync --pull >/dev/null 2>&1 && fail "a render passed a stray marker"
cp "$TMP/stray.keep" "$HOME/.zshenv"
[[ "$(json "$settings" 'v["effortLevel"]')" == high ]] || fail "claude written past a stray marker"
server_put settings/claude.json '{"json": {"theme": "dark"}, "permissionsAllowAdd": ["Bash(ls:*)"]}'
fleet sync --pull >/dev/null 2>&1 || fail "pass dropping a setting a stopped render changed"
[[ "$(json "$settings" '"effortLevel" in v')" == False ]] || fail "a setting a stopped render changed was left when dropped"
server_put settings/claude.json '{"json": {"theme": "dark", "effortLevel": "high"}, "permissionsAllowAdd": ["Bash(ls:*)"]}'
fleet sync --pull >/dev/null 2>&1 || fail "pass putting the setting back"
# One changed by a render that stops after claude stays fleet's at its new
# value.
server_put settings/claude.json '{"json": {"theme": "dark", "effortLevel": "low"}, "permissionsAllowAdd": ["Bash(ls:*)"]}'
python3 -c '
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("fleet_crash", sys.argv[1])
fleet = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(fleet)
def boom(*args): raise OSError("disk gone")
fleet.render_hermes = boom
sys.argv = ["fleet", "sync", "--pull"]
sys.exit(fleet.main())' "$ROOT/files/fleet" </dev/null >/dev/null 2>&1 && fail "a run stopped after claude rendered as done"
[[ "$(json "$settings" 'v["effortLevel"]')" == low ]] || fail "the stopped run did not write the new value"
server_put settings/claude.json '{"json": {"theme": "dark"}, "permissionsAllowAdd": ["Bash(ls:*)"]}'
fleet sync --pull >/dev/null 2>&1 || fail "pass dropping a setting a render stopped after changing"
[[ "$(json "$settings" '"effortLevel" in v')" == False ]] || fail "a setting a render stopped after changing was left when dropped"
[[ "$(json "$XDG_STATE_HOME/fleet/applied.json" '"claudeAfter" in v')" == False ]] || fail "a completed render kept the pending values"
server_put settings/claude.json '{"json": {"theme": "dark", "effortLevel": "high"}, "permissionsAllowAdd": ["Bash(ls:*)"]}'
fleet sync --pull >/dev/null 2>&1 || fail "pass putting the setting back again"
# A server Auth has no credential for is left out, and an ordinary sync
# brings it back once there is one.
grep -q '^\[mcp_servers.heatmap\]' "$codex" && fail "a server with no credential was rendered"
rm "$FAKE/token-gone"
fleet sync --pull >/dev/null 2>&1 || fail "sync once the credential is back"
grep -q '^\[mcp_servers.heatmap\]' "$codex" || fail "a credential that came back was not picked up"
# A proxy route the nightly pass could not export is reported too.
mkdir -p "$HOME/.local/bin"
printf 'import sys\nsys.exit(sys.argv[1:] == ["__export"])\n' > "$HOME/.local/bin/opencodex"
chmod +x "$HOME/.local/bin/opencodex"
fleet schedule run >/dev/null 2>&1 && fail "a failed route export went unreported"
rm "$HOME/.local/bin/opencodex"
[[ ! -e "$XDG_STATE_HOME/fleet/hermes.restart" ]] || fail "hermes restart left pending"

# A user's codex server that shares a fleet server's url under its own name
# is theirs, not a block an older release left.
shared=$(python3 -c '
import importlib.machinery, importlib.util, pathlib, sys
loader = importlib.machinery.SourceFileLoader("fleet_shared", sys.argv[1])
fleet = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(fleet)
fleet.CODEX_CONFIG = pathlib.Path(sys.argv[2])
fleet.CODEX_CONFIG.write_text("[mcp_servers.mine]\nurl = \"https://same.example/mcp\"\n")
fleet.render_codex_mcp([{"name": "ours", "url": "https://same.example/mcp", "auth": "none"}], {}, set())
print("mcp_servers.mine" in fleet.CODEX_CONFIG.read_text())' "$ROOT/files/fleet" "$TMP/shared.toml" 2>&1 | tail -1)
[[ "$shared" == True ]] || fail "a user codex server sharing a fleet url was removed: $shared"
# A block identical to ours outside the region is an older release's the
# first time fleet renders, and the user's after that.
same=$(python3 -c '
import importlib.machinery, importlib.util, pathlib, sys
loader = importlib.machinery.SourceFileLoader("fleet_same", sys.argv[1])
fleet = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(fleet)
fleet.CODEX_CONFIG = pathlib.Path(sys.argv[2])
server = {"name": "ours", "url": "https://same.example/mcp", "auth": "none"}
out = []
for previous in ({}, {"codexReclaimed": True}):
    fleet.CODEX_CONFIG.write_text("model = \"gpt\"\n\n" + fleet._codex_mcp_block(server))
    fleet.render_codex_mcp([server], previous, set())
    out.append(fleet.CODEX_MCP_BEGIN in fleet.CODEX_CONFIG.read_text())
print(out)' "$ROOT/files/fleet" "$TMP/same.toml" 2>&1 | tail -1)
[[ "$same" == "[True, False]" ]] || fail "an identical codex block was not told apart by whether fleet rendered before: $same"

# A cached plugin version that cannot be imported keeps the registration the
# last good one gave.
plugin=$(HOME="$TMP/plugin" XDG_STATE_HOME="$TMP/plugin/state" python3 -c '
import importlib.machinery, importlib.util, json, sys
loader = importlib.machinery.SourceFileLoader("fleet_plugin", sys.argv[1])
fleet = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(fleet)
fleet.sys.platform = "darwin"
fleet.manifest = lambda: {"localPluginMcpServers": [{"name": "ext", "plugin": "p", "server": "s"}]}
(fleet.CODEX_DIR/"plugins/cache/openai-bundled/p/2.0").mkdir(parents=True)
(fleet.CODEX_DIR/"plugins/cache/openai-bundled/p/2.0/.mcp.json").write_text("{")
before = {"type": "stdio", "command": "/bin/true", "args": [], "env": {}}
fleet._save_json(fleet.APPLIED, {"mcp": {"ext": {"claude": before}}})
out = [[s.get("stdio") == before for s in fleet.local_plugin_servers()]]
# Mid-update, with no version left, it is kept; with the plugin gone, not.
import shutil
shutil.rmtree(fleet.CODEX_DIR/"plugins/cache/openai-bundled/p/2.0")
out.append([s.get("stdio") == before for s in fleet.local_plugin_servers()])
shutil.rmtree(fleet.CODEX_DIR/"plugins/cache/openai-bundled/p")
out.append([s.get("stdio") == before for s in fleet.local_plugin_servers()])
print(out)' "$ROOT/files/fleet" 2>/dev/null)
rm -rf "$TMP/plugin"
[[ "$plugin" == "[[True], [True], []]" ]] || fail "a bad, updating or removed plugin cache kept the wrong registration: $plugin"

# A render loads fleet's record under the config lock, so a sync alongside
# waits rather than loading the same record.
locked=$(HOME="$TMP/lockhome" XDG_STATE_HOME="$TMP/lockhome/state" python3 -c '
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("fleet_lock", sys.argv[1])
fleet = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(fleet)
fleet.config_sync_enabled = lambda: False
seen, load = [], fleet._applied_record
fleet._applied_record = lambda: (seen.append(fleet._lock_depth), load())[1]
fleet.harness_render()
print(seen)' "$ROOT/files/fleet" 2>&1 | tail -1)
rm -rf "$TMP/lockhome"
[[ "$locked" == "[1]" ]] || fail "a render loaded its record outside the config lock: $locked"

# Fleet keeps the default Claude profile even from a shell aimed at another.
profile=$(CLAUDE_CONFIG_DIR="$TMP/other" python3 -c '
import importlib.machinery, importlib.util, os, sys
loader = importlib.machinery.SourceFileLoader("fleet_profile", sys.argv[1])
fleet = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(fleet)
print(os.environ.get("CLAUDE_CONFIG_DIR"), fleet._claude_json() == fleet.HOME/".claude.json")' "$ROOT/files/fleet")
[[ "$profile" == "None True" ]] || fail "fleet followed CLAUDE_CONFIG_DIR: $profile"

# Uninstalling takes back only the hermes skills folder and MCP block fleet
# added.
skills=$(HERMES_CONFIG="$TMP/hermes-skills.yaml" python3 -c '
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("fleet_skills", sys.argv[1])
fleet = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(fleet)
out = []
for text in ["skills:\n  external_dirs:\n  - ~/.agents/skills\n", "skills:\n  external_dirs:\n  - ~/mine\n",
             "model: x\n", "skills:\n  other: 1\n", "skills:\n  external_dirs:\n", "skills:\n  external_dirs: []\n",
             "model: x\nskills:\n", "mcp_servers:\n", "model: x\nmcp_servers:\n  mine:\n    url: https://m.example\n"]:
    fleet.HERMES_CONFIG.write_text(text)
    server = {"name": "s", "url": "https://s.example/mcp", "auth": "none"}
    _, ours, _, block = fleet.render_hermes([server], {}, set())
    fleet.render_hermes([], {"hermesSkills": ours, "hermesBlock": block,
                             "mcp": {"s": {"url": server["url"], "rendered": ["hermes"]}}}, set(), clear=True)
    after = fleet.HERMES_CONFIG.read_text()
    out.append(after == text)
open(sys.argv[2], "w").write(str(out))' "$ROOT/files/fleet" "$TMP/skills.out" >/dev/null 2>&1; cat "$TMP/skills.out")
[[ "$skills" == "[True, True, True, True, True, True, True, True, True]" ]] || fail "uninstall took the wrong hermes skills folder: $skills"
# A skills block indented otherwise is left for the user.
printf 'skills:\n    external_dirs:\n    - ~/mine\n' > "$TMP/hermes-wide.yaml"
cp "$TMP/hermes-wide.yaml" "$TMP/hermes-wide.keep"
HERMES_CONFIG="$TMP/hermes-wide.yaml" python3 -c '
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("fleet_wide", sys.argv[1])
fleet = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(fleet)
fleet.render_hermes([], {}, set())' "$ROOT/files/fleet" >/dev/null 2>&1
[[ "$(head -3 "$TMP/hermes-wide.yaml")" == "$(cat "$TMP/hermes-wide.keep")" ]] \
    && ! grep -q agents "$TMP/hermes-wide.yaml" || fail "edited a skills block indented by four: $(cat "$TMP/hermes-wide.yaml")"

# Installing: retired and unknown harnesses are refused.
out=$(fleet install kimi 2>&1) && fail "installed a retired harness"
[[ "$out" == *retired* ]] || fail "retired harness message: $out"
fleet install nope >/dev/null 2>&1 && fail "installed an unknown harness"

# Uninstalling takes back what fleet rendered; the user's own entries stay.
# Neither a broken manifest nor a claude gone from PATH stops it: claude's
# files are edited directly.
printf '{' > "$TMP/broken-manifest.json"
# A stray marker in the token block stops it before it cuts into the
# user's lines.
cp "$HOME/.zshenv" "$TMP/stray.keep"
{ printf '# BEGIN harnesses:mcp-tokens\nexport MINE=1\n'; cat "$TMP/stray.keep"; } > "$HOME/.zshenv"
cp "$HOME/.zshenv" "$TMP/stray.before"
fleet __unrender >/dev/null 2>&1 && fail "unrender passed a stray token marker"
cmp -s "$HOME/.zshenv" "$TMP/stray.before" || fail "unrender cut .zshenv past a stray marker"
cp "$TMP/stray.keep" "$HOME/.zshenv"
# An unreadable record stops a sync and an uninstall alike: read as none,
# everything fleet wrote would turn the user's.
applied="$XDG_STATE_HOME/fleet/applied.json"
cp "$applied" "$TMP/applied.keep"
printf '{"mcp": ' > "$applied"
cp "$HOME/.claude.json" "$TMP/claude-json.before"
fleet sync --pull > "$TMP/out" 2>&1 && fail "synced past an unreadable record"
grep -q "cannot read .*applied.json" "$TMP/out" || fail "an unreadable record went unreported: $(cat "$TMP/out")"
fleet __unrender >/dev/null 2>&1 && fail "unrender passed an unreadable record"
cmp -s "$HOME/.claude.json" "$TMP/claude-json.before" || fail "rendered past an unreadable record"
mv "$TMP/applied.keep" "$applied"
# Nor does a claude.json it cannot read: fleet's entries there are not gone.
chmod 000 "$HOME/.claude.json"
mv "$BIN/claude" "$TMP/claude.away"
fleet __unrender >/dev/null 2>&1 && fail "unrender passed an unreadable claude.json"
mv "$TMP/claude.away" "$BIN/claude"
chmod 600 "$HOME/.claude.json"
[[ -e "$applied" ]] || fail "an unreadable claude.json lost fleet's record"
cmp -s "$HOME/.claude.json" "$TMP/claude-json.before" || fail "unrender edited an unreadable claude.json"
fleet sync --pull >/dev/null 2>&1 || fail "sync after an unreadable claude.json"
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
grep -q 'harnesses:mcp-tokens' "$HOME/.codex/.env" "$HOME/.hermes/.env" && fail "unrender left token block markers"
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
# A hermes config made after the last render is left as it is.
fleet sync --pull >/dev/null 2>&1 || fail "sync before the late hermes config"
mv "$hermes" "$TMP/hermes.away"
fleet sync --pull >/dev/null 2>&1 || fail "sync without hermes' config"
printf 'model: y\n' > "$hermes"
fleet __unrender >/dev/null 2>&1 || fail "unrender with a late hermes config"
[[ "$(cat "$hermes")" == "model: y" ]] || fail "unrender changed a hermes config made after the render: $(cat -A "$hermes")"
mv "$TMP/hermes.away" "$hermes"

# A takeover while claude is away still owns what the old client registered,
# so the pass that finds claude again removes what the account dropped.
fleet __unrender >/dev/null 2>&1 || fail "unrender before the late-claude takeover"
python3 - "$HOME/.claude.json" <<'PY'
import json, sys
v = json.load(open(sys.argv[1])); v["mcpServers"]["jina"] = {"type": "http", "url": "https://mcp.jina.ai/v1"}
json.dump(v, open(sys.argv[1], "w"))
PY
mkdir -p "$HOME/.config/harnesses"; printf '{}\n' > "$HOME/.config/harnesses/manifest.json"
mv "$BIN/claude" "$TMP/claude.away"
fleet sync --pull >/dev/null 2>&1 || fail "takeover without claude"
mv "$TMP/claude.away" "$BIN/claude"
fleet sync --pull >/dev/null 2>&1 || fail "pass after claude came back to a takeover"
[[ "$(json "$HOME/.claude.json" '"jina" in v["mcpServers"]')" == False ]] \
    || fail "a seeded server stayed after a takeover without claude"

echo "fleet harness tests passed"
