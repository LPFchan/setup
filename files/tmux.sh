#!/usr/bin/env bash
# setup-module: tmux
# setup-type: script
#
# Manages tmux settings in ~/.tmux.conf, installs the tmux-cpu-mem status
# helper, and owns the ~/.zshrc block that auto-launches every interactive shell
# into the shared `main` session. Uninstalling removes all three surfaces.

[[ "$(type -t setup_sha256_string)" == "function" ]] || source "$(dirname "${BASH_SOURCE[0]}")/../lib/script-helpers.sh"

MODULE="tmux"
TMUX_CONF="$HOME/.tmux.conf"
HELPER="$HOME/.local/bin/tmux-cpu-mem"
ZSHRC="$HOME/.zshrc"

BLOCK_CONTENT='set -g default-terminal "tmux-256color"
set -as terminal-features ",xterm*:RGB"
set -g mouse on
bind -T copy-mode WheelUpPane select-pane \; send-keys -X -N 1 scroll-up
bind -T copy-mode WheelDownPane select-pane \; send-keys -X -N 1 scroll-down
bind -T copy-mode-vi WheelUpPane select-pane \; send-keys -X -N 1 scroll-up
bind -T copy-mode-vi WheelDownPane select-pane \; send-keys -X -N 1 scroll-down
set -g status-interval 5
set -g status-left " #h "
set -g status-right "#(tmux-cpu-mem) "'

AUTOSTART_BLOCK_CONTENT='if [[ -o interactive && -z $TMUX ]] && command -v tmux >/dev/null; then
  exec tmux new-session -A -s main
fi'

# Instantaneous CPU via a /proc/stat delta cached across calls (no sleep),
# RAM as (total-available)/total. Prints `CPU N% - RAM N%`.
# Desired helper content (source of truth). `_write_helper` installs it and
# `status()` hashes it to detect drift against the installed copy.
_helper_content() {
    cat <<'CPUMEM'
#!/bin/sh
PREV="/tmp/tmux-cpu.$(id -u)"
set -- $(awk '/^cpu /{print $2,$3,$4,$5,$6,$7,$8,$9}' /proc/stat)
idle=$(( $4 + $5 ))
total=$(( $1+$2+$3+$4+$5+$6+$7+$8 ))
if [ -r "$PREV" ]; then read pt pi < "$PREV"; else pt=0; pi=0; fi
echo "$total $idle" > "$PREV"
dt=$(( total - pt )); di=$(( idle - pi ))
cpu=0; [ "$dt" -gt 0 ] && cpu=$(( (100*(dt-di))/dt ))
ram=$(free | awk '/^Mem:/{printf "%.0f",($2-$7)/$2*100}')
printf 'CPU %d%% - RAM %d%%' "$cpu" "$ram"
CPUMEM
}

_write_helper() {
    mkdir -p "$(dirname "$HELPER")"
    _helper_content > "$HELPER"
    chmod 0755 "$HELPER"
}

_upsert_blocks() {
    manage_block "$TMUX_CONF" "tmux" "$BLOCK_CONTENT" "upsert" "append"
    manage_block "$ZSHRC" "tmux-autostart" "$AUTOSTART_BLOCK_CONTENT" "upsert" "prepend"
}

# If a tmux server is already running, reload the config so the new block takes
# effect without a manual source-file. Note: terminal-features/RGB (truecolor)
# is only re-read when a client (re)attaches, so an already-attached session
# needs a detach+reattach to pick up the color change (mouse/status apply live).
_reload() {
    command -v tmux >/dev/null 2>&1 || return 0
    tmux info >/dev/null 2>&1 || return 0   # no server running → nothing to reload
    tmux source-file "$TMUX_CONF" >/dev/null 2>&1 || true
}

# Combined hash over the .tmux.conf block, autostart block, and installed helper,
# so drift in any owned surface is detected.
_state_hash() {
    local block autostart helper
    block=""
    autostart=""
    [[ -f "$TMUX_CONF" ]] && block=$(awk '/^# >>> setup:tmux >>>/{f=1;next}/^# <<< setup:tmux <<</{f=0}f' "$TMUX_CONF")
    [[ -f "$ZSHRC" ]] && autostart=$(awk '/^# >>> setup:tmux-autostart >>>/{f=1;next}/^# <<< setup:tmux-autostart <<</{f=0}f' "$ZSHRC")
    helper=$([[ -f "$HELPER" ]] && cat "$HELPER")
    printf '%s\n%s\n%s' "$block" "$autostart" "$helper" | setup_sha256_string
}

# Combined hash over all desired module-owned content, so status() detects drift
# between source and any installed surface.
_desired_hash() {
    local block autostart helper
    block=$(setup_managed_block_body "$BLOCK_CONTENT")
    autostart=$(setup_managed_block_body "$AUTOSTART_BLOCK_CONTENT")
    helper=$(_helper_content)
    printf '%s\n%s\n%s' "$block" "$autostart" "$helper" | setup_sha256_string
}

_record_state() {
    local h
    h=$(_state_hash)
    record_script_state "$MODULE" "block" "$h" "$h"
}

install() {
    _write_helper
    _upsert_blocks
    _record_state
    _reload
}

update() { install; }

status() {
    if ! has_managed_block "$TMUX_CONF" "tmux" \
       && ! has_managed_block "$ZSHRC" "tmux-autostart" \
       && [[ ! -f "$HELPER" ]]; then
        printf '%-25s %-12s\n' "$MODULE" "uninstalled"
        return 2
    fi
    local expected actual
    expected=$(_desired_hash)
    actual=$(_state_hash)
    if [[ "$expected" == "$actual" ]]; then
        printf '%-25s %-12s local=%s remote=%s target=%s\n' "$MODULE" "current" "${actual:0:7}" "${expected:0:7}" "$TMUX_CONF"
        _record_state
        return 0
    fi
    printf '%-25s %-12s local=%s remote=%s target=%s\n' "$MODULE" "outdated" "${actual:0:7}" "${expected:0:7}" "$TMUX_CONF"
    return 1
}

uninstall() {
    manage_block "$TMUX_CONF" "tmux" "" "remove"
    manage_block "$ZSHRC" "tmux-autostart" "" "remove"
    rm -f "$HELPER"
    remove_script_state "$MODULE"
}
