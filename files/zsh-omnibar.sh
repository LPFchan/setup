#!/usr/bin/env zsh
# setup-module: zsh-omnibar
# setup-type: script

(( ${+functions[git_clone_if_missing]} )) || source "${${(%):-%x}:A:h}/../lib/script-helpers.sh"

MODULE="zsh-omnibar"
DIR1="$ZSH_PLUGINS_DIR/zsh-omnibar"

# Previous names, kept only for the one-time migration below.
OLD_MODULE="zsh-autocomplete"
OLD_DIR1="$ZSH_PLUGINS_DIR/zsh-autocomplete"
DIR2="$ZSH_PLUGINS_DIR/zsh-defer"
REPO1="https://github.com/LPFchan/zsh-omnibar.git"
REPO2="https://github.com/romkatv/zsh-defer.git"

# The guard tests the two files this sources, not the directories holding
# them. A directory test cannot protect a file source: the rename shipped a
# block sourcing zsh-omnibar.plugin.zsh, which only exists past the rename
# commit, so every checkout that had not pulled it yet passed the directory
# test and then failed the source on every single shell start.
BLOCK_CONTENT='if [[ -o interactive && -t 0 ]] \
   && [[ -n ${TERM_PROGRAM-} || -n ${SSH_TTY-} || -n ${TMUX-} ]] \
   && [[ -r "$HOME/.zsh/zsh-omnibar/zsh-omnibar.plugin.zsh" \
      && -r "$HOME/.zsh/zsh-defer/zsh-defer.plugin.zsh" ]]; then
    source ~/.zsh/zsh-omnibar/zsh-omnibar.plugin.zsh
    source ~/.zsh/zsh-defer/zsh-defer.plugin.zsh
    zstyle '\'':autocomplete:'\'' min-input 1
    zstyle '\'':autocomplete:'\'' default-context history-incremental-search-backward
    setopt histignorealldups sharehistory
    HISTSIZE=1000
    SAVEHIST=1000
    HISTFILE=~/.zsh_history
fi'

# One-time move from the old name. Has to run before anything else touches
# .zshrc or the clone.
#
# The block label is what manage_block matches on, so simply renaming the
# module would leave the old block sitting in .zshrc next to the new one, both
# sourcing the plugin. And the clone carries local commits, so it is moved
# rather than re-cloned.
_migrate_from_old_name() {
    # Nothing to do on a machine that never had the old name.
    [[ -e "$OLD_DIR1" ]] || return 0

    if [[ -e "$DIR1" ]]; then
        # `mv src existing_dir` moves the source *inside* it, so the clone
        # would end up at ~/.zsh/zsh-omnibar/zsh-autocomplete while this
        # reported success. Refuse instead, and leave the old block in place:
        # a stale block that still works beats none at all.
        print -u2 "zsh-omnibar: cannot migrate, $DIR1 already exists"
        return 1
    fi

    # Moved, not re-cloned: the checkout carries local commits.
    mv "$OLD_DIR1" "$DIR1" || return 1

    # Only now is it safe to drop the old block. Doing this before the move
    # succeeds can leave .zshrc with no plugin block at all -- which also
    # takes out zsh-defer, and with it syntax highlighting.
    manage_block "$HOME/.zshrc" "$OLD_MODULE" "" "remove"
    remove_script_state "$OLD_MODULE"
    return 0
}

install() {
    _migrate_from_old_name || return 1
    git_clone_if_missing "$REPO1" "$DIR1" || return 1
    git_clone_if_missing "$REPO2" "$DIR2" || return 1
    _upsert_block || return 1
    _record_state
}

status() {
    # A machine still on the old name counts as installed-but-outdated, not
    # uninstalled. `cmd_update` does nothing for "uninstalled" except count it,
    # so probing only for the post-migration directory meant the unattended
    # path never called update() and the migration never ran.
    if [[ ! -d "$DIR1/.git" && -d "$OLD_DIR1/.git" && -d "$DIR2/.git" ]]; then
        printf '%-25s %-12s local=%s remote=%s target=%s\n' \
            "$MODULE" "outdated" "pre-rename" "migrate" "$OLD_DIR1"
        record_script_state "$MODULE" "git" "pre-rename" "migrate"
        return 1
    fi
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
    _migrate_from_old_name || return 1
    if [[ ! -d "$DIR1/.git" ]]; then
        install
        return
    fi
    # A failed pull is a failed update. Both return codes used to be
    # discarded, so a checkout that could not fast-forward was reported as
    # succeeded=1 while the plugin sat on whatever commit it was already on.
    # That is how a machine whose `main` tracked the old third-party upstream
    # instead of the fork went a full sync cycle looking healthy.
    local pull_rc=0
    git_pull_ff "$DIR1" || pull_rc=1
    if [[ -d "$DIR2/.git" ]]; then
        git_pull_ff "$DIR2" || pull_rc=1
    fi
    # The block is written either way. It is guarded on the files it sources,
    # so a checkout that did not move just leaves the guard unmet and the
    # shell starts clean. Recording state is not: _record_state writes
    # local==remote, which would mark the module current while it is behind.
    _upsert_block || return 1
    (( pull_rc == 0 )) || return 1
    _record_state
}

uninstall() {
    rm -rf "$DIR1" "$DIR2"
    manage_block "$HOME/.zshrc" "zsh-omnibar" "" "remove"
    remove_script_state "$MODULE"
    [[ -d "$ZSH_PLUGINS_DIR" ]] && [[ -z "$(ls -A "$ZSH_PLUGINS_DIR" 2>/dev/null)" ]] && rmdir "$ZSH_PLUGINS_DIR"
}

_upsert_block() {
    manage_block "$HOME/.zshrc" "zsh-omnibar" "$BLOCK_CONTENT" "upsert" "append"
}

_record_state() {
    local ref1 ref2
    ref1=$(git_local_ref "$DIR1")
    ref2=$(git_local_ref "$DIR2")
    record_script_state "$MODULE" "git" "${ref1:0:7}+${ref2:0:7}" "${ref1:0:7}+${ref2:0:7}"
}
