#!/usr/bin/env bash
# setup-module: zsh-basics
# setup-type: script

[[ "$(type -t setup_sha256_string)" == "function" ]] || source "$(dirname "${BASH_SOURCE[0]}")/../lib/script-helpers.sh"

MODULE="zsh-basics"
ZSHENV="$HOME/.zshenv"

BLOCK_CONTENT='[[ -o interactive && -t 0 ]] || return
[[ -n ${TERM_PROGRAM-} || -n ${SSH_TTY-} || -n ${TMUX-} ]] || return

alias /exit='"'"'exit'"'"'

setopt NO_NOMATCH
# NFD Hangul (macOS drag-and-drop paths, APFS filenames) renders as <11xx>
# placeholders and garbles ZLE redraw/cursor math without this.
setopt COMBINING_CHARS
bindkey -e
WORDCHARS=${WORDCHARS//\//}'

# Shared machine identity for shell-launched tools. POSIX cksum makes the hue
# stable for a given short hostname; the integer HSV conversion fixes
# saturation and value/brightness at 100%, varying only hue.
COLOR_BLOCK_CONTENT='_setup_color_host=$(hostname -s 2>/dev/null || hostname)
_setup_color_host=${_setup_color_host%%.*}
_setup_color_host=$(printf "%s" "$_setup_color_host" | tr "[:upper:]" "[:lower:]")
_setup_color_hash=$(printf "%s" "$_setup_color_host" | cksum)
_setup_color_hash=${_setup_color_hash%% *}
case "$_setup_color_hash" in ""|*[!0-9]*) _setup_color_hash=0 ;; esac
SYSTEM_COLOR_HUE=$((_setup_color_hash % 360))
_setup_color_sector=$((SYSTEM_COLOR_HUE / 60))
_setup_color_offset=$((SYSTEM_COLOR_HUE % 60))
case "$_setup_color_sector" in
    0) _setup_color_r=255; _setup_color_g=$((255 * _setup_color_offset / 60)); _setup_color_b=0 ;;
    1) _setup_color_r=$((255 * (60 - _setup_color_offset) / 60)); _setup_color_g=255; _setup_color_b=0 ;;
    2) _setup_color_r=0; _setup_color_g=255; _setup_color_b=$((255 * _setup_color_offset / 60)) ;;
    3) _setup_color_r=0; _setup_color_g=$((255 * (60 - _setup_color_offset) / 60)); _setup_color_b=255 ;;
    4) _setup_color_r=$((255 * _setup_color_offset / 60)); _setup_color_g=0; _setup_color_b=255 ;;
    *) _setup_color_r=255; _setup_color_g=0; _setup_color_b=$((255 * (60 - _setup_color_offset) / 60)) ;;
esac
SYSTEM_COLOR_HEX=$(printf "#%02X%02X%02X" "$_setup_color_r" "$_setup_color_g" "$_setup_color_b")
if ((299 * _setup_color_r + 587 * _setup_color_g + 114 * _setup_color_b >= 128000)); then
    SYSTEM_COLOR_TEXT_HEX="#000000"
else
    SYSTEM_COLOR_TEXT_HEX="#FFFFFF"
fi
export SYSTEM_COLOR_HUE SYSTEM_COLOR_HEX SYSTEM_COLOR_TEXT_HEX
unset _setup_color_host _setup_color_hash _setup_color_sector _setup_color_offset
unset _setup_color_r _setup_color_g _setup_color_b'

install() {
    _upsert_blocks
    _activate_system_color
    _record_state
}

status() {
    if ! has_managed_block "$HOME/.zshrc" "zsh-basics" \
       && ! has_managed_block "$ZSHENV" "system-color"; then
        printf '%-25s %-12s\n' "$MODULE" "uninstalled"
        return 2
    fi
    # Compare the combined desired and installed .zshrc/.zshenv surfaces so a
    # missing or edited system-color block is repaired by setup update.
    local expected actual
    expected=$(_desired_hash)
    actual=$(_state_hash)
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
    _upsert_blocks
    _activate_system_color
    _record_state
}

uninstall() {
    manage_block "$HOME/.zshrc" "zsh-basics" "" "remove"
    manage_block "$HOME/.zshrc" "zsh-init" "" "remove"
    manage_block "$HOME/.zshrc" "zsh-ai" "" "remove"
    manage_block "$ZSHENV" "system-color" "" "remove"
    remove_script_state "$MODULE"
}

_upsert_blocks() {
    # Adopt the behavior previously owned by core setup under zsh-init (and its
    # older zsh-ai name) into this module's lifecycle-managed surfaces.
    manage_block "$HOME/.zshrc" "zsh-init" "" "remove"
    manage_block "$HOME/.zshrc" "zsh-ai" "" "remove"
    manage_block "$HOME/.zshrc" "zsh-basics" "$BLOCK_CONTENT" "upsert" "prepend"
    manage_block "$ZSHENV" "system-color" "$COLOR_BLOCK_CONTENT" "upsert" "append"
}

_activate_system_color() {
    eval "$COLOR_BLOCK_CONTENT"
}

_state_hash() {
    local basics color
    basics=$([[ -f "$HOME/.zshrc" ]] && awk '/^# >>> setup:zsh-basics >>>/{f=1;next}/^# <<< setup:zsh-basics <<</{f=0}f' "$HOME/.zshrc")
    color=$([[ -f "$ZSHENV" ]] && awk '/^# >>> setup:system-color >>>/{f=1;next}/^# <<< setup:system-color <<</{f=0}f' "$ZSHENV")
    printf '%s\n%s' "$basics" "$color" | setup_sha256_string
}

_desired_hash() {
    local basics color
    basics=$(setup_managed_block_body "$BLOCK_CONTENT")
    color=$(setup_managed_block_body "$COLOR_BLOCK_CONTENT")
    printf '%s\n%s' "$basics" "$color" | setup_sha256_string
}

_record_state() {
    local h
    h=$(_state_hash)
    record_script_state "$MODULE" "block" "$h" "$h"
}
