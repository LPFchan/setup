#!/usr/bin/env zsh
# setup-module: providers
# setup-type: script
#
# Installs the providers launcher at ~/.local/bin/providers: vault-owned
# provider API keys (llm/{PROVIDER}_API_KEY) with a local cache and mirrors
# into opencode's auth.json and ~/.zshenv, plus hourly model refresh for
# OpenCode, Hermes, and Pi-based tools such as Miniharness.

(( ${+functions[fetch_source_url]} )) || source "${${(%):-%x}:A:h}/../lib/script-helpers.sh"

MODULE="providers"
BIN="${PROVIDERS_BIN:-$HOME/.local/bin/providers}"
REGISTRY="${PROVIDERS_REGISTRY:-$HOME/.config/providers/registry.json}"
LEGACY_REGISTRY="${PROVIDERS_LEGACY_REGISTRY:-$HOME/.config/claudex/managed-profiles.json}"
CLAUDEX_BIN="${CLAUDEX_BIN:-$HOME/.local/bin/claudex}"
REFRESH_MODELS_BIN="${REFRESH_MODELS_BIN:-$HOME/.local/bin/refresh-models}"
SOURCE_BASE="${LINUX_SETUP_SOURCE_URL:-${SOURCE_URL:-https://raw.githubusercontent.com/LPFchan/setup/main}}"
BIN_SOURCE="${PROVIDERS_SOURCE:-$SOURCE_BASE/files/providers}"
REGISTRY_SOURCE="${PROVIDER_REGISTRY_SOURCE:-$SOURCE_BASE/files/provider-registry.json}"

_fetch_file() {
    local source="$1" destination="$2"
    if [[ -f "$source" ]]; then
        cp "$source" "$destination"
    elif (( ${+functions[fetch_source_url]} )); then
        fetch_source_url "$source" -o "$destination"
    else
        curl -fsSL "$source" -o "$destination"
    fi
}

_stage_assets() {
    local directory="$1"
    _fetch_file "$BIN_SOURCE" "$directory/providers" || return 1
    _fetch_file "$REGISTRY_SOURCE" "$directory/provider-registry.json" || return 1
    chmod +x "$directory/providers"
    python3 "$directory/providers" __validate "$directory/provider-registry.json"
}

_desired_hash_from() {
    local staged="$1"
    {
        cat "$staged/providers"
        cat "$staged/provider-registry.json"
    } | setup_sha256_string
}

_recorded_hash() {
    local rt lr rr
    IFS=$'\t' read -r rt lr rr < <(script_state_for "$MODULE" 2>/dev/null) && printf '%s' "$lr"
}

# Remove an obsolete registry path once no retired module still owns it.
_reclaim_legacy_registry() {
    [[ "$REGISTRY" != "$LEGACY_REGISTRY" ]] || return 0
    [[ -f "$LEGACY_REGISTRY" ]] || return 0
    [[ ! -x "$CLAUDEX_BIN" && ! -x "$REFRESH_MODELS_BIN" ]] || return 0
    rm -f "$LEGACY_REGISTRY"
}

_apply() {
    local action="$1" staged hash bin_tmp registry_tmp
    staged=$(mktemp -d)
    _stage_assets "$staged" || { rm -rf "$staged"; return 1; }
    hash=$(_desired_hash_from "$staged")
    mkdir -p "$(dirname "$BIN")" "$(dirname "$REGISTRY")"
    bin_tmp="${BIN}.tmp.$$"
    registry_tmp="${REGISTRY}.tmp.$$"
    cp "$staged/providers" "$bin_tmp" || { rm -rf "$staged"; return 1; }
    chmod +x "$bin_tmp"
    cp "$staged/provider-registry.json" "$registry_tmp" || {
        rm -f "$bin_tmp"
        rm -rf "$staged"
        return 1
    }
    PROVIDERS_REGISTRY="$staged/provider-registry.json" \
        python3 "$staged/providers" __migrate-state || {
            rm -f "$bin_tmp" "$registry_tmp"
            rm -rf "$staged"
            return 1
        }
    mv "$registry_tmp" "$REGISTRY"
    mv "$bin_tmp" "$BIN"
    _reclaim_legacy_registry
    rm -rf "$staged"
    record_script_state "$MODULE" "provider-registry" "$hash" "$hash"
    echo "providers: $action -> $BIN"
}

install() {
    _apply installed
}

update() {
    _apply updated
}

status() {
    if ! is_script_installed "$MODULE" && [[ ! -x "$BIN" ]]; then
        printf '%-25s %-12s\n' "$MODULE" "uninstalled"
        return 2
    fi
    local staged desired recorded drift=0
    staged=$(mktemp -d)
    _stage_assets "$staged" || { rm -rf "$staged"; return 1; }
    desired=$(_desired_hash_from "$staged")
    recorded=$(_recorded_hash)
    [[ -x "$BIN" && -f "$REGISTRY" ]] || drift=1
    if (( drift == 0 )); then
        cmp -s "$staged/providers" "$BIN" || drift=1
        cmp -s "$staged/provider-registry.json" "$REGISTRY" || drift=1
    fi
    rm -rf "$staged"
    if (( drift == 1 )); then
        printf '%-25s %-12s local=%s remote=%s target=%s\n' \
            "$MODULE" "outdated" "${recorded:0:7}" "${desired:0:7}" "$BIN"
        record_script_state "$MODULE" "provider-registry" "${recorded:-none}" "$desired"
        return 1
    fi
    printf '%-25s %-12s local=%s remote=%s target=%s\n' \
        "$MODULE" "current" "${desired:0:7}" "${desired:0:7}" "$BIN"
    record_script_state "$MODULE" "provider-registry" "$desired" "$desired"
}

uninstall() {
    rm -f "$BIN" "$REGISTRY"
    remove_script_state "$MODULE"
    echo "providers: uninstalled launcher"
}
