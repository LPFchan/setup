#!/usr/bin/env zsh
set -euo pipefail

ROOT=${0:A:h:h}
TEST_TMP=$(mktemp -d)
trap '/usr/bin/rm -rf "$TEST_TMP"' EXIT

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
[[ "$BLOCK_CONTENT" == *'set -s terminal-features[90] "xterm*:RGB"'* \
   && "$BLOCK_CONTENT" == *'set -s terminal-features[91] "tmux*:RGB"'* ]] \
    || fail "tmux does not advertise idempotent RGB support for direct and nested clients"
[[ "$BLOCK_CONTENT" == *'set -s terminal-features[92] "tmux*:clipboard"'* \
   && "$BLOCK_CONTENT" == *'set -s set-clipboard on'* ]] \
    || fail "tmux does not relay clipboard writes from nested clients"
[[ "$BLOCK_CONTENT" == *'set-environment -g COLORTERM truecolor'* ]] \
    || fail "tmux panes do not advertise truecolor to applications"
[[ "$BLOCK_CONTENT" == *'set-environment -g CLAUDE_CODE_TMUX_TRUECOLOR 1'* ]] \
    || fail "Claude Code is not allowed to render truecolor inside tmux"
[[ "$BLOCK_CONTENT" == *'bind c new-window -c ~'* ]] \
    || fail "tmux prefix-c does not create windows in home"
[[ "$BLOCK_CONTENT" == *'bind -n MouseDown1Status set-option -t = -F @setup-drag-window "#{window_id}"'* ]] \
    || fail "tmux tab dragging does not capture a stable source window"
[[ "$BLOCK_CONTENT" == *'bind -n MouseDrag1Status run-shell -C -t = '*'#{@setup-drag-window}'* ]] \
    || fail "tmux window tabs cannot be reordered by dragging"
[[ "$BLOCK_CONTENT" == *'bind -n MouseDown3Status display-menu -O '*' -t = '* ]] \
    || fail "tmux tab context menu does not stay open after button release"
[[ "$BLOCK_CONTENT" == *'unbind -n MouseUp3Status'* ]] \
    || fail "tmux does not remove the obsolete release-triggered tab menu"
[[ "$BLOCK_CONTENT" == *'unbind -n MouseDown3StatusDefault'* ]] \
    || fail "tmux does not remove the obsolete current-tab fallback menu"
[[ "$BLOCK_CONTENT" == *'bind -n MouseDown3StatusLeft display-menu -O '*' -t = '* ]] \
    || fail "tmux hostname menu is not persistent"
[[ "$BLOCK_CONTENT" == *'bind -n DoubleClick1Status kill-window -t ='* ]] \
    || fail "tmux tabs do not close on double-click"
[[ "$BLOCK_CONTENT" == *'bind -n DoubleClick1StatusDefault new-window -a -t ":{end}" -c ~'* ]] \
    || fail "empty tmux status space does not append a home-started window on double-click"
[[ "$BLOCK_CONTENT" == *'bind -T copy-mode MouseDragEnd1Pane if-shell -F "#{scroll_position}" "send-keys -X copy-selection" "send-keys -X copy-selection-and-cancel"'* \
   && "$BLOCK_CONTENT" == *'bind -T copy-mode-vi MouseDragEnd1Pane if-shell -F "#{scroll_position}" "send-keys -X copy-selection" "send-keys -X copy-selection-and-cancel"'* ]] \
    || fail "tmux mouse copying is not conditional on the scroll position"
[[ "$AUTOSTART_BLOCK_CONTENT" == *'tmux new-session -A -s main -c ~'* ]] \
    || fail "tmux autostart does not create the shared session in home"
[[ "$AUTOSTART_BLOCK_CONTENT" == *'[[ -o interactive && -t 0 && -z $TMUX ]]'* ]] \
    || fail "tmux autostart is not restricted to shells with a terminal on stdin"
