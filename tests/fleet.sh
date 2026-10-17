#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# Only the system basics: never a real harness.
export PATH="$(dirname "$(command -v python3)"):$(dirname "$(command -v zsh)"):/usr/bin:/bin"
export HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" FLEET_SSH_DIR="$TMP/home/.ssh"
export FLEET_AUTH_BIN="$TMP/auth" FLEET_SELF=grimoire FAKE="$TMP/fake"
export SETUP_OWNER_KEYS_URL="file://$TMP/github.keys"
mkdir -p "$FLEET_SSH_DIR" "$FAKE"
printf 'ssh-ed25519 AAAAOwner owner\n' > "$TMP/github.keys"
# These cases cover the SSH blocks; a recorded agents module keeps fleet to
# them (tests/fleet-config.sh covers the account config).
export STATE_DIR="$TMP/state/setup"
mkdir -p "$STATE_DIR"; printf 'agents\tclone\ta\tb\n' > "$STATE_DIR/script-state.tsv"

# A stand-in auth CLI: `request` prints $FAKE/fleet.json and exits $FAKE/rc,
# `context` names $FAKE/subject.
cat > "$FLEET_AUTH_BIN" <<'SH'
#!/bin/sh
case "$1" in
    refresh) exit 0 ;;
    context) printf '{"origin":"https://auth.lost.plus","subject":"%s"}\n' "$(cat "$FAKE/subject")" ;;
    request) cat "$FAKE/fleet.json"; exit "$(cat "$FAKE/rc")" ;;
esac
SH
chmod +x "$FLEET_AUTH_BIN"
fleet() { python3 "$ROOT/files/fleet" "$@"; }
serve() { printf '%s' "$1" > "$FAKE/fleet.json"; printf '%s' "${2:-0}" > "$FAKE/rc"; printf '%s' "${3:-7}" > "$FAKE/subject"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

FLEET_JSON='{"version":"v1","self":{"key":"ssh-ed25519 AAAASelf","served":true,"key_mismatch":false,"alias":"grimoire"},
"keys":["ssh-ed25519 AAAASelf","ssh-ed25519 AAAAPeer"],
"hosts":[{"alias":"grimoire","address":"grimoire.ts.net","user":"fox","term_fallback":false},
{"alias":"bingus","address":"bingus.lan","user":"fox","term_fallback":true},
{"alias":"evil","address":"x\nProxyCommand sh","user":"fox","term_fallback":false}]}'

# A friend's machine writes only its fleet: itself left out, the TERM
# fallback kept, a host with an unsafe field dropped.
cat > "$FLEET_SSH_DIR/config" <<'CFG'
Host mine
    User me

# >>> setup:ssh-aliases >>>
# old
# <<< setup:ssh-aliases <<<
CFG
printf 'ssh-ed25519 AAAAHand hand\n\n# >>> setup:ssh-aliases-github-keys >>>\nold\n# <<< setup:ssh-aliases-github-keys <<<\n' > "$FLEET_SSH_DIR/authorized_keys"
serve "$FLEET_JSON"
fleet sync --check 2>/dev/null && fail "check passed before the first write"
fleet sync >/dev/null 2>"$TMP/err"
grep -q 'Host bingus bingus.lan' "$FLEET_SSH_DIR/config" || fail "bingus missing"
grep -q 'SetEnv TERM=xterm-256color' "$FLEET_SSH_DIR/config" || fail "TERM fallback missing"
grep -q 'Host grimoire' "$FLEET_SSH_DIR/config" && fail "own alias written"
grep -q 'ProxyCommand' "$FLEET_SSH_DIR/config" && fail "unsafe host written"
grep -q 'ssh-aliases' "$FLEET_SSH_DIR/config" "$FLEET_SSH_DIR/authorized_keys" && fail "old block kept"
grep -q 'Host mine' "$FLEET_SSH_DIR/config" || fail "user stanza lost"
[[ "$(tail -1 "$FLEET_SSH_DIR/config")" == "# <<< setup:fleet <<<" ]] || fail "block not last"
grep -qx 'ssh-ed25519 AAAAPeer' "$FLEET_SSH_DIR/authorized_keys" || fail "peer key missing"
grep -qx 'ssh-ed25519 AAAAHand hand' "$FLEET_SSH_DIR/authorized_keys" || fail "hand key lost"
grep -q AAAAOwner "$FLEET_SSH_DIR/authorized_keys" && fail "a friend got the owner's GitHub keys"
[[ "$(ls -l "$FLEET_SSH_DIR/config")" == -rw-------* ]] || fail "config mode"
fleet sync --check 2>/dev/null || fail "check after a write"

