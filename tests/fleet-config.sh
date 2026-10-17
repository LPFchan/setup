#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" FLEET_SSH_DIR="$TMP/home/.ssh"
export FLEET_AUTH_BIN="$TMP/auth" FLEET_SELF=grimoire FAKE="$TMP/fake" STATE_DIR="$TMP/state/setup"
export SCHEDULE_USER_DIR="$TMP/units" SCHEDULE_BIN="$TMP/schedule"
mkdir -p "$FLEET_SSH_DIR" "$FAKE" "$STATE_DIR" "$HOME/.claude/skills" "$HOME/.codex/skills"
printf '7' > "$FAKE/subject"
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
    if os.path.exists(f"{fake}/no-session"):
        sys.exit(4)
    print(json.dumps({"origin": origin, "subject": open(f"{fake}/subject").read()}))
    sys.exit(0)
method, path = sys.argv[2], sys.argv[3]
body = json.load(sys.stdin) if sys.argv[4:] == ["-"] else None
open(f"{fake}/log", "a").write(f"{method} {path}\n")
if os.path.exists(f"{fake}/down"):
    sys.exit(1)
if path == "/api/fleet/config/fetch" and os.path.exists(f"{fake}/fetch-down"):
    sys.exit(1)
if path == "/api/fleet/config" and os.path.exists(f"{fake}/config-down"):
    sys.exit(1)
state = load()
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
        if os.path.exists(f"{fake}/edit-as-link"):
            os.remove(f"{fake}/edit-as-link"); os.remove(target); os.symlink("/dev/null", target)
        elif os.path.exists(f"{fake}/edit-as-delete"):
            os.remove(f"{fake}/edit-as-delete"); os.remove(target)
        else:
            open(target, "w").write("saved later\n")
    if os.path.exists(f"{fake}/switch-on-fetch"):
        # Another account signed in while the files were coming down.
        os.remove(f"{fake}/switch-on-fetch")
        open(f"{fake}/subject", "w").write("9")
    paths = body["paths"]
    # One file per answer, so callers must follow `remaining`.
    first = [p for p in paths if p in state["files"]][:1]
    if os.path.exists(f"{fake}/fetch-short"):
        # Claims to be done without sending what was asked for.
        os.remove(f"{fake}/fetch-short")
        answer(200, {"counter": state["counter"], "version": state["version"],
                     "files": [], "remaining": [], "missing": []})
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
# So does it when that record cannot be read.
chmod 000 "$STATE_DIR/script-state.tsv"; : > "$FAKE/log"
fleet sync >/dev/null 2>&1 || fail "sync with an unreadable setup state"
chmod 600 "$STATE_DIR/script-state.tsv"
grep -q '/api/fleet/config' "$FAKE/log" && fail "config touched with an unreadable setup state"

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
# So does a link there to the harness folder, put back by a failed one.
ln -s "$HOME/.codex/skills/both" "$HOME/.agents/skills/both"
touch "$FAKE/limited"
fleet onboard >/dev/null 2>&1 && fail "onboard read a refused upload as success"
rm "$FAKE/limited"
[[ "$(readlink "$HOME/.agents/skills/both")" == "$HOME/.codex/skills/both" ]] \
    || fail "a failed onboarding kept a copy where a link to a harness skill was"
rm "$HOME/.agents/skills/both"
# A copy that fails partway comes out with everything else it staged.
printf 'locked\n' > "$HOME/.codex/skills/both/locked.md"; chmod 000 "$HOME/.codex/skills/both/locked.md"
fleet onboard >/dev/null 2>&1 && fail "onboard read a failed copy as success"
rm -f "$HOME/.codex/skills/both/locked.md"
[[ ! -e "$HOME/.agents/AGENTS.md" && ! -e "$HOME/.agents/skills/claude-only" && ! -e "$HOME/.agents/skills/both" ]] \
    || fail "a failed staging kept what it copied into ~/.agents"
