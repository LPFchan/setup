#!/usr/bin/env bash
# setup-module: tmux
# setup-type: script

[[ "$(type -t setup_sha256_string)" == "function" ]] || source "$(dirname "${BASH_SOURCE[0]}")/../lib/script-helpers.sh"

MODULE="tmux"
TMUX_CONF="$HOME/.tmux.conf"

BLOCK_CONTENT='set -g mouse on
set -g status-interval 5
set -g status-left " #h "
set -g status-right "#(tmux-cpu-mem) "'

install() {
    _upsert_block
    _record_state
}

status() {
    if ! has_managed_block "$TMUX_CONF" "tmux"; then
        printf '%-25s %-12s\n' "$MODULE" "uninstalled"
        return 2
    fi
    local expected actual
    expected=$(script_state_for "$MODULE" 2>/dev/null | cut -f3)
    actual=$(awk '/^# >>> setup:tmux >>>/{f=1;next}/^# <<< setup:tmux <<</{f=0}f' "$TMUX_CONF" | setup_sha256_string)
    if [[ -z "$expected" ]]; then
        printf '%-25s %-12s local=%s remote=%s target=%s\n' "$MODULE" "current" "${actual:0:7}" "${actual:0:7}" "$TMUX_CONF"
        _record_state
        return 0
    fi
    if [[ "$expected" == "$actual" ]]; then
        printf '%-25s %-12s local=%s remote=%s target=%s\n' "$MODULE" "current" "${actual:0:7}" "${expected:0:7}" "$TMUX_CONF"
        _record_state
        return 0
    else
        printf '%-25s %-12s local=%s remote=%s target=%s\n' "$MODULE" "outdated" "${actual:0:7}" "${expected:0:7}" "$TMUX_CONF"
        return 1
    fi
}

update() {
    _upsert_block
    _record_state
}

uninstall() {
    manage_block "$TMUX_CONF" "tmux" "" "remove"
    remove_script_state "$MODULE"
}

_upsert_block() {
    manage_block "$TMUX_CONF" "tmux" "$BLOCK_CONTENT" "upsert" "append"
}

_record_state() {
    local h
    h=$(awk '/^# >>> setup:tmux >>>/{f=1;next}/^# <<< setup:tmux <<</{f=0}f' "$TMUX_CONF" | setup_sha256_string)
    record_script_state "$MODULE" "block" "$h" "$h"
}
