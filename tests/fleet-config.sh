#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# Only the system basics: never a real harness.
export PATH="$(dirname "$(command -v python3)"):$(dirname "$(command -v zsh)"):/usr/bin:/bin"
export HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" FLEET_SSH_DIR="$TMP/home/.ssh"
export FLEET_AUTH_BIN="$TMP/auth" FLEET_SELF=grimoire FAKE="$TMP/fake" STATE_DIR="$TMP/state/setup"
export SCHEDULE_USER_DIR="$TMP/units" SCHEDULE_BIN="$TMP/schedule"
export SETUP_OWNER_KEYS_URL="file://$TMP/github.keys"
mkdir -p "$FLEET_SSH_DIR" "$FAKE" "$STATE_DIR" "$HOME/.claude/skills" "$HOME/.codex/skills"
printf '7' > "$FAKE/subject"
printf 'ssh-ed25519 AAAAOwner owner\n' > "$TMP/github.keys"
printf '#!/bin/sh\nexit 1\n' > "$SCHEDULE_BIN"; chmod +x "$SCHEDULE_BIN"

# A stand-in auth CLI holding one account's config in $FAKE/server.json, with
# Auth's counters, fetch batching, and stale-push refusal.
cat > "$FLEET_AUTH_BIN" <<'PY'
#!/usr/bin/env python3
import base64, hashlib, json, os, sys
fake = os.environ["FAKE"]
def load():
    try:
        return json.load(open(f"{fake}/server.json"))
    except OSError:
        return {"counter": 0, "version": 0, "files": {}}
def answer(status, value):
    if status != 200:
        print(json.dumps({"status": status, "error": value.get("error"), "retry_after": value.get("retry_after")}))
        sys.exit(6)
    print(json.dumps(value))
    sys.exit(0)
cmd = sys.argv[1]
if cmd == "refresh":
    sys.exit(0)
origin = open(f"{fake}/origin").read() if os.path.exists(f"{fake}/origin") else "https://auth.lost.plus"
if cmd == "context":
    print(json.dumps({"origin": origin, "subject": open(f"{fake}/subject").read()}))
    sys.exit(0)
method, path = sys.argv[2], sys.argv[3]
body = json.load(sys.stdin) if sys.argv[4:] == ["-"] else None
open(f"{fake}/log", "a").write(f"{method} {path}\n")
if os.path.exists(f"{fake}/down"):
    sys.exit(1)
if path == "/api/fleet/config/fetch" and os.path.exists(f"{fake}/fetch-down"):
    sys.exit(1)
state = load()
if path == "/api/services":
    answer(200, [])
if path == "/api/fleet":
    answer(200, {"version": "v", "self": {"served": True}, "keys": ["ssh-ed25519 AAAASelf"], "hosts": []})
if path == "/api/fleet/config":
    answer(200, {"counter": state["counter"], "version": state["version"],
                 "files": [{"path": p, "size": len(f["content"]), "sha256": f["sha256"],
                            "executable": f["executable"]} for p, f in sorted(state["files"].items())]})
if path == "/api/fleet/config/fetch":
    if os.path.exists(f"{fake}/edit-on-fetch"):
        # An editor saves a file again between the scan and the upload.
        target = open(f"{fake}/edit-on-fetch").read()
        os.remove(f"{fake}/edit-on-fetch")
        open(target, "w").write("saved later\n")
    if os.path.exists(f"{fake}/switch-on-fetch"):
        # Another account signed in while the files were coming down.
        os.remove(f"{fake}/switch-on-fetch")
        open(f"{fake}/subject", "w").write("9")
    paths = body["paths"]
    # One file per answer, so callers must follow `remaining`.
    first = [p for p in paths if p in state["files"]][:1]
    answer(200, {"counter": state["counter"], "version": state["version"],
                 "files": [{"path": p, **state["files"][p]} for p in first],
                 "remaining": [p for p in paths if p in state["files"] and p not in first],
                 "missing": [p for p in paths if p not in state["files"]]})
if path == "/api/fleet/config/push":
    if os.path.exists(f"{fake}/switch-origin"):
        # The machine signed in to another Auth that issued the same subject.
        os.remove(f"{fake}/switch-origin")
        open(f"{fake}/origin", "w").write("https://other.example")
        origin = "https://other.example"
    if os.environ.get("LOST_AUTH_ORIGIN", origin) != origin:
        sys.exit(5)
    if os.path.exists(f"{fake}/switch"):
        # The machine signed in to another account after its pull.
        os.remove(f"{fake}/switch")
        open(f"{fake}/subject", "w").write("9")
    if body.get("subject") != open(f"{fake}/subject").read():
        answer(409, {"error": "account changed"})
    if os.path.exists(f"{fake}/limited"):
        answer(429, {"error": "too many pushes", "retry_after": 600})
    if os.path.exists(f"{fake}/race"):
        # Another machine pushed between this machine's pull and its push.
        os.remove(f"{fake}/race")
        data = b'{"a":1}'
        state["files"]["settings/claude.json"] = {"content": base64.b64encode(data).decode(),
                                                  "sha256": hashlib.sha256(data).hexdigest(), "executable": False}
        state["counter"] += 1; state["version"] += 1
        json.dump(state, open(f"{fake}/server.json", "w"))
    if body["base"] != state["counter"]:
        answer(409, {"error": "stale"})
    for put in body["put"]:
        data = base64.b64decode(put["content"])
        state["files"][put["path"]] = {"content": put["content"], "sha256": hashlib.sha256(data).hexdigest(),
                                       "executable": put["executable"]}
    for p in body["delete"]:
        state["files"].pop(p, None)
    state["counter"] += 1
    state["version"] += 1
    json.dump(state, open(f"{fake}/server.json", "w"))
    open(f"{fake}/pushes", "a").write(json.dumps(body["put"] and [p["path"] for p in body["put"]]) + " " + json.dumps(body["delete"]) + "\n")
    answer(200, {"counter": state["counter"], "version": state["version"]})
answer(404, {"error": "not found"})
PY
chmod +x "$FLEET_AUTH_BIN"
fleet() { python3 "$ROOT/files/fleet" "$@" </dev/null; }
fail() { echo "FAIL: $*" >&2; exit 1; }
# Another machine's push, straight into the fake server.
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
server_del() {
    python3 - "$1" <<'PY'
import json, os, sys
f = f"{os.environ['FAKE']}/server.json"
state = json.load(open(f))
state["files"].pop(sys.argv[1])
state["counter"] += 1; state["version"] += 1
json.dump(state, open(f, "w"))
PY
}
server_has() {
    python3 - "$1" <<'PY'
import base64, json, os, sys
state = json.load(open(f"{os.environ['FAKE']}/server.json"))
f = state["files"].get(sys.argv[1])
print(base64.b64decode(f["content"]).decode() if f else "<none>", end="")
PY
}

# While setup still records the old modules, fleet keeps to SSH.
printf 'agents\tclone\ta\tb\n' > "$STATE_DIR/script-state.tsv"
fleet sync >/dev/null 2>&1 || fail "sync while gated"
grep -q '/api/fleet/config' "$FAKE/log" && fail "config touched while agents is installed"
fleet status | grep -q 'waits until setup swaps out' || fail "status while gated"
: > "$STATE_DIR/script-state.tsv"