# An unreadable harness skill folder or instructions file fails onboarding,
# which would otherwise record the account without them.
chmod 000 "$HOME/.codex/skills"
rc=0; out=$(fleet onboard 2>&1) || rc=$?
chmod 700 "$HOME/.codex/skills"
[[ $rc != 0 && "$out" == *"cannot read"*".codex/skills"* ]] || fail "onboarded past an unreadable skill folder: $out"
chmod 000 "$HOME/.claude/CLAUDE.md"
rc=0; out=$(fleet onboard 2>&1) || rc=$?
chmod 600 "$HOME/.claude/CLAUDE.md"
[[ $rc != 0 && "$out" == *"cannot read"*"CLAUDE.md"* ]] || fail "onboarded past unreadable instructions: $out"
# So does an unreadable folder inside a harness skill that matches one in
# ~/.agents everywhere else.
cp -r "$HOME/.agents/skills/mine" "$HOME/.codex/skills/mine"; mkdir "$HOME/.codex/skills/mine/sub"
chmod 000 "$HOME/.codex/skills/mine/sub"
rc=0; out=$(fleet onboard 2>&1) || rc=$?
chmod 700 "$HOME/.codex/skills/mine/sub" 2>/dev/null || true; rm -rf "$HOME/.codex/skills/mine"
[[ $rc != 0 && "$out" == *"cannot read"*"mine/sub"* ]] || fail "onboarded past an unreadable skill subfolder: $out"
[[ ! -f "$FAKE/pushes" && ! -e "$XDG_STATE_HOME/fleet/config.json" ]] || fail "an unreadable source still uploaded"
# A harness skill folder that cannot move puts back the ones already moved,
# and no record is saved, so the next sync joins the account and moves them.
chmod 500 "$HOME/.codex/skills"
fleet onboard >/dev/null 2>&1 && fail "onboard read a failed skill move as success"
chmod 700 "$HOME/.codex/skills"
[[ -d "$HOME/.claude/skills/claude-only" && ! -L "$HOME/.claude/skills/claude-only" ]] \
    || fail "a failed move left an earlier skill folder in the backup"
[[ ! -e "$XDG_STATE_HOME/fleet/config.json" ]] || fail "a failed move saved the record"
# One with a link inside is left out whole: the link would not upload, and
# a relative one leads elsewhere once the folder moves.
mkdir -p "$HOME/.codex/skills/haslink"; printf 'has a link\n' > "$HOME/.codex/skills/haslink/SKILL.md"
ln -s ../shared "$HOME/.codex/skills/haslink/res"
# So does a record that cannot be saved after the upload.
printf '{"counter":0,"version":0,"files":{}}' > "$FAKE/server.json"
# A link in ~/.agents to a harness skill folder about to move becomes a copy,
# uploaded, instead of a link left dangling. (The failed move left a copy.)
rm -r "$HOME/.agents/skills/both"; ln -s "$HOME/.codex/skills/both" "$HOME/.agents/skills/both"
chmod 500 "$XDG_STATE_HOME/fleet"
fleet onboard >/dev/null 2>&1 && fail "onboard read an unsaved record as success"
chmod 700 "$XDG_STATE_HOME/fleet"
[[ -d "$HOME/.agents/skills/both" && ! -L "$HOME/.agents/skills/both" && "$(server_has skills/both/SKILL.md)" == "codex skill" ]] \
    || fail "a link to a harness skill folder was not uploaded as a copy"
[[ -d "$HOME/.claude/skills/claude-only" && ! -L "$HOME/.claude/skills/claude-only" && -d "$HOME/.codex/skills/both" ]] \
    || fail "an unsaved onboarding record left the skill folders in the backup"
# A harness skill whose SKILL.md is a link stays where it is.
mkdir "$HOME/.codex/skills/linked"; printf 'linked\n' > "$TMP/linked.md"
ln -s "$TMP/linked.md" "$HOME/.codex/skills/linked/SKILL.md"
fleet sync >/dev/null 2>&1 || fail "sync after a failed onboarding move"
[[ ! -e "$HOME/.agents/skills/haslink" && "$(server_has skills/haslink/SKILL.md)" == "<none>" ]] \
    || fail "a harness skill with a link inside was staged"
[[ -L "$HOME/.codex/skills/linked/SKILL.md" && "$(server_has skills/linked/SKILL.md)" == "<none>" ]] \
    || fail "a harness skill with a linked SKILL.md was moved"
rm -r "$HOME/.codex/skills/linked"
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
# A harness folder that is ~/.agents by another name keeps AGENTS.md a file.
mkdir -p "$HOME/.config"; ln -s "$HOME/.agents" "$HOME/.config/opencode"
fleet sync >/dev/null 2>&1 || fail "sync with a harness folder aliasing ~/.agents"
rm "$HOME/.config/opencode"
[[ -f "$HOME/.agents/AGENTS.md" && ! -L "$HOME/.agents/AGENTS.md" && "$(cat "$HOME/.agents/AGENTS.md")" == "my instructions" ]] \
    || fail "a harness folder aliasing ~/.agents replaced AGENTS.md"
