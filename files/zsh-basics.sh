#!/usr/bin/env bash
# setup-module: zsh-basics
# setup-type: script

[[ "$(type -t setup_sha256_string)" == "function" ]] || source "$(dirname "${BASH_SOURCE[0]}")/../lib/script-helpers.sh"

MODULE="zsh-basics"

BLOCK_CONTENT='setopt NO_NOMATCH
WORDCHARS=${WORDCHARS//\//}'

install() {
    _upsert_block
    _record_state
}

status() {
    if ! has_managed_block "$HOME/.zshrc" "zsh-basics"; then
        printf '%-25s %-12s\n' "$MODULE" "uninstalled"
        return 2
    fi
    local expected actual
    expected=$(script_state_for "$MODULE" 2>/dev/null | cut -f3)
    actual=$(awk '/^# >>> setup:zsh-basics >>>/{f=1;next}/^# <<< setup:zsh-basics <<</{f=0}f' "$HOME/.zshrc" | setup_sha256_string)
    if [[ -z "$expected" ]]; then
        printf '%-25s %-12s local=%s\n' "$MODULE" "current" "${actual:0:7}"
        _record_state
        return 0
    fi
    if [[ "$expected" == "$actual" ]]; then
        printf '%-25s %-12s local=%s\n' "$MODULE" "current" "${actual:0:7}"
        _record_state
        return 0
    else
        printf '%-25s %-12s local=%s remote=%s\n' "$MODULE" "outdated" "${actual:0:7}" "${expected:0:7}"
        return 1
    fi
}

update() {
    _upsert_block
    _record_state
}

uninstall() {
    manage_block "$HOME/.zshrc" "zsh-basics" "" "remove"
    remove_script_state "$MODULE"
}

_upsert_block() {
    manage_block "$HOME/.zshrc" "zsh-basics" "$BLOCK_CONTENT" "upsert" "append"
}

_record_state() {
    local h
    h=$(awk '/^# >>> setup:zsh-basics >>>/{f=1;next}/^# <<< setup:zsh-basics <<</{f=0}f' "$HOME/.zshrc" | setup_sha256_string)
    record_script_state "$MODULE" "block" "$h" "$h"
}