[[ "$BLOCK_CONTENT" == *'set -g status-left-length 64'* ]] \
    || fail "tmux hostname segment cannot expand beyond the default limit"
[[ "$BLOCK_CONTENT" == *'set -g status-left " #{p12:host_short} "'* ]] \
    || fail "tmux hostname segment is not left-aligned and padded to at least 12 characters"
[[ "$BLOCK_CONTENT" == *'set -g window-status-format "#[range=window|#{window_index}] #W #[norange]"'* ]] \
    || fail "tmux window titles still include the window index or flags"
[[ "$BLOCK_CONTENT" == *'set -g window-status-current-format "#[range=window|#{window_index}] #W #[norange]"'* ]] \
    || fail "current tmux window title lacks an explicit mouse range"
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
    "$tmux_bin" -L "$test_server" source-file "$tmux_config"
    "$tmux_bin" -L "$test_server" source-file "$tmux_config"
    rendered=$("$tmux_bin" -L "$test_server" display-message -p '#{p12:host_short}')
    rendered_host=$("$tmux_bin" -L "$test_server" display-message -p '#{host_short}')
    rendered_style=$("$tmux_bin" -L "$test_server" show-options -gv status-style)
    rendered_inactive_style=$("$tmux_bin" -L "$test_server" show-options -gwv window-status-style)
    rendered_current_style=$("$tmux_bin" -L "$test_server" show-options -gwv window-status-current-style)
    rendered_terminal_features=$("$tmux_bin" -L "$test_server" show-options -gs terminal-features)
    rendered_set_clipboard=$("$tmux_bin" -L "$test_server" show-options -sv set-clipboard)
    rendered_colorterm=$("$tmux_bin" -L "$test_server" show-environment -g COLORTERM)
    rendered_claude_truecolor=$("$tmux_bin" -L "$test_server" show-environment -g CLAUDE_CODE_TMUX_TRUECOLOR)
    mouse_down_binding=$("$tmux_bin" -L "$test_server" list-keys -T root | grep 'MouseDown1Status ' || true)
    drag_binding=$("$tmux_bin" -L "$test_server" list-keys -T root | grep 'MouseDrag1Status' || true)
    right_down_binding=$("$tmux_bin" -L "$test_server" list-keys -T root | grep -E ' root MouseDown3Status[[:space:]]' || true)
    right_up_binding=$("$tmux_bin" -L "$test_server" list-keys -T root | grep -E ' root MouseUp3Status[[:space:]]' || true)
    right_default_binding=$("$tmux_bin" -L "$test_server" list-keys -T root | grep -E ' root MouseDown3StatusDefault[[:space:]]' || true)
    right_left_binding=$("$tmux_bin" -L "$test_server" list-keys -T root | grep -E ' root MouseDown3StatusLeft[[:space:]]' || true)
    new_window_binding=$("$tmux_bin" -L "$test_server" list-keys -T prefix | grep -E ' prefix c[[:space:]]' || true)
    double_tab_binding=$("$tmux_bin" -L "$test_server" list-keys -T root | grep -E ' root DoubleClick1Status[[:space:]]' || true)
    double_empty_binding=$("$tmux_bin" -L "$test_server" list-keys -T root | grep -E ' root DoubleClick1StatusDefault[[:space:]]' || true)
    copy_drag_binding=$("$tmux_bin" -L "$test_server" list-keys -T copy-mode | grep -E ' copy-mode MouseDragEnd1Pane[[:space:]]' || true)
    copy_drag_vi_binding=$("$tmux_bin" -L "$test_server" list-keys -T copy-mode-vi | grep -E ' copy-mode-vi MouseDragEnd1Pane[[:space:]]' || true)
    "$tmux_bin" -L "$test_server" kill-server
    [[ -n "$rendered_host" && "$rendered" == "$rendered_host"* ]] \
        || fail "tmux hostname format rendered empty or was not left-aligned: '$rendered'"
    [[ "${#rendered}" -ge 12 ]] \
        || fail "tmux hostname format rendered fewer than 12 characters: '$rendered'"
    [[ "$rendered_style" == *"bg=#FF0000"* && "$rendered_style" == *"fg=#FFFFFF"* ]] \
        || fail "tmux did not resolve shared system colors: '$rendered_style'"
    [[ "$rendered_inactive_style" == "dim" ]] \
        || fail "tmux did not apply inactive-window dimming: '$rendered_inactive_style'"
    [[ "$rendered_current_style" == *"bg=#FF0000"* \
       && "$rendered_current_style" == *"fg=#FFFFFF"* \
       && "$rendered_current_style" == *"bold"* \
       && "$rendered_current_style" == *"nodim"* ]] \
        || fail "tmux did not resolve current-window colors: '$rendered_current_style'"
    [[ "$rendered_terminal_features" == *'terminal-features[90] xterm*:RGB'* \
       && "$rendered_terminal_features" == *'terminal-features[91] tmux*:RGB'* ]] \
        || fail "tmux did not load direct and nested RGB features: '$rendered_terminal_features'"
    [[ $(printf '%s\n' "$rendered_terminal_features" | grep -cF 'xterm*:RGB') -eq 1 \
       && $(printf '%s\n' "$rendered_terminal_features" | grep -cF 'tmux*:RGB') -eq 1 \
       && $(printf '%s\n' "$rendered_terminal_features" | grep -cF 'tmux*:clipboard') -eq 1 ]] \
        || fail "tmux duplicated terminal features after repeated reloads: '$rendered_terminal_features'"
    [[ "$rendered_set_clipboard" == 'on' ]] \
        || fail "tmux did not enable nested clipboard relay: '$rendered_set_clipboard'"
    [[ "$rendered_colorterm" == 'COLORTERM=truecolor' ]] \
        || fail "tmux did not export truecolor capability: '$rendered_colorterm'"
    [[ "$rendered_claude_truecolor" == 'CLAUDE_CODE_TMUX_TRUECOLOR=1' ]] \
        || fail "tmux did not enable Claude Code truecolor: '$rendered_claude_truecolor'"
    [[ "$mouse_down_binding" == *'@setup-drag-window'* \
       && "$mouse_down_binding" == *'switch-client -t ='* ]] \
        || fail "tmux did not install stable tab source capture: '$mouse_down_binding'"
    [[ "$drag_binding" == *'run-shell -C -t ='* \
       && "$drag_binding" == *'@setup-drag-window'* \
       && "$drag_binding" == *'#{window_id}'* ]] \
        || fail "tmux did not install the tab drag binding: '$drag_binding'"
    [[ "$right_down_binding" == *'display-menu -O'* \
       && "$right_down_binding" == *'-t ='* \
       && "$right_down_binding" == *"new-window -a -c $HOME"* \
       && "$right_down_binding" == *"new-window -c $HOME"* ]] \
        || fail "tmux did not install the persistent tab menu: '$right_down_binding'"
    [[ -z "$right_up_binding" ]] \
        || fail "tmux retained the obsolete release-triggered tab menu: '$right_up_binding'"
    [[ -z "$right_default_binding" ]] \
        || fail "tmux retained the obsolete current-tab fallback: '$right_default_binding'"
    [[ "$right_left_binding" == *'display-menu -O'* \
       && "$right_left_binding" == *'-t ='* \
       && "$right_left_binding" == *"new-session -c $HOME"* \
       && "$right_left_binding" == *"new-window -c $HOME"* ]] \
        || fail "tmux did not install the persistent hostname menu: '$right_left_binding'"
    [[ "$new_window_binding" == *"new-window -c $HOME"* ]] \
        || fail "tmux prefix-c does not create windows in home: '$new_window_binding'"
    [[ "$double_tab_binding" == *'kill-window -t ='* ]] \
        || fail "tmux did not install tab double-click close: '$double_tab_binding'"
    [[ "$double_empty_binding" == *'new-window -a'* \
       && "$double_empty_binding" == *'-t ":{end}"'* \
       && "$double_empty_binding" == *"-c $HOME"* ]] \
        || fail "tmux did not install home-started empty-space double-click append: '$double_empty_binding'"
    [[ "$copy_drag_binding" == *'if-shell -F "#{scroll_position}" "send-keys -X copy-selection" "send-keys -X copy-selection-and-cancel"'* ]] \
        || fail "tmux emacs mouse copy does not branch on scroll position: '$copy_drag_binding'"
    [[ "$copy_drag_vi_binding" == *'if-shell -F "#{scroll_position}" "send-keys -X copy-selection" "send-keys -X copy-selection-and-cancel"'* ]] \
        || fail "tmux vi mouse copy does not branch on scroll position: '$copy_drag_vi_binding'"
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
    cat > "$FAKE_BIN/fzf" <<'EOF'