# The old agents module's clone is settled once, before the first pull. On
# the operator's machine only the clone goes.
old_agents() {
    mkdir -p "$STATE_DIR/agents-src/.git" "$HOME/.agents/skills/opskill" "$HOME/.gemini"
    printf 'operator instructions\n' > "$HOME/.agents/AGENTS.md"
    printf 'op\n' > "$HOME/.agents/skills/opskill/SKILL.md"
    printf 'gemini own\n' > "$HOME/.gemini/GEMINI.md.pre-agents.bak"
    ln -sfn "$HOME/.agents/AGENTS.md" "$HOME/.gemini/GEMINI.md"
    ln -sfn "$HOME/.agents/skills/opskill" "$HOME/.claude/skills/opskill"
}
old_agents
printf '1' > "$FAKE/subject"
fleet sync >/dev/null 2>&1 || fail "sync settling the clone on the operator's machine"
[[ ! -e "$STATE_DIR/agents-src" ]] || fail "clone left on the operator's machine"
[[ -f "$HOME/.agents/AGENTS.md" && -L "$HOME/.claude/skills/opskill" ]] \
    || fail "the operator's machine lost what the old module installed"
# On another account's machine its links go, what they displaced comes back,
# and the operator's files move to the backup.
old_agents
printf '7' > "$FAKE/subject"
# Until the account's copy is in hand, the old one stays in use.
touch "$FAKE/down"
fleet sync >/dev/null 2>&1 && fail "a sync with Auth down reported success"
rm "$FAKE/down"
[[ -d "$STATE_DIR/agents-src" && -L "$HOME/.gemini/GEMINI.md" && -f "$HOME/.agents/AGENTS.md" ]] \
    || fail "settled the clone before Auth answered"
server_put AGENTS.md 'account instructions'
touch "$FAKE/fetch-down"
fleet sync >/dev/null 2>&1 && fail "a failed fetch reported success"
rm "$FAKE/fetch-down"
[[ -d "$STATE_DIR/agents-src" && -L "$HOME/.gemini/GEMINI.md" && "$(cat "$HOME/.agents/AGENTS.md")" == "operator instructions" ]] \
    || fail "settled the clone before the account's copy was fetched"
# A copy that cannot be written leaves the old payload in use too.
server_put settings/x.json '{}'
mkdir -p "$HOME/.agents/settings"; chmod 555 "$HOME/.agents/settings"
fleet sync >/dev/null 2>&1 && fail "a failed write reported success"
chmod 755 "$HOME/.agents/settings"; rmdir "$HOME/.agents/settings"
[[ -d "$STATE_DIR/agents-src" && -L "$HOME/.gemini/GEMINI.md" && "$(cat "$HOME/.agents/AGENTS.md")" == "operator instructions" \
    && -f "$HOME/.agents/skills/opskill/SKILL.md" && -L "$HOME/.claude/skills/opskill" ]] \
    || fail "settled the clone before the account's copy was written"
# So does a record that cannot be saved, with the copy already written.
chmod 500 "$XDG_STATE_HOME/fleet"
fleet sync >/dev/null 2>&1 && fail "a failed record save reported success"
chmod 700 "$XDG_STATE_HOME/fleet"
[[ -d "$STATE_DIR/agents-src" && -L "$HOME/.gemini/GEMINI.md" && "$(cat "$HOME/.agents/AGENTS.md")" == "operator instructions" \
    && -f "$HOME/.agents/skills/opskill/SKILL.md" && -L "$HOME/.claude/skills/opskill" ]] \
    || fail "a failed record save left the account's copy over the old payload"
# So does another account's ~/.agents that cannot move aside.
printf '{"account": "someone-else", "counter": 1, "files": {}}' > "$XDG_STATE_HOME/fleet/config.json"
chmod 555 "$HOME"
fleet sync >/dev/null 2>&1 && fail "a foreign tree that could not move reported success"
chmod 755 "$HOME"
rm "$XDG_STATE_HOME/fleet/config.json"
[[ "$(cat "$HOME/.agents/AGENTS.md")" == "operator instructions" && -f "$HOME/.agents/skills/opskill/SKILL.md" ]] \
    || fail "a foreign tree that could not move left the old payload displaced"
# A clone that cannot move once the copy is in place leaves its links made.
chmod 500 "$STATE_DIR"
fleet sync >/dev/null 2>&1 && fail "a clone that could not move reported success"
chmod 755 "$STATE_DIR"
[[ -L "$HOME/.claude/CLAUDE.md" && "$(cat "$HOME/.claude/CLAUDE.md")" == "account instructions" ]] \
    || fail "a clone that could not move left the account's links missing"
# A link that cannot go puts the clone back, still with the account's links.
chmod 500 "$HOME/.claude"
fleet sync >/dev/null 2>&1 && fail "a link that could not go reported success"
chmod 755 "$HOME/.claude"
[[ -d "$STATE_DIR/agents-src/.git" ]] || fail "a link that could not go left the clone in the backup"
[[ -L "$HOME/.claude/CLAUDE.md" && "$(cat "$HOME/.claude/CLAUDE.md")" == "account instructions" ]] \
    || fail "a link that could not go left the account's links missing"
# With the copy in hand, it replaces the old payload.
fleet sync >/dev/null 2>&1 || fail "sync replacing the old payload"
[[ ! -e "$STATE_DIR/agents-src" && "$(cat "$HOME/.agents/AGENTS.md")" == "account instructions" ]] \
    || fail "the account's copy did not replace the old payload"
[[ ! -e "$HOME/.claude/skills/opskill" ]] || fail "the operator's skill link stayed under the account's copy"
fleet __unlink >/dev/null
rm -rf "$HOME/.agents" "$FAKE/server.json" "$XDG_STATE_HOME/fleet/config.json"
old_agents
# A skill link the user already deleted still gets its sidecar back.
mkdir -p "$HOME/.claude/skills/lost.pre-agents.bak"; printf 'lost\n' > "$HOME/.claude/skills/lost.pre-agents.bak/SKILL.md"
# For an account never pushed, another account's ~/.agents that cannot move
# aside puts the old payload back too.
printf '{"account": "someone-else", "counter": 1, "files": {}}' > "$XDG_STATE_HOME/fleet/config.json"
chmod 555 "$HOME"
fleet sync >/dev/null 2>&1 && fail "a pending account's foreign tree that could not move reported success"
chmod 755 "$HOME"
rm "$XDG_STATE_HOME/fleet/config.json"
[[ -d "$STATE_DIR/agents-src/.git" && "$(cat "$HOME/.agents/AGENTS.md")" == "operator instructions" \
   && -f "$HOME/.agents/skills/opskill/SKILL.md" ]] \
    || fail "a pending account's foreign tree that could not move left the old payload displaced"
