#!/usr/bin/env bash
# fleet's account tree, marketplace installs, links and harness rendering,
# against a stand-in Auth that keeps its files in $FAKE/server.json.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap '[[ -n "${KEEP:-}" ]] && cat "$TMP/err"; rm -rf "$TMP"' EXIT
export FAKE="$TMP/fake" XDG_STATE_HOME="$TMP/state" FLEET_SSH_DIR="$TMP/ssh" FLEET_SELF=grimoire
export FLEET_AUTH_BIN="$TMP/bin/auth" FLEET_MANIFEST="$ROOT/files/fleet-manifest.json"
mkdir -p "$FAKE" "$TMP/bin" "$FLEET_SSH_DIR"
# claude, codex and systemctl are stand-ins that only record their calls.
export PATH="$TMP/bin:/usr/bin:/bin"
for tool in claude systemctl; do
    printf '#!/bin/sh\necho "%s $*" >> "$FAKE/calls"\n' "$tool" > "$TMP/bin/$tool"
    chmod +x "$TMP/bin/$tool"
done
echo '{"counter":0,"files":{},"installs":[],"skills":{}}' > "$FAKE/server.json"
echo '[{"key":"okdam.lost.plus","mcp_url":"https://okdam.lost.plus/mcp","token_key":"okdam-mcp"},{"key":"site","mcp_url":null}]' > "$FAKE/services.json"

cat > "$FLEET_AUTH_BIN" <<'PY'
#!/usr/bin/env python3
import base64, hashlib, json, os, sys
fake = os.environ["FAKE"]
args = sys.argv[1:]
if args[0] == "context":
    print(json.dumps({"origin": "https://auth.test", "subject": "7"})); sys.exit(0)
if args[0] == "token":
    print("tok-" + args[1]); sys.exit(0)
if args[0] != "request":
    sys.exit(0)
method, path = args[1], args[2]
body = json.load(sys.stdin) if len(args) > 3 else None
state = json.load(open(f"{fake}/server.json"))
sha = lambda b64: hashlib.sha256(base64.b64decode(b64)).hexdigest()
def out(value):
    json.dump(state, open(f"{fake}/server.json", "w")); print(json.dumps(value)); sys.exit(0)
if path == "/api/fleet":
    out({"version": "v", "self": {"served": True}, "keys": ["ssh-ed25519 AAAAPeer"], "hosts": []})
if path == "/api/services":
    print(open(f"{fake}/services.json").read()); sys.exit(0)
if path == "/api/fleet/config":
    installs = [{**i, "files": [{"path": p, "sha256": sha(c), "size": 1, "executable": 0}
                                for p, c in state["skills"][i["id"]].items()]} for i in state["installs"]]
    out({"counter": state["counter"], "version": "v%d" % state["counter"], "installs": installs,
         "files": [{"path": p, "sha256": sha(f["content"]), "size": 1, "executable": f["executable"]}
                   for p, f in state["files"].items()]})
if path == "/api/fleet/config/fetch":
    out({"files": [{"path": p, "sha256": sha(state["files"][p]["content"]), **state["files"][p]}
                   for p in body["paths"]], "remaining": [], "missing": []})
if path == "/api/fleet/skills/fetch":
    tree = state["skills"][body["id"]]
    out({"files": [{"path": p, "content": tree[p], "sha256": sha(tree[p]), "executable": False}
                   for p in body["paths"]], "remaining": [], "missing": []})
if path == "/api/fleet/config/push":
    if body["base"] != state["counter"]:
        print(json.dumps({"status": 409, "error": "stale"})); sys.exit(6)
    for f in body["put"]:
        state["files"][f["path"]] = {"content": f["content"], "executable": f["executable"]}
    for p in body["delete"]:
        state["files"].pop(p, None)
    state["counter"] += 1
    out({"counter": state["counter"], "version": "v%d" % state["counter"]})
print(json.dumps({"status": 404, "error": "no route " + path})); sys.exit(6)
PY
chmod +x "$FLEET_AUTH_BIN"

fail() { echo "FAIL: $*" >&2; exit 1; }
on() { export HOME="$TMP/$1"; mkdir -p "$HOME"; export XDG_STATE_HOME="$HOME/.state"; }
fleet() { python3 "$ROOT/files/fleet" "$@" 2>>"$TMP/err"; }
server() { python3 -c 'import json,sys,base64; f=json.load(open(sys.argv[1]))["files"]; print(base64.b64decode(f[sys.argv[2]]["content"]).decode() if sys.argv[2] in f else "<none>", end="")' "$FAKE/server.json" "$1"; }