# So does one that is a folder inside it.
mkdir -p "$HOME/.agents/settings"; printf 'synced\n' > "$HOME/.agents/settings/AGENTS.md"
ln -s "$HOME/.agents/settings" "$HOME/.config/opencode"
fleet sync >/dev/null 2>&1 || fail "sync with a harness folder inside ~/.agents"
rm "$HOME/.config/opencode"
[[ ! -L "$HOME/.agents/settings/AGENTS.md" && "$(cat "$HOME/.agents/settings/AGENTS.md")" == "synced" ]] \
    || fail "a harness folder inside ~/.agents had a file replaced by a link"
rm -rf "$HOME/.agents/settings"; fleet sync >/dev/null 2>&1 || fail "sync after removing settings"
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
# So does a file where the skills folder was.
mv "$HOME/.agents/skills" "$TMP/skills.away"; printf 'x\n' > "$HOME/.agents/skills"
rc=0; out=$(fleet sync 2>&1) || rc=$?
rm "$HOME/.agents/skills"; mv "$TMP/skills.away" "$HOME/.agents/skills"
[[ $rc != 0 && "$out" == *"Not a directory"* ]] || fail "synced with a file for the skills folder: $out"
[[ "$(server_has skills/mine/SKILL.md)" == "edited" ]] || fail "a file for the skills folder was uploaded as deletions"
# A damaged sync record fails the sync instead of reading as a first join.
cp "$XDG_STATE_HOME/fleet/config.json" "$TMP/record.keep"; printf '{' > "$XDG_STATE_HOME/fleet/config.json"
rc=0; out=$(fleet sync 2>&1) || rc=$?
mv "$TMP/record.keep" "$XDG_STATE_HOME/fleet/config.json"
[[ $rc != 0 && "$out" == *"move it aside"* ]] || fail "synced over a damaged record: $out"
# So does one whose fields are the wrong shape: an empty file map would
# read as nothing synced yet.
for files in '[]' '{"AGENTS.md": [null, false]}' '{"AGENTS.md": ["abc", false]}'; do
    cp "$XDG_STATE_HOME/fleet/config.json" "$TMP/record.keep"
    python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); r["files"]=json.loads(sys.argv[2]); json.dump(r, open(sys.argv[1], "w"))' \
        "$XDG_STATE_HOME/fleet/config.json" "$files"
    rc=0; out=$(fleet sync 2>&1) || rc=$?
    mv "$TMP/record.keep" "$XDG_STATE_HOME/fleet/config.json"
    [[ $rc != 0 && "$out" == *"is damaged"* ]] || fail "synced over a record with files $files: $out"
done
# An account _context() never gives would read as another account's.
cp "$XDG_STATE_HOME/fleet/config.json" "$TMP/record.keep"
python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); r["account"]="invalid"; json.dump(r, open(sys.argv[1], "w"))' \
    "$XDG_STATE_HOME/fleet/config.json"
rc=0; out=$(fleet sync 2>&1) || rc=$?
mv "$TMP/record.keep" "$XDG_STATE_HOME/fleet/config.json"
[[ $rc != 0 && "$out" == *"is damaged"* ]] || fail "synced over a record of account \"invalid\": $out"
# So does a folder where a synced file was, or a pipe in a skill folder.
for odd in 'mkdir "$HOME/.agents/AGENTS.md"' 'mkfifo "$HOME/.agents/skills/mine/SKILL.md"'; do
    f=$(eval "echo ${odd#* }"); mv "$f" "$TMP/odd.keep"; eval "$odd"
    rc=0; out=$(fleet sync 2>&1) || rc=$?
    status=$(fleet status 2>&1) || status="failed: $status"
    rm -rf "$f"; mv "$TMP/odd.keep" "$f"
    [[ $rc != 0 && "$out" == *"is not a regular file"* ]] || fail "synced past $odd: $out"
    [[ "$status" == *"account config: "*"is not a regular file"* ]] || fail "status past $odd: $status"