# So does a clone that cannot move, with the other account's tree put back.
printf '{"account": "someone-else", "counter": 1, "files": {}}' > "$XDG_STATE_HOME/fleet/config.json"
printf 'theirs\n' > "$HOME/.agents/theirs"
chmod 500 "$STATE_DIR"
fleet sync >/dev/null 2>&1 && fail "a pending account's clone that could not move reported success"
chmod 755 "$STATE_DIR"
rm "$XDG_STATE_HOME/fleet/config.json"
[[ "$(cat "$HOME/.agents/theirs")" == "theirs" && "$(cat "$HOME/.agents/AGENTS.md")" == "operator instructions" ]] \
    || fail "a pending account's clone that could not move left the other account's tree aside"
rm "$HOME/.agents/theirs"
# A payload that cannot all move aside puts back what did.
chmod 500 "$HOME/.agents/skills"
fleet sync >/dev/null 2>&1 && fail "a payload that could not move reported success"
chmod 700 "$HOME/.agents/skills"
[[ "$(cat "$HOME/.agents/AGENTS.md")" == "operator instructions" ]] \
    || fail "a failed payload move left AGENTS.md in the backup"
# A clone that cannot move puts the operator's payload back.
chmod 500 "$STATE_DIR"
fleet sync >/dev/null 2>&1 && fail "a clone that could not move reported success"
chmod 755 "$STATE_DIR"
[[ "$(cat "$HOME/.agents/AGENTS.md")" == "operator instructions" && -f "$HOME/.agents/skills/opskill/SKILL.md" ]] \
    || fail "a failed clone move left the operator's payload in the backup"
# A link that cannot go puts the clone and the payload back.
chmod 500 "$HOME/.claude/skills"
fleet sync >/dev/null 2>&1 && fail "a link that could not go reported success on a friend's machine"
chmod 755 "$HOME/.claude/skills"
[[ -d "$STATE_DIR/agents-src/.git" && "$(cat "$HOME/.agents/AGENTS.md")" == "operator instructions" && -f "$HOME/.agents/skills/opskill/SKILL.md" ]] \
    || fail "a link that could not go left the clone or the payload in the backup"
[[ -L "$HOME/.gemini/GEMINI.md" && "$(cat "$HOME/.gemini/GEMINI.md")" == "operator instructions" \
    && "$(cat "$HOME/.gemini/GEMINI.md.pre-agents.bak")" == "gemini own" ]] \
    || fail "a link that could not go left an earlier link removed"
fleet sync >/dev/null 2>&1 || fail "sync settling the clone on a friend's machine"
[[ "$(cat "$HOME/.claude/skills/lost/SKILL.md")" == "lost" && ! -e "$HOME/.claude/skills/lost.pre-agents.bak" ]] \
    || fail "an orphaned skill sidecar not restored"
rm -rf "$HOME/.claude/skills/lost"
[[ ! -e "$STATE_DIR/agents-src" ]] || fail "clone left on a friend's machine"
[[ "$(cat "$HOME/.gemini/GEMINI.md")" == "gemini own" && ! -L "$HOME/.gemini/GEMINI.md" ]] \
    || fail "GEMINI.md not restored when the clone was settled"
[[ ! -e "$HOME/.claude/skills/opskill" && ! -e "$HOME/.agents/AGENTS.md" && ! -e "$HOME/.agents/skills" ]] \
    || fail "the operator's payload stayed on a friend's machine"
find "$XDG_STATE_HOME/fleet/backup" -path '*.agents/skills/opskill/SKILL.md' | grep -q . \
    || fail "the operator's skills not in the backup"
rm -rf "$HOME/.gemini" "$HOME/.agents" "$XDG_STATE_HOME/fleet/onboarding.pending"
# An account this machine already pulled takes its whole copy back over the
# old payload, so its record never names files the payload took away.
server_put AGENTS.md 'account instructions'; server_put skills/acct/SKILL.md 'account skill'
fleet sync --pull >/dev/null 2>&1 || fail "pull before the old module's payload"
old_agents
fleet sync --pull >/dev/null 2>&1 || fail "pull settling the clone with a record"
[[ ! -e "$STATE_DIR/agents-src" ]] || fail "clone left with a record"
[[ "$(cat "$HOME/.agents/AGENTS.md")" == "account instructions" && -f "$HOME/.agents/skills/acct/SKILL.md" ]] \
    || fail "the old payload took the account's files away"
fleet sync >/dev/null 2>&1 || fail "direct sync after settling with a record"
python3 -c 'import json, sys; f = json.load(open(sys.argv[1]))["files"]; sys.exit(not {"AGENTS.md", "skills/acct/SKILL.md"} <= set(f))' \
    "$FAKE/server.json" || fail "settling with a record uploaded deletions"
fleet __unlink >/dev/null
rm -rf "$HOME/.gemini" "$HOME/.agents" "$FAKE/server.json" "$XDG_STATE_HOME/fleet/config.json" \
    "$XDG_STATE_HOME/fleet/onboarding.pending"
# Onboarding run by hand settles the old payload first too, so the
# operator's files are never uploaded as this account's.
old_agents
fleet onboard >/dev/null 2>&1 || true
[[ ! -e "$STATE_DIR/agents-src" ]] || fail "onboard left the clone"
[[ "$(server_has AGENTS.md)" != "operator instructions" && "$(server_has skills/opskill/SKILL.md)" == "<none>" ]] \
    || fail "onboard uploaded the old module's payload as the account's"
fleet __unlink >/dev/null
rm -rf "$HOME/.gemini" "$HOME/.agents" "$FAKE/server.json" "$FAKE/pushes" "$XDG_STATE_HOME/fleet/config.json" \
    "$XDG_STATE_HOME/fleet/onboarding.pending"

# A friend's machine, account never pushed: local files stay, nothing is
# uploaded, and onboarding is left pending.
mkdir -p "$HOME/.agents/skills/mine" "$HOME/.claude/skills/claude-only" "$HOME/.codex/skills/both"
printf 'own skill\n' > "$HOME/.agents/skills/mine/SKILL.md"
printf 'claude skill\n' > "$HOME/.claude/skills/claude-only/SKILL.md"
printf 'codex skill\n' > "$HOME/.codex/skills/both/SKILL.md"
mkdir -p "$HOME/.codex/skills/.system/x"; printf 'bundled\n' > "$HOME/.codex/skills/.system/x/SKILL.md"
printf 'my instructions\n' > "$HOME/.claude/CLAUDE.md"
chmod 600 "$HOME/.claude/CLAUDE.md"
fleet sync >/dev/null 2>&1 || fail "sync before onboarding"
[[ -f "$XDG_STATE_HOME/fleet/onboarding.pending" ]] || fail "no onboarding marker"
[[ -f "$FAKE/pushes" ]] && fail "uploaded before onboarding"
[[ -f "$HOME/.claude/CLAUDE.md" && ! -L "$HOME/.claude/CLAUDE.md" ]] || fail "touched CLAUDE.md before onboarding"
fleet sync --check >/dev/null 2>&1 || fail "pending onboarding reads as outdated"

