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
    local warn="# [setup] managed block — do NOT edit between these markers; overwritten on 'setup update'. Source: LPFchan/setup"
    {
        printf '\n%s\n' "$begin_mark"
        printf '%s\n' "$warn"
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
    local warn="# [setup] managed block — do NOT edit between these markers; overwritten on 'setup update'. Source: LPFchan/setup"
    tmp=$(mktemp)
    {
        printf '%s\n' "$begin_mark"
        printf '%s\n' "$warn"
        printf '%s\n' "$content"
        printf '%s\n\n' "$end_mark"
        cat "$file"
    } > "$tmp"
    mv "$tmp" "$file"
    echo "Updated $file"
}

# Canonical top→bottom order of setup-managed .zshrc blocks. Mirrors
# ZSHRC_BLOCK_ORDER in bin/setup so a fresh curl-install ends up ordered too.
ZSHRC_BLOCK_ORDER=(tmux-autostart zsh-init starship zsh-autocomplete zsh-basics zsh-syntax-highlighting ai-menu)

# Reorder setup-managed blocks in <file> to match the given label order,
# preserving unmanaged content and staying idempotent. Mirrors
# normalize_block_order in bin/setup (see there for the full algorithm).
normalize_block_order() {
    local file="$1"; shift
    [[ -f "$file" ]] || return 0
    local order=("$@")
    local tmp; tmp=$(mktemp)
    ORDER_LIST="$(printf '%s\n' "${order[@]}")" awk '
        function flush_nonblock(   i) {
            if (nb_count == 0) return
            start = 1; endi = nb_count
            while (start <= endi && nb[start] ~ /^[[:space:]]*$/) start++
            while (endi >= start && nb[endi] ~ /^[[:space:]]*$/) endi--
            if (start > endi) { nb_count = 0; return }
            item_type[++nitems] = "text"
            s = ""
            for (i = start; i <= endi; i++) s = s (i > start ? "\n" : "") nb[i]
            item_text[nitems] = s
            nb_count = 0
        }
        BEGIN {
            n_order = 0
            m = split(ENVIRON["ORDER_LIST"], oarr, "\n")
            for (i = 1; i <= m; i++) if (oarr[i] != "") order_idx[oarr[i]] = ++n_order
        }
        {
            if ($0 ~ /^# >>> setup:.* >>>$/) {
                flush_nonblock()
                label = $0
                sub(/^# >>> setup:/, "", label)
                sub(/ >>>$/, "", label)
                blk = $0
                inblock = 1
                item_type[++nitems] = "block"
                item_label[nitems] = label
                next
            }
            if (inblock) {
                blk = blk "\n" $0
                if ($0 ~ /^# <<< setup:.* <<<$/) {
                    inblock = 0
                    item_text[nitems] = blk
                }
                next
            }
            nb[++nb_count] = $0
        }
        END {
            flush_nonblock()
            nslots = 0
            for (i = 1; i <= nitems; i++) if (item_type[i] == "block") slot[++nslots] = i
            for (i = 1; i <= nslots; i++) {
                idx = slot[i]; lbl = item_label[idx]
                if (lbl in order_idx) key[i] = order_idx[lbl]
                else key[i] = n_order + i
                ord[i] = i
            }
            for (i = 2; i <= nslots; i++) {
                kk = key[i]; oo = ord[i]; j = i - 1
                while (j >= 1 && key[j] > kk) { key[j+1] = key[j]; ord[j+1] = ord[j]; j-- }
                key[j+1] = kk; ord[j+1] = oo
            }
            for (i = 1; i <= nslots; i++) sorted_text[i] = item_text[slot[ord[i]]]
            si = 0; out = 0
            for (i = 1; i <= nitems; i++) {
                if (item_type[i] == "block") { piece = sorted_text[++si] }
                else                          { piece = item_text[i] }
                if (out++) printf "\n"
                printf "%s\n", piece
            }
        }
    ' "$file" > "$tmp" && mv "$tmp" "$file" || { rm -f "$tmp"; return 1; }
}

configure_shell() {
    local path_block zsh_init_block tmux_autostart_block

    # Remove stale ai managed blocks so fresh ones with ai-menu path are written.
    # This awk also strips the legacy `setup:zsh-ai` block, which doubles as the
    # zsh-ai -> zsh-init rename migration (prepend_block_once then writes zsh-init
    # fresh, so no orphaned duplicate remains).
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

    zsh_init_block='[[ -o interactive && -t 0 ]] || return
[[ -n ${TERM_PROGRAM-} || -n ${SSH_TTY-} || -n ${TMUX-} ]] || return

alias /exit='"'"'exit'"'"''

    tmux_autostart_block='if [[ -o interactive && -z $TMUX ]] && command -v tmux >/dev/null; then
  exec tmux new-session -A -s main
fi'

    if has_path_setup "$HOME/.zshenv"; then
        echo "Current shell path -> $HOME/.zshenv"
    else
        append_block_once "$HOME/.zshenv" path "$path_block"
    fi
    # Prepend order: zsh-init first, then tmux-autostart, so tmux-autostart lands
    # ABOVE zsh-init in the final .zshrc (each prepend inserts at the top). Final
    # ordering across all blocks is enforced by normalize_block_order below.
    prepend_block_once "$HOME/.zshrc" zsh-init "$zsh_init_block"
    prepend_block_once "$HOME/.zshrc" tmux-autostart "$tmux_autostart_block"
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

# Write the prepended .zshrc blocks (also strips the legacy zsh-ai block) before
# the CLI runs and adds its module-owned blocks.
configure_shell

if (($# > 0)); then
    "$TARGET" "$@"
else
    "$TARGET"
fi

# After configure_shell + the CLI's module bootstrap (which appends the
# remaining .zshrc blocks), enforce the canonical ordering so a fresh
# curl-install ends up ordered even without relying on the installed CLI.
normalize_block_order "$HOME/.zshrc" "${ZSHRC_BLOCK_ORDER[@]}"
