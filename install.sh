#!/usr/bin/env bash
set -euo pipefail

SOURCE_URL="${LINUX_SETUP_SOURCE_URL:-https://raw.githubusercontent.com/LPFchan/setup/main}"
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
    grep -Eq 'ai-menu' "$file" \
        && grep -Eq 'AI_AUTO_LAUNCHED' "$file" \
        && grep -Eq '(^|[^[:alnum:]_])ai([[:space:]]*$|[[:space:]]|;|&&|\|\|)' "$file"
}

append_block_once() {
    local file="$1" label="$2" content="$3" dir begin_mark end_mark
    begin_mark="# >>> setup:$label >>>"
    end_mark="# <<< setup:$label <<<"
    dir=$(dirname "$file")
    mkdir -p "$dir"
    touch "$file"
    if grep -Fq "$begin_mark" "$file" || grep -Fq "# >>> linux-setup:$label >>>" "$file"; then
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
    begin_mark="# >>> setup:$label >>>"
    end_mark="# <<< setup:$label <<<"
    dir=$(dirname "$file")
    mkdir -p "$dir"
    touch "$file"
    if grep -Fq "$begin_mark" "$file" || grep -Fq "# >>> linux-setup:$label >>>" "$file"; then
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

    # Remove stale ai managed blocks so fresh ones with ai-menu path are written
    for _f in "$HOME/.zshrc" "$HOME/.bashrc"; do
        [[ -f "$_f" ]] || continue
        if grep -qE '(linux-setup|setup):(zsh-ai|bash-ai)' "$_f" 2>/dev/null; then
            _tmp=$(mktemp)
            awk '
                /^# >>> linux-setup:zsh-ai >>>/   { skip=1; next }
                /^# >>> linux-setup:bash-ai >>>/  { skip=1; next }
                /^# <<< linux-setup:zsh-ai <<</   { skip=0; next }
                /^# <<< linux-setup:bash-ai <<</  { skip=0; next }
                /^# >>> setup:zsh-ai >>>/         { skip=1; next }
                /^# >>> setup:bash-ai >>>/        { skip=1; next }
                /^# <<< setup:zsh-ai <<</         { skip=0; next }
                /^# <<< setup:bash-ai <<</        { skip=0; next }
                !skip { print }
            ' "$_f" > "$_tmp" && mv "$_tmp" "$_f"
        fi
        if grep -q 'ai-start-menu' "$_f" 2>/dev/null; then
            sed -i'' -e '/ai-start-menu/d' "$_f" 2>/dev/null || true
        fi
    done
    rm -f "$HOME/.bashrc.d/ai-start-menu"

    path_block='case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) export PATH="$HOME/.local/bin:$PATH" ;;
esac'

    zsh_ai_block='[[ -o interactive && -t 0 ]] || return
[[ -n ${TERM_PROGRAM-} || -n ${SSH_TTY-} ]] || return
(( SHLVL > 1 )) && return

[[ -f "$HOME/.bashrc.d/ai-menu" ]] && source "$HOME/.bashrc.d/ai-menu"
if (( ${+functions[ai]} )) && [[ -z "${AI_AUTO_LAUNCHED:-}" ]]; then
    export AI_AUTO_LAUNCHED=1
    ai
fi'

    bash_ai_block='[[ $- == *i* && -t 0 ]] || return

[[ -f "$HOME/.bashrc.d/ai-menu" ]] && source "$HOME/.bashrc.d/ai-menu"
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

if ! curl -fsSL "$SOURCE_URL/bin/setup" -o "$tmp" \
    || ! grep -q '^# setup-module: setup$' "$tmp"; then
    echo "Failed to fetch setup from $SOURCE_URL" >&2
    exit 1
fi

install -m 0755 "$tmp" "$TARGET"

# Record the hash so setup shows as up-to-date immediately
_hash=$(if command -v sha256sum >/dev/null 2>&1; then sha256sum "$TARGET" | cut -d' ' -f1; else shasum -a 256 "$TARGET" | cut -d' ' -f1; fi)
_hash_file="${XDG_STATE_HOME:-$HOME/.local/state}/setup/installed.tsv"
_hash_dir=$(dirname "$_hash_file")
mkdir -p "$_hash_dir"
if [[ -f "$_hash_file" ]]; then
    _tmp2=$(mktemp)
    grep -vF "${TARGET}"$'\t' "$_hash_file" > "$_tmp2" 2>/dev/null || true
    mv "$_tmp2" "$_hash_file"
fi
printf '%s\t%s\t%s\n' "$TARGET" "$_hash" "$_hash" >> "$_hash_file"

echo "Installed $TARGET"

if (($# > 0)); then
    "$TARGET" "$@"
else
    "$TARGET"
fi