# Onboarding uploads ~/.agents plus the harness folders' own skills and
# instructions, moves the originals to the backup, and links them back.
touch "$FAKE/limited"
fleet onboard >/dev/null 2>&1 && fail "onboard read a refused upload as success"
rm "$FAKE/limited"
[[ -d "$HOME/.claude/skills/claude-only" && ! -L "$HOME/.claude/skills/claude-only" ]] \
    || fail "a refused onboarding moved the harness skills"
[[ -d "$HOME/.codex/skills/both" ]] || fail "a refused onboarding moved codex's skills"
[[ ! -e "$HOME/.agents/AGENTS.md" && ! -e "$HOME/.agents/skills/claude-only" ]] \
    || fail "a refused onboarding kept what it staged in ~/.agents"
[[ -f "$HOME/.agents/skills/mine/SKILL.md" ]] || fail "a refused onboarding removed an own skill"
# A dangling link where a harness skill would be staged stays the user's.
ln -s "$TMP/nowhere" "$HOME/.agents/skills/both"
touch "$FAKE/limited"
fleet onboard >/dev/null 2>&1 && fail "onboard read a refused upload as success"
rm "$FAKE/limited"
[[ -L "$HOME/.agents/skills/both" ]] || fail "a failed onboarding removed the user's dangling link"
rm "$HOME/.agents/skills/both"
# A copy that fails partway comes out with everything else it staged.
printf 'locked\n' > "$HOME/.codex/skills/both/locked.md"; chmod 000 "$HOME/.codex/skills/both/locked.md"
fleet onboard >/dev/null 2>&1 && fail "onboard read a failed copy as success"
rm -f "$HOME/.codex/skills/both/locked.md"
[[ ! -e "$HOME/.agents/AGENTS.md" && ! -e "$HOME/.agents/skills/claude-only" && ! -e "$HOME/.agents/skills/both" ]] \
    || fail "a failed staging kept what it copied into ~/.agents"
# A harness skill folder that cannot move puts back the ones already moved,
# and no record is saved, so the next sync joins the account and moves them.
chmod 500 "$HOME/.codex/skills"
fleet onboard >/dev/null 2>&1 && fail "onboard read a failed skill move as success"
chmod 700 "$HOME/.codex/skills"
[[ -d "$HOME/.claude/skills/claude-only" && ! -L "$HOME/.claude/skills/claude-only" ]] \
    || fail "a failed move left an earlier skill folder in the backup"
