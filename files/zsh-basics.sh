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
        printf '%-25s %-12s target=%s\n' "$MODULE" "missing" "$HOME/.zshrc"
        return 2
    fi
    local expected actual
    expected=$(setup_sha256_string "$BLOCK_CONTENT")
    actual=$(awk '/^# >>> setup:zsh-basics >>>/{f=1;next}/^# <<< setup:zsh-basics <<</{f=0}f' "$HOME/.zshrc" | sed '$ { /^$/ d; }' | setup_sha256_string)
    if [[ "$expected" == "$actual" ]]; then
        printf '%-25s %-12s target=%s\n' "$MODULE" "managed" "$HOME/.zshrc"
        _record_state
        return 0
    else
        printf '%-25s %-12s target=%s\n' "$MODULE" "modified" "$HOME/.zshrc"
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
    h=$(setup_sha256_string "$BLOCK_CONTENT")
    record_script_state "$MODULE" "block" "$h" "$h"
}