# A stanza appended below the block moves the block back to the end, so the
# accept-new default stays last.
printf 'Host later\n    User me\n' >> "$FLEET_SSH_DIR/config"
fleet sync --check 2>/dev/null && fail "check missed a block that is no longer last"
fleet sync >/dev/null 2>&1
[[ "$(tail -1 "$FLEET_SSH_DIR/config")" == "# <<< setup:fleet <<<" ]] || fail "block not moved last"
[[ "$(grep -c 'setup:fleet >>>' "$FLEET_SSH_DIR/config")" == 1 ]] || fail "block duplicated"

# No authoritative answer keeps the blocks: an empty set, Auth down, or a
# rejected session on a machine without an owner key.
cp "$FLEET_SSH_DIR/config" "$TMP/config.before"
cp "$FLEET_SSH_DIR/authorized_keys" "$TMP/keys.before"
for case in '{"version":"v","self":{},"keys":[],"hosts":[]} 0' 'oops 1' '{} 4'; do
    serve ${case% *} ${case#* }
    rc=0; fleet sync >/dev/null 2>&1 || rc=$?
    [[ $rc == 3 ]] || fail "sync with ($case) exited $rc"
    cmp -s "$TMP/config.before" "$FLEET_SSH_DIR/config" || fail "config changed with ($case)"
    cmp -s "$TMP/keys.before" "$FLEET_SSH_DIR/authorized_keys" || fail "keys changed with ($case)"
done
[[ -f "$XDG_STATE_HOME/setup/auth.needs-login" ]] || fail "rejected session left no login marker"

# With no session, a machine holding an owner key keeps the old sources, as
# ssh-aliases did.
printf 'ssh-ed25519 AAAAOwner me@grimoire\n' > "$FLEET_SSH_DIR/id_ed25519.pub"
serve '{}' 4
fleet sync >/dev/null 2>&1 || fail "owner machine without a session"
grep -q 'Host mangchi mangchi.lost.plus' "$FLEET_SSH_DIR/config" || fail "FLEET table not used"
grep -q 'Host bingus bingus.lost.plus' "$FLEET_SSH_DIR/config" || fail "FLEET TERM host missing"
grep -q 'Host grimoire' "$FLEET_SSH_DIR/config" && fail "own FLEET alias written"
grep -qx 'ssh-ed25519 AAAAOwner' "$FLEET_SSH_DIR/authorized_keys" || fail "owner key missing"

# The operator's account keeps the old sources until cutover, with Auth's keys
# added, and status lists the FLEET rows Auth does not serve yet.
serve "$FLEET_JSON" 0 1
fleet sync >/dev/null 2>&1 || fail "operator sync"
grep -q 'Host mangchi' "$FLEET_SSH_DIR/config" || fail "operator lost FLEET aliases"
grep -q 'bingus.lan' "$FLEET_SSH_DIR/config" && fail "operator got Auth's stanzas before cutover"
grep -qx 'ssh-ed25519 AAAAOwner' "$FLEET_SSH_DIR/authorized_keys" || fail "operator lost GitHub keys"
grep -qx 'ssh-ed25519 AAAAPeer' "$FLEET_SSH_DIR/authorized_keys" || fail "operator missing Auth keys"
[[ -f "$XDG_STATE_HOME/setup/auth.needs-login" ]] && fail "login marker kept after a good answer"
fleet status 2>&1 | grep -q 'not yet served by Auth as in FLEET: spark1' || fail "status shows no cutover gaps"

# An unconfirmed machine is told why its key is not in other machines' files.
serve "${FLEET_JSON/\"served\":true/\"served\":false}" 0 7
fleet sync 2>&1 >/dev/null | grep -q 'waiting for confirmation' || fail "no confirmation notice"

# A file whose text is current but whose mode loosened is put back to 0600.
serve "$FLEET_JSON"
fleet sync >/dev/null 2>&1
chmod 664 "$FLEET_SSH_DIR/config"
fleet sync >/dev/null 2>&1
[[ "$(ls -l "$FLEET_SSH_DIR/config")" == -rw-------* ]] || fail "loosened mode left alone"

# A login between the request and the account check is no answer: the fleet
# may belong to the account that was signed in before.
cp "$FLEET_SSH_DIR/authorized_keys" "$TMP/keys.before"
cat > "$TMP/auth.switching" <<'SH'
#!/bin/sh
case "$1" in
    refresh) exit 0 ;;
    context) printf '{"origin":"https://auth.lost.plus","subject":"%s"}\n' "$(cat "$FAKE/subject")" ;;
    request) printf 1 > "$FAKE/subject"; printf '%s' '{"version":"v1","self":{"served":true,"key_mismatch":false},"keys":["ssh-ed25519 AAAAOther"],"hosts":[]}' ;;
