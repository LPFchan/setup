#!/usr/bin/env zsh
# setup-module: starship
# setup-type: script

(( ${+functions[git_clone_if_missing]} )) || source "${${(%):-%x}:A:h}/../lib/script-helpers.sh"

MODULE="starship"
BIN="$HOME/.local/bin/starship"
CONFIG_SRC="${${(%):-%x}:A:h}/starship.toml"
CONFIG_DST="${XDG_CONFIG_HOME:-$HOME/.config}/starship.toml"

BLOCK_CONTENT='if [[ -o interactive && -t 0 ]] \
   && [[ -n ${TERM_PROGRAM-} || -n ${SSH_TTY-} || -n ${TMUX-} ]] \
   && command -v starship >/dev/null; then
    _STARSHIP_CACHE="$HOME/.cache/starship-init.zsh"
    if [[ -f "$_STARSHIP_CACHE" ]]; then
        source "$_STARSHIP_CACHE"
    else
        mkdir -p "$HOME/.cache" 2>/dev/null
        starship init zsh > "$_STARSHIP_CACHE" 2>/dev/null && source "$_STARSHIP_CACHE"
    fi
fi'

install() {
    if [[ -x "$BIN" ]]; then
        echo "starship already installed: $("$BIN" --version | head -1)"
    else
        curl -fsSL https://starship.rs/install.sh | sh -s -- -y -b "$HOME/.local/bin"
    fi
    _upsert_block
    _link_config
    _record_state
}

status() {
    if [[ ! -x "$BIN" ]]; then
        printf '%-25s %-12s\n' "$MODULE" "uninstalled"
        return 2
    fi
    local installed_ver latest_ver
    installed_ver=$("$BIN" --version 2>/dev/null | awk 'NR==1{print $2}')
    latest_ver=$(curl -fsSL "https://api.github.com/repos/starship/starship/releases/latest" \
        2>/dev/null | grep '"tag_name"' | head -1 | sed 's/.*"v\(.*\)".*/\1/' || true)
    if [[ -z "$latest_ver" ]]; then
        printf '%-25s %-12s local=%s remote=%s target=%s\n' "$MODULE" "installed" "$installed_ver" "$installed_ver" "$BIN"
        record_script_state "$MODULE" "version" "$installed_ver" "$installed_ver"
        return 0
    fi
    if [[ "$installed_ver" == "$latest_ver" ]]; then
        printf '%-25s %-12s local=%s remote=%s target=%s\n' "$MODULE" "current" "$installed_ver" "$latest_ver" "$BIN"
        record_script_state "$MODULE" "version" "$installed_ver" "$latest_ver"
        return 0
    else
        printf '%-25s %-12s local=%s remote=%s target=%s\n' "$MODULE" "outdated" "$installed_ver" "$latest_ver" "$BIN"
        record_script_state "$MODULE" "version" "$installed_ver" "$latest_ver"
        return 1
    fi
}

update() {
    curl -fsSL https://starship.rs/install.sh | sh -s -- -y -b "$HOME/.local/bin"
    _upsert_block
    _link_config
    _record_state
}

uninstall() {
    rm -f "$BIN"
    # Only remove the link if it is ours; a user's own config stays put.
    [[ -L "$CONFIG_DST" && "$(readlink "$CONFIG_DST")" == "$CONFIG_SRC" ]] &&
        rm -f "$CONFIG_DST"
    manage_block "$HOME/.zshrc" "starship" "" "remove"
    remove_script_state "$MODULE"
}

_upsert_block() {
    manage_block "$HOME/.zshrc" "starship" "$BLOCK_CONTENT" "upsert" "append"
}

# Symlink the repo's config into place, so an edit here reaches every machine
# on the next sync. Anything already there is kept as a .pre-starship.bak
# rather than thrown away. Same approach as the agents module.
_link_config() {
    [[ -f "$CONFIG_SRC" ]] || return 0
    mkdir -p "$(dirname "$CONFIG_DST")"
    if [[ -L "$CONFIG_DST" ]]; then
        [[ "$(readlink "$CONFIG_DST")" == "$CONFIG_SRC" ]] || ln -sfn "$CONFIG_SRC" "$CONFIG_DST"
        return 0
    fi
    if [[ -e "$CONFIG_DST" ]]; then
        local bak="$CONFIG_DST.pre-starship.bak"
        [[ -e "$bak" ]] || mv "$CONFIG_DST" "$bak"
        rm -f "$CONFIG_DST"
    fi
    ln -s "$CONFIG_SRC" "$CONFIG_DST"
}

_record_state() {
    if [[ -x "$BIN" ]]; then
        local ver
        ver=$("$BIN" --version 2>/dev/null | awk 'NR==1{print $2}')
        record_script_state "$MODULE" "version" "${ver:-unknown}" "${ver:-unknown}"
    fi
}