done
# A file where ~/.agents was stops the sync rather than reading as empty.
mv "$HOME/.agents" "$TMP/agents.away"; printf 'x\n' > "$HOME/.agents"
rc=0; out=$(fleet sync 2>&1) || rc=$?
rm "$HOME/.agents"; mv "$TMP/agents.away" "$HOME/.agents"
[[ $rc != 0 && "$out" == *"is not a folder"* ]] || fail "synced with a file for ~/.agents: $out"
[[ "$(server_has skills/mine/SKILL.md)" == "edited" ]] || fail "a file for ~/.agents was uploaded as deletions"
# A file saved again after the scan, which the account then replaces, is a
# conflict too, its edit in the backup.
server_put skills/mine/SKILL.md 'from account'
printf '%s' "$HOME/.agents/skills/mine/SKILL.md" > "$FAKE/edit-on-fetch"
out=$(fleet sync --pull 2>&1) || true
[[ "$(cat "$HOME/.agents/skills/mine/SKILL.md")" == "from account" ]] || fail "the account's copy not taken over a late save"
[[ "$out" == *"changed here and in the account"*"skills/mine/SKILL.md"* ]] || fail "a late save replaced silently: $out"
grep -rlx 'saved later' "$XDG_STATE_HOME/fleet/backup" | grep -q 'skills/mine/SKILL.md' || fail "a late save not in the backup"
# So is a link put in its place.
server_put skills/mine/SKILL.md 'from account again'
printf '%s' "$HOME/.agents/skills/mine/SKILL.md" > "$FAKE/edit-on-fetch"; touch "$FAKE/edit-as-link"
out=$(fleet sync --pull 2>&1) || true
[[ ! -L "$HOME/.agents/skills/mine/SKILL.md" && "$(cat "$HOME/.agents/skills/mine/SKILL.md")" == "from account again" ]] \
    || fail "the account's copy not taken over a late link"