esac
SH
chmod +x "$TMP/auth.switching"
serve "$FLEET_JSON" 0 7
FLEET_AUTH_BIN="$TMP/auth.switching" fleet sync >/dev/null 2>&1 && fail "sync across a login change"
cmp -s "$TMP/keys.before" "$FLEET_SSH_DIR/authorized_keys" || fail "keys written across a login change"

# The setup module: no answer from Auth installs fine and reads as unknown, not
# outdated, so setup does not fail every run on a machine waiting to log in.
serve '{}' 4
rm -f "$FLEET_SSH_DIR/id_ed25519.pub"
export ROOT BATCH=1 FLEET_BIN="$HOME/.local/bin/fleet" FLEET_SOURCE="$ROOT/files/fleet"
export FLEET_MANIFEST_SOURCE="$ROOT/files/fleet-manifest.json"
module() {
    zsh -c 'source "$ROOT/lib/script-helpers.sh"; source "$ROOT/files/fleet.sh"; "$@"' module "$@"
}
module status >/dev/null && fail "status before install"
module install >/dev/null 2>&1 || fail "install without an answer from Auth"
[[ "$(module status)" == "fleet"*"unknown"* ]] || fail "status without an answer: $(module status)"
serve "${FLEET_JSON/AAAAPeer\"/AAAAPeer\",\"ssh-ed25519 AAAANew\"}"
[[ "$(module status)" == *outdated* ]] || fail "status missed a pending write"
module update >/dev/null 2>&1 || fail "update"
[[ "$(module status)" == *current* ]] || fail "status after update"

# A binary that lost its executable bit still restores the harness links.
printf 'import os, sys\nopen(os.environ["FAKE"] + "/ran", "a").write(" ".join(sys.argv[1:]) + "\\n")\n' > "$TMP/recorder"
cp "$TMP/recorder" "$FLEET_BIN"
chmod -x "$FLEET_BIN"
module uninstall >/dev/null 2>&1 || fail "uninstall"
grep -qx __unlink "$FAKE/ran" || fail "uninstall skipped __unlink for a non-executable binary"
grep -qx __unrender "$FAKE/ran" || fail "uninstall skipped __unrender for a non-executable binary"
[[ ! -e "$FLEET_BIN" ]] || fail "uninstall left the binary"
# A deleted binary is fetched again for the cleanup, since only it can put
# the links back.
module install >/dev/null 2>&1 || fail "reinstall"
rm -f "$FLEET_BIN" "$FAKE/ran"
cp "$TMP/recorder" "$TMP/recorder.py"
FLEET_SOURCE="$TMP/recorder.py" module uninstall >/dev/null 2>&1 || fail "uninstall without the binary"
grep -qx __unlink "$FAKE/ran" || fail "uninstall skipped __unlink when the binary was gone"
grep -qx __unrender "$FAKE/ran" || fail "uninstall skipped __unrender when the binary was gone"
# Without a CLI that put the links back, uninstall keeps everything.
module install >/dev/null 2>&1 || fail "reinstall"
rm -f "$FLEET_BIN"
FLEET_SOURCE="$TMP/missing" module uninstall >/dev/null 2>&1 && fail "uninstall went on without a CLI"
cat > "$FLEET_BIN" <<'EOF'
import os, sys
open(os.environ["FAKE"] + "/ran", "a").write(" ".join(sys.argv[1:]) + "\n")
if sys.argv[1:] == ["schedule", "status"]:
    print("fleet: nightly sync on")
if sys.argv[1:] == ["schedule", "enable"]:
    open(os.environ["FAKE"] + "/path", "w").write(os.environ.get("FLEET_PATH", ""))
