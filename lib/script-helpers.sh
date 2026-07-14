#!/usr/bin/env bash
# lib/script-helpers.sh — shared helpers for script-type modules

ZSH_PLUGINS_DIR="${ZSH_PLUGINS_DIR:-$HOME/.zsh}"

git_clone_if_missing() {
    local repo="$1" dir="$2"
    if [[ -d "$dir/.git" ]]; then
        return 0
    fi
    mkdir -p "$(dirname "$dir")"
    git clone "$repo" "$dir"
}

git_local_ref() {
    git -C "$1" rev-parse HEAD 2>/dev/null
}

git_remote_ref() {
    git -C "$1" ls-remote origin HEAD 2>/dev/null | cut -f1
}

git_check_status() {
    local dir="$1"
    if [[ ! -d "$dir/.git" ]]; then
        echo "missing"
        return 2
    fi
    local local_ref remote_ref
    local_ref=$(git_local_ref "$dir")
    remote_ref=$(git_remote_ref "$dir")
    if [[ "$local_ref" == "$remote_ref" ]]; then
        echo "local=${local_ref:0:7}"
        return 0
    else
        echo "local=${local_ref:0:7} remote=${remote_ref:0:7}"
        return 1
    fi
}

git_pull_ff() {
    local dir="$1"
    if [[ ! -d "$dir/.git" ]]; then
        return 1
    fi
    git -C "$dir" pull --ff-only
}

setup_sha256_string() {
    local input="${1:-}"
    if [[ -n "$input" ]]; then
        printf '%s' "$input" | if command -v sha256sum >/dev/null 2>&1; then
            sha256sum | cut -d' ' -f1
        else
            shasum -a 256 | cut -d' ' -f1
        fi
    else
        if command -v sha256sum >/dev/null 2>&1; then
            sha256sum | cut -d' ' -f1
        else
            shasum -a 256 | cut -d' ' -f1
        fi
    fi
}

# Reproduce the exact body bytes that `manage_block` (bin/setup) writes between
# a block's markers: a fixed managed-block warning line, then the module's
# content. Script modules use this to derive the *desired* block-body hash from
# their in-scope BLOCK_CONTENT (source of truth), so `status()` can detect drift
# between source and the installed block — not just human edits to the install.
#
# The warning string MUST stay byte-identical to `warn` in manage_block.
setup_managed_block_body() {
    local content="${1:-}"
    local warn="# [setup] managed block — do NOT edit between these markers; overwritten on 'setup update'. Source: LPFchan/setup"
    printf '%s\n' "$warn"$'\n'"$content"
}

record_script_state() {
    # Durable installation marker and diagnostic cache. Live status probes, not
    # these cached refs, are authoritative for freshness.
    local module="$1" ref_type="$2" local_ref="$3" remote_ref="$4"
    local state_file="${STATE_DIR:-$HOME/.local/state/setup}/script-state.tsv"
    local tmp m rt lr rr
    mkdir -p "$(dirname "$state_file")"
    tmp=$(mktemp)
    if [[ -f "$state_file" ]]; then
        while IFS=$'\t' read -r m rt lr rr; do
            [[ "$m" == "$module" ]] && continue
            printf '%s\t%s\t%s\t%s\n' "$m" "$rt" "$lr" "$rr"
        done < "$state_file" > "$tmp"
    fi
    printf '%s\t%s\t%s\t%s\n' "$module" "$ref_type" "$local_ref" "$remote_ref" >> "$tmp"
    mv "$tmp" "$state_file"
}

script_state_for() {
    local module="$1"
    local state_file="${STATE_DIR:-$HOME/.local/state/setup}/script-state.tsv"
    local m rt lr rr
    [[ -f "$state_file" ]] || return 1
    while IFS=$'\t' read -r m rt lr rr; do
        [[ "$m" == "$module" ]] && { echo "$rt"$'\t'"$lr"$'\t'"$rr"; return 0; }
    done < "$state_file"
    return 1
}

remove_script_state() {
    local module="$1"
    local state_file="${STATE_DIR:-$HOME/.local/state/setup}/script-state.tsv"
    local tmp m rt lr rr
    [[ -f "$state_file" ]] || return 0
    tmp=$(mktemp)
    while IFS=$'\t' read -r m rt lr rr; do
        [[ "$m" == "$module" ]] && continue
        printf '%s\t%s\t%s\t%s\n' "$m" "$rt" "$lr" "$rr"
    done < "$state_file" > "$tmp"
    mv "$tmp" "$state_file"
}

is_script_installed() {
    local module="$1"
    local state_file="${STATE_DIR:-$HOME/.local/state/setup}/script-state.tsv"
    [[ -f "$state_file" ]] || return 1
    grep -q "^${module}"$'\t' "$state_file"
}
