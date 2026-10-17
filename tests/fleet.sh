#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" FLEET_SSH_DIR="$TMP/home/.ssh"
export FLEET_AUTH_BIN="$TMP/auth" FLEET_SELF=grimoire FAKE="$TMP/fake"
mkdir -p "$FLEET_SSH_DIR" "$FAKE/api/fleet"
printf '{"counter":0,"version":"","files":[],"installs":[],"skills":[]}' > "$FAKE/api/fleet/config.json"
printf '[]' > "$FAKE/api/services.json"

# A stand-in auth CLI: `request GET /api/fleet` prints $FAKE/fleet.json and
# exits $FAKE/rc, other requests print $FAKE<path>.json,
# `context` names $FAKE/subject.
cat > "$FLEET_AUTH_BIN" <<'SH'
#!/bin/sh
case "$1" in
    refresh) exit 0 ;;
    context) printf '{"origin":"https://auth.lost.plus","subject":"%s"}\n' "$(cat "$FAKE/subject")" ;;
    request) [ "$(cat "$FAKE/rc")" = 4 ] && exit 4
             [ "$3" = /api/fleet ] || { cat "$FAKE${3}.json" 2>/dev/null || echo '{"status":404,"error":"not found"}'; [ -f "$FAKE${3}.json" ] || exit 6; exit 0; }
             cat "$FAKE/fleet.json"; exit "$(cat "$FAKE/rc")" ;;
esac
SH
chmod +x "$FLEET_AUTH_BIN"
fleet() { python3 "$ROOT/files/fleet" "$@"; }
serve() { printf '%s' "$1" > "$FAKE/fleet.json"; printf '%s' "${2:-0}" > "$FAKE/rc"; printf '%s' "${3:-7}" > "$FAKE/subject"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

FLEET_JSON='{"version":"v1","self":{"key":"ssh-ed25519 AAAASelf","key_mismatch":false,"alias":"grimoire"},
"keys":["ssh-ed25519 AAAASelf","ssh-ed25519 AAAAPeer"],
"hosts":[{"alias":"grimoire","address":"grimoire.ts.net","user":"fox","term_fallback":false},
{"alias":"bingus","address":"bingus.lan","user":"fox","term_fallback":true},
{"alias":"evil","address":"x\nProxyCommand sh","user":"fox","term_fallback":false}],
"known_hosts":["mac.lost.plus ssh-ed25519 AAAAMacA","mac.lost.plus ssh-ed25519 AAAAMacB","x ProxyCommand sh"]}'

# A machine writes only its fleet: itself left out, the TERM
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
[[ "$(ls -l "$FLEET_SSH_DIR/config")" == -rw-------* ]] || fail "config mode"
[[ "$(cat "$FLEET_SSH_DIR/known_hosts.fleet")" == $'mac.lost.plus ssh-ed25519 AAAAMacA\nmac.lost.plus ssh-ed25519 AAAAMacB' ]] \
    || fail "vouched host keys not written"
grep -qx '    GlobalKnownHostsFile ~/.ssh/known_hosts.fleet /etc/ssh/ssh_known_hosts /etc/ssh/ssh_known_hosts2' \
    "$FLEET_SSH_DIR/config" || fail "known_hosts.fleet not trusted"
fleet sync --check 2>/dev/null || fail "check after a write"

# A stanza appended below the block moves the block back to the end, so the
# accept-new default stays last.
printf 'Host later\n    User me\n' >> "$FLEET_SSH_DIR/config"
fleet sync --check 2>/dev/null && fail "check missed a block that is no longer last"
fleet sync >/dev/null 2>&1
[[ "$(tail -1 "$FLEET_SSH_DIR/config")" == "# <<< setup:fleet <<<" ]] || fail "block not moved last"
[[ "$(grep -c 'setup:fleet >>>' "$FLEET_SSH_DIR/config")" == 1 ]] || fail "block duplicated"

# No authoritative answer keeps the blocks: an empty set, Auth down, or a
# rejected session.
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

# The operator's account gets its fleet from Auth like any other.
serve "$FLEET_JSON" 0 1
fleet sync >/dev/null 2>&1 || fail "operator sync"
grep -q 'Host bingus bingus.lan' "$FLEET_SSH_DIR/config" || fail "operator missing Auth's stanzas"
grep -qx 'ssh-ed25519 AAAAPeer' "$FLEET_SSH_DIR/authorized_keys" || fail "operator missing Auth keys"
[[ -f "$XDG_STATE_HOME/setup/auth.needs-login" ]] && fail "login marker kept after a good answer"
fleet status 2>&1 | grep -q 'keys from Auth' || fail "status does not name Auth"

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
    request) printf 1 > "$FAKE/subject"; printf '%s' '{"version":"v1","self":{"key_mismatch":false},"keys":["ssh-ed25519 AAAAOther"],"hosts":[]}' ;;
esac
SH
chmod +x "$TMP/auth.switching"
serve "$FLEET_JSON" 0 7
FLEET_AUTH_BIN="$TMP/auth.switching" fleet sync >/dev/null 2>&1 && fail "sync across a login change"
cmp -s "$TMP/keys.before" "$FLEET_SSH_DIR/authorized_keys" || fail "keys written across a login change"

# The setup module: no answer from Auth installs fine and reads as unknown, not
# outdated, so setup does not fail every run on a machine waiting to log in.
serve '{}' 4
export ROOT BATCH=1 FLEET_BIN="$HOME/.local/bin/fleet" FLEET_SOURCE="$ROOT/files/fleet" \
    FLEET_MANIFEST_SOURCE="$ROOT/files/fleet-manifest.json" STATE_DIR="$XDG_STATE_HOME/setup"
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

# A bare install with nobody at a terminal names nothing and installs nothing.
fleet install </dev/null >/dev/null 2>&1 && fail "bare install without a terminal"
[[ "$(fleet install bogus 2>&1)" == *"unknown harness: bogus"* ]] || fail "unknown harness accepted"

echo "fleet tests passed"
