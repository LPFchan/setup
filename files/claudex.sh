#!/usr/bin/env zsh
# setup-module: claudex
# setup-type: script
#
# Installs a profile-selecting launcher at ~/.local/bin/claudex, the pinned
# third-party executable at ~/.local/libexec/claudex-core, and a setup-managed
# profile registry snapshot. Profile metadata is fleet state; API credentials
# are resolved from the machine-local opencode auth store when profiles are
# rendered into the canonical Claudex config.

(( ${+functions[git_clone_if_missing]} )) || source "${${(%):-%x}:A:h}/../lib/script-helpers.sh"

MODULE="claudex"
BIN="${CLAUDEX_BIN:-$HOME/.local/bin/claudex}"
CORE="${CLAUDEX_CORE:-$HOME/.local/libexec/claudex-core}"
GLOBAL_CONFIG="${CLAUDEX_CONFIG:-$HOME/.config/claudex/config.toml}"
REGISTRY="${CLAUDEX_REGISTRY:-$HOME/.config/claudex/managed-profiles.json}"
AUTH_JSON="${CLAUDEX_AUTH_JSON:-$HOME/.local/share/opencode/auth.json}"
REFRESH_MODELS_BIN="${REFRESH_MODELS_BIN:-$HOME/.local/bin/refresh-models}"
FORK_REPO="LPFchan/claudex"
FORK_TAG="v0.2.4-fork.4"
SOURCE_BASE="${LINUX_SETUP_SOURCE_URL:-${SOURCE_URL:-https://raw.githubusercontent.com/LPFchan/setup/main}}"
LAUNCHER_SOURCE="${CLAUDEX_LAUNCHER_SOURCE:-$SOURCE_BASE/files/claudex}"
REGISTRY_SOURCE="${CLAUDEX_REGISTRY_SOURCE:-$SOURCE_BASE/files/claudex-profiles.json}"

_detect_target() {
    local os arch libc
    os=$(uname -s) arch=$(uname -m)
    case "$os" in
        Darwin)
            case "$arch" in
                arm64|aarch64) echo "aarch64-apple-darwin" ;;
                *)             echo "x86_64-apple-darwin" ;;
            esac ;;
        Linux)
            libc=gnu
            case "$(ldd --version 2>&1)" in *musl*) libc=musl ;; esac
            case "$arch" in
                arm64|aarch64) echo "aarch64-unknown-linux-$libc" ;;
                *)             echo "x86_64-unknown-linux-$libc" ;;
            esac ;;
        *) return 1 ;;
    esac
}

_installed_version() {
    "$CORE" --version 2>/dev/null | awk '{print $2; exit}'
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
    _fetch_file "$LAUNCHER_SOURCE" "$directory/claudex" || {
        echo "claudex: could not fetch launcher from $LAUNCHER_SOURCE" >&2
        return 1
    }
    _fetch_file "$REGISTRY_SOURCE" "$directory/claudex-profiles.json" || {
        echo "claudex: could not fetch registry from $REGISTRY_SOURCE" >&2
        return 1
    }
    chmod +x "$directory/claudex"
    CLAUDEX_AUTH_JSON="$AUTH_JSON" python3 "$directory/claudex" __validate "$directory/claudex-profiles.json" || return 1
}

_install_fork_core() {
    local target url tmp
    target=$(_detect_target) || return 1
    url="https://github.com/$FORK_REPO/releases/download/$FORK_TAG/claudex-$FORK_TAG-$target.tar.gz"
    tmp=$(mktemp -d)
    if ! curl -fsSL "$url" -o "$tmp/claudex.tar.gz"; then
        echo "claudex: fork release asset not available: $url" >&2
        rm -rf "$tmp"
        return 1
    fi
    tar xzf "$tmp/claudex.tar.gz" -C "$tmp" || { rm -rf "$tmp"; return 1; }
    mkdir -p "$(dirname "$CORE")"
    chmod +x "$tmp/claudex"
    mv "$tmp/claudex" "$CORE"
    rm -rf "$tmp"
}

_ensure_core() {
    [[ "$(_installed_version)" == "${FORK_TAG#v}" ]] && return 0
    # Migrate the former single-binary install without a network fetch when it
    # already matches the pin. The launcher is installed only after this copy.
    if [[ -x "$BIN" ]] && [[ "$("$BIN" --version 2>/dev/null | awk '{print $2; exit}')" == "${FORK_TAG#v}" ]]; then
        mkdir -p "$(dirname "$CORE")"
        cp "$BIN" "$CORE"
        chmod +x "$CORE"
        return 0
    fi
    _install_fork_core
}

