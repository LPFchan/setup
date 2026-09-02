#!/usr/bin/env zsh
# setup-module: ssh-aliases
# setup-type: script
#
# Manages marker-delimited outbound Host aliases in ~/.ssh/config and inbound
# owner keys from GitHub in ~/.ssh/authorized_keys. Keep the fleet table below
# in sync with agents/FLEET.md.

(( ${+functions[setup_sha256_string]} )) || source "${${(%):-%x}:A:h}/../lib/script-helpers.sh"

MODULE="ssh-aliases"
SSH_CONFIG="$HOME/.ssh/config"
AUTHORIZED_KEYS="$HOME/.ssh/authorized_keys"
AUTHORIZED_KEYS_BLOCK="ssh-aliases-github-keys"
OWNER_KEYS_URL="${SETUP_OWNER_KEYS_URL:-https://github.com/LPFchan.keys}"

# alias | hostname | user | optional TERM fallback | optional host-key policy
FLEET=(
    "yeowoolmac|mac.lost.plus|yeowool||ignore"
    "grimoire|grimoire.lost.plus|yeowool"
    "oci-ubuntu|oci.lost.plus|ubuntu"
    "bingus|bingus.lost.plus|yeowool|xterm-256color"
    "yeowoolair|yeowool-air.tailaa113.ts.net|yeowool"
)

_self() { echo "${SSH_ALIASES_SELF:-$(hostname -s 2>/dev/null || hostname)}"; }

_build_block() {
    local self entry alias hn user term host_keys
    self=$(_self)
    for entry in "${FLEET[@]}"; do
        IFS='|' read -r alias hn user term host_keys <<< "$entry"
        [[ "$alias" == "$self" ]] && continue
        if [[ "$host_keys" == "ignore" ]]; then
            printf 'Host %s %s\n' "$alias" "$hn"
        else
            printf 'Host %s\n' "$alias"
        fi
        printf '    HostName %s\n' "$hn"
        printf '    User %s\n' "$user"
        printf '    IdentityFile ~/.ssh/id_ed25519\n'
        if [[ "$host_keys" == "ignore" ]]; then
            printf '    UserKnownHostsFile /dev/null\n'
            printf '    StrictHostKeyChecking no\n'
        fi
        # Suspending a laptop strands the TCP session; without keepalives the
        # client waits out the full TCP timeout before reporting a broken pipe,
        # which is what makes a lid-close look like a hung terminal.
        printf '    ServerAliveInterval 15\n'
        printf '    ServerAliveCountMax 3\n'
        # Bounded connect so a reconnect attempt made before Wi-Fi has
        # reassociated fails fast and is retried, rather than stalling.
        printf '    ConnectTimeout 5\n'
        [[ -n "$term" ]] && printf '    SetEnv TERM=%s\n' "$term"
    done
    return 0
}

_managed_block_hash() {
    local file="$1" block="$2"
    if [[ ! -f "$file" ]]; then
        setup_sha256_string ""
        return 0
    fi
    awk -v start="# >>> setup:${block} >>>" -v end="# <<< setup:${block} <<<" '
        $0 == start { found=1; next }
        $0 == end { found=0 }
        found
    ' "$file" | setup_sha256_string
}

_fetch_owner_keys() {
    local downloaded
    downloaded=$(mktemp) || return 1
    if ! curl -fsSL --connect-timeout 8 --max-time 30 "$OWNER_KEYS_URL" -o "$downloaded"; then
        rm -f "$downloaded"
        return 1
    fi
    awk 'NF >= 2 && ($1 ~ /^ssh-/ || $1 ~ /^ecdsa-/ || $1 ~ /^sk-/) { print $1 " " $2 }' "$downloaded"
    rm -f "$downloaded"
}

_combined_hash() {
    local config_hash keys_hash
    config_hash=$(_managed_block_hash "$SSH_CONFIG" "$MODULE")
    keys_hash=$(_managed_block_hash "$AUTHORIZED_KEYS" "$AUTHORIZED_KEYS_BLOCK")
    printf '%s\n%s\n' "$config_hash" "$keys_hash" | setup_sha256_string
}

_ensure_perms() {
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh" 2>/dev/null || true
    [[ -f "$SSH_CONFIG" ]] && chmod 600 "$SSH_CONFIG" 2>/dev/null || true
    [[ -f "$AUTHORIZED_KEYS" ]] && chmod 600 "$AUTHORIZED_KEYS" 2>/dev/null || true
}

install() {
    local owner_keys
    if ! owner_keys=$(_fetch_owner_keys); then
        echo "$MODULE: could not fetch owner keys from $OWNER_KEYS_URL" >&2
        return 1
    fi
    _ensure_perms
    manage_block "$SSH_CONFIG" "ssh-aliases" "$(_build_block)" "upsert" "append"
    manage_block "$AUTHORIZED_KEYS" "$AUTHORIZED_KEYS_BLOCK" "$owner_keys" "upsert" "append"
    _ensure_perms
    _record_state
}

update() { install; }

status() {
    if ! has_managed_block "$SSH_CONFIG" "ssh-aliases"; then
        printf '%-25s %-12s\n' "$MODULE" "uninstalled"
        return 2
    fi
    local owner_keys expected_config expected_keys expected actual
    if ! owner_keys=$(_fetch_owner_keys); then
        printf '%-25s %-12s source=%s\n' "$MODULE" "unavailable" "$OWNER_KEYS_URL"
        return 1
    fi
    actual=$(_combined_hash)
    expected_config=$(setup_managed_block_body "$(_build_block)" | setup_sha256_string)
    expected_keys=$(setup_managed_block_body "$owner_keys" | setup_sha256_string)
    expected=$(printf '%s\n%s\n' "$expected_config" "$expected_keys" | setup_sha256_string)
    if [[ "$expected" == "$actual" ]]; then
        printf '%-25s %-12s local=%s remote=%s targets=%s,%s\n' "$MODULE" "current" "${actual:0:7}" "${actual:0:7}" "$SSH_CONFIG" "$AUTHORIZED_KEYS"
        _record_state
        return 0
    fi
    printf '%-25s %-12s local=%s remote=%s targets=%s,%s\n' "$MODULE" "outdated" "${actual:0:7}" "${expected:0:7}" "$SSH_CONFIG" "$AUTHORIZED_KEYS"
    return 1
}

uninstall() {
    manage_block "$SSH_CONFIG" "ssh-aliases" "" "remove"
    manage_block "$AUTHORIZED_KEYS" "$AUTHORIZED_KEYS_BLOCK" "" "remove"
    _ensure_perms
    remove_script_state "$MODULE"
}

_record_state() {
    local h
    h=$(_combined_hash)
    record_script_state "$MODULE" "block" "$h" "$h"
}
