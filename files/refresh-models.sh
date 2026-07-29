#!/usr/bin/env zsh
# setup-module: refresh-models
# setup-type: script

(( ${+functions[fetch_source_url]} )) || source "${${(%):-%x}:A:h}/../lib/script-helpers.sh"

MODULE="refresh-models"
BIN="${REFRESH_MODELS_BIN:-$HOME/.local/bin/refresh-models}"
REGISTRY="${CLAUDEX_REGISTRY:-$HOME/.config/claudex/managed-profiles.json}"
CLAUDEX_BIN="${CLAUDEX_BIN:-$HOME/.local/bin/claudex}"
CLAUDEX_CONFIG="${CLAUDEX_CONFIG:-$HOME/.config/claudex/config.toml}"
CLAUDEX_AUTH_JSON="${CLAUDEX_AUTH_JSON:-$HOME/.local/share/opencode/auth.json}"
SOURCE_BASE="${LINUX_SETUP_SOURCE_URL:-${SOURCE_URL:-https://raw.githubusercontent.com/LPFchan/setup/main}}"
BIN_SOURCE="${REFRESH_MODELS_SOURCE:-$SOURCE_BASE/files/refresh-models}"
REGISTRY_SOURCE="${CLAUDEX_REGISTRY_SOURCE:-$SOURCE_BASE/files/claudex-profiles.json}"

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
    _fetch_file "$BIN_SOURCE" "$directory/refresh-models" || return 1
    _fetch_file "$REGISTRY_SOURCE" "$directory/claudex-profiles.json" || return 1
    chmod +x "$directory/refresh-models"
    python3 "$directory/refresh-models" __validate "$directory/claudex-profiles.json"
}

_desired_hash_from() {
    local staged="$1"
    {
        cat "$staged/refresh-models"
        cat "$staged/claudex-profiles.json"
    } | setup_sha256_string
}

_recorded_hash() {
    local rt lr rr
    IFS=$'\t' read -r rt lr rr < <(script_state_for "$MODULE" 2>/dev/null) && printf '%s' "$lr"
}

_apply() {
    local action="$1" staged hash bin_tmp registry_tmp
    staged=$(mktemp -d)
    _stage_assets "$staged" || { rm -rf "$staged"; return 1; }
    hash=$(_desired_hash_from "$staged")
    mkdir -p "$(dirname "$BIN")" "$(dirname "$REGISTRY")"
    bin_tmp="${BIN}.tmp.$$"
    registry_tmp="${REGISTRY}.tmp.$$"
    cp "$staged/refresh-models" "$bin_tmp" || { rm -rf "$staged"; return 1; }
    chmod +x "$bin_tmp"
    cp "$staged/claudex-profiles.json" "$registry_tmp" || {
        rm -f "$bin_tmp"
        rm -rf "$staged"
        return 1
    }
    if [[ -x "$CLAUDEX_BIN" ]]; then
        CLAUDEX_AUTH_JSON="$CLAUDEX_AUTH_JSON" \
            python3 "$CLAUDEX_BIN" __apply "$staged/claudex-profiles.json" "$CLAUDEX_CONFIG" || {
                rm -f "$bin_tmp" "$registry_tmp"
                rm -rf "$staged"
                return 1
            }
    fi
    mv "$registry_tmp" "$REGISTRY"
    mv "$bin_tmp" "$BIN"
    rm -rf "$staged"
    record_script_state "$MODULE" "provider-registry" "$hash" "$hash"
    echo "refresh-models: $action -> $BIN"
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
        cmp -s "$staged/refresh-models" "$BIN" || drift=1
        cmp -s "$staged/claudex-profiles.json" "$REGISTRY" || drift=1
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
    rm -f "$BIN"
    if [[ ! -x "$CLAUDEX_BIN" ]]; then
        rm -f "$REGISTRY"
    fi
    remove_script_state "$MODULE"
    echo "refresh-models: uninstalled launcher"
}
