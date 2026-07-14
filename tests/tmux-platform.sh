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
[[ "$BLOCK_CONTENT" == *'set -g window-status-format " #W "'* ]] \
    || fail "tmux window titles still include the window index or flags"
[[ "$BLOCK_CONTENT" == *'set -g window-status-current-format " #W "'* ]] \
    || fail "current tmux window titles still include the window index or flags"
[[ "$BLOCK_CONTENT" == *'set -g window-status-style "dim"'* ]] \
    || fail "inactive tmux window titles are not visually muted"
[[ "$BLOCK_CONTENT" == *'set -gF window-status-current-style '*'bold,nodim"'* ]] \
    || fail "current tmux window title has no distinct color treatment"

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
    rendered_inactive_style=$("$tmux_bin" -L "$test_server" show-options -gwv window-status-style)
    rendered_current_style=$("$tmux_bin" -L "$test_server" show-options -gwv window-status-current-style)
    "$tmux_bin" -L "$test_server" kill-server
    [[ -n "$rendered_host" && "$rendered" == "$rendered_host"* ]] \
        || fail "tmux hostname format rendered empty or was not left-aligned: '$rendered'"
    [[ "${#rendered}" -ge 12 ]] \
        || fail "tmux hostname format rendered fewer than 12 characters: '$rendered'"
    [[ "$rendered_style" == *"bg=#FF0000"* && "$rendered_style" == *"fg=#FFFFFF"* ]] \
        || fail "tmux did not resolve shared system colors: '$rendered_style'"
    [[ "$rendered_inactive_style" == "dim" ]] \
        || fail "tmux did not apply inactive-window dimming: '$rendered_inactive_style'"
    [[ "$rendered_current_style" == *"fg=#FF0000"* \
       && "$rendered_current_style" == *"bg=#FFFFFF"* \
       && "$rendered_current_style" == *"bold"* \
       && "$rendered_current_style" == *"nodim"* ]] \
        || fail "tmux did not resolve current-window colors: '$rendered_current_style'"
fi

# Exercise the zsh hook that captures the launched command before an executable
# can replace itself with an implementation-specific process name.
if zsh_bin=$(command -v zsh 2>/dev/null); then
    title_log="$TEST_TMP/tmux-title.log"
    cat > "$FAKE_BIN/tmux" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$TMUX_TITLE_LOG"
EOF
    cat > "$FAKE_BIN/codex" <<'EOF'
#!/bin/sh
exit 0
EOF
    cat > "$FAKE_BIN/ssh" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$FAKE_BIN/tmux" "$FAKE_BIN/codex" "$FAKE_BIN/ssh"

    zdotdir="$TEST_TMP/zsh"
    mkdir -p "$zdotdir"
    printf '%s\n' "$TITLE_BLOCK_CONTENT" > "$zdotdir/.zshrc"
    TMUX="test,1,0" TMUX_TITLE_LOG="$title_log" ZDOTDIR="$zdotdir" \
        PATH="$FAKE_BIN:/usr/bin:/bin" "$zsh_bin" -di > /dev/null 2>&1 <<'EOF'
alias cx=codex
TEST_TITLE=1 cx --help
env TEST_TITLE=1 codex --help
ssh -p 2222 user@grimoire
exit
EOF
    grep -Fxq 'rename-window -- codex' "$title_log" \
        || fail "tmux command title did not use the expanded top-level command"
    grep -Fxq 'rename-window -- grimoire' "$title_log" \
        || fail "tmux SSH title did not use the remote host"
    rm -f "$FAKE_BIN/tmux" "$FAKE_BIN/codex" "$FAKE_BIN/ssh"
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
