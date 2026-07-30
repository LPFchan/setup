#!/usr/bin/env zsh
# setup-module: opencodex
# setup-type: script
#
# Installs a four-reel provider/model/effort/harness launcher at ~/.local/bin/opencodex, a
# latest OpenCodex runtime, and a setup-managed provider registry snapshot.
# Routing is provider-only; provider metadata is fleet state (shared with
# claudex and refresh-models via files/claudex-profiles.json) while
# credentials remain machine-local.

(( ${+functions[git_clone_if_missing]} )) || source "${${(%):-%x}:A:h}/../lib/script-helpers.sh"

MODULE="opencodex"
BIN="${OPENCODEX_LAUNCHER:-$HOME/.local/bin/opencodex}"
REGISTRY="${OPENCODEX_REGISTRY:-$HOME/.config/opencodex/managed-profiles.json}"
AUTH_JSON="${OPENCODEX_AUTH_JSON:-${CLAUDEX_AUTH_JSON:-$HOME/.local/share/opencode/auth.json}}"
OPENCODEX_ROOT="${OPENCODEX_ROOT:-$HOME/.local/libexec/opencodex}"
OPENCODEX_BIN="${OPENCODEX_BIN:-$HOME/.local/bin/ocx}"
OPENCODEX_CONFIG="${OPENCODEX_CONFIG:-$HOME/.opencodex/config.json}"
OPENCODEX_MANAGED="${OPENCODEX_MANAGED:-$HOME/.opencodex/setup-managed-providers.json}"
OPENCODEX_PACKAGE_NAME="@bitkyc08/opencodex"
OPENCODEX_RELEASE_VERSION="${OPENCODEX_RELEASE_VERSION:-}"
SOURCE_BASE="${LINUX_SETUP_SOURCE_URL:-${SOURCE_URL:-https://raw.githubusercontent.com/LPFchan/setup/main}}"
LAUNCHER_SOURCE="${OPENCODEX_LAUNCHER_SOURCE:-$SOURCE_BASE/files/opencodex}"
REGISTRY_SOURCE="${OPENCODEX_REGISTRY_SOURCE:-${CLAUDEX_REGISTRY_SOURCE:-$SOURCE_BASE/files/claudex-profiles.json}}"

_installed_version() {
    "$OPENCODEX_BIN" --version 2>/dev/null | awk '{print $NF; exit}'
}

_resolve_release_version() {
    if [[ -n "$OPENCODEX_RELEASE_VERSION" ]]; then
        printf '%s\n' "$OPENCODEX_RELEASE_VERSION"
        return 0
    fi

    command -v npm >/dev/null 2>&1 || {
        echo "opencodex: npm is required to resolve the latest release" >&2
        return 1
    }
    local response version
    response=$(npm view "$OPENCODEX_PACKAGE_NAME" dist-tags.latest \
        --fetch-retries=0 --fetch-timeout=10000 2>/dev/null) || {
        echo "opencodex: could not resolve the latest $OPENCODEX_PACKAGE_NAME release" >&2
        return 1
    }
    version=$(printf '%s\n' "$response" | awk 'NF { print $1; exit }')
    [[ -n "$version" && "$version" != undefined ]] || {
        echo "opencodex: latest $OPENCODEX_PACKAGE_NAME release has no version" >&2
        return 1
    }
    printf '%s\n' "$version"
}