[[ "$out" == *"changed here and in the account"*"skills/mine/SKILL.md"* ]] || fail "a late link replaced silently: $out"
# And so is a deletion.
server_put skills/mine/SKILL.md 'from account once more'
printf '%s' "$HOME/.agents/skills/mine/SKILL.md" > "$FAKE/edit-on-fetch"; touch "$FAKE/edit-as-delete"
out=$(fleet sync --pull 2>&1) || true
[[ "$out" == *"deleted here during the sync"*"skills/mine/SKILL.md"* ]] || fail "a late deletion undone silently: $out"
[[ "$out" != *"yours are in"*"skills/mine/SKILL.md"* ]] || fail "a late deletion reported as backed up: $out"
# A file saved again during the sync is recorded as the version it sent.
printf 'scanned\n' > "$HOME/.agents/skills/mine/SKILL.md"
printf '%s' "$HOME/.agents/skills/mine/SKILL.md" > "$FAKE/edit-on-fetch"
fleet sync >/dev/null 2>&1 || fail "sync with a save during it"
[[ "$(server_has skills/mine/SKILL.md)" == "saved later" ]] || fail "sent '$(server_has skills/mine/SKILL.md)'"
fleet status | grep -q 'local changes wait' && fail "the version sent was recorded as another"
# One deleted at the scan but back before the push is uploaded, not deleted.
rm "$HOME/.agents/skills/mine/SKILL.md"
printf '%s' "$HOME/.agents/skills/mine/SKILL.md" > "$FAKE/edit-on-fetch"
fleet sync >/dev/null 2>&1 || fail "sync with a file back during it"
[[ "$(server_has skills/mine/SKILL.md)" == "saved later" ]] || fail "a file back before the push was deleted"
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
# A user's link that only passes through ~/.agents by name is not fleet's.
mv "$HOME/.claude/CLAUDE.md" "$TMP/claude.keep"; printf 'theirs\n' > "$HOME/instructions"
ln -s "$HOME/.agents/../instructions" "$HOME/.claude/CLAUDE.md"
fleet sync --pull >/dev/null 2>&1 || fail "pull with a link through ~/.agents/.."
[[ "$(readlink "$HOME/.claude/CLAUDE.md")" == "$HOME/.agents/../instructions" ]] || fail "took a user's link through .. as fleet's"
rm "$HOME/.claude/CLAUDE.md" "$HOME/instructions"; mv "$TMP/claude.keep" "$HOME/.claude/CLAUDE.md"
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
# An old skill folder that is itself a link is shared: its entries stay.
mkdir -p "$HOME/.config/muse" "$TMP/muse-shared"; ln -s "$HOME/.agents/skills/mine" "$TMP/muse-shared/mine"
ln -s "$TMP/muse-shared" "$HOME/.config/muse/skills"
fleet sync --pull >/dev/null 2>&1 || fail "pull with a linked old skill folder"
[[ -L "$TMP/muse-shared/mine" ]] || fail "removed a link inside a shared old skill folder"
rm -rf "$HOME/.config/muse" "$TMP/muse-shared"

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
fleet sync --check >/dev/null 2>&1 || fail "check after a pull read as outdated"
# An account config Auth did not answer for is unknown, not current.
touch "$FAKE/config-down"
rc=0; fleet sync --check >/dev/null 2>&1 || rc=$?
rm "$FAKE/config-down"
[[ $rc == 3 ]] || fail "check read an unanswered account config as $rc, not unknown"
# So is one with no session to ask with.
touch "$FAKE/no-session"
rc=0; fleet sync --check >/dev/null 2>&1 || rc=$?
[[ $rc == 3 ]] || fail "check without a session read as $rc, not unknown"
# Also when SSH blocks are told some other way.
python3 - "$ROOT/files/fleet" <<'PY' || fail "a config check without a session read as known"
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("fleet_nosession", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader)); loader.exec_module(m)
assert m.config_outdated() is None
PY
rm "$FAKE/no-session"
# A fetch that leaves out a file it was asked for is refused.
prev=$(cat "$HOME/.agents/skills/mine/SKILL.md")
server_put skills/mine/SKILL.md 'short fetch'
touch "$FAKE/fetch-short"
rc=0; out=$(fleet sync --pull 2>&1) || rc=$?
rm -f "$FAKE/fetch-short"
[[ $rc != 0 && "$out" == *"left out requested files"* && "$out" != *Traceback* ]] || fail "took a short fetch: $out"
fleet sync --pull >/dev/null 2>&1 || fail "pull after a short fetch"
[[ "$(cat "$HOME/.agents/skills/mine/SKILL.md")" == "short fetch" ]] || fail "short fetch not retried"
server_put skills/mine/SKILL.md "$prev"; fleet sync --pull >/dev/null 2>&1 || fail "pull back after a short fetch"
# A name that is not UTF-8 is skipped, not a crash.
touch "$HOME/.agents/skills/mine/"$'\xff'
rc=0; out=$(fleet sync 2>&1) || rc=$?
rm -f "$HOME/.agents/skills/mine/"$'\xff'
[[ "$out" != *Traceback* ]] || fail "a non-UTF-8 name crashed the sync: $out"
# A damaged sync record reads as outdated, so the sync that follows says so.
cp "$XDG_STATE_HOME/fleet/config.json" "$TMP/config.keep"
python3 -c 'import json,sys; p=sys.argv[1]; r=json.load(open(p)); r["files"]=[]; json.dump(r,open(p,"w"))' "$XDG_STATE_HOME/fleet/config.json"
fleet sync --check >/dev/null 2>&1 && fail "check read a damaged sync record as current"
mv "$TMP/config.keep" "$XDG_STATE_HOME/fleet/config.json"
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
grep -q "symlinks are not uploaded: skills/mine/linked" "$TMP/out" || fail "symlink not listed: $(cat "$TMP/out")"
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
# So is a ~/.agents that is not a folder, by onboarding too.
FOURTH="$TMP/fourth"; mkdir -p "$FOURTH"; : > "$FOURTH/.agents"
rc=0; HOME="$FOURTH" XDG_STATE_HOME="$TMP/state4" fleet onboard >"$TMP/out" 2>&1 || rc=$?
[[ $rc == 1 ]] && grep -q 'is not a folder' "$TMP/out" || fail "onboarding into a file ~/.agents exited $rc"
[[ ! -e "$TMP/state4/fleet/config.json" ]] || fail "onboarding into a file ~/.agents saved a record"

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
# Nor does a missing schedule helper stop the pull.
mkdir -p "$SCHEDULE_USER_DIR"
printf 'ExecStart=%%h/.local/bin/fleet sync\n' > "$SCHEDULE_USER_DIR/fleet-sync.service"
printf 'OnCalendar=*-*-* 04:00:00\n' > "$SCHEDULE_USER_DIR/fleet-sync.timer"
prev=$(cat "$HOME/.agents/skills/mine/SKILL.md")
server_put skills/mine/SKILL.md 'pulled past the helper'
rc=0; SCHEDULE_BIN="$TMP/no-schedule" fleet sync >"$TMP/out" 2>&1 || rc=$?
[[ $rc == 1 ]] && grep -q 'schedule helper not found' "$TMP/out" || fail "a missing schedule helper exited $rc"
[[ "$(cat "$HOME/.agents/skills/mine/SKILL.md")" == "pulled past the helper" ]] || fail "a missing schedule helper skipped the pull"
rm -f "$SCHEDULE_USER_DIR"/fleet-sync.*
server_put skills/mine/SKILL.md "$prev"; fleet sync --pull >/dev/null 2>&1 || fail "pull back after the helper test"
# One that cannot be read is taken as that old timer too.
mkdir -p "$SCHEDULE_USER_DIR"
printf 'ExecStart=%%h/.local/bin/fleet schedule run\n' > "$SCHEDULE_USER_DIR/fleet-sync.service"
printf 'OnCalendar=*-*-* 04:00:00\n' > "$SCHEDULE_USER_DIR/fleet-sync.timer"
chmod 000 "$SCHEDULE_USER_DIR/fleet-sync.service"
printf 'unsent\n' > "$HOME/.agents/skills/mine/unsent"
fleet sync >/dev/null 2>&1 || true
[[ "$(server_has skills/mine/unsent)" == "<none>" ]] || fail "uploaded past a timer it could not read"
chmod 644 "$SCHEDULE_USER_DIR/fleet-sync.service"
rm -f "$HOME/.agents/skills/mine/unsent" "$SCHEDULE_USER_DIR"/fleet-sync.*
# So is half of one.
mkdir -p "$SCHEDULE_USER_DIR"
printf 'OnCalendar=*-*-* 04:00:00\n' > "$SCHEDULE_USER_DIR/fleet-sync.timer"
printf 'unsent\n' > "$HOME/.agents/skills/mine/unsent"
fleet sync >"$TMP/out" 2>&1 || true
grep -q 'could not replace the nightly timer' "$TMP/out" || fail "half a timer not replaced"
[[ "$(server_has skills/mine/unsent)" == "<none>" ]] || fail "uploaded past half a timer"
rm -f "$HOME/.agents/skills/mine/unsent" "$SCHEDULE_USER_DIR"/fleet-sync.*
# A file turned into a link after the scan is not read through it.
python3 - "$ROOT/files/fleet" "$TMP" <<'PY' || fail "pushed through a link swapped in after the scan"
import importlib.machinery, importlib.util, pathlib, sys
loader = importlib.machinery.SourceFileLoader("fleet_swap", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader)); loader.exec_module(m)
secret = pathlib.Path(sys.argv[2])/"secret"; secret.write_text("not fleet's\n")
swapped = m.AGENTS_DIR/"skills/mine/swapped"; swapped.symlink_to(secret)
try:
    m.push({"account": "o s"}, {}, {"skills/mine/swapped"}, [])