# A first machine seeds an empty account; a pull alone never does.
on one
mkdir -p "$HOME/.agents/settings" "$HOME/.agents/skills/notes" "$HOME/.agents/junk" "$HOME/.claude"
echo "be kind" > "$HOME/.agents/AGENTS.md"
echo '{"effortLevel":"high","permissions":{"allow":["Read"]}}' > "$HOME/.agents/settings/claude.json"
printf -- '---\nname: notes\n---\nnotes\n' > "$HOME/.agents/skills/notes/SKILL.md"
echo stray > "$HOME/.agents/junk/file"
echo '{"keep":true,"effortLevel":"low"}' > "$HOME/.claude/settings.json"
fleet sync --pull >/dev/null 2>&1
[[ "$(server AGENTS.md)" == "<none>" ]] || fail "a pull seeded the account"
fleet sync >/dev/null 2>&1 || fail "seeding sync"
[[ "$(server AGENTS.md)" == "be kind" ]] || fail "AGENTS.md not pushed"
[[ "$(server junk/file)" == "<none>" ]] || fail "a file outside the tree was pushed"
[[ "$(readlink "$HOME/.claude/CLAUDE.md")" == "$HOME/.agents/AGENTS.md" ]] || fail "CLAUDE.md not linked"
[[ "$(readlink "$HOME/.claude/skills/notes")" == "$HOME/.agents/skills/notes" ]] || fail "skill not linked"

# Claude settings: the account's keys win, the rest of the file stays, and the
# hub's MCP grant is derived.
python3 - "$HOME/.claude/settings.json" <<'PY' || fail "claude settings"
import json, sys
s = json.load(open(sys.argv[1]))
assert s["keep"] and s["effortLevel"] == "high" and s["attribution"] == {"commit": "", "pr": ""}, s
assert s["permissions"]["allow"] == ["Read", "mcp__okdam__*"], s
PY
grep -q "export OKDAM_MCP_TOKEN=tok-okdam-mcp" "$HOME/.zshenv" || fail "hub token not exported"
[[ "$(fleet mcp-headers bearer OKDAM_MCP_TOKEN)" == '{"Authorization": "Bearer tok-okdam-mcp"}' ]] || fail "mcp-headers"
grep -q "claude mcp add-json --scope user okdam" "$FAKE/calls" || fail "okdam not enrolled in claude"

