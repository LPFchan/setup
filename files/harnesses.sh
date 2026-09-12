#!/usr/bin/env zsh
# setup-module: harnesses
# setup-type: script
#
# Installs the harnesses fzf client at ~/.local/bin/harnesses plus its
# canonical manifest. The client installs and self-updates AI coding
# harnesses (claude, codex, t3, ...), renders per-harness settings, and
# enrolls MCP servers from vaultwarden folder=mcp. Absorbs the harness
# self-update logic that used to live in bin/setup.

(( ${+functions[fetch_source_url]} )) || source "${${(%):-%x}:A:h}/../lib/script-helpers.sh"

MODULE="harnesses"
BIN="${HARNESSES_BIN:-$HOME/.local/bin/harnesses}"
MANIFEST_TARGET="${HARNESSES_MANIFEST_TARGET:-$HOME/.config/harnesses/manifest.json}"
SOURCE_BASE="${LINUX_SETUP_SOURCE_URL:-${SOURCE_URL:-https://raw.githubusercontent.com/LPFchan/setup/main}}"
BIN_SOURCE="${HARNESSES_SOURCE:-$SOURCE_BASE/files/harnesses}"
MANIFEST_SOURCE="${HARNESSES_MANIFEST_SOURCE:-$SOURCE_BASE/files/harnesses-manifest.json}"

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
    _fetch_file "$BIN_SOURCE" "$directory/harnesses" || return 1
    _fetch_file "$MANIFEST_SOURCE" "$directory/manifest.json" || return 1
    chmod +x "$directory/harnesses"
    python3 -c "import ast,sys;ast.parse(open(sys.argv[1]).read())" "$directory/harnesses" || return 1
    python3 -c "import json,sys;json.load(open(sys.argv[1]))" "$directory/manifest.json" || return 1
}

_desired_hash_from() {
    local staged="$1"
    { cat "$staged/harnesses"; cat "$staged/manifest.json"; } | setup_sha256_string
}

_recorded_hash() {
    local rt lr rr
    IFS=$'\t' read -r rt lr rr < <(script_state_for "$MODULE" 2>/dev/null) && printf "%s" "$lr"
}

_apply() {
    local action="$1" staged hash bin_tmp manifest_tmp
    staged=$(mktemp -d)
    _stage_assets "$staged" || { rm -rf "$staged"; return 1; }
    hash=$(_desired_hash_from "$staged")
    mkdir -p "$(dirname "$BIN")" "$(dirname "$MANIFEST_TARGET")"
    bin_tmp="${BIN}.tmp.$$"; manifest_tmp="${MANIFEST_TARGET}.tmp.$$"
    cp "$staged/harnesses" "$bin_tmp" || { rm -rf "$staged"; return 1; }
    chmod +x "$bin_tmp"
    cp "$staged/manifest.json" "$manifest_tmp" || { rm -f "$bin_tmp"; rm -rf "$staged"; return 1; }
    mv "$bin_tmp" "$BIN"
    mv "$manifest_tmp" "$MANIFEST_TARGET"
    rm -rf "$staged"
    record_script_state "$MODULE" "harnesses" "$hash" "$hash"
    echo "harnesses: $action -> $BIN"
}

install() { _apply installed; }
update() { _apply updated; }

status() {
    if ! is_script_installed "$MODULE" && [[ ! -x "$BIN" ]]; then
        printf "%-25s %-12s\n" "$MODULE" "uninstalled"
        return 2
    fi
    local staged desired recorded drift=0
    staged=$(mktemp -d)
    _stage_assets "$staged" || { rm -rf "$staged"; return 1; }
    desired=$(_desired_hash_from "$staged")
    recorded=$(_recorded_hash)
    [[ -x "$BIN" && -f "$MANIFEST_TARGET" ]] || drift=1
    if (( drift == 0 )); then
        cmp -s "$staged/harnesses" "$BIN" || drift=1
        cmp -s "$staged/manifest.json" "$MANIFEST_TARGET" || drift=1
    fi
    rm -rf "$staged"
    if (( drift == 1 )); then
        printf "%-25s %-12s local=%s remote=%s target=%s\n" \
            "$MODULE" "outdated" "${recorded:0:7}" "${desired:0:7}" "$BIN"
        record_script_state "$MODULE" "harnesses" "${recorded:-none}" "$desired"
        return 1
    fi
    printf "%-25s %-12s local=%s remote=%s target=%s\n" \
        "$MODULE" "current" "${desired:0:7}" "${desired:0:7}" "$BIN"
    record_script_state "$MODULE" "harnesses" "$desired" "$desired"
}

uninstall() {
    # Tear the schedule down before the binary goes: the timer/agent outlives
    # an uninstall otherwise and keeps firing at a path that no longer exists.
    # refresh-models left two launchd agents failing on both Macs that way.
    if [[ -x "$BIN" ]]; then
        python3 "$BIN" schedule disable >/dev/null 2>&1 || true
    fi
    rm -f "$BIN" "$MANIFEST_TARGET"
    remove_script_state "$MODULE"
    echo "harnesses: uninstalled launcher"
}
