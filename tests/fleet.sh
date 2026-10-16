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
export FLEET_MANIFEST_SOURCE="$ROOT/files/fleet-manifest.json" FLEET_MANIFEST_TARGET="$HOME/.config/fleet/manifest.json"
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
printf 'import sys\nsys.exit(0 if sys.argv[1:] != ["__unlink"] else 1)\n' > "$FLEET_BIN"
module uninstall >/dev/null 2>&1 && fail "uninstall went on after __unlink failed"
[[ -e "$FLEET_BIN" ]] || fail "a failed uninstall removed the binary"

echo "fleet tests passed"
