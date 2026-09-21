#!/usr/bin/env zsh
# setup-module: miniharness
# setup-type: script
#
# miniharness is the headless model summon `system-updates` asks at 07:00
# whether rebooting is safe, so the module exists to put it on a machine that
# installs system-updates rather than leaving it to a hand-run npm.
#
# It cannot ride in files/harnesses-manifest.json: that module updates by
# running `<binary> update`, and miniharness has no update subcommand -- it
# would read "update" as a prompt and make a real model call.

(( ${+functions[record_script_state]} )) || source "${${(%):-%x}:A:h}/../lib/script-helpers.sh"

MODULE="miniharness"
PACKAGE="miniharness"
REGISTRY="https://registry.npmjs.org/$PACKAGE/latest"

# npm, found the way harnesses finds node (files/harnesses:328). A login shell
# has nvm on PATH, but `setup update` also runs from a systemd timer that does
# not, so the nvm and /opt/node directories are searched directly as a fallback.
_npm() {
    local dir
    if [[ -n "${NVM_BIN:-}" && -x "$NVM_BIN/npm" ]]; then
        printf '%s\n' "$NVM_BIN/npm"
        return 0
    fi
    if dir=$(command -v npm 2>/dev/null) && [[ -n "$dir" ]]; then
        printf '%s\n' "$dir"
        return 0
    fi
    # Newest node version first, so a stale 16.x alongside a live 22.x loses.
    for dir in /opt/node/bin $HOME/.nvm/versions/node/*/bin(NOn); do
        [[ -x "$dir/npm" ]] && { printf '%s\n' "$dir/npm"; return 0 }
    done
    return 1
}

_bin() {
    local candidate npm prefix
    if candidate=$(command -v "$PACKAGE" 2>/dev/null) && [[ -n "$candidate" ]]; then
        printf '%s\n' "$candidate"
        return 0
    fi
    npm=$(_npm) || return 1
    prefix=$("$npm" config get prefix 2>/dev/null) || return 1
    [[ -n "$prefix" && "$prefix" != undefined ]] || return 1
    candidate="$prefix/bin/$PACKAGE"
    [[ -x "$candidate" ]] || return 1
    printf '%s\n' "$candidate"
}

_installed_version() {
    local bin
    bin=$(_bin) || return 1
    "$bin" --version 2>/dev/null | awk 'NF { print $1; exit }'
}

# Short timeouts: this runs inside `setup status`, which the TUI blocks on.
_latest_version() {
    curl -fsSL --connect-timeout 5 --max-time 10 "$REGISTRY" 2>/dev/null \
        | sed -n 's/.*"version" *: *"\([^"]*\)".*/\1/p' \
        | head -1
}

install() {
    local npm
    if _bin >/dev/null; then
        echo "miniharness already installed: $(_installed_version)"
        _record_state
        return 0
    fi
    npm=$(_npm) || {
        echo "miniharness: npm not found; install node via nvm (https://github.com/nvm-sh/nvm) or /opt/node, then re-run" >&2
        return 1
    }
    echo "Installing $PACKAGE via $npm ..."
    "$npm" install -g "$PACKAGE" || return 1
    _bin >/dev/null || {
        echo "miniharness: npm reported success but no $PACKAGE binary resolved" >&2
        return 1
    }
    echo "miniharness $(_installed_version) installed at $(_bin)"
    _record_state
}

status() {
    local installed_ver latest_ver target
    installed_ver=$(_installed_version) || installed_ver=""
    if [[ -z "$installed_ver" ]]; then
        printf '%-25s %-12s\n' "$MODULE" "uninstalled"
        return 2
    fi
    target=$(_bin)
    latest_ver=$(_latest_version)
    if [[ -z "$latest_ver" ]]; then
        printf '%-25s %-12s local=%s remote=%s target=%s\n' \
            "$MODULE" "installed" "$installed_ver" "$installed_ver" "$target"
        record_script_state "$MODULE" "version" "$installed_ver" "$installed_ver"
        return 0
    fi
    if [[ "$installed_ver" == "$latest_ver" ]]; then
        printf '%-25s %-12s local=%s remote=%s target=%s\n' \
            "$MODULE" "current" "$installed_ver" "$latest_ver" "$target"
        record_script_state "$MODULE" "version" "$installed_ver" "$latest_ver"
        return 0
    fi
    printf '%-25s %-12s local=%s remote=%s target=%s\n' \
        "$MODULE" "outdated" "$installed_ver" "$latest_ver" "$target"
    record_script_state "$MODULE" "version" "$installed_ver" "$latest_ver"
    return 1
}

update() {
    local npm
    npm=$(_npm) || {
        echo "miniharness: npm not found; cannot update" >&2
        return 1
    }
    "$npm" install -g "$PACKAGE@latest" || return 1
    echo "miniharness now at $(_installed_version)"
    _record_state
}

uninstall() {
    local npm
    if npm=$(_npm); then
        "$npm" uninstall -g "$PACKAGE" || true
    else
        echo "miniharness: npm not found; leaving any installed copy in place" >&2
    fi
    remove_script_state "$MODULE"
}

_record_state() {
    local ver
    ver=$(_installed_version) || ver=""
    record_script_state "$MODULE" "version" "${ver:-unknown}" "${ver:-unknown}"
}
