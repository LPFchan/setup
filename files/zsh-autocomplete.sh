#!/usr/bin/env bash
# setup-module: zsh-autocomplete
# setup-type: script

[[ "$(type -t git_clone_if_missing)" == "function" ]] || source "$(dirname "${BASH_SOURCE[0]}")/../lib/script-helpers.sh"

MODULE="zsh-autocomplete"
DIR1="$ZSH_PLUGINS_DIR/zsh-autocomplete"
DIR2="$ZSH_PLUGINS_DIR/zsh-defer"
REPO1="git@github.com:LPFchan/zsh-autocomplete.git"
REPO2="https://github.com/romkatv/zsh-defer.git"

BLOCK_CONTENT='if [[ -d "$HOME/.zsh/zsh-autocomplete" && -d "$HOME/.zsh/zsh-defer" ]]; then
    source ~/.zsh/zsh-autocomplete/zsh-autocomplete.plugin.zsh
    source ~/.zsh/zsh-defer/zsh-defer.plugin.zsh
    zstyle '\'':autocomplete:'\'' persist-context yes
    zstyle '\'':autocomplete:'\'' min-input 1
    zstyle '\'':autocomplete:'\'' default-context history-incremental-search-backward
    setopt histignorealldups sharehistory
    HISTSIZE=1000
    SAVEHIST=1000
    HISTFILE=~/.zsh_history
fi'

install() {
    git_clone_if_missing "$REPO1" "$DIR1"
    git_clone_if_missing "$REPO2" "$DIR2"
    _upsert_block
    _record_state
}

status() {
    if [[ ! -d "$DIR1/.git" ]] || [[ ! -d "$DIR2/.git" ]]; then
        printf '%-25s %-12s\n' "$MODULE" "uninstalled"
        return 2
    fi
    local s1 s2 rc1 rc2
    s1=$(git_check_status "$DIR1"); rc1=$?
    s2=$(git_check_status "$DIR2"); rc2=$?
    if [[ $rc1 -eq 1 || $rc2 -eq 1 ]]; then
        printf '%-25s %-12s %s | %s\n' "$MODULE" "outdated" "$s1" "$s2"
        record_script_state "$MODULE" "git" \
            "$(git_local_ref "$DIR1" | cut -c1-7)+$(git_local_ref "$DIR2" | cut -c1-7)" \
            "$(git_remote_ref "$DIR1" | cut -c1-7)+$(git_remote_ref "$DIR2" | cut -c1-7)"
        return 1
    fi
    printf '%-25s %-12s %s | %s\n' "$MODULE" "current" "$s1" "$s2"
    _record_state
    return 0
}

update() {
    if [[ -d "$DIR1/.git" ]]; then
        git_pull_ff "$DIR1"
    else
        install; return
    fi
    if [[ -d "$DIR2/.git" ]]; then
        git_pull_ff "$DIR2"
    fi
    _upsert_block
    _record_state
}

uninstall() {
    rm -rf "$DIR1" "$DIR2"
    manage_block "$HOME/.zshrc" "zsh-autocomplete" "" "remove"
    remove_script_state "$MODULE"
    [[ -d "$ZSH_PLUGINS_DIR" ]] && [[ -z "$(ls -A "$ZSH_PLUGINS_DIR" 2>/dev/null)" ]] && rmdir "$ZSH_PLUGINS_DIR"
}

_upsert_block() {
    manage_block "$HOME/.zshrc" "zsh-autocomplete" "$BLOCK_CONTENT" "upsert" "append"
}

_record_state() {
    local ref1 ref2
    ref1=$(git_local_ref "$DIR1")
    ref2=$(git_local_ref "$DIR2")
    record_script_state "$MODULE" "git" "${ref1:0:7}+${ref2:0:7}" "${ref1:0:7}+${ref2:0:7}"
}
