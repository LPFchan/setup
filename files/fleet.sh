#!/usr/bin/env zsh
# setup-module: fleet
# setup-type: script
#
# Installs the fleet CLI (files/fleet) and its common manifest
# (files/fleet-manifest.json). fleet keeps the managed ~/.ssh/config and
# authorized_keys blocks, the account's ~/.agents tree and the harness settings
# built from it in step with the account in Common Auth.

(( ${+functions[fetch_source_url]} )) || source "${${(%):-%x}:A:h}/../lib/script-helpers.sh"

MODULE="fleet"
BIN="${FLEET_BIN:-$HOME/.local/bin/fleet}"
SOURCE_BASE="${LINUX_SETUP_SOURCE_URL:-${SOURCE_URL:-https://raw.githubusercontent.com/LPFchan/setup/main}}"
BIN_SOURCE="${FLEET_SOURCE:-$SOURCE_BASE/files/fleet}"
MANIFEST="${FLEET_MANIFEST:-$HOME/.config/fleet/manifest.json}"
MANIFEST_SOURCE="${FLEET_MANIFEST_SOURCE:-$SOURCE_BASE/files/fleet-manifest.json}"
ENGINE="${FLEET_PROVIDER_ENGINE:-${BIN:h}/fleet-providers.py}"
ENGINE_SOURCE="${FLEET_PROVIDER_SOURCE:-$SOURCE_BASE/files/fleet-providers.py}"
DEFAULTS="${FLEET_PROVIDER_DEFAULTS:-$HOME/.config/fleet/provider-defaults.json}"
DEFAULTS_SOURCE="${PROVIDER_REGISTRY_SOURCE:-$SOURCE_BASE/files/provider-registry.json}"

_fetch() {
    local source="$1" destination="$2"
    if [[ -f "$source" ]]; then
        cp "$source" "$destination"
    elif (( ${+functions[fetch_source_url]} )); then
        fetch_source_url "$source" -o "$destination"
    else
        curl -fsSL "$source" -o "$destination"
    fi
}

# Stage and validate the complete fleet payload before replacing installed files.
_stage() {
    local dir="$1"
    _fetch "$BIN_SOURCE" "$dir/fleet" && _fetch "$MANIFEST_SOURCE" "$dir/manifest.json" || return 1
    _fetch "$ENGINE_SOURCE" "$dir/fleet-providers.py" && _fetch "$DEFAULTS_SOURCE" "$dir/provider-registry.json" || return 1
    chmod +x "$dir/fleet"
    python3 "$dir/fleet-providers.py" __validate "$dir/provider-registry.json" || return 1
    python3 -c 'import ast,json,sys; ast.parse(open(sys.argv[1]).read()); json.load(open(sys.argv[2]))' \
        "$dir/fleet" "$dir/manifest.json"
}

_hash() { cat "$@" 2>/dev/null | setup_sha256_string; }

_desired_hash() {
    local staged; staged=$(mktemp -d)
    _stage "$staged" || { rm -rf "$staged"; return 1; }
    _hash "$staged/fleet" "$staged/manifest.json" "$staged/fleet-providers.py" "$staged/provider-registry.json"
    rm -rf "$staged"
}

_auth_bin() {
    [[ -x "$HOME/.local/bin/auth" ]] && { echo "$HOME/.local/bin/auth"; return 0; }
    command -v auth 2>/dev/null
}

