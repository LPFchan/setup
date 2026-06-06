#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${LINUX_SETUP_BASE_URL:-https://setup.lost.plus}"
FALLBACK_URL="${LINUX_SETUP_FALLBACK_URL:-https://raw.githubusercontent.com/LPFchan/setup/main}"
BIN_DIR="$HOME/.local/bin"
TARGET="$BIN_DIR/setup"
has_path_setup() {
    local file="$1"
    [[ -f "$file" ]] || return 1
    grep -Eq '(^|["=:])\$HOME/\.local/bin|(^|["=:])~/\.local/bin|(^|["=:])/.*/\.local/bin' "$file"
}

has_ai_autolaunch() {
    local file="$1"
    [[ -f "$file" ]] || return 1
    grep -Eq 'ai-start-menu' "$file" \
        && grep -Eq 'AI_AUTO_LAUNCHED' "$file" \
        && grep -Eq '(^|[^[:alnum:]_])ai([[:space:]]*$|[[:space:]]|;|&&|\|\|)' "$file"
}

append_block_once() {
    local file="$1" label="$2" content="$3" dir begin_mark end_mark
    begin_mark="# >>> linux-setup:$label >>>"
    end_mark="# <<< linux-setup:$label <<<"
    dir=$(dirname "$file")
    mkdir -p "$dir"
    touch "$file"
    if grep -Fq "$begin_mark" "$file"; then
        return 0
    fi
    {
        printf '\n%s\n' "$begin_mark"
        printf '%s\n' "$content"
        printf '%s\n' "$end_mark"
    } >> "$file"
    echo "Updated $file"
}

prepend_block_once() {
    local file="$1" label="$2" content="$3" dir begin_mark end_mark tmp
    begin_mark="# >>> linux-setup:$label >>>"
    end_mark="# <<< linux-setup:$label <<<"
    dir=$(dirname "$file")
    mkdir -p "$dir"
    touch "$file"
    if grep -Fq "$begin_mark" "$file"; then
        return 0
    fi
    tmp=$(mktemp)
    {
        printf '%s\n' "$begin_mark"
        printf '%s\n' "$content"
        printf '%s\n\n' "$end_mark"
        cat "$file"
    } > "$tmp"
    mv "$tmp" "$file"
    echo "Updated $file"
}

configure_shell() {
    local path_block zsh_ai_block bash_ai_block bash_profile_block

    path_block='case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) export PATH="$HOME/.local/bin:$PATH" ;;
esac'

    zsh_ai_block='[[ -o interactive && -t 0 ]] || return
[[ -n ${TERM_PROGRAM-} || -n ${SSH_TTY-} ]] || return
(( SHLVL > 1 )) && return

[[ -f "$HOME/.bashrc.d/ai-start-menu" ]] && source "$HOME/.bashrc.d/ai-start-menu"
if (( ${+functions[ai]} )) && [[ -z "${AI_AUTO_LAUNCHED:-}" ]]; then
    export AI_AUTO_LAUNCHED=1
    ai
fi'

    bash_ai_block='[[ $- == *i* && -t 0 ]] || return

[[ -f "$HOME/.bashrc.d/ai-start-menu" ]] && source "$HOME/.bashrc.d/ai-start-menu"
if declare -F ai >/dev/null && [[ -z "${AI_AUTO_LAUNCHED:-}" ]]; then
    export AI_AUTO_LAUNCHED=1
    ai
fi'

    bash_profile_block='case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) export PATH="$HOME/.local/bin:$PATH" ;;
esac

if [[ -f "$HOME/.bashrc" ]]; then
    . "$HOME/.bashrc"
fi'

    if has_path_setup "$HOME/.zshenv"; then
        echo "Current shell path -> $HOME/.zshenv"
    else
        append_block_once "$HOME/.zshenv" path "$path_block"
    fi
    if has_ai_autolaunch "$HOME/.zshrc"; then
        echo "Current zsh ai autolaunch -> $HOME/.zshrc"
    else
        prepend_block_once "$HOME/.zshrc" zsh-ai "$zsh_ai_block"
    fi

    if has_path_setup "$HOME/.bashrc"; then
        echo "Current shell path -> $HOME/.bashrc"
    else
        append_block_once "$HOME/.bashrc" path "$path_block"
    fi
    if has_ai_autolaunch "$HOME/.bashrc"; then
        echo "Current bash ai autolaunch -> $HOME/.bashrc"
    else
        append_block_once "$HOME/.bashrc" bash-ai "$bash_ai_block"
    fi

    if [[ ! -f "$HOME/.bash_profile" && ! -f "$HOME/.bash_login" && ! -f "$HOME/.profile" ]]; then
        append_block_once "$HOME/.bash_profile" bash-profile "$bash_profile_block"
    else
        echo "Current bash login profile -> existing profile"
    fi
}

mkdir -p "$BIN_DIR"

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

if ! curl -fsSL "$BASE_URL/bin/setup" -o "$tmp" \
    || ! grep -q '^# setup-module: setup$' "$tmp"; then
    curl -fsSL "$FALLBACK_URL/bin/setup" -o "$tmp"
fi

install -m 0755 "$tmp" "$TARGET"

# Clear stale hash record so setup can self-update cleanly
hash_file="${XDG_STATE_HOME:-$HOME/.local/state}/setup/installed.tsv"
if [[ -f "$hash_file" ]]; then
    tmp2=$(mktemp)
    grep -vF "${TARGET}"$'\t' "$hash_file" > "$tmp2" 2>/dev/null || true
    mv "$tmp2" "$hash_file"
fi

echo "Installed $TARGET"

if (($# > 0)); then
    "$TARGET" "$@"
else
    "$TARGET"
fi
