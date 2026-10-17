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
    if os.path.exists(f"{fake}/switch-skill"):
        # The machine signs in to another account right after fleet checks.
        os.remove(f"{fake}/switch-skill")
        open(f"{fake}/subject", "w").write("9")
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
market, installs = state.setdefault("market", {}), state.setdefault("installs", {})
def save():
    json.dump(state, open(f"{fake}/server.json", "w"))
def listed(files):
    return [{"path": p, "size": len(f["content"]), "sha256": f["sha256"], "executable": f["executable"]}
            for p, f in sorted(files.items())]
if path == "/api/fleet/config":
    answer(200, {"counter": state["counter"], "version": state["version"], "files": listed(state["files"]),
                 "installs": [{"id": i, "name": n, "skill": market[i]["folder"], "author": market[i]["author"],
                               "author_name": market[i]["author"], "updating": market[i]["published"],
                               "files": listed(market[i]["files"])} for i, n in sorted(installs.items())],
                 "skills": [{"id": i, "folder": s["folder"], "published": s["published"]}
                            for i, s in sorted(market.items()) if s["mine"]]})
if path == "/api/fleet/skills":
    answer(200, {"skills": [{"id": i, "folder": s["folder"], "author": s["author"], "author_name": s["author"],
                             "description": "", "installs": list(installs).count(i), "updated_at": 0,
                             "own": s["mine"]} for i, s in sorted(market.items()) if s["published"]]})
if path in ("/api/fleet/skills/install", "/api/fleet/skills/uninstall",
            "/api/fleet/skills/publish", "/api/fleet/skills/unpublish"):
    if os.environ.get("LOST_AUTH_ORIGIN", origin) != origin:
        sys.exit(5)
    if body.get("subject") != open(f"{fake}/subject").read():
        answer(409, {"error": "account changed"})
if path == "/api/fleet/skills/install":
    ref = body["skill"]
    found = [i for i, s in market.items() if s["published"] and (i == ref or f"{s['author']}/{s['folder']}" == ref)]
    if not found:
        answer(404, {"error": "no published skill " + ref})
    name = body.get("as") or market[found[0]]["folder"]
    if found[0] in installs:
        answer(200, {"id": found[0], "name": installs[found[0]], "installed": False})
    if name in installs.values():
        answer(409, {"error": "an installed skill is already named " + name + "; pick another with --as"})
    folded = f"skills/{name}".casefold()
    if any(p.casefold() == folded or p.casefold().startswith(folded + "/") for p in state["files"]):
        answer(409, {"error": "your own skills include " + name + "; pick another name with --as"})
    installs[found[0]] = name
    state["version"] += 1; save()
    answer(200, {"id": found[0], "name": name, "installed": True})
if path == "/api/fleet/skills/uninstall":
    found = [i for i, n in installs.items() if body["skill"] in (i, n)]
    if not found:
        answer(404, {"error": "no installed skill " + body["skill"]})
    del installs[found[0]]
    state["version"] += 1; save()
    answer(200, {"ok": True})
if path == "/api/fleet/skills/publish":
    folder = body["folder"]
    prefix = f"skills/{folder}/"
    if prefix + "SKILL.md" not in state["files"]:
        answer(400, {"error": "push skills/" + folder + "/SKILL.md first"})
    held = [i for i, s in market.items() if s["mine"] and s["published"] and s["folder"] == folder]
    sid = held[0] if held else "22222222-2222-4222-8222-%012d" % len(market)
    market[sid] = {"author": "me", "folder": folder, "published": True, "mine": True,
                   "files": {p[len(prefix):]: f for p, f in state["files"].items() if p.startswith(prefix)}}
    save()
    answer(200, {"id": sid, "folder": folder})
if path == "/api/fleet/skills/unpublish":
    found = [i for i, s in market.items() if s["mine"] and s["published"] and body["skill"] in (i, s["folder"])]
    if not found:
        answer(404, {"error": "no published skill of yours " + body["skill"]})
    market[found[0]]["published"] = False
    save()
    answer(200, {"ok": True})
