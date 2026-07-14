#!/usr/bin/env bash
# setup-module: ssh-aliases
# setup-type: script
#
# Manages a marker-delimited block of outbound Host aliases in ~/.ssh/config,
# built from the fleet table below and omitting the current machine. Keep the
# table in sync with agents/FLEET.md.

[[ "$(type -t setup_sha256_string)" == "function" ]] || source "$(dirname "${BASH_SOURCE[0]}")/../lib/script-helpers.sh"

MODULE="ssh-aliases"
SSH_CONFIG="$HOME/.ssh/config"

# alias | hostname | user
FLEET=(
    "yeowoolmac|mac.lost.plus|yeowool"
    "grimoire|grimoire.lost.plus|yeowool"
    "oci-ubuntu|oci.lost.plus|ubuntu"
    "bingus|bingus.lost.plus|yeowool"
    "yeowoolair|yeowool-air.tailaa113.ts.net|yeowool"
)

_self() { echo "${SSH_ALIASES_SELF:-$(hostname -s 2>/dev/null || hostname)}"; }

_build_block() {
    local self entry alias hn user
    self=$(_self)
    for entry in "${FLEET[@]}"; do
        IFS='|' read -r alias hn user <<< "$entry"
        [[ "$alias" == "$self" ]] && continue
        printf 'Host %s\n' "$alias"
        printf '    HostName %s\n' "$hn"
        printf '    User %s\n' "$user"
        printf '    IdentityFile ~/.ssh/id_ed25519\n'
    done
}

_block_hash() {
    awk '/^# >>> setup:ssh-aliases >>>/{f=1;next}/^# <<< setup:ssh-aliases <<</{f=0}f' "$SSH_CONFIG" | setup_sha256_string
}

_ensure_perms() {
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh" 2>/dev/null || true
    [[ -f "$SSH_CONFIG" ]] && chmod 600 "$SSH_CONFIG" 2>/dev/null || true
}

install() {
    _ensure_perms
    manage_block "$SSH_CONFIG" "ssh-aliases" "$(_build_block)" "upsert" "append"
    _ensure_perms
    _record_state
}

update() { install; }

status() {
    if ! has_managed_block "$SSH_CONFIG" "ssh-aliases"; then
        printf '%-25s %-12s\n' "$MODULE" "uninstalled"
        return 2
    fi
    # expected = hash of the block body built from the fleet table (source of
    # truth), so drift between source and the installed block is detected.
    local expected actual
    actual=$(_block_hash)
    expected=$(setup_managed_block_body "$(_build_block)" | setup_sha256_string)
    if [[ "$expected" == "$actual" ]]; then
        printf '%-25s %-12s local=%s remote=%s target=%s\n' "$MODULE" "current" "${actual:0:7}" "${actual:0:7}" "$SSH_CONFIG"
        _record_state
        return 0
    fi
    printf '%-25s %-12s local=%s remote=%s target=%s\n' "$MODULE" "outdated" "${actual:0:7}" "${expected:0:7}" "$SSH_CONFIG"
    return 1
}

uninstall() {
    manage_block "$SSH_CONFIG" "ssh-aliases" "" "remove"
    _ensure_perms
    remove_script_state "$MODULE"
}

_record_state() {
    local h
    h=$(_block_hash)
    record_script_state "$MODULE" "block" "$h" "$h"
}
