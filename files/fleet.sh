#!/usr/bin/env zsh
# setup-module: fleet
# setup-type: script
#
# Installs the fleet CLI (files/fleet), which keeps the managed ~/.ssh/config
# and authorized_keys blocks in step with the account's fleet in Common Auth,
# and takes over ssh-aliases' blocks in place on its first write. Its harness
# manifest (files/fleet-manifest.json) lists the harnesses fleet installs and
# keeps updated, and the settings it renders into them.

(( ${+functions[fetch_source_url]} )) || source "${${(%):-%x}:A:h}/../lib/script-helpers.sh"

MODULE="fleet"
BIN="${FLEET_BIN:-$HOME/.local/bin/fleet}"
SOURCE_BASE="${LINUX_SETUP_SOURCE_URL:-${SOURCE_URL:-https://raw.githubusercontent.com/LPFchan/setup/main}}"
BIN_SOURCE="${FLEET_SOURCE:-$SOURCE_BASE/files/fleet}"
# Where fleet itself looks for it.
MANIFEST="$HOME/.config/fleet/manifest.json"
MANIFEST_SOURCE="${FLEET_MANIFEST_SOURCE:-$SOURCE_BASE/files/fleet-manifest.json}"
HARNESSES_BIN="$HOME/.local/bin/harnesses"

_fetch() {
    if [[ -f "$1" ]]; then
        cp "$1" "$2"
    elif (( ${+functions[fetch_source_url]} )); then
        fetch_source_url "$1" -o "$2"
    else
        curl -fsSL "$1" -o "$2"
    fi || return 1
    # An empty file parses too.
    [[ -s "$2" ]]
}

# Stage the CLI and its manifest into a directory, checked before either
# replaces the installed copy.
_stage() {
    local directory="$1"
    _fetch "$BIN_SOURCE" "$directory/fleet" && _fetch "$MANIFEST_SOURCE" "$directory/manifest.json" || return 1
    chmod +x "$directory/fleet"
    python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$directory/fleet" || return 1
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$directory/manifest.json"
}

_hash() { { cat "$1"; cat "$2"; } | setup_sha256_string; }

_desired_hash() {
    local staged; staged=$(mktemp -d)
    _stage "$staged" || { rm -rf "$staged"; return 1; }
    _hash "$staged/fleet" "$staged/manifest.json"
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
    mkdir -p "${BIN:h}" "${MANIFEST:h}"
    staged=$(mktemp -d)
    _stage "$staged" || { rm -rf "$staged"; return 1; }
    hash=$(_hash "$staged/fleet" "$staged/manifest.json")
    # Same-filesystem temporaries, so each swap is a rename.
    cp "$staged/fleet" "$BIN.tmp.$$" && cp "$staged/manifest.json" "$MANIFEST.tmp.$$" \
        || { rm -rf "$staged" "$BIN.tmp.$$" "$MANIFEST.tmp.$$"; return 1; }
    rm -rf "$staged"
    mv "$MANIFEST.tmp.$$" "$MANIFEST"
    mv "$BIN.tmp.$$" "$BIN"
    record_script_state "$MODULE" "fleet" "$hash" "$hash"
    echo "fleet: $action -> $BIN"
    [[ "$action" == installed ]] && _login_if_needed
    # Exit 3 means Auth gave no authoritative answer: the blocks already there
    # stay, and status says so rather than failing every run.
    # setup only pulls; uploads are for a direct `fleet sync`.
    "$BIN" sync --pull || (( $? == 3 ))
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
    actual=$([[ -f "$BIN" && -f "$MANIFEST" ]] && _hash "$BIN" "$MANIFEST")
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
    # Through python3, so a binary that lost its executable bit still cleans up;
    # a deleted one is fetched again, since only it can take the rendered
    # settings and links back down.
    local cli="$BIN" staged="" ok="" was_on="" off="" timer=""
    if [[ ! -f "$cli" ]]; then
        staged=$(mktemp -d)
        _stage "$staged" && cli="$staged/fleet"
    fi
    # The timer stops first, so a nightly run cannot render again mid-way, and
    # whether it ran says whether to turn it back on if the rest fails. It goes
    # running or not: one left behind would run a binary about to go. A CLI
    # that cannot do either (broken, or older than one that knows a missing
    # timer is already off) hands over to the current one.
    if [[ -f "$cli" ]] && timer=$(python3 "$cli" schedule status 2>/dev/null) \
        && python3 "$cli" schedule disable >/dev/null 2>&1; then
        off=1
    elif [[ -f "$cli" && -z "$staged" ]]; then
        staged=$(mktemp -d)
        if _stage "$staged"; then
            cli="$staged/fleet"
            [[ -n "$timer" ]] || timer=$(python3 "$cli" schedule status 2>/dev/null)
            python3 "$cli" schedule disable >/dev/null 2>&1 && off=1
        fi
    fi
    [[ "$timer" == *' on' ]] && was_on=1
    if [[ -f "$cli" && -z "$off" ]]; then
        [[ -n "$staged" ]] && rm -rf "$staged"
        echo "fleet: could not turn off the nightly sync; nothing was removed, try again" >&2
        return 1
    fi
    # Only the CLI knows what fleet rendered and which links and backups are
    # its own, so without it nothing else goes either. __unrender first:
    # claude's MCP entries call the binary for their tokens. An installed one
    # older than this module may not know how, so the current one gets a
    # second try.
    [[ -f "$cli" ]] && python3 "$cli" __unrender && python3 "$cli" __unlink && ok=1
    if [[ -z "$ok" && -z "$staged" ]]; then
        staged=$(mktemp -d)
        _stage "$staged" && python3 "$staged/fleet" __unrender && python3 "$staged/fleet" __unlink && ok=1
    fi
    if [[ -z "$ok" ]]; then
        # fleet stays installed: a sync puts back whatever the cleanup took
        # before it failed, and its nightly sync comes back.
        # The staged CLI whenever there is one: it is the current version, and
        # an installed one it stood in for may not render what it removed.
        local again="$BIN" back=""
        [[ -n "$staged" && -f "$staged/fleet" ]] && again="$staged/fleet"
        [[ -f "$again" ]] && FLEET_PATH="$BIN" python3 "$again" sync --pull >/dev/null 2>&1 && back=1
        if [[ -n "$was_on" ]] && ! { [[ -f "$cli" ]] && python3 "$cli" schedule enable >/dev/null 2>&1; }; then
            echo "fleet: could not turn the nightly sync back on; run: fleet schedule on" >&2
        fi
        [[ -n "$staged" ]] && rm -rf "$staged"
        if [[ -n "$back" ]]; then
            echo "fleet: could not take back the rendered settings and links; fleet stays installed, try again" >&2
        else
            echo "fleet: could not take back the rendered settings and links, nor put them back; run fleet sync, then try again" >&2
        fi
        return 1
    fi
    [[ -n "$staged" ]] && rm -rf "$staged"
    manage_block "$HOME/.ssh/config" "fleet" "" "remove"
    manage_block "$HOME/.ssh/authorized_keys" "fleet-keys" "" "remove"
    # The harnesses alias fleet left in place of the old client.
    [[ -f "$HARNESSES_BIN" ]] && grep -q '^# fleet: harnesses alias' "$HARNESSES_BIN" && rm -f "$HARNESSES_BIN"
    rm -f "$BIN" "$MANIFEST"
    rmdir "${MANIFEST:h}" 2>/dev/null
    remove_script_state "$MODULE"
    echo "fleet: uninstalled. This machine stays in its fleet until it is revoked in the Fleet tab."
}
