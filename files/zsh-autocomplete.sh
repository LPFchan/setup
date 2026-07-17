#!/usr/bin/env zsh
# setup-module: zsh-autocomplete
# setup-type: script

(( ${+functions[git_clone_if_missing]} )) || source "${${(%):-%x}:A:h}/../lib/script-helpers.sh"

MODULE="zsh-autocomplete"
DIR1="$ZSH_PLUGINS_DIR/zsh-autocomplete"
DIR2="$ZSH_PLUGINS_DIR/zsh-defer"
REPO1="https://github.com/LPFchan/zsh-autocomplete.git"
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
    git_clone_if_missing "$REPO1" "$DIR1" || return 1
    git_clone_if_missing "$REPO2" "$DIR2" || return 1
    _upsert_block || return 1
    _record_state
}

status() {
    if [[ ! -d "$DIR1/.git" ]] || [[ ! -d "$DIR2/.git" ]]; then
        printf '%-25s %-12s\n' "$MODULE" "uninstalled"
        return 2
    fi
    local lr1 lr2 rr1 rr2 combined_local combined_remote
    lr1=$(git_local_ref "$DIR1")
    lr2=$(git_local_ref "$DIR2")
    rr1=$(git_remote_ref "$DIR1")
    rr2=$(git_remote_ref "$DIR2")
    combined_local=$(printf '%s%s' "$lr1" "$lr2" | setup_sha256_string | cut -c1-7)
    combined_remote=$(printf '%s%s' "$rr1" "$rr2" | setup_sha256_string | cut -c1-7)
    if [[ "$lr1" != "$rr1" || "$lr2" != "$rr2" ]]; then
        printf '%-25s %-12s local=%s remote=%s target=%s\n' "$MODULE" "outdated" "$combined_local" "$combined_remote" "$DIR1"
        record_script_state "$MODULE" "git" "$combined_local" "$combined_remote"
        return 1
    fi
    printf '%-25s %-12s local=%s remote=%s target=%s\n' "$MODULE" "current" "$combined_local" "$combined_remote" "$DIR1"
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