sys.exit(0 if sys.argv[1:] != ["__unlink"] else 1)
EOF
cp "$FLEET_BIN" "$TMP/failing.py"
rm -f "$FAKE/ran"
FLEET_SOURCE="$TMP/failing.py" module uninstall >/dev/null 2>&1 && fail "uninstall went on after __unlink failed"
[[ -e "$FLEET_BIN" ]] || fail "a failed uninstall removed the binary"
# A failed cleanup leaves fleet installed, so its nightly sync comes back on.
cat > "$FLEET_BIN" <<'EOF'
import os, sys
open(os.environ["FAKE"] + "/ran", "a").write(" ".join(sys.argv[1:]) + "\n")
if sys.argv[1:] == ["schedule", "status"]:
    print("fleet: nightly sync on")
if sys.argv[1:] == ["schedule", "enable"]:
    open(os.environ["FAKE"] + "/path", "w").write(os.environ.get("FLEET_PATH", ""))
sys.exit(1 if sys.argv[1:] == ["__unlink"] else 0)
EOF
rm -f "$FAKE/ran"; cp "$FLEET_BIN" "$TMP/failing-rec.py"
FLEET_SOURCE="$TMP/failing-rec.py" module uninstall >/dev/null 2>&1 && fail "uninstall went on after __unlink failed"
[[ "$(tail -1 "$FAKE/ran")" == "schedule enable" ]] || fail "a failed uninstall left the nightly sync off"
[[ "$(cat "$FAKE/path")" == "$FLEET_BIN" ]] || fail "the nightly sync came back on without the installed path"
# And a sync puts back what the cleanup took before it failed.
grep -qx "sync --pull" "$FAKE/ran" || fail "a failed uninstall did not put back what it took"
# An installed binary older than this module, without __unlink, hands the
# cleanup to the current one.
printf 'import sys\nsys.exit(2 if sys.argv[1:] == ["__unlink"] else 0)\n' > "$FLEET_BIN"
rm -f "$FAKE/ran"
FLEET_SOURCE="$TMP/recorder.py" module uninstall >/dev/null 2>&1 || fail "uninstall with an old binary"
grep -qx __unlink "$FAKE/ran" || fail "an old binary's failed __unlink was not retried with the current one"
[[ ! -e "$FLEET_BIN" ]] || fail "uninstall with an old binary left it"
# When the current CLI stood in for that old one and failed too, it is the
# one that puts things back: the old one may not render what it removed.
module install >/dev/null 2>&1 || fail "reinstall"
printf 'import os, sys\nopen(os.environ["FAKE"] + "/ran", "a").write("old " + " ".join(sys.argv[1:]) + "\\n")\nsys.exit(2 if sys.argv[1:] == ["__unrender"] else 0)\n' > "$FLEET_BIN"
printf 'import os, sys\nopen(os.environ["FAKE"] + "/ran", "a").write("new " + " ".join(sys.argv[1:]) + "\\n")\nsys.argv[1:2] == ["sync"] and open(os.environ["FAKE"] + "/path", "w").write(os.environ.get("FLEET_PATH", ""))\nsys.exit(1 if sys.argv[1:] == ["__unlink"] else 0)\n' > "$TMP/newfail.py"
rm -f "$FAKE/ran"
FLEET_SOURCE="$TMP/newfail.py" module uninstall >/dev/null 2>&1 && fail "uninstall went on after the current CLI's __unlink failed"
grep -qx "new sync --pull" "$FAKE/ran" && ! grep -q "old sync" "$FAKE/ran" \
    || fail "a failed stand-in cleanup was put back by the old binary: $(cat "$FAKE/ran")"
# It renders the installed path, not its own, which is deleted after.
[[ "$(cat "$FAKE/path")" == "$FLEET_BIN" ]] || fail "the stand-in put back settings pointing at itself"
# A nightly sync that will not turn off keeps everything.
module install >/dev/null 2>&1 || fail "reinstall"
cat > "$FLEET_BIN" <<'EOF'
import sys
if sys.argv[1:] == ["schedule", "status"]:
    print("fleet: nightly sync on")
