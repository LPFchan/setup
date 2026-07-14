#!/usr/bin/env bash
# setup-module: tmux
# setup-type: script
#
# Manages a block in ~/.tmux.conf (mouse + status bar: hostname left,
# `CPU% - RAM%` right) AND installs the tmux-cpu-mem status helper to
# ~/.local/bin. Uninstalling this module removes both surfaces.

[[ "$(type -t setup_sha256_string)" == "function" ]] || source "$(dirname "${BASH_SOURCE[0]}")/../lib/script-helpers.sh"

MODULE="tmux"
TMUX_CONF="$HOME/.tmux.conf"
HELPER="$HOME/.local/bin/tmux-cpu-mem"

BLOCK_CONTENT='set -g default-terminal "tmux-256color"
set -as terminal-features ",xterm*:RGB"
set -g mouse on
set -g status-interval 5
set -g status-left " #h "
set -g status-right "#(tmux-cpu-mem) "'

# Instantaneous CPU via a /proc/stat delta cached across calls (no sleep),
# RAM as (total-available)/total. Prints `CPU N% - RAM N%`.
_write_helper() {
    mkdir -p "$(dirname "$HELPER")"
    cat > "$HELPER" <<'CPUMEM'
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
    chmod 0755 "$HELPER"
}

_upsert_block() {
    manage_block "$TMUX_CONF" "tmux" "$BLOCK_CONTENT" "upsert" "append"
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

# Combined hash over the .tmux.conf block and the installed helper, so drift in
# either surface is detected.
_state_hash() {
    local block helper
    block=$(awk '/^# >>> setup:tmux >>>/{f=1;next}/^# <<< setup:tmux <<</{f=0}f' "$TMUX_CONF")
    helper=$([[ -f "$HELPER" ]] && cat "$HELPER")
    printf '%s\n%s' "$block" "$helper" | setup_sha256_string
}

_record_state() {
    local h
    h=$(_state_hash)
    record_script_state "$MODULE" "block" "$h" "$h"
}

install() {
    _write_helper
    _upsert_block
    _record_state
    _reload
}

update() { install; }

status() {
    if ! has_managed_block "$TMUX_CONF" "tmux" || [[ ! -f "$HELPER" ]]; then
        printf '%-25s %-12s\n' "$MODULE" "uninstalled"
        return 2
    fi
    local expected actual
    expected=$(script_state_for "$MODULE" 2>/dev/null | cut -f3)
    actual=$(_state_hash)
    if [[ -z "$expected" || "$expected" == "$actual" ]]; then
        printf '%-25s %-12s local=%s remote=%s target=%s\n' "$MODULE" "current" "${actual:0:7}" "${actual:0:7}" "$TMUX_CONF"
        _record_state
        return 0
    fi
    printf '%-25s %-12s local=%s remote=%s target=%s\n' "$MODULE" "outdated" "${actual:0:7}" "${expected:0:7}" "$TMUX_CONF"
    return 1
}

uninstall() {
    manage_block "$TMUX_CONF" "tmux" "" "remove"
    rm -f "$HELPER"
    remove_script_state "$MODULE"
}