#!/bin/sh
printf '%s\n' "$AI_TEST_CHOICE"
EOF
    chmod +x "$FAKE_BIN/tmux" "$FAKE_BIN/codex" "$FAKE_BIN/ssh" "$FAKE_BIN/fzf"

    zdotdir="$TEST_TMP/zsh"
    mkdir -p "$zdotdir"
    printf '%s\n' "$TITLE_BLOCK_CONTENT" > "$zdotdir/.zshrc"
    cat "$ROOT/files/ai-menu" >> "$zdotdir/.zshrc"
    mkdir -p "$HOME/.ssh"
    printf 'Host grimoire\n' > "$HOME/.ssh/config"
    TMUX="test,1,0" TMUX_TITLE_LOG="$title_log" ZDOTDIR="$zdotdir" \
        PATH="$FAKE_BIN:/usr/bin:/bin" "$zsh_bin" -di > /dev/null 2>&1 <<'EOF'
alias cx=codex
TEST_TITLE=1 cx --help
env TEST_TITLE=1 codex --help
ssh -p 2222 user@grimoire
AI_TEST_CHOICE=codex ai
AI_TEST_CHOICE=grimoire ai
exit
EOF
    grep -Fxq 'rename-window -- codex' "$title_log" \
        || fail "tmux command title did not use the expanded top-level command"
    grep -Fxq 'rename-window -- grimoire' "$title_log" \
        || fail "tmux SSH title did not use the remote host"
    [[ $(grep -Fxc 'rename-window -- codex' "$title_log") -ge 3 ]] \
        || fail "ai-menu did not replace its outer title with the selected harness"
    [[ $(grep -Fxc 'rename-window -- grimoire' "$title_log") -ge 2 ]] \
        || fail "ai-menu did not replace its outer title with the selected SSH host"
    rm -f "$FAKE_BIN/tmux" "$FAKE_BIN/codex" "$FAKE_BIN/ssh" "$FAKE_BIN/fzf"
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

# Provide minimal POSIX utilities so the macOS simulation can run with
# PATH=$FAKE_BIN only — keeping /usr/bin out prevents the host's real tmux
# from shadowing the "tmux not found" path we need to exercise.
cp /usr/bin/touch /usr/bin/chmod /usr/bin/cat /usr/bin/dirname \
   /usr/bin/mkdir /usr/bin/rm /usr/bin/awk /usr/bin/cp "$FAKE_BIN/"

export TEST_TMP
PATH="$FAKE_BIN"
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
cp "$FAKE_BIN/uname" /usr/bin/touch "$NO_PKG_BIN/"
PATH="$NO_PKG_BIN"
export PATH
_write_helper() { touch "$TEST_TMP/helper-written"; }
_upsert_blocks() { touch "$TEST_TMP/blocks-written"; }
if install >"$TEST_TMP/install-output" 2>&1; then
    fail "install unexpectedly succeeded without tmux or a package manager"
fi
[[ ! -e "$TEST_TMP/helper-written" && ! -e "$TEST_TMP/blocks-written" ]] \
    || fail "install wrote module surfaces before satisfying the tmux dependency"

echo "tmux platform tests passed"