except m.ConfigError as exc:
    assert "became a link" in str(exc), exc
else:
    raise SystemExit("pushed")
finally:
    swapped.unlink(); secret.unlink()
PY

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
# So does a skill folder that cannot be looked into, rather than being left
# behind as if it held no skill.
printf '{"counter":0,"version":0,"files":{}}' > "$FAKE/server.json"
server_put skills/theirs/SKILL.md 'theirs'
mkdir -p "$HOME/.claude/skills/handmade"; printf 'mine\n' > "$HOME/.claude/skills/handmade/SKILL.md"
chmod 000 "$HOME/.claude/skills/handmade"
out=$(fleet sync 2>&1) && fail "switched accounts past a skill folder it could not read"
chmod 700 "$HOME/.claude/skills/handmade"
grep -q "cannot read .*handmade" <<<"$out" || fail "an unreadable skill folder was not named: $out"
[[ -e "$HOME/.agents/skills/mine" && ! -e "$HOME/.agents/skills/theirs" ]] \
    || fail "an unreadable skill folder left the other account's files"
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
# A switch that cannot be written down puts the other account's files and
# links back.
chmod 500 "$XDG_STATE_HOME/fleet"
out=$(fleet sync 2>&1) && fail "switched accounts without writing the switch down"
chmod 700 "$XDG_STATE_HOME/fleet"
# A link that displaced a file cannot be put back without its record, and
# the failure says so.
grep -q "links could not be put back" <<<"$out" || fail "an unwritten switch hid the links it could not put back: $out"
[[ -e "$HOME/.agents/skills/mine" && -e "$HOME/.claude/skills/mine/SKILL.md" ]] \
    || fail "an unwritten switch left the other account's files or links out"
