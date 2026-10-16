#!/usr/bin/env zsh
# setup-module: fleet
# setup-type: script
#
# Installs the fleet CLI (files/fleet), which keeps the managed ~/.ssh/config
# and authorized_keys blocks in step with the account's fleet in Common Auth,
# and takes over ssh-aliases' blocks in place on its first write.

(( ${+functions[fetch_source_url]} )) || source "${${(%):-%x}:A:h}/../lib/script-helpers.sh"

MODULE="fleet"
BIN="${FLEET_BIN:-$HOME/.local/bin/fleet}"
SOURCE_BASE="${LINUX_SETUP_SOURCE_URL:-${SOURCE_URL:-https://raw.githubusercontent.com/LPFchan/setup/main}}"
BIN_SOURCE="${FLEET_SOURCE:-$SOURCE_BASE/files/fleet}"

_stage() {
    local destination="$1"
    if [[ -f "$BIN_SOURCE" ]]; then
        cp "$BIN_SOURCE" "$destination"
    elif (( ${+functions[fetch_source_url]} )); then
        fetch_source_url "$BIN_SOURCE" -o "$destination"
    else
        curl -fsSL "$BIN_SOURCE" -o "$destination"
    fi
    chmod +x "$destination"
    python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$destination"
}

_desired_hash() {
    local staged; staged=$(mktemp)
    _stage "$staged" || { rm -f "$staged"; return 1; }
    setup_sha256_string < "$staged"
    rm -f "$staged"
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
    # Swapped in by `setup update` rather than asked for: ask first.
    if [[ -n "${SETUP_SWAP_FROM:-}" ]]; then
        local answer
        printf 'fleet replaces %s and signs this machine in to its fleet. Log in now? [Y/n] ' \
            "$SETUP_SWAP_FROM" >/dev/tty
        read -r answer </dev/tty || answer=n
        if [[ "$answer" == [nN]* ]]; then
            echo "fleet: login skipped; setup offers it again after its next interactive run"
            return 0
        fi
    fi
    echo "fleet: signing this machine in to its fleet"
    "$auth_bin" login </dev/tty >/dev/tty 2>&1 || echo "fleet: login skipped; run: auth login" >&2
}

_apply() {
    local action="$1" temporary hash
    mkdir -p "${BIN:h}"
    temporary="${BIN}.tmp.$$"
    _stage "$temporary" || { rm -f "$temporary"; return 1; }
    hash=$(setup_sha256_string < "$temporary")
    mv "$temporary" "$BIN"
    record_script_state "$MODULE" "fleet" "$hash" "$hash"
    echo "fleet: $action -> $BIN"
    [[ "$action" == installed ]] && _login_if_needed
    # Exit 3 means Auth gave no authoritative answer: the blocks already there
    # stay, and status says so rather than failing every run.
    "$BIN" sync || (( $? == 3 ))
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
    actual=$([[ -f "$BIN" ]] && setup_sha256_string < "$BIN")
    if [[ ! -x "$BIN" || "$actual" != "$desired" ]]; then
        printf '%-25s %-12s local=%s remote=%s target=%s\n' \
            "$MODULE" "outdated" "${actual:0:7}" "${desired:0:7}" "$BIN"
        return 1
    fi
    "$BIN" sync --check 2>/dev/null
    rc=$?
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
    rm -f "$BIN"
    remove_script_state "$MODULE"
    echo "fleet: uninstalled. This machine stays in its fleet until it is revoked in the Fleet tab."
}
