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
if cmd == "context":
    print(json.dumps({"origin": "https://auth.lost.plus", "subject": open(f"{fake}/subject").read()}))
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
fleet onboard >/dev/null 2>&1 || fail "onboard"
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
cp "$XDG_STATE_HOME/fleet/config.json" "$TMP/record"

# Signing in to another account between pull and push uploads nothing.
printf 'meant for 7\n' > "$HOME/.agents/skills/mine/SKILL.md"
touch "$FAKE/switch"
fleet sync >"$TMP/out" 2>&1 && fail "pushed after the account changed"
grep -q 'session changed' "$TMP/out" || fail "account change not reported: $(cat "$TMP/out")"
[[ "$(server_has skills/mine/SKILL.md)" == "edited" ]] || fail "a push landed for the wrong account"
printf '7' > "$FAKE/subject"
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
printf '{"counter":0,"version":0,"files":{}}' > "$FAKE/server.json"
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
[[ -d "$HOME/.claude/skills/old.pre-agents.bak" ]] || fail "an old agents sidecar was taken for a skill"
rm -rf "$HOME/.claude/skills/old.pre-agents.bak"

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
fleet sync --pull >/dev/null 2>&1 || fail "pull after the skill folder came back"
rm -rf "$HOME/.claude/skills"
fleet __unlink
[[ "$(cat "$HOME/.claude/skills/shadow/SKILL.md")" == "hand-made" ]] || fail "uninstall stranded a displaced skill"
[[ ! -L "$HOME/.claude/CLAUDE.md" && "$(cat "$HOME/.claude/CLAUDE.md")" == "mine, late" ]] || fail "CLAUDE.md not restored"
[[ ! -L "$HOME/.claude/skills/mine" ]] || fail "skill link kept"

echo "fleet config tests passed"