_runtime_root_is_safe() {
    [[ "$OPENCODEX_ROOT" == /*/opencodex && "$OPENCODEX_ROOT" != "/opencodex" ]]
}

_require_safe_runtime_root() {
    _runtime_root_is_safe && return 0
    echo "opencodex: refusing unsafe OpenCodex runtime path: $OPENCODEX_ROOT" >&2
    return 1
}

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
    _fetch_file "$LAUNCHER_SOURCE" "$directory/opencodex" || {
        echo "opencodex: could not fetch launcher from $LAUNCHER_SOURCE" >&2
        return 1
    }
    _fetch_file "$REGISTRY_SOURCE" "$directory/claudex-profiles.json" || {
        echo "opencodex: could not fetch registry from $REGISTRY_SOURCE" >&2
        return 1
    }
    chmod +x "$directory/opencodex"
    OPENCODEX_AUTH_JSON="$AUTH_JSON" python3 "$directory/opencodex" __validate "$directory/claudex-profiles.json" || return 1
}

_ensure_runtime() {
    local version="$1"
    [[ "$(_installed_version)" == "$version" ]] && return 0
    _require_safe_runtime_root || return 1
    command -v npm >/dev/null 2>&1 || {
        echo "opencodex: npm is required to install OpenCodex" >&2
        return 1
    }
    local staged old package="$OPENCODEX_PACKAGE_NAME@$version"
    staged=$(mktemp -d)
    if ! npm install --prefix "$staged/root" --no-audit --no-fund --no-package-lock \
        --allow-scripts=bun "$package"; then
        rm -rf "$staged"
        return 1
    fi
    [[ -x "$staged/root/node_modules/.bin/ocx" ]] || {
        echo "opencodex: OpenCodex package did not install its CLI" >&2
        rm -rf "$staged"
        return 1
    }
    mkdir -p "$(dirname "$OPENCODEX_ROOT")" "$(dirname "$OPENCODEX_BIN")"
    old="${OPENCODEX_ROOT}.old.$$"
    [[ ! -e "$OPENCODEX_ROOT" ]] || mv "$OPENCODEX_ROOT" "$old"
    mv "$staged/root" "$OPENCODEX_ROOT" || {
        [[ ! -e "$old" ]] || mv "$old" "$OPENCODEX_ROOT"
        rm -rf "$staged"
        return 1
    }
    if ! ln -sfn "$OPENCODEX_ROOT/node_modules/.bin/ocx" "${OPENCODEX_BIN}.tmp.$$" \
        || ! mv "${OPENCODEX_BIN}.tmp.$$" "$OPENCODEX_BIN"; then
        rm -f "${OPENCODEX_BIN}.tmp.$$"
        rm -rf "$OPENCODEX_ROOT"
        [[ ! -e "$old" ]] || mv "$old" "$OPENCODEX_ROOT"
        rm -rf "$staged"
        return 1
    fi
    rm -rf "$old" "$staged"
}

_install_assets() {
    local staged="$1" bin_tmp registry_tmp
    mkdir -p "$(dirname "$BIN")" "$(dirname "$REGISTRY")"
    bin_tmp="${BIN}.tmp.$$"
    registry_tmp="${REGISTRY}.tmp.$$"
    cp "$staged/opencodex" "$bin_tmp" || return 1
    chmod +x "$bin_tmp"
    cp "$staged/claudex-profiles.json" "$registry_tmp" || { rm -f "$bin_tmp"; return 1; }
    mv "$registry_tmp" "$REGISTRY"
    mv "$bin_tmp" "$BIN"
}

_apply_all_providers() {
    OPENCODEX_AUTH_JSON="$AUTH_JSON" OPENCODEX_BIN="$OPENCODEX_BIN" \
        OPENCODEX_CONFIG="$OPENCODEX_CONFIG" OPENCODEX_MANAGED="$OPENCODEX_MANAGED" \
        python3 "$BIN" __apply "$REGISTRY"
}

_providers_current() {
    OPENCODEX_AUTH_JSON="$AUTH_JSON" OPENCODEX_CONFIG="$OPENCODEX_CONFIG" \
        OPENCODEX_MANAGED="$OPENCODEX_MANAGED" \
        python3 "$BIN" __status "$REGISTRY"
}

_desired_hash_from() {
    local staged="$1" version="$2"
    {
        printf '%s\n' "$version"
        cat "$staged/opencodex"
        cat "$staged/claudex-profiles.json"
    } | setup_sha256_string
}

_desired_hash() {
    local staged version hash
    version=$(_resolve_release_version) || return 1
    staged=$(mktemp -d)
    _stage_assets "$staged" || { rm -rf "$staged"; return 1; }
    hash=$(_desired_hash_from "$staged" "$version")
    rm -rf "$staged"
    printf '%s' "$hash"
}

_assets_current_from() {
    local staged="$1" rc=0
    cmp -s "$staged/opencodex" "$BIN" || rc=1
    cmp -s "$staged/claudex-profiles.json" "$REGISTRY" || rc=1
    return $rc
}

_recorded_hash() {
    local rt lr rr
    IFS=$'\t' read -r rt lr rr < <(script_state_for "$MODULE" 2>/dev/null) && printf '%s' "$lr"
}

_release_ref() {
    printf 'release:%s' "$1"
}

_activate_runtime() {
    "$OPENCODEX_BIN" service install
}

_runtime_active() {
    "$OPENCODEX_BIN" service status >/dev/null 2>&1
}

_apply() {
    local action="$1" staged version hash
    version=$(_resolve_release_version) || return 1
    staged=$(mktemp -d)
    _stage_assets "$staged" || { rm -rf "$staged"; return 1; }
    _ensure_runtime "$version" || { rm -rf "$staged"; return 1; }
    hash=$(_desired_hash_from "$staged" "$version")
    _install_assets "$staged" || { rm -rf "$staged"; return 1; }
    rm -rf "$staged"
    _apply_all_providers || return 1
    _activate_runtime || return 1
    record_script_state "$MODULE" "$(_release_ref "$version")" "$hash" "$hash"
    echo "opencodex: $action -> $BIN"
}

install() {
    _apply installed
}

update() {
    _apply updated
}

status() {
    if ! is_script_installed "$MODULE"; then
        printf '%-25s %-12s\n' "$MODULE" "uninstalled"
        return 2
    fi
    local staged version installed desired recorded drift=0
    installed=$(_installed_version)
    if ! version=$(_resolve_release_version); then
        printf '%-25s %-12s local=%s remote=- target=%s\n' \
            "$MODULE" "unknown" "${installed:-unknown}" "$BIN"
        return 0
    fi
    staged=$(mktemp -d)
    _stage_assets "$staged" || { rm -rf "$staged"; return 1; }
    desired=$(_desired_hash_from "$staged" "$version")
    recorded=$(_recorded_hash)
    [[ -x "$BIN" && -x "$OPENCODEX_BIN" && -f "$REGISTRY" ]] || drift=1
    if (( drift == 0 )); then
        [[ "$installed" == "$version" ]] || drift=1
        _assets_current_from "$staged" || drift=1
        (( drift == 1 )) || _providers_current || drift=1
        (( drift == 1 )) || _runtime_active || drift=1
    fi
    rm -rf "$staged"
    if (( drift == 1 )); then
        printf '%-25s %-12s local=%s remote=%s target=%s\n' \
            "$MODULE" "outdated" "${installed:-unknown}" "$version" "$BIN"
        record_script_state "$MODULE" "$(_release_ref "${installed:-unknown}")" "${recorded:-none}" "$desired"
        return 1
    fi
    printf '%-25s %-12s local=%s remote=%s target=%s\n' \
        "$MODULE" "current" "$installed" "$version" "$BIN"
    record_script_state "$MODULE" "$(_release_ref "$version")" "$desired" "$desired"
}

uninstall() {
    _require_safe_runtime_root || return 1
    if [[ -x "$OPENCODEX_BIN" ]]; then
        "$OPENCODEX_BIN" service uninstall >/dev/null 2>&1 || true
        "$OPENCODEX_BIN" restore >/dev/null 2>&1 || true
    fi
    if [[ -x "$BIN" && -f "$REGISTRY" ]]; then
        OPENCODEX_CONFIG="$OPENCODEX_CONFIG" OPENCODEX_MANAGED="$OPENCODEX_MANAGED" \
            python3 "$BIN" __remove "$REGISTRY" \
            || echo "opencodex: could not remove managed providers from $OPENCODEX_CONFIG" >&2
    fi
    rm -f "$BIN" "$OPENCODEX_BIN"
    rm -rf "$OPENCODEX_ROOT"
    rm -f "$REGISTRY"
    remove_script_state "$MODULE"
    echo "opencodex: uninstalled launcher, OpenCodex runtime, and managed providers"
}
