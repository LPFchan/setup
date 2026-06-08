#!/usr/bin/env bash
# setup-module: zsh-syntax-highlighting
# setup-type: script

[[ "$(type -t git_clone_if_missing)" == "function" ]] || source "$(dirname "${BASH_SOURCE[0]}")/../lib/script-helpers.sh"

MODULE="zsh-syntax-highlighting"
DIR="$ZSH_PLUGINS_DIR/zsh-syntax-highlighting"
REPO="https://github.com/zsh-users/zsh-syntax-highlighting.git"

BLOCK_CONTENT='if [[ -d "$HOME/.zsh/zsh-syntax-highlighting" ]] && (( ${+functions[zsh-defer]} )); then
    zsh-defer source "$HOME/.zsh/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
fi'

install() {
    git_clone_if_missing "$REPO" "$DIR"
    _upsert_block
    _record_state
}

status() {
    if [[ ! -d "$DIR/.git" ]]; then
        printf '%-25s %-12s\n' "$MODULE" "uninstalled"
        return 2
    fi
    local s rc
    s=$(git_check_status "$DIR"); rc=$?
    if [[ $rc -eq 1 ]]; then
        printf '%-25s %-12s %s\n' "$MODULE" "outdated" "$s"
        record_script_state "$MODULE" "git" "$(git_local_ref "$DIR" | cut -c1-7)" "$(git_remote_ref "$DIR" | cut -c1-7)"
        return 1
    fi
    printf '%-25s %-12s %s\n' "$MODULE" "current" "$s"
    _record_state
    return 0
}

update() {
    if [[ -d "$DIR/.git" ]]; then
        git_pull_ff "$DIR"
    else
        install; return
    fi
    _upsert_block
    _record_state
}

uninstall() {
    rm -rf "$DIR"
    manage_block "$HOME/.zshrc" "zsh-syntax-highlighting" "" "remove"
    remove_script_state "$MODULE"
}

_upsert_block() {
    manage_block "$HOME/.zshrc" "zsh-syntax-highlighting" "$BLOCK_CONTENT" "upsert" "append"
}

_record_state() {
    local ref
    ref=$(git_local_ref "$DIR")
    record_script_state "$MODULE" "git" "${ref:0:7}" "${ref:0:7}"
}
