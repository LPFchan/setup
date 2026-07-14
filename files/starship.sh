#!/usr/bin/env bash
# setup-module: starship
# setup-type: script

[[ "$(type -t git_clone_if_missing)" == "function" ]] || source "$(dirname "${BASH_SOURCE[0]}")/../lib/script-helpers.sh"

MODULE="starship"
BIN="$HOME/.local/bin/starship"

BLOCK_CONTENT='if command -v starship >/dev/null; then
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
    _record_state
}

uninstall() {
    rm -f "$BIN"
    manage_block "$HOME/.zshrc" "starship" "" "remove"
    remove_script_state "$MODULE"
}

_upsert_block() {
    manage_block "$HOME/.zshrc" "starship" "$BLOCK_CONTENT" "upsert" "append"
}

_record_state() {
    if [[ -x "$BIN" ]]; then
        local ver
        ver=$("$BIN" --version 2>/dev/null | awk 'NR==1{print $2}')
        record_script_state "$MODULE" "version" "${ver:-unknown}" "${ver:-unknown}"
    fi
}