sys.exit(1 if sys.argv[1:] == ["schedule", "disable"] else 0)
EOF
cp "$FLEET_BIN" "$TMP/stuck.py"
FLEET_SOURCE="$TMP/stuck.py" module uninstall >/dev/null 2>&1 && fail "uninstall went on with the nightly sync still on"
[[ -e "$FLEET_BIN" ]] || fail "an uninstall that left the timer on removed the binary"
# A broken binary cannot say the timer is on; the current CLI checks and
# turns it off.
printf 'syntax error(\n' > "$FLEET_BIN"
cat > "$TMP/ontimer.py" <<'EOF'
import os, sys
open(os.environ["FAKE"] + "/ran", "a").write(" ".join(sys.argv[1:]) + "\n")
if sys.argv[1:] == ["schedule", "status"]:
    print("fleet: nightly sync on")
EOF
rm -f "$FAKE/ran"
FLEET_SOURCE="$TMP/ontimer.py" module uninstall >/dev/null 2>&1 || fail "uninstall with a broken binary"
grep -qx 'schedule disable' "$FAKE/ran" || fail "a broken binary's timer was left on"
# And when the cleanup then fails, the timer it found on comes back.
printf 'syntax error(\n' > "$FLEET_BIN"
rm -f "$FAKE/ran"
FLEET_SOURCE="$TMP/failing.py" module uninstall >/dev/null 2>&1 && fail "uninstall went on after __unlink failed"
[[ "$(tail -1 "$FAKE/ran")" == "schedule enable" ]] || fail "a failed uninstall left a broken binary's timer off"
rm -f "$FLEET_BIN"
# The CLI removes an installed timer whether or not it runs, and calls a
# missing one off without asking the helper, which would refuse it.
printf '#!/bin/sh\necho "$@" >> "$FAKE/helper"\n' > "$TMP/helper"
chmod +x "$TMP/helper"
units="$TMP/units"
mkdir -p "$units"
SCHEDULE_BIN="$TMP/helper" SCHEDULE_USER_DIR="$units" python3 "$ROOT/files/fleet" schedule disable >/dev/null 2>&1 \
    || fail "turning off a missing timer failed"
[[ ! -e "$FAKE/helper" ]] || fail "asked the helper to remove a missing timer"
touch "$units/fleet-sync.timer"
SCHEDULE_BIN="$TMP/helper" SCHEDULE_USER_DIR="$units" python3 "$ROOT/files/fleet" schedule disable >/dev/null 2>&1 \
    || fail "turning off an installed timer failed"
grep -qx 'uninstall-timer user fleet-sync' "$FAKE/helper" || fail "an installed timer was left behind"
# The systemd job runs the binary turning it on, quoted for systemd.
SCHEDULE_BIN="$TMP/helper" SCHEDULE_USER_DIR="$units" FLEET_PATH='/opt/my "fleet" 100%/fleet' \
    python3 "$ROOT/files/fleet" schedule enable >/dev/null 2>&1 || fail "turning on the systemd timer failed"
grep -qF 'install-timer user fleet-sync Nightly fleet SSH sync "/opt/my \"fleet\" 100%%/fleet" schedule run' "$FAKE/helper" \
    || fail "the systemd job does not run the installed binary"

# The launchd job runs the binary that turned it on, or the installed one a
# temporary copy names.
HOME="$TMP/machome" FLEET_PATH="$TMP/custom/fleet" python3 - "$ROOT/files/fleet" <<'PY' || fail "the launchd job does not run the installed binary"
import importlib.machinery, importlib.util, subprocess, sys
loader = importlib.machinery.SourceFileLoader("fleet_launchd", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader)); loader.exec_module(m)
m.sys.platform = "darwin"
m.subprocess.run = lambda *a, **k: subprocess.CompletedProcess(a, 0)
sys.argv[0] = "/tmp/staged-fleet"
assert m.schedule_enable() == 0
assert "<string>" + m.os.environ["FLEET_PATH"] + "</string>" in m._plist_path().read_text()
del m.os.environ["FLEET_PATH"]
sys.argv[0] = "/opt/fleet/bin/fleet"
assert m.schedule_enable() == 0
assert "<string>/opt/fleet/bin/fleet</string>" in m._plist_path().read_text()
sys.argv[0] = "/Volumes/Tools & Data/fleet"
assert m.schedule_enable() == 0
assert "<string>/Volumes/Tools &amp; Data/fleet</string>" in m._plist_path().read_text()
PY

echo "fleet tests passed"
