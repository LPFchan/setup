#!/usr/bin/env bash
# setup-module: zsh-basics
# setup-type: script

[[ "$(type -t setup_sha256_string)" == "function" ]] || source "$(dirname "${BASH_SOURCE[0]}")/../lib/script-helpers.sh"

MODULE="zsh-basics"

BLOCK_CONTENT='[[ -o interactive && -t 0 ]] || return
[[ -n ${TERM_PROGRAM-} || -n ${SSH_TTY-} || -n ${TMUX-} ]] || return

alias /exit='"'"'exit'"'"'

setopt NO_NOMATCH
bindkey -e
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
    # expected = hash of the block body derived from BLOCK_CONTENT (source of
    # truth), so drift between source and the installed block is detected.
    local expected actual
    expected=$(setup_managed_block_body "$BLOCK_CONTENT" | setup_sha256_string)
    actual=$(awk '/^# >>> setup:zsh-basics >>>/{f=1;next}/^# <<< setup:zsh-basics <<</{f=0}f' "$HOME/.zshrc" | setup_sha256_string)
    if [[ "$expected" == "$actual" ]]; then
        printf '%-25s %-12s local=%s remote=%s target=%s\n' "$MODULE" "current" "${actual:0:7}" "${expected:0:7}" "$HOME/.zshrc"
        _record_state
        return 0
    else
        printf '%-25s %-12s local=%s remote=%s target=%s\n' "$MODULE" "outdated" "${actual:0:7}" "${expected:0:7}" "$HOME/.zshrc"
        return 1
    fi
}

update() {
    _upsert_block
    _record_state
}

uninstall() {
    manage_block "$HOME/.zshrc" "zsh-basics" "" "remove"
    manage_block "$HOME/.zshrc" "zsh-init" "" "remove"
    manage_block "$HOME/.zshrc" "zsh-ai" "" "remove"
    remove_script_state "$MODULE"
}

_upsert_block() {
    # Adopt the behavior previously owned by core setup under zsh-init (and its
    # older zsh-ai name) into this module's single lifecycle-managed block.
    manage_block "$HOME/.zshrc" "zsh-init" "" "remove"
    manage_block "$HOME/.zshrc" "zsh-ai" "" "remove"
    manage_block "$HOME/.zshrc" "zsh-basics" "$BLOCK_CONTENT" "upsert" "prepend"
}

_record_state() {
    local h
    h=$(awk '/^# >>> setup:zsh-basics >>>/{f=1;next}/^# <<< setup:zsh-basics <<</{f=0}f' "$HOME/.zshrc" | setup_sha256_string)
    record_script_state "$MODULE" "block" "$h" "$h"
}