_install_assets() {
    local staged="$1" bin_tmp registry_tmp
    mkdir -p "$(dirname "$BIN")" "$(dirname "$REGISTRY")"
    bin_tmp="${BIN}.tmp.$$"
    registry_tmp="${REGISTRY}.tmp.$$"
    cp "$staged/claudex" "$bin_tmp" || return 1
    chmod +x "$bin_tmp"
    cp "$staged/claudex-profiles.json" "$registry_tmp" || { rm -f "$bin_tmp"; return 1; }
    mv "$registry_tmp" "$REGISTRY"
    mv "$bin_tmp" "$BIN"
}

_apply_all_profiles() {
    CLAUDEX_AUTH_JSON="$AUTH_JSON" python3 "$BIN" __apply "$REGISTRY" "$GLOBAL_CONFIG"
}

_managed_names() {
    python3 "$BIN" __names "$REGISTRY"
}

_profiles_current() {
    CLAUDEX_AUTH_JSON="$AUTH_JSON" python3 "$BIN" __status "$REGISTRY" "$GLOBAL_CONFIG"
}

_desired_hash_from() {
    local staged="$1"
    {
        printf '%s\n' "$FORK_TAG"
        cat "$staged/claudex"
        cat "$staged/claudex-profiles.json"
    } | setup_sha256_string
}

_desired_hash() {
    local staged hash
    staged=$(mktemp -d)
    _stage_assets "$staged" || { rm -rf "$staged"; return 1; }
    hash=$(_desired_hash_from "$staged")
    rm -rf "$staged"
    printf '%s' "$hash"
}

_assets_current_from() {
    local staged="$1" rc=0
    cmp -s "$staged/claudex" "$BIN" || rc=1
    cmp -s "$staged/claudex-profiles.json" "$REGISTRY" || rc=1
    return $rc
}

_recorded_hash() {
    local rt lr rr
    IFS=$'\t' read -r rt lr rr < <(script_state_for "$MODULE" 2>/dev/null) && printf '%s' "$lr"
}

_auth_login() {
    local -a login=("$CORE" auth login --config "$GLOBAL_CONFIG" chatgpt --profile codex)
    if [[ "$(uname -s)" == "Linux" ]] && command -v keyctl >/dev/null 2>&1; then
        keyctl session - "${login[@]}"
    else
        "${login[@]}"
    fi
}

_apply() {
    local action="$1" staged hash
    staged=$(mktemp -d)
    _stage_assets "$staged" || { rm -rf "$staged"; return 1; }
    _ensure_core || { rm -rf "$staged"; return 1; }
    hash=$(_desired_hash_from "$staged")
    _install_assets "$staged" || { rm -rf "$staged"; return 1; }
    rm -rf "$staged"
    _apply_all_profiles || return 1
    if ! _auth_login; then
        echo "claudex: OAuth login did not complete; run claudex auth login --config '$GLOBAL_CONFIG' chatgpt --profile codex" >&2
    fi
    record_script_state "$MODULE" "profile" "$hash" "$hash"
    echo "claudex: $action -> $BIN"
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
    local staged desired recorded drift=0
    staged=$(mktemp -d)
    _stage_assets "$staged" || { rm -rf "$staged"; return 1; }
    desired=$(_desired_hash_from "$staged")
    recorded=$(_recorded_hash)
    [[ -x "$BIN" && -x "$CORE" && -f "$REGISTRY" ]] || drift=1
    if (( drift == 0 )); then
        [[ "$(_installed_version)" == "${FORK_TAG#v}" ]] || drift=1
        _assets_current_from "$staged" || drift=1
        (( drift == 1 )) || _profiles_current || drift=1
    fi
    rm -rf "$staged"
    if (( drift == 1 )); then
        printf '%-25s %-12s local=%s remote=%s target=%s\n' \
            "$MODULE" "outdated" "${recorded:0:7}" "${desired:0:7}" "$BIN"
        record_script_state "$MODULE" "profile" "${recorded:-none}" "$desired"
        return 1
    fi
    printf '%-25s %-12s local=%s remote=%s target=%s\n' \
        "$MODULE" "current" "${recorded:0:7}" "${desired:0:7}" "$BIN"
    record_script_state "$MODULE" "profile" "$desired" "$desired"
}

uninstall() {
    if [[ -x "$BIN" && -f "$REGISTRY" ]]; then
        python3 "$BIN" __remove "$REGISTRY" "$GLOBAL_CONFIG" \
            || echo "claudex: could not remove managed profiles from $GLOBAL_CONFIG" >&2
    fi
    rm -f "$BIN" "$CORE"
    if [[ ! -x "$REFRESH_MODELS_BIN" ]]; then
        rm -f "$REGISTRY"
    fi
    remove_script_state "$MODULE"
    echo "claudex: uninstalled managed launcher, core, and profiles"
}
