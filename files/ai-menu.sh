#!/usr/bin/env bash
# setup-module: ai-menu
# setup-type: script
#
# Installs the ai-menu fzf picker payload to ~/.bashrc.d/ai-menu and owns a
# .zshrc managed block that sources it and auto-launches `ai` on interactive
# shell startup. Uninstalling this module removes both the payload and the
# autolaunch block. Source of truth for the payload lives in this repo at
# files/ai-menu.

[[ "$(type -t git_clone_if_missing)" == "function" ]] || source "$(dirname "${BASH_SOURCE[0]}")/../lib/script-helpers.sh"

MODULE="ai-menu"
PAYLOAD_TARGET="$HOME/.bashrc.d/ai-menu"
SRC_REPO="${AI_MENU_SRC_REPO:-https://github.com/LPFchan/setup.git}"
SRC_CLONE="${STATE_DIR:-$HOME/.local/state/setup}/ai-menu-src"

BLOCK_CONTENT='[[ ${(t)AI_AUTO_LAUNCHED} == *export* ]] && unset AI_AUTO_LAUNCHED
[[ -f "$HOME/.bashrc.d/ai-menu" ]] && source "$HOME/.bashrc.d/ai-menu"
if (( ${+functions[ai]} )) && (( ! ${+AI_AUTO_LAUNCHED} )); then
    typeset -g +x AI_AUTO_LAUNCHED=1
    ai
fi'

_sync_src() {
    if [[ -d "$SRC_CLONE/.git" ]]; then
        git_pull_ff "$SRC_CLONE" >/dev/null 2>&1 || true
    else
        git_clone_if_missing "$SRC_REPO" "$SRC_CLONE"
    fi
}

_install_payload() {
    _sync_src
    if [[ ! -f "$SRC_CLONE/files/ai-menu" ]]; then
        echo "ai-menu: payload missing at $SRC_CLONE/files/ai-menu — push files/ai-menu to $SRC_REPO first" >&2
        return 1
    fi
    mkdir -p "$(dirname "$PAYLOAD_TARGET")"
    cp "$SRC_CLONE/files/ai-menu" "$PAYLOAD_TARGET"
}

_upsert_block() {
    manage_block "$HOME/.zshrc" "ai-menu" "$BLOCK_CONTENT" "upsert" "append"
}

install() {
    _install_payload || return 1
    _upsert_block
    _record_state
    echo "ai-menu: installed -> $PAYLOAD_TARGET (+ .zshrc autolaunch block)"
}

update() { install; }

status() {
    if [[ ! -f "$PAYLOAD_TARGET" ]] || ! has_managed_block "$HOME/.zshrc" "ai-menu"; then
        printf '%-25s %-12s\n' "$MODULE" "uninstalled"
        return 2
    fi
    local expected actual local_ref remote_ref
    local_ref=$(git_local_ref "$SRC_CLONE")
    remote_ref=$(git_remote_ref "$SRC_CLONE")
    if [[ -n "$remote_ref" && "$local_ref" != "$remote_ref" ]]; then
        printf '%-25s %-12s local=%s remote=%s target=%s\n' "$MODULE" "outdated" \
            "${local_ref:0:7}" "${remote_ref:0:7}" "$PAYLOAD_TARGET"
        record_script_state "$MODULE" "git" "${local_ref:0:7}" "${remote_ref:0:7}"
        return 1
    fi

    expected=$(_desired_hash)
    actual=$(_state_hash)
    if [[ "$expected" == "$actual" ]]; then
        printf '%-25s %-12s local=%s remote=%s target=%s\n' "$MODULE" "current" "${actual:0:7}" "${expected:0:7}" "$PAYLOAD_TARGET"
        _record_state
        return 0
    fi
    printf '%-25s %-12s local=%s remote=%s target=%s\n' "$MODULE" "outdated" "${actual:0:7}" "${expected:0:7}" "$PAYLOAD_TARGET"
    return 1
}

uninstall() {
    manage_block "$HOME/.zshrc" "ai-menu" "" "remove"
    rm -f "$PAYLOAD_TARGET"
    remove_script_state "$MODULE"
    echo "ai-menu: uninstalled (payload + autolaunch block removed)"
}

# Combined hash over the installed payload and the managed block, so drift in
# either surface is detected.
_state_hash() {
    local block payload
    block=$(awk '/^# >>> setup:ai-menu >>>/{f=1;next}/^# <<< setup:ai-menu <<</{f=0}f' "$HOME/.zshrc")
    payload=$([[ -f "$PAYLOAD_TARGET" ]] && cat "$PAYLOAD_TARGET")
    printf '%s\n%s' "$block" "$payload" | setup_sha256_string
}

# Combined hash over the *desired* block body (from BLOCK_CONTENT, source of
# truth) and the *desired* payload. The block is derivable in-process; the
# payload's source of truth is files/ai-menu in the git clone ($SRC_CLONE).
# status() first compares that clone with remote HEAD so setup update cannot
# mistake a stale clone for the desired payload. Once refs match, hash the
# clone's payload to detect drift in both the block and installed payload. If
# no clone exists yet, fall back to the installed payload; the installation
# checks above still report a missing managed surface as uninstalled.
_desired_hash() {
    local block payload src="$SRC_CLONE/files/ai-menu"
    block=$(setup_managed_block_body "$BLOCK_CONTENT")
    if [[ -f "$src" ]]; then
        payload=$(cat "$src")
    else
        payload=$([[ -f "$PAYLOAD_TARGET" ]] && cat "$PAYLOAD_TARGET")
    fi
    printf '%s\n%s' "$block" "$payload" | setup_sha256_string
}

_record_state() {
    local h
    h=$(_state_hash)
    record_script_state "$MODULE" "block" "$h" "$h"
}