# A second machine joins: it takes the account's copy over its own.
on two
mkdir -p "$HOME/.agents" "$HOME/.claude"
echo "mine" > "$HOME/.agents/AGENTS.md"
rc=0; fleet sync >/dev/null 2>&1 || rc=$?
[[ $rc == 1 ]] || fail "joining over a local file exited $rc"
[[ "$(cat "$HOME/.agents/AGENTS.md")" == "be kind" ]] || fail "join kept the local copy"
ls "$XDG_STATE_HOME"/fleet/backup/*/AGENTS.md >/dev/null || fail "the local copy was not backed up"
[[ -f "$HOME/.agents/skills/notes/SKILL.md" ]] || fail "skill not pulled"

# An edit on two reaches one; a key dropped from the account leaves settings.json.
echo '{"permissions":{"allow":["Read"]}}' > "$HOME/.agents/settings/claude.json"
rm "$HOME/.agents/skills/notes/SKILL.md"
fleet sync >/dev/null 2>&1 || fail "push from two"
on one
fleet sync --pull >/dev/null 2>&1 || fail "pull on one"
[[ ! -e "$HOME/.agents/skills/notes" ]] || fail "deleted skill kept"
[[ ! -L "$HOME/.claude/skills/notes" ]] || fail "dangling skill link kept"
python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); assert "effortLevel" not in s and s["keep"], s' \
    "$HOME/.claude/settings.json" || fail "dropped key kept"
fleet sync --check >/dev/null 2>&1 || fail "check after a pull"
echo "edited" > "$HOME/.agents/AGENTS.md"
fleet sync --check >/dev/null 2>&1 && fail "check missed a local edit"

# Both sides edit: Auth's copy wins and the local one is kept aside.
on two
echo "two's" > "$HOME/.agents/AGENTS.md"
fleet sync >/dev/null 2>&1
on one
rc=0; fleet sync >/dev/null 2>&1 || rc=$?
[[ $rc == 1 && "$(cat "$HOME/.agents/AGENTS.md")" == "two's" ]] || fail "conflict ($rc)"

# A marketplace install lands under its local name and is never pushed back.
python3 - "$FAKE/server.json" <<'PY'
import base64, json, sys
s = json.load(open(sys.argv[1]))
s["skills"]["s1"] = {"SKILL.md": base64.b64encode(b"---\nname: tool\n---\nhi\n").decode()}
s["installs"] = [{"id": "s1", "name": "kit", "skill": "tool", "author": "fox"}]
json.dump(s, open(sys.argv[1], "w"))
PY
fleet sync >/dev/null 2>&1 || fail "sync with an install"
grep -qx "name: kit" "$HOME/.agents/skills/kit/SKILL.md" || fail "install not renamed"
[[ "$(server skills/kit/SKILL.md)" == "<none>" ]] || fail "install pushed as account files"
python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); s["installs"]=[]; json.dump(s,open(sys.argv[1],"w"))' "$FAKE/server.json"
fleet sync >/dev/null 2>&1
[[ ! -e "$HOME/.agents/skills/kit" ]] || fail "uninstalled skill kept"

# t3 and hermes: our rows replaced, retired rows dropped, the operator's kept.
mkdir -p "$HOME/.t3/userdata" "$HOME/.hermes"
echo '{"providerInstances":{"claudeAgent":{"config":{"customModels":[{"slug":"mine"},{"slug":"gpt-5.6-sol"}]}}}}' \
    > "$HOME/.t3/userdata/settings.json"
printf 'model: x\nmcp_servers:\n  own:\n    url: https://own\n' > "$HOME/.hermes/config.yaml"
echo '{"claudeCustomModels":[{"slug":"zai/glm-5.3","name":"GLM"}]}' > "$HOME/.agents/settings/t3.json"
fleet sync >/dev/null 2>&1 || fail "sync with t3 and hermes"
python3 -c 'import json,sys; m=json.load(open(sys.argv[1]))["providerInstances"]["claudeAgent"]["config"]["customModels"]; assert [r["slug"] for r in m]==["mine","zai/glm-5.3"], m' \
    "$HOME/.t3/userdata/settings.json" || fail "t3 models"
grep -q "  own:" "$HOME/.hermes/config.yaml" && grep -q "      Authorization: Bearer \${OKDAM_MCP_TOKEN}" "$HOME/.hermes/config.yaml" \
    || fail "hermes entries"
grep -q "OKDAM_MCP_TOKEN=tok-okdam-mcp" "$HOME/.hermes/.env" || fail "hermes token"
rm "$HOME/.agents/settings/t3.json"
fleet sync >/dev/null 2>&1
python3 -c 'import json,sys; m=json.load(open(sys.argv[1]))["providerInstances"]["claudeAgent"]["config"]["customModels"]; assert [r["slug"] for r in m]==["mine"], m' \
    "$HOME/.t3/userdata/settings.json" || fail "dropped t3 model kept"

# Codex: our region next to the operator's own servers; keepout in both hook files.
mkdir -p "$HOME/.codex"
printf 'model = "x"\n\n[mcp_servers.okdam]\ncommand = "own"\n\n[mcp_servers.mine]\nurl = "https://mine"\n' > "$HOME/.codex/config.toml"
echo '{"enabled":true,"command":"curl -s https://today.lost.plus/api/keepout"}' > "$HOME/.agents/settings/keepout.json"
fleet sync >/dev/null 2>&1 || fail "sync with codex"
grep -q "BEGIN harnesses:mcp-servers" "$HOME/.codex/config.toml" && fail "codex region written over the operator's okdam"
grep -q 'command = "own"' "$HOME/.codex/config.toml" || fail "operator's codex server lost"
grep -q "today.lost.plus/api/keepout" "$HOME/.codex/hooks.json" "$HOME/.claude/settings.json" || fail "keepout hook"
sed -i '/okdam/,/own/d' "$HOME/.codex/config.toml"
fleet sync >/dev/null 2>&1
grep -q 'bearer_token_env_var = "OKDAM_MCP_TOKEN"' "$HOME/.codex/config.toml" || fail "codex region"
echo '{"enabled":false}' > "$HOME/.agents/settings/keepout.json"
fleet sync >/dev/null 2>&1
grep -q "keepout" "$HOME/.claude/settings.json" && fail "keepout hook kept after disabling"

# A service leaving the registry leaves every harness.
echo '[]' > "$FAKE/services.json"
fleet sync >/dev/null 2>&1
grep -q okdam "$HOME/.hermes/config.yaml" && fail "hermes kept a removed server"
python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); assert s["permissions"]["allow"]==["Read"], s' \
    "$HOME/.claude/settings.json" || fail "removed server's grant kept"
grep -q OKDAM "$HOME/.zshenv" && fail "removed server's token kept"
grep -q "BEGIN harnesses:mcp-servers" "$HOME/.codex/config.toml" && fail "codex kept a removed server"
grep -q 'url = "https://mine"' "$HOME/.codex/config.toml" || fail "operator's codex server lost"

echo "fleet-agents tests passed"