if path == "/api/fleet/skills/fetch":
    files = market[body["id"]]["files"] if body["id"] in installs else {}
    paths = body["paths"]
    first = [p for p in paths if p in files][:1]
    answer(200, {"files": [{"path": p, **files[p]} for p in first],
                 "remaining": [p for p in paths if p in files and p not in first],
                 "missing": [p for p in paths if p not in files]})
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
# An author's published skill, straight into the fake server.
market_put() {
    python3 - "$@" <<'PY'
import base64, hashlib, json, os, sys
f = f"{os.environ['FAKE']}/server.json"
state = json.load(open(f))
sid, author, folder, rel, text = sys.argv[1:6]
skill = state.setdefault("market", {}).setdefault(sid, {"author": author, "folder": folder, "published": True,
                                                        "mine": False, "files": {}})
data = text.encode()
skill["files"][rel] = {"content": base64.b64encode(data).decode(), "sha256": hashlib.sha256(data).hexdigest(),
                       "executable": rel.endswith(".sh")}
if sid in state.get("installs", {}):
    state["version"] += 1
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
# A payload that cannot all move aside puts back what did.
chmod 500 "$HOME/.agents/skills"
fleet sync >/dev/null 2>&1 && fail "a payload that could not move reported success"
chmod 700 "$HOME/.agents/skills"
[[ "$(cat "$HOME/.agents/AGENTS.md")" == "operator instructions" ]] \
    || fail "a failed payload move left AGENTS.md in the backup"
# A clone that cannot be removed puts the operator's payload back.
mkdir -p "$STATE_DIR/agents-src/.git/locked"; : > "$STATE_DIR/agents-src/.git/locked/f"
chmod 500 "$STATE_DIR/agents-src/.git/locked"
fleet sync >/dev/null 2>&1 && fail "a clone that could not be removed reported success"
chmod 700 "$STATE_DIR/agents-src/.git/locked"
[[ "$(cat "$HOME/.agents/AGENTS.md")" == "operator instructions" && -f "$HOME/.agents/skills/opskill/SKILL.md" ]] \
    || fail "a failed clone removal left the operator's payload in the backup"
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

# The marketplace, on a fresh machine and account.
export HOME="$TMP/market" XDG_STATE_HOME="$TMP/market-state"
mkdir -p "$HOME/.claude/skills"
printf '5' > "$FAKE/subject"
printf '{"counter":0,"version":0,"files":{}}' > "$FAKE/server.json"
: > "$FAKE/pushes"
server_put AGENTS.md 'market account'
fleet sync >/dev/null 2>&1 || fail "market account join"
FOO=11111111-1111-4111-8111-111111111111 OTHER=33333333-3333-4333-8333-333333333333
market_put $FOO alice foo SKILL.md $'---\nname: foo\ndescription: d\n---\nv1'
market_put $FOO alice foo run.sh 'echo v1'
market_put $OTHER bob foo SKILL.md $'---\ndescription: no name\n---\nbob'
out=$(fleet install nosuchharness 2>&1) && fail "installed an unknown harness"
grep -q 'unknown harness nosuchharness' <<<"$out" || fail "a plain name was not taken for a harness"
fleet install alice/foo >/dev/null 2>&1 || fail "install by author/skill"
installed="$HOME/.agents/skills/foo"
[[ "$(cat "$installed/run.sh")" == "echo v1" && -x "$installed/run.sh" ]] || fail "installed copy not written"
[[ "$(stat -c %a "$installed/SKILL.md")" == 600 ]] || fail "installed file readable by others"
grep -q "\"$FOO\"" "$HOME/.agents/installed.json" || fail "install not recorded"
[[ -L "$HOME/.claude/skills/foo" ]] || fail "installed skill not linked"
fleet sync --check >/dev/null 2>&1 || fail "a fresh install read as outdated"
# Installed folders are never pushed as the account's own.
fleet sync >/dev/null 2>&1 || fail "direct sync with an install"
grep -q 'skills/foo' "$FAKE/pushes" && fail "an installed skill was pushed"
[[ "$(server_has skills/foo/SKILL.md)" == "<none>" ]] || fail "an installed skill reached the account's files"
# The author's update arrives on the next pull.
market_put $FOO alice foo run.sh 'echo v2'
fleet sync --check >/dev/null 2>&1 && fail "an author's update read as current"
fleet sync --pull >/dev/null 2>&1 || fail "pull of an author's update"
[[ "$(cat "$installed/run.sh")" == "echo v2" ]] || fail "author's update not written"
grep -q '^\.installing-' "$XDG_STATE_HOME/fleet/staging" || fail "a pull's staging folder went unrecorded"
# The copy being replaced is compared only once moved out of the skills
# folder, so a save that lands during the comparison is never deleted unseen.
market_put $FOO alice foo run.sh 'echo v3'
python3 -c '
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("fleet_aside", sys.argv[1])
fleet = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(fleet)
scan, aside = fleet._scan_folder, []
def check(folder):
    aside.append(folder.parent.name.startswith(".replacing-"))
    return scan(folder)
fleet._scan_folder = check
sys.argv = ["fleet", "sync", "--pull"]
rc = fleet.main()
assert any(aside), "the replaced install was compared in place"
sys.exit(rc)' "$ROOT/files/fleet" </dev/null >"$TMP/aside.out" 2>&1 || fail "pull replacing an install: $(tail -3 "$TMP/aside.out")"
[[ "$(cat "$installed/run.sh")" == "echo v3" ]] || fail "author's second update not written"
ls -a "$HOME/.agents" | grep -q '^\.replacing-' && fail "a replaced install was left aside"
grep -rq 'echo v2' "$XDG_STATE_HOME/fleet/backup" 2>/dev/null && fail "an unchanged install was backed up"
market_put $FOO alice foo run.sh 'echo v2'
fleet sync --pull >/dev/null 2>&1 || fail "pull putting the author's update back"
# A local edit is reported, then put back, and kept in the backup.
printf 'edited\n' >> "$installed/run.sh"
fleet status 2>&1 | grep -q 'installed skills changed here.*foo' || fail "status missed an edited install"
fleet sync --check >/dev/null 2>&1 && fail "an edited install read as current"
fleet sync --pull >/dev/null 2>&1 || fail "pull over an edited install"
[[ "$(cat "$installed/run.sh")" == "echo v2" ]] || fail "edited install not put back"
grep -rq edited "$XDG_STATE_HOME/fleet/backup" || fail "the edit was not backed up"
# So is one left unreadable: a file, or a folder whose files cannot be listed.
for locked in "$installed/run.sh" "$installed/sub"; do
    [[ $locked == */sub ]] && mkdir "$locked"
    chmod 000 "$locked"
    fleet status 2>&1 | grep -q 'installed skills changed here.*foo' || fail "status missed an unreadable ${locked##*/}"
    fleet sync --pull >/dev/null 2>&1 || fail "pull over an unreadable ${locked##*/}"
    [[ "$(cat "$installed/run.sh")" == "echo v2" && ! -e "$installed/sub" ]] || fail "an unreadable ${locked##*/} was not put back"
done
chmod -R u+rwx "$XDG_STATE_HOME/fleet/backup"
# And a FIFO, which is not read.
mkfifo "$installed/pipe"
timeout 60 python3 "$ROOT/files/fleet" status </dev/null 2>&1 | grep -q 'installed skills changed here.*foo' || fail "status missed a FIFO"
timeout 60 python3 "$ROOT/files/fleet" sync --pull </dev/null >/dev/null 2>&1 || fail "pull over a FIFO"
[[ ! -e "$installed/pipe" ]] || fail "a FIFO was not put back"
# Local names are unique; --as picks another, which SKILL.md then carries.
fleet install bob/foo >/dev/null 2>&1 && fail "installed a second skill under a taken name"
fleet install $OTHER --as bob-foo >/dev/null 2>&1 || fail "install by id with --as"
[[ "$(sed -n 2p "$HOME/.agents/skills/bob-foo/SKILL.md")" == "name: bob-foo" ]] || fail "local name not inserted"
[[ "$(sed -n 2p "$installed/SKILL.md")" == "name: foo" ]] || fail "local name not kept"
fleet install alice/foo 2>&1 | grep -q 'already installed as foo' || fail "a repeat install"
# An unpublished skill stays, no longer updated.
python3 - <<'PY'
import json, os
f = f"{os.environ['FAKE']}/server.json"; state = json.load(open(f))
state["market"]["11111111-1111-4111-8111-111111111111"]["published"] = False; json.dump(state, open(f, "w"))
PY
fleet skills | grep -q "^foo  installed from alice/foo  $FOO  (no longer updated)" || fail "skills missed an unpublished install"
# A change is made only on the account fleet checked, not one signed in
# to since.
was=$(cat "$FAKE/subject"); touch "$FAKE/switch-skill"
out=$(fleet uninstall foo 2>&1) && fail "uninstalled from an account signed in to since"
printf '%s' "$was" > "$FAKE/subject"
grep -q 'session changed' <<<"$out" || fail "a changed session went unreported: $out"
fleet skills | grep -q '^foo  installed' || fail "a changed session lost the install"
fleet uninstall foo >/dev/null 2>&1 || fail "uninstall"
[[ ! -e "$installed" && ! -L "$HOME/.claude/skills/foo" ]] || fail "uninstalled skill kept"
fleet uninstall bob-foo >/dev/null 2>&1 || fail "second uninstall"
[[ ! -e "$HOME/.agents/installed.json" ]] || fail "installed.json kept with no installs"
# A name YAML would read as a bool goes in quoted.
fleet install $OTHER --as true >/dev/null 2>&1 || fail "install --as true"
[[ "$(sed -n 2p "$HOME/.agents/skills/true/SKILL.md")" == 'name: "true"' ]] || fail "a bool-like name went in plain"
fleet uninstall true >/dev/null 2>&1 || fail "uninstall true"
# A name key YAML spells another way, with its value after a blank line, is
# the one replaced; the blank line after the value stays.
market_put $OTHER bob foo SKILL.md $'---\n"name" :\n\n  bob\n\ndescription: d\n---\nbob'
fleet install $OTHER --as spelled >/dev/null 2>&1 || fail "install --as spelled"
[[ "$(cat "$HOME/.agents/skills/spelled/SKILL.md")" == $'---\nname: spelled\n\ndescription: d\n---\nbob' ]] \
    || fail "a differently spelled name key was not replaced: $(cat "$HOME/.agents/skills/spelled/SKILL.md")"
fleet uninstall spelled >/dev/null 2>&1 || fail "uninstall spelled"
market_put $OTHER bob foo SKILL.md $'---\ndescription: no name\n---\nbob'
# Another machine uninstalls a skill and pushes its own under that name:
# the install's folder goes and the account's copy takes its place.
market_put $OTHER bob foo extra.txt 'from bob'
fleet install $OTHER --as foo >/dev/null 2>&1 || fail "install bob's foo as foo"
python3 - <<'PY'
import json, os
f = f"{os.environ['FAKE']}/server.json"; state = json.load(open(f))
state["installs"] = {}; json.dump(state, open(f, "w"))
PY
server_put skills/foo/SKILL.md 'owned foo'
fleet sync --pull >/dev/null 2>&1 || fail "pull of an owned skill replacing an install"
[[ "$(cat "$installed/SKILL.md" 2>/dev/null)" == "owned foo" && ! -e "$installed/extra.txt" ]] \
    || fail "an owned skill replacing an install was not written"
[[ ! -e "$HOME/.agents/installed.json" ]] || fail "the replaced install is still recorded"
fleet sync --check >/dev/null 2>&1 || fail "an owned skill replacing an install read as outdated"
rm -rf "$installed"; fleet sync >/dev/null 2>&1 || fail "sync deleting the owned foo"
[[ "$(server_has skills/foo/SKILL.md)" == "<none>" ]] || fail "owned foo not deleted"
# Publishing pushes the folder first, then names it in fleet skills.
mkdir -p "$HOME/.agents/skills/pub"; printf -- '---\nname: pub\n---\n' > "$HOME/.agents/skills/pub/SKILL.md"
fleet publish pub >/dev/null 2>&1 || fail "publish"
[[ "$(server_has skills/pub/SKILL.md)" != "<none>" ]] || fail "publish did not push the folder"
fleet skills | grep -q '^pub  .*  published$' || fail "skills missed a published skill"
fleet skills --market | grep -q '^me/pub  .*(yours)' || fail "market missed one's own skill"
touch "$FAKE/switch-skill"
fleet unpublish pub >/dev/null 2>&1 && fail "unpublished on an account signed in to since"
printf '%s' "$was" > "$FAKE/subject"
fleet skills | grep -q '^pub  .*  published$' || fail "a changed session unpublished"
fleet unpublish pub >/dev/null 2>&1 || fail "unpublish"
fleet skills | grep -q '^pub  .*  unpublished$' || fail "skills missed an unpublished skill"
# An account never pushed still gets its installs.
export HOME="$TMP/market2" XDG_STATE_HOME="$TMP/market2-state"
mkdir -p "$HOME/.claude/skills"
python3 - <<'PY'
import json, os
f = f"{os.environ['FAKE']}/server.json"; state = json.load(open(f))
state["market"]["11111111-1111-4111-8111-111111111111"]["published"] = True
json.dump({"counter": 0, "version": 1, "files": {}, "market": state["market"],
           "installs": {"11111111-1111-4111-8111-111111111111": "foo"}}, open(f, "w"))
PY
fleet sync >/dev/null 2>&1 || true
[[ -f "$HOME/.agents/skills/foo/SKILL.md" && -L "$HOME/.claude/skills/foo" ]] || fail "a never-pushed account's install not written"
# Its links are made on every pass, also one with nothing to write, as
# after a pass whose links failed once the installs were in place.
rm "$HOME/.claude/skills/foo"
fleet sync >/dev/null 2>&1 || true
[[ -L "$HOME/.claude/skills/foo" ]] || fail "a never-pushed account's install left unlinked"
# An install folder replaced by a link here is backed up and written again.
mkdir -p "$TMP/elsewhere"; printf 'elsewhere\n' > "$TMP/elsewhere/SKILL.md"
rm -rf "$HOME/.agents/skills/foo"; ln -s "$TMP/elsewhere" "$HOME/.agents/skills/foo"
market_put $FOO alice foo run.sh 'echo v3'
fleet sync >/dev/null 2>&1 || true
[[ ! -L "$HOME/.agents/skills/foo" && "$(cat "$HOME/.agents/skills/foo/run.sh")" == "echo v3" ]] \
    || fail "an install folder replaced by a link was not written again"
[[ "$(cat "$TMP/elsewhere/SKILL.md")" == "elsewhere" ]] || fail "wrote through the link"
find "$XDG_STATE_HOME/fleet/backup" -type l -name foo | grep -q . || fail "the link was not backed up"
# Another account's installs that cannot be written put this one's files back,
# links and record with them.
export HOME="$TMP/market" XDG_STATE_HOME="$TMP/market-state"
TMP="$TMP" python3 - <<'PY2'
import base64, hashlib, json, os
f = f"{os.environ['FAKE']}/server.json"; state = json.load(open(f))
json.dump(state, open(f"{os.environ['TMP']}/market.keep", "w"))
def entry(text):
    data = text.encode()
    return {"content": base64.b64encode(data).decode(), "sha256": hashlib.sha256(data).hexdigest(), "executable": False}
sid = "44444444-4444-4444-8444-444444444444"
state["market"][sid] = {"author": "carol", "folder": "clash", "published": True, "mine": False,
                        "files": {"SKILL.md": entry("clash"), "x": entry("a file"), "x/y": entry("and a folder")}}
json.dump({"counter": 0, "version": 1, "files": {}, "market": state["market"], "installs": {sid: "clash"}}, open(f, "w"))
PY2
printf '6' > "$FAKE/subject"
fleet sync >/dev/null 2>&1 && fail "applied installs that cannot be written"
[[ "$(cat "$HOME/.agents/AGENTS.md")" == "market account" && -e "$HOME/.claude/skills/pub/SKILL.md" ]] \
    || fail "failed installs left the old account's files or links out"
grep -q '"account": "https://auth.lost.plus 5"' "$XDG_STATE_HOME/fleet/config.json" || fail "failed installs dropped the old record"
# So do they on a machine the old agents module set up: its payload, clone
# and links stay in use.
export HOME="$TMP/market3" XDG_STATE_HOME="$TMP/market3-state"
mkdir -p "$HOME/.claude/skills"
old_agents
fleet sync >/dev/null 2>&1 && fail "applied installs that cannot be written over the old payload"
[[ -d "$STATE_DIR/agents-src" && -L "$HOME/.gemini/GEMINI.md" && "$(cat "$HOME/.agents/AGENTS.md")" == "operator instructions" \
    && -f "$HOME/.agents/skills/opskill/SKILL.md" && -e "$HOME/.claude/skills/opskill/SKILL.md" ]] \
    || fail "failed installs settled the old payload"
rm -rf "$STATE_DIR/agents-src"
export HOME="$TMP/market" XDG_STATE_HOME="$TMP/market-state"
# An install in a folder the account also owns, or under a hidden name, is
# refused before anything is written.
for case in owned hidden; do
    CASE="$case" python3 - <<'PY2'
import base64, hashlib, json, os
f = f"{os.environ['FAKE']}/server.json"; state = json.load(open(f))
def entry(text):
    data = text.encode()
    return {"content": base64.b64encode(data).decode(), "sha256": hashlib.sha256(data).hexdigest(), "executable": False}
sid = "44444444-4444-4444-8444-444444444444"
state["market"][sid]["files"] = {"SKILL.md": entry("installed")}
owned = os.environ["CASE"] == "owned"
state["files"] = {"skills/mine/SKILL.md": entry("owned")} if owned else {}
state["installs"] = {sid: "mine" if owned else ".mine"}
json.dump(state, open(f, "w"))
PY2
    out=$(fleet sync 2>&1) && fail "accepted a $case install"
    [[ "$out" == *"owns files in the folder of an installed skill: mine"* || "$case" == hidden ]] \
        || fail "an owned-folder install was not named: $out"
    [[ "$out" == *"install outside"* || "$case" == owned ]] || fail "a hidden install was not refused: $out"
    [[ ! -e "$HOME/.agents/skills/mine" && ! -e "$HOME/.agents/skills/Mine" && ! -e "$HOME/.agents/skills/.mine" ]] \
        || fail "a refused $case install was written"
done
: > "$FAKE/log"
rc=0; fleet install carol/clash --as .hid >/dev/null 2>&1 || rc=$?; [[ $rc == 2 ]] || fail "--as took a hidden name"
grep -q 'skills/install' "$FAKE/log" && fail "a hidden --as name reached Auth"
printf '5' > "$FAKE/subject"; mv "$TMP/market.keep" "$FAKE/server.json"
# An owned skill whose name case-folds to an installed one is not pushed:
# every later listing would refuse the pair.
export HOME="$TMP/market4" XDG_STATE_HOME="$TMP/market4-state"
mkdir -p "$HOME/.claude/skills"
python3 - <<'PY2'
import json, os
f = f"{os.environ['FAKE']}/server.json"; state = json.load(open(f))
json.dump({"counter": 0, "version": 0, "files": {}, "market": state["market"],
           "installs": {"11111111-1111-4111-8111-111111111111": "foo"}}, open(f, "w"))
PY2
server_put AGENTS.md 'fourth'
fleet sync >/dev/null 2>&1 || fail "fourth account join"
[[ -f "$HOME/.agents/skills/foo/SKILL.md" ]] || fail "fourth account's install not written"
mkdir -p "$HOME/.agents/skills/Foo"; printf 'mine\n' > "$HOME/.agents/skills/Foo/SKILL.md"
: > "$FAKE/pushes"
out=$(fleet sync 2>&1) && fail "pushed a skill that case-folds to an install"
[[ "$out" == *"case-insensitive"*"skills/Foo"* ]] || fail "the case-folding skill was not named: $out"
grep -q 'skills/Foo' "$FAKE/pushes" && fail "a skill case-folding to an install reached Auth"
rm -rf "$HOME/.agents/skills/Foo"
# Auth refuses an install named after a folder the account owns.
server_put skills/owned/SKILL.md 'mine'
out=$(fleet install bob/foo --as Owned 2>&1) && fail "installed under a name the account owns"
[[ "$out" == *"your own skills include Owned"* ]] || fail "the owned name was not refused: $out"
[[ "$(python3 -c 'import json,os; print(list(json.load(open(os.environ["FAKE"]+"/server.json"))["installs"].values()))')" == "['foo']" ]] \
    || fail "an install named after an owned folder was stored"
# Installs that cannot be written put the account's files back too, so a
# local edit the account's copy replaced is not lost behind a stale record.
printf 'edited here\n' > "$HOME/.agents/AGENTS.md"
server_put AGENTS.md 'changed there'
python3 - <<'PY2'
import base64, hashlib, json, os
f = f"{os.environ['FAKE']}/server.json"; state = json.load(open(f))
def entry(text):
    data = text.encode()
    return {"content": base64.b64encode(data).decode(), "sha256": hashlib.sha256(data).hexdigest(), "executable": False}
sid = "55555555-5555-4555-8555-555555555555"
state["market"][sid] = {"author": "carol", "folder": "clash2", "published": True, "mine": False,
                        "files": {"SKILL.md": entry("clash"), "x": entry("a file"), "x/y": entry("and a folder")}}
state["installs"][sid] = "clash2"
json.dump(state, open(f, "w"))
PY2
fleet sync --pull >/dev/null 2>&1 && fail "applied installs that cannot be written"
[[ "$(cat "$HOME/.agents/AGENTS.md")" == "edited here" ]] || fail "failed installs left the account's copy over a local edit"

# A pull's own staging folder left by a stopped run goes; one it did not
# make stays.
mkdir -p "$HOME/.agents/.installing-mine" "$HOME/.agents/.installing-stopped"
: > "$HOME/.agents/.installing-mine/keep"; : > "$HOME/.agents/.installing-stopped/half"
printf '.installing-stopped\n' > "$XDG_STATE_HOME/fleet/staging"
fleet sync --pull >/dev/null 2>&1 || true
[[ -e "$HOME/.agents/.installing-mine/keep" ]] || fail "a pull removed a staging-like folder it did not make"
[[ ! -e "$HOME/.agents/.installing-stopped" ]] || fail "a pull left its own stopped staging folder"
rm -rf "$HOME/.agents/.installing-mine"

# An installed folder the disk spells otherwise (HFS+ decomposes accents)
# is still the install, not the account's own files.
mkdir -p "$TMP/nfd"
HOME="$TMP/nfd" python3 - "$ROOT/files/fleet" >/dev/null <<'PY' || fail "an otherwise-spelled installed folder read as the account's own"
import importlib.machinery, importlib.util, json, sys, unicodedata
loader = importlib.machinery.SourceFileLoader("fleet_nfd", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader)); loader.exec_module(m)
name = "caf\u00e9"
folder = m.AGENTS_DIR/"skills"/unicodedata.normalize("NFD", name)
folder.mkdir(parents=True); (folder/"SKILL.md").write_text("x")
m.INSTALLED.write_text(json.dumps({name: {}}))
assert m.scan_local()[0] == {}, m.scan_local()
# Where the disk keeps both spellings apart, the other one is the account's.
(m.AGENTS_DIR/"skills"/name).mkdir(); (m.AGENTS_DIR/"skills"/name/"SKILL.md").write_text("y")
assert list(m.scan_local()[0]) == [f"skills/{folder.name}/SKILL.md"], m.scan_local()
# An install renamed to another spelling is still found edited, and a pull
# replaces it rather than writing a second copy beside it.
import shutil
shutil.rmtree(m.AGENTS_DIR/"skills"/name)
m.INSTALLED.write_text(json.dumps({name: {"id": "i", "server": {}, "local": m._scan_folder(folder)}}))
(folder/"SKILL.md").write_text("edited")
assert m._edited_installs() == [name], m._edited_installs()
m._apply_installs({name: {"id": "i", "server": {"SKILL.md": ["h", False]}}}, [name], [],
                  {name: {"SKILL.md": b"---\nname: x\n---\n"}}, m.Backup())
assert [e.name for e in (m.AGENTS_DIR/"skills").iterdir()] == [name], list((m.AGENTS_DIR/"skills").iterdir())
assert m._edited_installs() == [], m._edited_installs()
PY
rm -rf "$TMP/nfd"

echo "fleet config tests passed"
