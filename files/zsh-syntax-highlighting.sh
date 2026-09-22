#!/usr/bin/env zsh
# setup-module: zsh-syntax-highlighting
# setup-type: script

(( ${+functions[git_clone_if_missing]} )) || source "${${(%):-%x}:A:h}/../lib/script-helpers.sh"

MODULE="zsh-syntax-highlighting"
DIR="$ZSH_PLUGINS_DIR/zsh-syntax-highlighting"
REPO="https://github.com/zsh-users/zsh-syntax-highlighting.git"

# Guarded on the file it sources, not the directory holding it: an
# interrupted clone leaves the directory with the file still missing, and a
# directory test passes right before the source fails. Same defect the
# zsh-omnibar rename made visible.
BLOCK_CONTENT='if [[ -o interactive && -t 0 ]] \
   && [[ -n ${TERM_PROGRAM-} || -n ${SSH_TTY-} || -n ${TMUX-} ]] \
   && [[ -r "$HOME/.zsh/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" ]] \
   && (( ${+functions[zsh-defer]} )); then
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
    local lr rr
    lr=$(git_local_ref "$DIR" | cut -c1-7)
    rr=$(git_remote_ref "$DIR" | cut -c1-7)
    if [[ "$lr" != "$rr" ]]; then
        printf '%-25s %-12s local=%s remote=%s target=%s\n' "$MODULE" "outdated" "$lr" "$rr" "$DIR"
        record_script_state "$MODULE" "git" "$lr" "$rr"
        return 1
    fi
    printf '%-25s %-12s local=%s remote=%s target=%s\n' "$MODULE" "current" "$lr" "$rr" "$DIR"
    _record_state
    return 0
}

update() {
    if [[ ! -d "$DIR/.git" ]]; then
        install
        return
    fi
    # A failed pull is a failed update; the return code used to be discarded.
    # The block is still written -- it is guarded on the file it sources --
    # but state is not recorded, because that would mark the module current
    # while it is still behind.
    local pull_rc=0
    git_pull_ff "$DIR" || pull_rc=1
    _upsert_block || return 1
    (( pull_rc == 0 )) || return 1
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
