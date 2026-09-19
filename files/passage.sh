#!/usr/bin/env zsh
# setup-module: passage
# setup-type: script
#
# Installs the passage launcher at ~/.local/bin/passage: shell access to the
# passage secrets MCP (get / list / run) using the auth module's login.

(( ${+functions[fetch_source_url]} )) || source "${${(%):-%x}:A:h}/../lib/script-helpers.sh"

MODULE="passage"
BIN="${PASSAGE_BIN:-$HOME/.local/bin/passage}"
SOURCE_BASE="${LINUX_SETUP_SOURCE_URL:-${SOURCE_URL:-https://raw.githubusercontent.com/LPFchan/setup/main}}"
BIN_SOURCE="${PASSAGE_SOURCE:-$SOURCE_BASE/files/passage}"

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

_recorded_hash() {
    local rt lr rr
    IFS=$'\t' read -r rt lr rr < <(script_state_for "$MODULE" 2>/dev/null) && printf '%s' "$lr"
}

_apply() {
    local action="$1" temporary hash
    mkdir -p "${BIN:h}"
    temporary="${BIN}.tmp.$$"
    _stage "$temporary" || { rm -f "$temporary"; return 1; }
    hash=$(setup_sha256_string < "$temporary")
    mv "$temporary" "$BIN"
    record_script_state "$MODULE" "passage" "$hash" "$hash"
    echo "passage: $action -> $BIN"
}

install() { _apply installed; }
update() { _apply updated; }

status() {
    if ! is_script_installed "$MODULE" && [[ ! -x "$BIN" ]]; then
        printf '%-25s %-12s\n' "$MODULE" "uninstalled"
        return 2
    fi
    local desired recorded
    desired=$(_desired_hash) || return 1
    recorded=$(_recorded_hash)
    if [[ ! -x "$BIN" ]] || [[ "$(setup_sha256_string < "$BIN")" != "$desired" ]]; then
        printf '%-25s %-12s local=%s remote=%s target=%s\n' \
            "$MODULE" "outdated" "${recorded:0:7}" "${desired:0:7}" "$BIN"
        return 1
    fi
    printf '%-25s %-12s local=%s remote=%s target=%s\n' \
        "$MODULE" "current" "${desired:0:7}" "${desired:0:7}" "$BIN"
}

uninstall() {
    rm -f "$BIN"
    remove_script_state "$MODULE"
    echo "passage: uninstalled launcher"
}
