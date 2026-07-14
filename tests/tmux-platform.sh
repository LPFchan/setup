#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

export HOME="$TEST_TMP/home"
export XDG_STATE_HOME="$TEST_TMP/state"
export STATE_DIR="$XDG_STATE_HOME/setup"
export FAKE_BIN="$TEST_TMP/bin"
mkdir -p "$HOME/.local/bin" "$STATE_DIR" "$FAKE_BIN"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# shellcheck disable=SC1091
source "$ROOT/lib/script-helpers.sh"
# shellcheck disable=SC1091
source "$ROOT/files/tmux.sh"

[[ "$BLOCK_CONTENT" == *'set -g status-position top'* ]] \
    || fail "tmux status bar is not configured at the top"
[[ "$BLOCK_CONTENT" == *'set -g status-left-length 64'* ]] \
    || fail "tmux hostname segment cannot expand beyond the default limit"
[[ "$BLOCK_CONTENT" == *'set -g status-left " #{p12:host_short} "'* ]] \
    || fail "tmux hostname segment is not left-aligned and padded to at least 12 characters"

[[ "$BLOCK_CONTENT" == *'bg=#{?SYSTEM_COLOR_HEX,#{SYSTEM_COLOR_HEX},colour39}'* ]] \
    || fail "tmux status bar does not consume the shared system color"

# Exercise tmux's actual format evaluator when tmux is available. This catches
# shorthand aliases nested inside padding modifiers, which parse but render as
# an empty field.
if tmux_bin=$(command -v tmux 2>/dev/null); then
    test_server="setup-hostname-format-$$"
    tmux_config="$TEST_TMP/tmux.conf"
    printf '%s\n' "$BLOCK_CONTENT" > "$tmux_config"
    SYSTEM_COLOR_HEX="#FF0000" SYSTEM_COLOR_TEXT_HEX="#FFFFFF" \
        "$tmux_bin" -L "$test_server" -f "$tmux_config" new-session -d
    rendered=$("$tmux_bin" -L "$test_server" display-message -p '#{p12:host_short}')
    rendered_host=$("$tmux_bin" -L "$test_server" display-message -p '#{host_short}')
    rendered_style=$("$tmux_bin" -L "$test_server" show-options -gv status-style)
    "$tmux_bin" -L "$test_server" kill-server
    [[ -n "$rendered_host" && "$rendered" == "$rendered_host"* ]] \
        || fail "tmux hostname format rendered empty or was not left-aligned: '$rendered'"
    [[ "${#rendered}" -ge 12 ]] \
        || fail "tmux hostname format rendered fewer than 12 characters: '$rendered'"
    [[ "$rendered_style" == *"bg=#FF0000"* && "$rendered_style" == *"fg=#FFFFFF"* ]] \
        || fail "tmux did not resolve shared system colors: '$rendered_style'"
fi

cat > "$FAKE_BIN/uname" <<'EOF'
#!/bin/sh
echo Darwin
EOF
cat > "$FAKE_BIN/top" <<'EOF'
#!/bin/sh
echo 'CPU usage: 10.0% user, 15.0% sys, 75.0% idle'
EOF
cat > "$FAKE_BIN/memory_pressure" <<'EOF'
#!/bin/sh
echo 'System-wide memory free percentage: 60%'
EOF
cat > "$FAKE_BIN/brew" <<'EOF'
#!/bin/sh
[ "$1 $2" = 'install tmux' ] || exit 2
touch "$TEST_TMP/brew-invoked"
cat > "$FAKE_BIN/tmux" <<'INNER'
#!/bin/sh
exit 0
INNER
chmod +x "$FAKE_BIN/tmux"
EOF
chmod +x "$FAKE_BIN/uname" "$FAKE_BIN/top" "$FAKE_BIN/memory_pressure" "$FAKE_BIN/brew"

export TEST_TMP
PATH="$FAKE_BIN:/usr/bin:/bin"
export PATH

_ensure_tmux
[[ -x "$FAKE_BIN/tmux" ]] || fail "macOS dependency install did not provide tmux"
[[ -e "$TEST_TMP/brew-invoked" ]] || fail "macOS dependency install did not invoke Homebrew"

_write_helper
helper_output=$($HELPER)
[[ "$helper_output" == "CPU 25% - RAM 40%" ]] \
    || fail "macOS helper output was '$helper_output'"

# Existing module-owned surfaces plus a missing executable must be repairable
# through `setup update`, which relies on an `outdated` live status.
rm -f "$FAKE_BIN/tmux"
has_managed_block() { return 0; }
if missing_output=$(status); then
    missing_rc=0
else
    missing_rc=$?
fi
[[ "$missing_rc" -eq 1 ]] || fail "missing tmux should report outdated, got rc=$missing_rc"
[[ "$missing_output" == *"outdated"* && "$missing_output" == *"local=missing remote=required"* ]] \
    || fail "missing tmux status was '$missing_output'"

# If no supported macOS package manager exists, installation must fail before
# it writes any setup-owned configuration or helper.
NO_PKG_BIN="$TEST_TMP/no-package-manager"
mkdir -p "$NO_PKG_BIN"
cp "$FAKE_BIN/uname" "$NO_PKG_BIN/uname"
PATH="$NO_PKG_BIN:/usr/bin:/bin"
export PATH
_write_helper() { touch "$TEST_TMP/helper-written"; }
_upsert_blocks() { touch "$TEST_TMP/blocks-written"; }
if install >"$TEST_TMP/install-output" 2>&1; then
    fail "install unexpectedly succeeded without tmux or a package manager"
fi
[[ ! -e "$TEST_TMP/helper-written" && ! -e "$TEST_TMP/blocks-written" ]] \
    || fail "install wrote module surfaces before satisfying the tmux dependency"

echo "tmux platform tests passed"