# Installing fleet is one sitting: with a terminal and no session, it opens the
# approval page before the first sync. A non-interactive install skips it; the
# login marker offers it again after the next interactive setup run. When
# setup swaps fleet in for ssh-aliases, it asks before opening the page.
_login_if_needed() {
    local auth_bin
    auth_bin=$(_auth_bin) || return 0
    "$auth_bin" status >/dev/null 2>&1 && return 0
    [[ "${BATCH:-0}" == 0 && -t 1 && -r /dev/tty ]] || return 0
    local deferred="${XDG_STATE_HOME:-$HOME/.local/state}/setup/auth.login-deferred"
    # Declined earlier in this run; setup clears the file at its login step.
    [[ -f "$deferred" ]] && return 0
    # Swapped in by `setup update` rather than asked for: ask first.
    if [[ -n "${SETUP_SWAP_FROM:-}" ]]; then
        local answer
        printf 'fleet replaces %s and signs this machine in to its fleet. Log in now? [Y/n] ' \
            "$SETUP_SWAP_FROM" >/dev/tty
        read -r answer </dev/tty || answer=n
        if [[ "$answer" == [nN]* ]]; then
            # setup's own login step would ask again later in this run; this
            # file tells it to skip once.
            mkdir -p "${deferred:h}" && touch "$deferred"
            echo "fleet: login skipped; setup offers it again after its next interactive run"
            return 0
        fi
    fi
    echo "fleet: signing this machine in to its fleet"
    "$auth_bin" login </dev/tty >/dev/tty 2>&1 || echo "fleet: login skipped; run: auth login" >&2
}

_apply() {
    local action="$1" staged hash
    mkdir -p "${BIN:h}" "${MANIFEST:h}" "${ENGINE:h}" "${DEFAULTS:h}"
    staged=$(mktemp -d "${BIN:h}/.fleet.XXXXXX")
    _stage "$staged" || { rm -rf "$staged"; return 1; }
    hash=$(_hash "$staged/fleet" "$staged/manifest.json" "$staged/fleet-providers.py" "$staged/provider-registry.json")
    mv "$staged/manifest.json" "$MANIFEST"
    mv "$staged/fleet-providers.py" "$ENGINE"
    mv "$staged/provider-registry.json" "$DEFAULTS"
    mv "$staged/fleet" "$BIN"
    rm -rf "$staged"
    record_script_state "$MODULE" "fleet" "$hash" "$hash"
    echo "fleet: $action -> $BIN"
    [[ "$action" == installed ]] && _login_if_needed
    # A pull: local edits in ~/.agents go up only when the operator syncs.
    # Exit 3 means Auth gave no authoritative answer: what is on disk stays,
    # and status says so rather than failing every run.
    "$BIN" sync --pull || (( $? == 3 )) || return 1
}

install() { _apply installed; }
update() { _apply updated; }

status() {
    if ! is_script_installed "$MODULE" && [[ ! -x "$BIN" ]]; then
        printf '%-25s %-12s\n' "$MODULE" "uninstalled"
        return 2
    fi
    local desired actual rc
    desired=$(_desired_hash) || return 1
    actual=$([[ -f "$BIN" ]] && _hash "$BIN" "$MANIFEST" "$ENGINE" "$DEFAULTS")
    if [[ ! -x "$BIN" || "$actual" != "$desired" ]]; then
        printf '%-25s %-12s local=%s remote=%s target=%s\n' \
            "$MODULE" "outdated" "${actual:0:7}" "${desired:0:7}" "$BIN"
        return 1
    fi
    rc=0
    "$BIN" sync --check 2>/dev/null || rc=$?
    case "$rc" in
        0) printf '%-25s %-12s local=%s remote=%s target=%s\n' \
               "$MODULE" "current" "${desired:0:7}" "${desired:0:7}" "$BIN" ;;
        1) printf '%-25s %-12s local=%s remote=%s target=%s\n' \
               "$MODULE" "outdated" "${desired:0:7}" "${desired:0:7}" "$BIN"
           return 1 ;;
        *) printf '%-25s %-12s target=%s\n' "$MODULE" "unknown" "$BIN" ;;
    esac
}

uninstall() {
    [[ -x "$BIN" ]] && "$BIN" schedule disable >/dev/null 2>&1
    manage_block "$HOME/.ssh/config" "fleet" "" "remove"
    manage_block "$HOME/.ssh/authorized_keys" "fleet-keys" "" "remove"
    rm -f "$BIN" "$MANIFEST" "$ENGINE" "$DEFAULTS"
    remove_script_state "$MODULE"
    echo "fleet: uninstalled. This machine stays in its fleet until it is revoked in the Fleet tab."
}