grep -q '"account": "https://auth.lost.plus 7"' "$XDG_STATE_HOME/fleet/config.json" || fail "an unwritten switch dropped the old record"
[[ ! -e "$XDG_STATE_HOME/fleet/onboarding.pending" ]] || fail "an unwritten switch left onboarding pending"
# Links that cannot be cleared yet are cleared by the next sync.
chmod 500 "$HOME/.claude/skills"
fleet sync >/dev/null 2>&1 && fail "sync read uncleared links as done"
chmod 700 "$HOME/.claude/skills"
[[ -e "$HOME/.agents/skills/mine" ]] || fail "uncleared links left the other account's files moved away"
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
mkdir -p "$HOME/.config/opencode"; rm -f "$HOME/.config/opencode/AGENTS.md"
printf 'opencode mine\n' > "$HOME/.config/opencode/AGENTS.md"
mkdir "$TMP/nosave"; cat > "$TMP/nosave/sitecustomize.py" <<'PY'
import os
real = os.replace
def replace(src, dst, *a, **k):
    if str(dst).endswith("links.json"):
        raise OSError(28, "No space left on device")
    return real(src, dst, *a, **k)
os.replace = replace
PY
rc=0; PYTHONPATH="$TMP/nosave" fleet sync >/dev/null 2>&1 || rc=$?
rm -rf "$TMP/nosave"
[[ $rc != 0 ]] || fail "a sync whose links record could not be saved reported success"
rm -f "$XDG_STATE_HOME"/fleet/.links.json.*
[[ ! -L "$HOME/.config/opencode/AGENTS.md" && "$(cat "$HOME/.config/opencode/AGENTS.md")" == "opencode mine" ]] \
    || fail "an unrecorded link kept what it displaced"
rm -f "$HOME/.config/opencode/AGENTS.md"
# A damaged links record stops the sync instead of forgetting what the
# links displaced.
cp "$XDG_STATE_HOME/fleet/links.json" "$TMP/links.keep"; printf '{"x": 1}' > "$XDG_STATE_HOME/fleet/links.json"
rc=0; out=$(fleet sync 2>&1) || rc=$?
[[ $rc != 0 && "$out" == *"is damaged"* && "$(cat "$XDG_STATE_HOME/fleet/links.json")" == '{"x": 1}' ]] \
    || fail "synced over a damaged links record: $out"
mv "$TMP/links.keep" "$XDG_STATE_HOME/fleet/links.json"
# Restoring moves a record's file onto its link, so one naming anything
# but fleet's links, or anything but that link's own backup, is damaged too.
for entry in "\"$HOME/.bashrc\": \"$XDG_STATE_HOME/fleet/backup/x\"" \
             "\"$HOME/.claude/CLAUDE.md\": \"$TMP/elsewhere\"" \
             "\"$HOME/.claude/CLAUDE.md\": \"$XDG_STATE_HOME/fleet/backup/../../x\"" \
             "\"$HOME/.claude/CLAUDE.md\": \"$XDG_STATE_HOME/fleet/backup\"" \
             "\"$HOME/.claude/CLAUDE.md\": \"$XDG_STATE_HOME/fleet/backup/20261017-000000/displaced/.gemini/CLAUDE.md\"" \
             "\"$HOME/.claude/skills/a\": \"$XDG_STATE_HOME/fleet/backup/20261017-000000/displaced/.claude/skills/b\"" \
             "\"$HOME/.claude/skills/a\": \"$XDG_STATE_HOME/fleet/backup/x/displaced/.claude/skills/a\""; do
    cp "$XDG_STATE_HOME/fleet/links.json" "$TMP/links.keep"; printf '{%s}' "$entry" > "$XDG_STATE_HOME/fleet/links.json"
    rc=0; out=$(fleet sync 2>&1) || rc=$?
    [[ $rc != 0 && "$out" == *"is damaged"* ]] || fail "read a links record of {$entry}: $out"
    mv "$TMP/links.keep" "$XDG_STATE_HOME/fleet/links.json"
