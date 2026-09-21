#!/usr/bin/env zsh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" STATE_DIR="$TMP/state/setup"
mkdir -p "$HOME/.local/bin" "$STATE_DIR"
# Drop nvm from PATH: _bin() resolves through `command -v`, so the operator's
# real miniharness would otherwise answer every probe in this test.
export PATH="$HOME/.local/bin:/usr/bin:/bin"

# shellcheck disable=SC1091
source "$ROOT/lib/script-helpers.sh"
# shellcheck disable=SC1091
source "$ROOT/files/miniharness.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

STATE_FILE="$STATE_DIR/script-state.tsv"
FAKE_BIN="$HOME/.local/bin/miniharness"
NPM_LOG="$TMP/npm.log"

# Neither npm nor the registry is reachable from a test. Both are stubbed so
# the module's own logic is what is under test.
LATEST="0.2.0"
_latest_version() { printf '%s\n' "$LATEST" }

make_bin() {
    cat > "$FAKE_BIN" <<EOF
#!/bin/sh
[ "\$1" = --version ] && echo "$1"
EOF
    chmod +x "$FAKE_BIN"
}

# A stub npm whose "install -g" materializes the binary, so install() is
# exercised through the same path it takes for real.
: > "$NPM_LOG"
cat > "$TMP/npm" <<EOF
#!/bin/sh
echo "\$@" >> "$NPM_LOG"
case "\$1" in
    config) echo "$HOME/.local" ;;
    install) printf '#!/bin/sh\n[ "\$1" = --version ] && echo %s\n' "$LATEST" > "$FAKE_BIN"
             chmod +x "$FAKE_BIN" ;;
    uninstall) rm -f "$FAKE_BIN" ;;
esac
EOF
chmod +x "$TMP/npm"
_npm() { printf '%s\n' "$TMP/npm" }

# --- uninstalled ------------------------------------------------------
rm -f "$FAKE_BIN"
set +e; out=$(status); rc=$?; set -e
[[ "$rc" == 2 ]] || fail "absent binary reported rc=$rc, expected 2"
[[ "$out" == *uninstalled* ]] || fail "absent binary reported '$out'"

# --- install materializes it and records state ------------------------
install >/dev/null || fail "install failed"
[[ -x "$FAKE_BIN" ]] || fail "install left no binary"
grep -q "install -g miniharness" "$NPM_LOG" || fail "install did not call npm install -g"
is_script_installed miniharness || fail "install recorded no script state"

# --- current ----------------------------------------------------------
set +e; out=$(status); rc=$?; set -e
[[ "$rc" == 0 ]] || fail "matching versions reported rc=$rc, expected 0"
[[ "$out" == *current* ]] || fail "matching versions reported '$out'"
[[ "$out" == *"target=$FAKE_BIN"* ]] || fail "status did not report the resolved path: '$out'"

# --- outdated ---------------------------------------------------------
make_bin "0.1.0"
set +e; out=$(status); rc=$?; set -e
[[ "$rc" == 1 ]] || fail "version drift reported rc=$rc, expected 1"
[[ "$out" == *outdated* ]] || fail "version drift reported '$out'"
[[ "$out" == *"local=0.1.0"* && "$out" == *"remote=$LATEST"* ]] \
    || fail "version drift lost a version label: '$out'"

# --- registry unreachable is not a failure ----------------------------
# An offline machine must not read as "outdated" and trigger a pointless
# update; the contract for an unknown remote is state=installed, rc=0.
_latest_version() { printf '' }
set +e; out=$(status); rc=$?; set -e
[[ "$rc" == 0 ]] || fail "unreachable registry reported rc=$rc, expected 0"
[[ "$out" == *installed* ]] || fail "unreachable registry reported '$out'"
_latest_version() { printf '%s\n' "$LATEST" }

# --- install is a no-op when already present --------------------------
: > "$NPM_LOG"
install >/dev/null || fail "install failed on an already-present binary"
grep -q "install -g" "$NPM_LOG" && fail "install re-ran npm on an already-present binary"

# --- update pins @latest ----------------------------------------------
: > "$NPM_LOG"
update >/dev/null || fail "update failed"
grep -q "install -g miniharness@latest" "$NPM_LOG" || fail "update did not pin @latest"

# --- uninstall clears the state row -----------------------------------
uninstall >/dev/null || fail "uninstall failed"
is_script_installed miniharness && fail "uninstall left a script-state row"
[[ -f "$STATE_FILE" ]] && grep -q "^miniharness	" "$STATE_FILE" && fail "state row survived uninstall"

echo "PASS: miniharness"
