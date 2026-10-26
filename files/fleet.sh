#!/usr/bin/env zsh
# setup-module: fleet
# setup-type: script
#
# fleet lives in LPFchan/auth and installs and updates itself from Auth
# (https://auth.lost.plus/fleet.sh, then its own nightly pass), so this module
# only hands a machine over: install and update run that installer, and once
# fleet's own nightly timer is on, setup stops managing fleet and auth. Old
# onboarding prompts that run `setup install fleet` land here too.

(( ${+functions[fetch_source_url]} )) || source "${${(%):-%x}:A:h}/../lib/script-helpers.sh"

MODULE="fleet"
BIN="$HOME/.local/bin/fleet"
MANIFEST="$HOME/.config/fleet/manifest.json"
ENGINE="$HOME/.local/bin/fleet-providers.py"
DEFAULTS="$HOME/.config/fleet/provider-defaults.json"
# Where Auth serves fleet's files; tests point it at a local directory.
FLEET_SOURCE="${FLEET_SOURCE_URL:-https://auth.lost.plus/fleet}"

_handoff() {
    local installer rc=0
    # Pending until the whole hand-over works: a failure after fleet is on disk
    # still reads as outdated, so the next run retries and setup stays.
    record_script_state "$MODULE" handoff pending pending
    installer=$(mktemp) || return 1
    if [[ -d "$FLEET_SOURCE" ]]; then
        cp "$FLEET_SOURCE/install.sh" "$installer"
    elif (( ${+functions[fetch_source_url]} )); then
        fetch_source_url "$FLEET_SOURCE/install.sh" -o "$installer"
    else
        curl -fsSL "$FLEET_SOURCE/install.sh" -o "$installer"
    fi || rc=1
    # A pull, as before: local edits in ~/.agents go up only when the operator syncs.
    (( rc == 0 )) && { SOURCE_URL="$FLEET_SOURCE" sh "$installer" --pull || rc=1; }
    rm -f "$installer"
    (( rc == 0 )) || return 1
    # Only a timer that is on lets setup let go; until then the next run retries.
    if ! "$BIN" schedule status >/dev/null 2>&1; then
        echo "fleet: its nightly pass is not on yet; setup keeps updating fleet for now" >&2
        return 1
    fi
    remove_script_state "$MODULE"
    remove_script_state auth
    echo "fleet: fleet now updates itself; setup no longer manages fleet or auth"
}

install() { _handoff; }
update() { _handoff; }

status() {
    # Still setup's: update hands it over.
    if is_script_installed "$MODULE"; then
        printf '%-25s %-12s target=%s\n' "$MODULE" "outdated" "$BIN"
        return 1
    fi
    if [[ -x "$BIN" ]]; then
        printf '%-25s %-12s target=%s\n' "$MODULE" "current" "$BIN"
        return 0
    fi
    printf '%-25s %-12s\n' "$MODULE" "uninstalled"
    return 2
}

uninstall() {
    [[ -x "$BIN" ]] && "$BIN" schedule disable >/dev/null 2>&1
    manage_block "$HOME/.ssh/config" "fleet" "" "remove"
    manage_block "$HOME/.ssh/authorized_keys" "fleet-keys" "" "remove"
    rm -f "$BIN" "$MANIFEST" "$ENGINE" "$DEFAULTS"
    remove_script_state "$MODULE"
    echo "fleet: uninstalled. This machine stays in its fleet until it is revoked in the Fleet tab."
}