done
# A linked claude skill folder is left alone: linking through it would move
# what it leads to, here ~/.agents/skills itself, into the backup.
mv "$HOME/.claude/skills" "$TMP/claude-skills"; ln -s "$HOME/.agents/skills" "$HOME/.claude/skills"
before=$(cd "$HOME/.agents/skills" && find . | sort)
out=$(fleet sync 2>&1) || fail "sync with a linked claude skill folder: $out"
[[ "$out" == *"is a link"* && "$(cd "$HOME/.agents/skills" && find . | sort)" == "$before" ]] \
    || fail "linked skills through a linked claude skill folder: $out"
fleet __unlink >/dev/null 2>&1 || fail "unlink with a linked claude skill folder"
[[ "$(cd "$HOME/.agents/skills" && find . | sort)" == "$before" ]] || fail "unlinked through a linked claude skill folder"
# Nor is a link into ~/.agents that the folder it leads to holds dropped.
mkdir "$TMP/shared"; ln -s "$HOME/.agents/skills/mine" "$TMP/shared/mine"
rm "$HOME/.claude/skills"; ln -s "$TMP/shared" "$HOME/.claude/skills"
fleet __unlink >/dev/null 2>&1 || fail "unlink with a shared claude skill folder"
[[ -L "$TMP/shared/mine" ]] || fail "unlinked a link in a shared claude skill folder"
rm "$HOME/.claude/skills"; ln -s "$HOME/.agents/skills" "$HOME/.claude/skills"; rm -r "$TMP/shared"
python3 - "$ROOT/files/fleet" "$HOME/.claude/skills" "$TMP" <<'PY' || fail "onboarding gathers skills through a linked harness folder"
import importlib.machinery, importlib.util, pathlib, sys
loader = importlib.machinery.SourceFileLoader("fleet_test", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
assert m._skill_folders(pathlib.Path(sys.argv[2])) == []
# A codex folder linked to ~/.agents gathers nothing from ~/.agents/skills.
codex = pathlib.Path(sys.argv[3])/"codex-alias"
codex.symlink_to(m.AGENTS_DIR)
try:
    assert m._skill_folders(codex/"skills") == []
finally:
    codex.unlink()
PY
rm "$HOME/.claude/skills"; mv "$TMP/claude-skills" "$HOME/.claude/skills"
fleet sync >/dev/null 2>&1 || fail "sync after the claude skill folder came back"
# A claude folder that is ~/.agents itself leads its skill folder there too.
mv "$HOME/.claude" "$TMP/claude-dir"; ln -s "$HOME/.agents" "$HOME/.claude"
before=$(cd "$HOME/.agents" && find . | sort)
out=$(fleet sync 2>&1)
[[ "$out" == *"is inside"* && "$(cd "$HOME/.agents" && find . | sort)" == "$before" ]] \
    || fail "linked skills into ~/.agents through a linked claude folder: $out"
rm "$HOME/.claude"; mv "$TMP/claude-dir" "$HOME/.claude"
fleet sync >/dev/null 2>&1 || fail "sync after the claude folder came back"

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
# A link the user has since replaced keeps the way back to what it displaced.
rm "$HOME/.claude/CLAUDE.md"; printf 'replaced\n' > "$HOME/.claude/CLAUDE.md"
fleet __unlink >/dev/null 2>&1 && fail "uninstall passed a displaced file it could not put back"
grep -q CLAUDE.md "$XDG_STATE_HOME/fleet/links.json" || fail "uninstall dropped the way back to a displaced file"
rm "$HOME/.claude/CLAUDE.md"
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

# Onboarding compares a colliding skill's links too, not only its files.
mkdir -p "$TMP/tree-a" "$TMP/tree-b"
printf 'same\n' | tee "$TMP/tree-a/SKILL.md" > "$TMP/tree-b/SKILL.md"
ln -s /etc/hostname "$TMP/tree-a/extra"
ln -s /etc "$TMP/tree-a/extra-dir"
python3 -c '
import importlib.machinery, importlib.util, os, sys
loader = importlib.machinery.SourceFileLoader("fleet_tree", sys.argv[1])
fleet = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(fleet)
a, b = map(fleet.pathlib.Path, sys.argv[2:])
assert not fleet._same_tree(a, b), "an extra file link"
os.symlink("/etc/hostname", b/"extra")
assert not fleet._same_tree(a, b), "an extra folder link"
os.symlink("/etc", b/"extra-dir")
assert fleet._same_tree(a, b), "the same links"' "$ROOT/files/fleet" "$TMP/tree-a" "$TMP/tree-b" \
    || fail "onboarding read skill trees with different links as the same"

echo "fleet config tests passed"