[[ ! -e "$XDG_STATE_HOME/fleet/config.json" ]] || fail "a failed move saved the record"
fleet sync >/dev/null 2>&1 || fail "sync after a failed onboarding move"
[[ "$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$HOME/.agents/AGENTS.md")" == 0o600 ]] \
    || fail "an owner-only CLAUDE.md was copied world-readable"
[[ "$(server_has AGENTS.md)" == "my instructions" ]] || fail "AGENTS.md not taken from CLAUDE.md"
[[ "$(server_has skills/claude-only/SKILL.md)" == "claude skill" ]] || fail "claude skill not uploaded"
[[ "$(server_has skills/both/SKILL.md)" == "codex skill" ]] || fail "codex skill not uploaded"
[[ "$(server_has skills/mine/SKILL.md)" == "own skill" ]] || fail "own skill not uploaded"
[[ "$(server_has skills/.system/x/SKILL.md)" == "<none>" ]] || fail "codex bundled skill uploaded"
[[ -d "$HOME/.codex/skills/.system" ]] || fail "codex bundled skills moved"
[[ -L "$HOME/.claude/skills/claude-only" && -L "$HOME/.claude/skills/mine" ]] || fail "skills not linked into claude"
[[ ! -e "$HOME/.codex/skills/both" ]] || fail "codex original not moved"
[[ "$(readlink "$HOME/.claude/CLAUDE.md")" == "$HOME/.agents/AGENTS.md" ]] || fail "CLAUDE.md not linked"
[[ "$(readlink "$HOME/AGENTS.md")" == "$HOME/.agents/AGENTS.md" ]] || fail "~/AGENTS.md not linked"
[[ ! -e "$HOME/.config/opencode/AGENTS.md" ]] || fail "linked for a harness that is not installed"
[[ ! -f "$XDG_STATE_HOME/fleet/onboarding.pending" ]] || fail "onboarding marker kept"
find "$XDG_STATE_HOME/fleet/backup" -path '*codex/skills/both/SKILL.md' | grep -q . || fail "codex original not in backup"

# A local edit waits for a direct sync; setup's pull leaves it alone.
printf 'edited\n' > "$HOME/.agents/skills/mine/SKILL.md"
fleet sync --pull >/dev/null 2>&1 || fail "pull with a local edit"
[[ "$(server_has skills/mine/SKILL.md)" == "own skill" ]] || fail "a pull uploaded"
fleet status | grep -q '1 local changes wait' || fail "status missed the local edit"
fleet sync >/dev/null 2>&1 || fail "direct sync"
[[ "$(server_has skills/mine/SKILL.md)" == "edited" ]] || fail "direct sync did not upload"
# An unreadable skill folder fails the sync instead of reading as deleted.
chmod 000 "$HOME/.agents/skills/mine"
rc=0; fleet sync >"$TMP/out" 2>&1 || rc=$?
chmod 700 "$HOME/.agents/skills/mine"
[[ $rc != 0 ]] || fail "synced with an unreadable skill folder"
[[ "$(server_has skills/mine/SKILL.md)" == "edited" ]] || fail "an unreadable folder was uploaded as deleted"
# A file saved again during the sync is recorded as the version it sent.
printf 'scanned\n' > "$HOME/.agents/skills/mine/SKILL.md"
printf '%s' "$HOME/.agents/skills/mine/SKILL.md" > "$FAKE/edit-on-fetch"
fleet sync >/dev/null 2>&1 || fail "sync with a save during it"
[[ "$(server_has skills/mine/SKILL.md)" == "saved later" ]] || fail "sent '$(server_has skills/mine/SKILL.md)'"
fleet status | grep -q 'local changes wait' && fail "the version sent was recorded as another"
printf 'edited\n' > "$HOME/.agents/skills/mine/SKILL.md"
fleet sync >/dev/null 2>&1 || fail "direct sync after the save"
cp "$XDG_STATE_HOME/fleet/config.json" "$TMP/record"

# Signing in to another account between pull and push uploads nothing.
printf 'meant for 7\n' > "$HOME/.agents/skills/mine/SKILL.md"
touch "$FAKE/switch"
fleet sync >"$TMP/out" 2>&1 && fail "pushed after the account changed"
grep -q 'session changed' "$TMP/out" || fail "account change not reported: $(cat "$TMP/out")"
[[ "$(server_has skills/mine/SKILL.md)" == "edited" ]] || fail "a push landed for the wrong account"
printf '7' > "$FAKE/subject"
printf 'edited\n' > "$HOME/.agents/skills/mine/SKILL.md"

# So does signing in to another Auth origin that issued the same subject.
printf 'meant for this origin\n' > "$HOME/.agents/skills/mine/SKILL.md"
touch "$FAKE/switch-origin"
fleet sync >"$TMP/out" 2>&1 && fail "pushed after the origin changed"
grep -q 'session changed' "$TMP/out" || fail "origin change not reported: $(cat "$TMP/out")"
[[ "$(server_has skills/mine/SKILL.md)" == "edited" ]] || fail "a push landed for the other origin"
rm -f "$FAKE/origin"
printf 'edited\n' > "$HOME/.agents/skills/mine/SKILL.md"

# A skill link that displaced a real folder puts it back when the skill
# leaves the account.
mkdir -p "$HOME/.claude/skills/shadow"; printf 'hand-made\n' > "$HOME/.claude/skills/shadow/SKILL.md"
server_put skills/shadow/SKILL.md 'account shadow'
fleet sync --pull >/dev/null 2>&1 || fail "pull with a displaced skill"
[[ -L "$HOME/.claude/skills/shadow" ]] || fail "shadow skill not linked"
server_del skills/shadow/SKILL.md
fleet sync --pull >/dev/null 2>&1 || fail "pull removing a skill"
[[ ! -L "$HOME/.claude/skills/shadow" && "$(cat "$HOME/.claude/skills/shadow/SKILL.md")" == "hand-made" ]] \
    || fail "pruning did not restore the displaced skill"
rm -rf "$HOME/.claude/skills/shadow"
# A displaced skill that cannot be put back yet keeps its backup mapping.
mkdir -p "$HOME/.claude/skills/shadow"; printf 'hand-made\n' > "$HOME/.claude/skills/shadow/SKILL.md"
server_put skills/shadow/SKILL.md 'account shadow'
fleet sync --pull >/dev/null 2>&1 || fail "pull with a displaced skill"
server_del skills/shadow/SKILL.md
# The link is already gone and the folder is read-only, so the move fails.
rm "$HOME/.claude/skills/shadow"; chmod 500 "$HOME/.claude/skills"
rc=0; fleet sync --pull >/dev/null 2>&1 || rc=$?
chmod 700 "$HOME/.claude/skills"
[[ $rc != 0 ]] || fail "pull restored into a read-only folder"
fleet sync --pull >/dev/null 2>&1 || fail "pull once the folder is writable"
[[ "$(cat "$HOME/.claude/skills/shadow/SKILL.md" 2>/dev/null)" == "hand-made" ]] \
    || fail "a failed restore lost the displaced skill"
rm -rf "$HOME/.claude/skills/shadow"

# Files fetched while another account signed in are not applied.
server_put skills/mine/SKILL.md 'fetched for 7'
touch "$FAKE/switch-on-fetch"
fleet sync --pull >"$TMP/out" 2>&1 && fail "applied files fetched across an account change"
grep -q 'session changed' "$TMP/out" || fail "fetch-time account change not reported: $(cat "$TMP/out")"
[[ "$(cat "$HOME/.agents/skills/mine/SKILL.md")" == "edited" ]] || fail "applied another account's fetch"
printf '7' > "$FAKE/subject"
fleet sync --pull >/dev/null 2>&1 || fail "pull after the account came back"

# AGENTS.md leaving the account puts back the harness files it replaced.
server_del AGENTS.md
fleet sync --pull >/dev/null 2>&1 || fail "pull removing AGENTS.md"
[[ ! -L "$HOME/.claude/CLAUDE.md" && "$(cat "$HOME/.claude/CLAUDE.md")" == "my instructions" ]] \
    || fail "CLAUDE.md not restored when AGENTS.md left"
[[ ! -L "$HOME/AGENTS.md" ]] || fail "~/AGENTS.md left dangling"
server_put AGENTS.md 'my instructions'
fleet sync --pull >/dev/null 2>&1 || fail "pull restoring AGENTS.md"
[[ "$(readlink "$HOME/.claude/CLAUDE.md")" == "$HOME/.agents/AGENTS.md" ]] || fail "CLAUDE.md not relinked"

# What the old agents module set aside as <target>.pre-agents.bak comes
# back: at once for the links fleet drops, and when AGENTS.md leaves the
# account for the links fleet takes over.
rm -f "$HOME/.codex/AGENTS.md"
printf 'codex own\n' > "$HOME/.codex/AGENTS.md.pre-agents.bak"
ln -s "$HOME/.agents/AGENTS.md" "$HOME/.codex/AGENTS.md"
mkdir -p "$HOME/.gemini"
printf 'gemini own\n' > "$HOME/.gemini/GEMINI.md.pre-agents.bak"
ln -s "$HOME/.agents/AGENTS.md" "$HOME/.gemini/GEMINI.md"
mkdir -p "$HOME/.codex/skills/mine.pre-agents.bak"
ln -s "$HOME/.agents/skills/mine" "$HOME/.codex/skills/mine"
mkdir -p "$HOME/.claude/skills/gone.pre-agents.bak"
ln -s "$HOME/.agents/skills/gone" "$HOME/.claude/skills/gone"
# Also when the old link was already deleted.
mkdir -p "$HOME/.config/muse" "$HOME/.codex/skills/lost.pre-agents.bak"
printf 'muse own\n' > "$HOME/.config/muse/AGENTS.md.pre-agents.bak"
fleet sync --pull >/dev/null 2>&1 || fail "pull over the old agents links"
[[ "$(cat "$HOME/.gemini/GEMINI.md")" == "gemini own" && ! -L "$HOME/.gemini/GEMINI.md" ]] \
    || fail "GEMINI.md not restored from the old backup"
[[ -d "$HOME/.codex/skills/mine" && ! -L "$HOME/.codex/skills/mine" ]] || fail "old codex skill backup not restored"
[[ -d "$HOME/.claude/skills/gone" && ! -L "$HOME/.claude/skills/gone" ]] || fail "old claude skill backup not restored"
[[ "$(cat "$HOME/.config/muse/AGENTS.md")" == "muse own" ]] || fail "old backup of a deleted link not restored"
[[ -d "$HOME/.codex/skills/lost" && ! -e "$HOME/.codex/skills/lost.pre-agents.bak" ]] \
    || fail "old skill backup of a deleted link not restored"
[[ "$(readlink "$HOME/.codex/AGENTS.md")" == "$HOME/.agents/AGENTS.md" ]] || fail "codex AGENTS.md not kept linked"
server_del AGENTS.md
fleet sync --pull >/dev/null 2>&1 || fail "pull removing AGENTS.md again"
[[ "$(cat "$HOME/.codex/AGENTS.md")" == "codex own" && ! -e "$HOME/.codex/AGENTS.md.pre-agents.bak" ]] \
    || fail "codex AGENTS.md not restored from the old backup"
rm -rf "$HOME/.codex/AGENTS.md" "$HOME/.gemini" "$HOME/.codex/skills/mine" "$HOME/.claude/skills/gone" \
    "$HOME/.config/muse" "$HOME/.codex/skills/lost"
server_put AGENTS.md 'my instructions'
fleet sync --pull >/dev/null 2>&1 || fail "pull restoring AGENTS.md again"

# Paths a case-insensitive disk would merge are neither taken nor pushed.
server_put skills/Mine/SKILL.md 'upper case'
fleet sync --pull >/dev/null 2>&1 && fail "pulled paths that differ only in case"
[[ ! -e "$HOME/.agents/skills/Mine" ]] || fail "applied a case-colliding path"
server_del skills/Mine/SKILL.md
fleet sync --pull >/dev/null 2>&1 || fail "pull after the collision went"
mkdir -p "$HOME/.agents/skills/Mine"; printf 'upper\n' > "$HOME/.agents/skills/Mine/SKILL.md"
fleet sync >/dev/null 2>&1 && fail "pushed paths that differ only in case"
[[ "$(server_has skills/Mine/SKILL.md)" == "<none>" ]] || fail "a case-colliding path reached the account"
rm -rf "$HOME/.agents/skills/Mine"
# Folders count too: skills/Mine/a and skills/mine/b would share one folder.
server_put skills/Mine/other.md 'upper folder'
fleet sync --pull >/dev/null 2>&1 && fail "pulled folders that differ only in case"
[[ ! -e "$HOME/.agents/skills/Mine" ]] || fail "applied a case-colliding folder"
server_del skills/Mine/other.md

# A pull that cannot finish writing leaves this account's files as they were.
before=$(cat "$HOME/.agents/skills/mine/SKILL.md")
# So does one whose record cannot be saved.
server_put skills/mine/SKILL.md 'unsaved'
chmod 500 "$XDG_STATE_HOME/fleet"
fleet sync --pull >/dev/null 2>&1 && fail "a pull that could not save its record reported success"
chmod 700 "$XDG_STATE_HOME/fleet"
[[ "$(cat "$HOME/.agents/skills/mine/SKILL.md")" == "$before" ]] || fail "an unsaved pull left its changes applied"
mkdir -p "$HOME/.agents/skills/zz"; chmod 500 "$HOME/.agents/skills/zz"
server_put skills/mine/SKILL.md 'half applied'; server_put skills/zz/new.md 'blocked'
fleet sync --pull >/dev/null 2>&1 && fail "a pull that could not write reported success"
[[ "$(cat "$HOME/.agents/skills/mine/SKILL.md")" == "$before" ]] || fail "a failed pull left a file half applied"
[[ "$(cat "$HOME/.claude/skills/mine/SKILL.md")" == "$before" ]] || fail "a failed pull left a skill link dangling"
chmod 700 "$HOME/.agents/skills/zz"; rm -rf "$HOME/.agents/skills/zz"
server_del skills/zz/new.md
fleet sync --pull >/dev/null 2>&1 || fail "pull after the blocked write went"
# A folder the account turned into a file comes back whole too.
server_put skills/mine/sub/x.md 'in the folder'
fleet sync --pull >/dev/null 2>&1 || fail "pull of a nested file"
mkdir -p "$HOME/.agents/skills/zz"; chmod 500 "$HOME/.agents/skills/zz"
server_del skills/mine/sub/x.md; server_put skills/mine/sub 'now a file'; server_put skills/zz/new.md 'blocked'
fleet sync --pull >/dev/null 2>&1 && fail "a blocked folder-to-file pull reported success"
[[ "$(cat "$HOME/.agents/skills/mine/sub/x.md")" == "in the folder" && ! -e "$HOME/.agents/skills/mine/sub/sub" ]] \
    || fail "a failed folder-to-file pull did not restore the folder: $(find "$HOME/.agents/skills/mine/sub")"
chmod 700 "$HOME/.agents/skills/zz"; rm -rf "$HOME/.agents/skills/zz"
server_del skills/zz/new.md; server_del skills/mine/sub
fleet sync --pull >/dev/null 2>&1 || fail "pull after the folder-to-file test"

# A server-only change is taken by any pull, and status/--check see it first.
server_put skills/mine/SKILL.md 'from another machine'
fleet sync --check >/dev/null 2>&1 && fail "check missed a server change"
fleet sync --pull >/dev/null 2>&1
[[ "$(cat "$HOME/.agents/skills/mine/SKILL.md")" == "from another machine" ]] || fail "server change not taken"
find "$HOME/.agents/skills/mine/SKILL.md" -perm 600 | grep -q . || fail "an account file is readable by others"
server_put skills/new/SKILL.md 'new skill'
fleet sync --pull >/dev/null 2>&1
[[ -L "$HOME/.claude/skills/new" ]] || fail "new skill not linked"

# Both sides changed: the account's copy wins, the local one is backed up,
# and a direct sync says so and exits non-zero.
printf 'local side\n' > "$HOME/.agents/skills/mine/SKILL.md"
server_put skills/mine/SKILL.md 'server side'
rc=0; fleet sync >"$TMP/out" 2>&1 || rc=$?
[[ $rc == 1 ]] || fail "conflict exited $rc"
grep -q 'skills/mine/SKILL.md' "$TMP/out" || fail "conflict not listed"
[[ "$(cat "$HOME/.agents/skills/mine/SKILL.md")" == "server side" ]] || fail "server copy lost"
grep -rqx 'local side' "$XDG_STATE_HOME/fleet/backup" || fail "local copy not backed up"

# A stale upload pulls and retries; deletions upload too.
rm -rf "$HOME/.agents/skills/new"
touch "$FAKE/race"
fleet sync >/dev/null 2>&1 || fail "sync after a concurrent push"
[[ "$(server_has skills/new/SKILL.md)" == "<none>" ]] || fail "deletion not uploaded"
[[ "$(cat "$HOME/.agents/settings/claude.json")" == '{"a":1}' ]] || fail "concurrent push not pulled"
[[ ! -L "$HOME/.claude/skills/new" ]] || fail "removed skill still linked"
[[ ! -e "$FAKE/race" ]] || fail "the race never ran"

# A settings file that is not a JSON object is never uploaded.
printf '[1]' > "$HOME/.agents/settings/codex.json"
fleet sync >/dev/null 2>&1 && fail "uploaded a non-object settings file"
[[ "$(server_has settings/codex.json)" == "<none>" ]] || fail "bad settings reached the account"
rm "$HOME/.agents/settings/codex.json"

# Symlinks are listed, not uploaded; a rate-limited account says when to retry.
ln -s /etc/hostname "$HOME/.agents/skills/mine/linked"
printf 'x\n' > "$HOME/.agents/skills/mine/extra"
touch "$FAKE/limited"
fleet sync >"$TMP/out" 2>&1 && fail "rate limit read as success"
grep -q 'uploads resume in 10 min' "$TMP/out" || fail "no retry time: $(cat "$TMP/out")"
grep -q 'symlinks are not uploaded: skills/mine/linked' "$TMP/out" || fail "symlink not listed"
rm "$FAKE/limited"
fleet sync >/dev/null 2>&1 || fail "sync after the limit"
[[ "$(server_has skills/mine/linked)" == "<none>" ]] || fail "symlink uploaded"

# A synced file replaced by a symlink is skipped, not deleted from the account.
mv "$HOME/.agents/skills/mine/extra" "$TMP/extra"
ln -s "$TMP/extra" "$HOME/.agents/skills/mine/extra"
fleet sync >/dev/null 2>&1 || fail "sync with a symlinked synced file"
[[ "$(server_has skills/mine/extra)" == "x" ]] || fail "symlinked file deleted from the account"
fleet status | grep -q 'local changes' && fail "symlinked file listed as a local change"
rm "$HOME/.agents/skills/mine/extra"; mv "$TMP/extra" "$HOME/.agents/skills/mine/extra"

# A symlinked ~/.agents is refused before anything is read or written.
THIRD="$TMP/third"; mkdir -p "$THIRD/real"; ln -s "$THIRD/real" "$THIRD/.agents"
rc=0; HOME="$THIRD" XDG_STATE_HOME="$TMP/state3" fleet sync >"$TMP/out" 2>&1 || rc=$?
[[ $rc == 1 ]] || fail "symlinked ~/.agents exited $rc"
grep -q 'refusing a symlinked' "$TMP/out" || fail "symlinked ~/.agents not reported"
[[ -z "$(ls -A "$THIRD/real")" ]] || fail "wrote through a symlinked ~/.agents"

# A timer from before uploads that cannot be replaced: the run only pulls and
# says so.
mkdir -p "$SCHEDULE_USER_DIR"
printf 'ExecStart=%%h/.local/bin/fleet sync\n' > "$SCHEDULE_USER_DIR/fleet-sync.service"
printf 'OnCalendar=*-*-* 04:00:00\n' > "$SCHEDULE_USER_DIR/fleet-sync.timer"
printf 'unsent\n' > "$HOME/.agents/skills/mine/unsent"
rc=0; fleet sync >"$TMP/out" 2>&1 || rc=$?
[[ $rc == 1 ]] || fail "failed timer swap exited $rc"
grep -q 'could not replace the nightly timer' "$TMP/out" || fail "failed timer swap not reported"
[[ "$(server_has skills/mine/unsent)" == "<none>" ]] || fail "uploaded while the old timer may remain"
rm -f "$HOME/.agents/skills/mine/unsent" "$SCHEDULE_USER_DIR"/fleet-sync.*

# Auth down: exit 3, nothing touched.
touch "$FAKE/down"
rc=0; fleet sync >/dev/null 2>&1 || rc=$?
[[ $rc == 3 ]] || fail "down exited $rc"
rm "$FAKE/down"

# A second machine joining the pushed account takes its copy wholesale and
# moves its own harness skill folders to the backup.
cp -r "$FAKE/server.json" "$TMP/server.keep"
SECOND="$TMP/second"; mkdir -p "$SECOND/.claude/skills/stray" "$SECOND/.agents/skills/old"
printf 'stray\n' > "$SECOND/.claude/skills/stray/SKILL.md"
printf 'old\n' > "$SECOND/.agents/skills/old/SKILL.md"
HOME="$SECOND" XDG_STATE_HOME="$TMP/state2" fleet sync >/dev/null 2>&1 || fail "joining sync"
[[ "$(cat "$SECOND/.agents/skills/mine/SKILL.md")" == "server side" ]] || fail "join did not take the account copy"
[[ ! -e "$SECOND/.agents/skills/old" ]] || fail "join kept a local-only file"
[[ ! -e "$SECOND/.claude/skills/stray" || -L "$SECOND/.claude/skills/stray" ]] || fail "stray skill folder kept"
[[ -L "$SECOND/.claude/skills/mine" ]] || fail "join did not link skills"

# Another account on the same machine: its ~/.agents goes to the backup, but
# only once the new account's copy is fetched.
printf '9' > "$FAKE/subject"
touch "$FAKE/fetch-down"
rc=0; fleet sync >/dev/null 2>&1 || rc=$?
[[ $rc == 3 ]] || fail "failed fetch exited $rc"
[[ -e "$HOME/.agents/skills/mine" && -L "$HOME/.claude/skills/mine" ]] || fail "a failed fetch moved the old account's files"
rm "$FAKE/fetch-down"
# A copy that cannot be written (a file where a folder must go) puts the old
# account's files back, links and record with them.
printf '{"counter":0,"version":0,"files":{}}' > "$FAKE/server.json"
server_put skills/clash 'a file'; server_put skills/clash/SKILL.md 'and a folder'
fleet sync >/dev/null 2>&1 && fail "applied a copy that cannot be written"
[[ -e "$HOME/.agents/skills/mine" && -e "$HOME/.claude/skills/mine/SKILL.md" ]] \
    || fail "a failed apply left the old account's links dangling"
grep -q '"account": "https://auth.lost.plus 7"' "$XDG_STATE_HOME/fleet/config.json" || fail "a failed apply dropped the old record"
# So does a hand-made skill folder that cannot be moved out of claude's way.
printf '{"counter":0,"version":0,"files":{}}' > "$FAKE/server.json"
server_put skills/theirs/SKILL.md 'theirs'
mkdir -p "$HOME/.claude/skills/handmade"; printf 'mine\n' > "$HOME/.claude/skills/handmade/SKILL.md"
chmod 500 "$HOME/.claude/skills"
fleet sync >/dev/null 2>&1 && fail "switched accounts with a skill folder that could not move"
chmod 700 "$HOME/.claude/skills"
[[ -e "$HOME/.agents/skills/mine" && ! -e "$HOME/.agents/skills/theirs" ]] \
    || fail "a failed skill-folder move left the other account's files"
grep -q '"account": "https://auth.lost.plus 7"' "$XDG_STATE_HOME/fleet/config.json" || fail "a failed skill-folder move dropped the old record"
rm -rf "$HOME/.claude/skills/handmade"
# So does a record that cannot be saved, and a skill folder moved out of
# claude's way comes back.
printf '{"counter":0,"version":0,"files":{}}' > "$FAKE/server.json"
server_put skills/theirs/SKILL.md 'theirs'
mkdir -p "$HOME/.claude/skills/handmade"; printf 'mine\n' > "$HOME/.claude/skills/handmade/SKILL.md"
chmod 500 "$XDG_STATE_HOME/fleet"
fleet sync >/dev/null 2>&1 && fail "switched accounts without saving the record"
chmod 700 "$XDG_STATE_HOME/fleet"
[[ -e "$HOME/.agents/skills/mine" && ! -e "$HOME/.agents/skills/theirs" ]] \
    || fail "an unsaved record left the other account's files"
[[ -f "$HOME/.claude/skills/handmade/SKILL.md" ]] || fail "an unsaved record kept the skill folder moved"
grep -q '"account": "https://auth.lost.plus 7"' "$XDG_STATE_HOME/fleet/config.json" || fail "an unsaved record dropped the old record"
rm -rf "$HOME/.claude/skills/handmade"
printf '{"counter":0,"version":0,"files":{}}' > "$FAKE/server.json"
# Links that cannot be cleared yet are cleared by the next sync.
chmod 500 "$HOME/.claude/skills"
fleet sync >/dev/null 2>&1 && fail "sync read uncleared links as done"
chmod 700 "$HOME/.claude/skills"
fleet sync >/dev/null 2>&1 || fail "sync as another account"
[[ ! -e "$HOME/.agents/skills/mine" ]] || fail "another account's files kept"
[[ ! -L "$HOME/.claude/CLAUDE.md" && "$(cat "$HOME/.claude/CLAUDE.md")" == "my instructions" ]] \
    || fail "CLAUDE.md left dangling while the other account waits for onboarding"
[[ ! -L "$HOME/.claude/skills/mine" ]] || fail "skill link left dangling for the other account"
find "$XDG_STATE_HOME/fleet/backup" -maxdepth 2 -name agents-other-account | grep -q . || fail "other account's files not backed up"
printf '7' > "$FAKE/subject"

# Backed-up server copies are owner-only.
find "$XDG_STATE_HOME/fleet/backup" -maxdepth 0 -perm 0700 | grep -q . || fail "backup folder not 0700"
find "$XDG_STATE_HOME/fleet/backup" -path '*/account/*' -type f | grep -q . || fail "no server copy backed up"
find "$XDG_STATE_HOME/fleet/backup" -path '*/account/*' -type f -perm /077 | grep -q . && fail "server copy readable by others"

# Uninstalling drops the links and puts back what they displaced.
mv "$TMP/server.keep" "$FAKE/server.json"
rm -f "$XDG_STATE_HOME/fleet/config.json"
printf 'mine again\n' > "$TMP/claude.md"; rm -f "$HOME/.claude/CLAUDE.md"; cp "$TMP/claude.md" "$HOME/.claude/CLAUDE.md"
mkdir -p "$HOME/.claude/skills/old.pre-agents.bak"; printf 'old\n' > "$HOME/.claude/skills/old.pre-agents.bak/SKILL.md"
fleet sync >/dev/null 2>&1 || fail "rejoin"
[[ -L "$HOME/.claude/CLAUDE.md" ]] || fail "CLAUDE.md not linked on rejoin"
# A sidecar whose link is gone is neither taken for a skill nor stranded.
[[ -f "$HOME/.claude/skills/old/SKILL.md" && ! -L "$HOME/.claude/skills/old" && ! -e "$HOME/.claude/skills/old.pre-agents.bak" ]] \
    || fail "an old agents sidecar was taken for a skill or left under its sidecar name"
rm -rf "$HOME/.claude/skills/old"

# A link whose record cannot be saved puts back what it displaced, since
# nothing would know to later.
mv "$XDG_STATE_HOME/fleet/links.json" "$TMP/links.keep"; mkdir "$XDG_STATE_HOME/fleet/links.json"
mkdir -p "$HOME/.config/opencode"; rm -f "$HOME/.config/opencode/AGENTS.md"
printf 'opencode mine\n' > "$HOME/.config/opencode/AGENTS.md"
fleet sync >/dev/null 2>&1 && fail "a sync whose links record could not be saved reported success"
rmdir "$XDG_STATE_HOME/fleet/links.json"; mv "$TMP/links.keep" "$XDG_STATE_HOME/fleet/links.json"
rm -f "$XDG_STATE_HOME"/fleet/.links.json.*
[[ ! -L "$HOME/.config/opencode/AGENTS.md" && "$(cat "$HOME/.config/opencode/AGENTS.md")" == "opencode mine" ]] \
    || fail "an unrecorded link kept what it displaced"
rm -f "$HOME/.config/opencode/AGENTS.md"

# Another account while ~/.agents is gone still drops this account's links.
cp "$FAKE/server.json" "$TMP/server.keep"
rm -rf "$HOME/.agents"
printf '9' > "$FAKE/subject"; printf '{"counter":0,"version":0,"files":{}}' > "$FAKE/server.json"
fleet sync --check >/dev/null 2>&1 && fail "another account's config here read as current"
fleet sync >/dev/null 2>&1 || fail "sync as another account without ~/.agents"
[[ ! -L "$HOME/.claude/CLAUDE.md" && "$(cat "$HOME/.claude/CLAUDE.md")" == "mine again" ]] \
    || fail "links kept for another account when ~/.agents was gone"
printf '7' > "$FAKE/subject"; mv "$TMP/server.keep" "$FAKE/server.json"
fleet sync >/dev/null 2>&1 || fail "rejoin again"
[[ -L "$HOME/.claude/CLAUDE.md" ]] || fail "CLAUDE.md not linked on the second rejoin"
mkdir -p "$HOME/.claude/skills/shadow"; printf 'hand-made\n' > "$HOME/.claude/skills/shadow/SKILL.md"
server_put skills/shadow/SKILL.md 'account shadow'
fleet sync --pull >/dev/null 2>&1 || fail "pull before uninstall"
# A pass that displaces a file and then fails on a later link still records
# the first, so the retry and the uninstall can put it back.
rm -f "$HOME/.claude/CLAUDE.md"; printf 'mine, late\n' > "$HOME/.claude/CLAUDE.md"
server_put skills/late/SKILL.md 'late'
chmod 500 "$HOME/.claude/skills"
fleet sync --pull >/dev/null 2>&1 && fail "a pass with an unwritable skill folder reported success"
chmod 700 "$HOME/.claude/skills"
fleet sync --pull >/dev/null 2>&1 || fail "pull once the folder is writable"
rm -rf "$HOME/.claude/skills"
# The old agents module's links go too, with what they replaced back.
mkdir -p "$HOME/.gemini" "$HOME/.config/muse/skills"
printf 'gemini own\n' > "$HOME/.gemini/GEMINI.md.pre-agents.bak"
ln -s "$HOME/.agents/AGENTS.md" "$HOME/.gemini/GEMINI.md"
mkdir -p "$HOME/.config/muse/skills/mine.pre-agents.bak"
ln -s "$HOME/.agents/skills/mine" "$HOME/.config/muse/skills/mine"
fleet __unlink
[[ ! -L "$HOME/.gemini/GEMINI.md" && "$(cat "$HOME/.gemini/GEMINI.md")" == "gemini own" ]] \
    || fail "uninstall left the old module's instructions link"
[[ -d "$HOME/.config/muse/skills/mine" && ! -L "$HOME/.config/muse/skills/mine" ]] \
    || fail "uninstall left the old module's skill link"
[[ "$(cat "$HOME/.claude/skills/shadow/SKILL.md")" == "hand-made" ]] || fail "uninstall stranded a displaced skill"
[[ ! -L "$HOME/.claude/CLAUDE.md" && "$(cat "$HOME/.claude/CLAUDE.md")" == "mine, late" ]] || fail "CLAUDE.md not restored"
[[ ! -L "$HOME/.claude/skills/mine" ]] || fail "skill link kept"

# Overlapping runs take turns on ~/.agents and the links.
python3 - "$XDG_STATE_HOME/fleet/config.lock" "$TMP/locked" <<'PY' &
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
open(sys.argv[2], "w").close()
time.sleep(10)
PY
holder=$!
until [[ -e "$TMP/locked" ]]; do sleep 0.1; done
rc=0; timeout 2 python3 "$ROOT/files/fleet" __unlink </dev/null || rc=$?
kill $holder; wait $holder 2>/dev/null || true
[[ $rc == 124 ]] || fail "a run did not wait for the one holding the config lock"
fleet __unlink || fail "a run after the lock was released"

echo "fleet config tests passed"
