#!/usr/bin/env bash
# setup-module: fzf-multicolumn
# setup-type: script

[[ "$(type -t git_clone_if_missing)" == "function" ]] || source "$(dirname "${BASH_SOURCE[0]}")/../lib/script-helpers.sh"

MODULE="fzf-multicolumn"
BIN="$HOME/.local/bin/fzf-multicolumn"
REPO="LPFchan/fzf-multicolumn"

install() {
    if command -v fzf-multicolumn >/dev/null 2>&1; then
        echo "fzf-multicolumn already installed: $(fzf-multicolumn --version)"
    else
        _download_release || return 1
    fi
    _record_state
}

status() {
    if ! command -v fzf-multicolumn >/dev/null 2>&1; then
        printf '%-25s %-12s\n' "$MODULE" "uninstalled"
        return 2
    fi
    local installed_ver latest_ver
    installed_ver=$(fzf-multicolumn --version 2>/dev/null | awk 'NR==1{print $1}')
    latest_ver=$(_latest_tag || true)
    latest_ver="${latest_ver#v}"
    if [[ -z "$latest_ver" ]]; then
        printf '%-25s %-12s local=%s remote=%s target=%s\n' "$MODULE" "installed" "$installed_ver" "$installed_ver" "$BIN"
        record_script_state "$MODULE" "version" "$installed_ver" "$installed_ver"
        return 0
    fi
    if [[ "$installed_ver" == "$latest_ver" ]]; then
        printf '%-25s %-12s local=%s remote=%s target=%s\n' "$MODULE" "current" "$installed_ver" "$latest_ver" "$BIN"
        record_script_state "$MODULE" "version" "$installed_ver" "$latest_ver"
        return 0
    else
        printf '%-25s %-12s local=%s remote=%s target=%s\n' "$MODULE" "outdated" "$installed_ver" "$latest_ver" "$BIN"
        record_script_state "$MODULE" "version" "$installed_ver" "$latest_ver"
        return 1
    fi
}

update() {
    _download_release || return 1
    _record_state
}

uninstall() {
    rm -f "$BIN"
    remove_script_state "$MODULE"
}

_latest_tag() {
    # Short timeouts: ai-menu may trigger install during shell startup
    curl -fsSL --connect-timeout 5 --max-time 10 \
        "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
        | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/'
}

_download_release() {
    local tag ver os arch asset tmp base_url
    tag=$(_latest_tag)
    if [[ -z "$tag" ]]; then
        echo "fzf-multicolumn: could not resolve latest release of $REPO" >&2
        return 1
    fi
    ver="${tag#v}"
    case "$(uname -s)" in
        Darwin) os=darwin ;;
        Linux)  os=linux ;;
        *) echo "fzf-multicolumn: unsupported OS $(uname -s)" >&2; return 1 ;;
    esac
    case "$(uname -m)" in
        arm64|aarch64) arch=arm64 ;;
        x86_64|amd64)  arch=amd64 ;;
        *) echo "fzf-multicolumn: unsupported arch $(uname -m)" >&2; return 1 ;;
    esac
    asset="fzf-multicolumn-${ver}-${os}_${arch}.tgz"
    base_url="https://github.com/$REPO/releases/download/$tag"
    tmp=$(mktemp -d)
    if ! curl -fsSL --connect-timeout 5 --max-time 120 "$base_url/$asset" -o "$tmp/$asset" \
       || ! curl -fsSL --connect-timeout 5 --max-time 30 "$base_url/fzf-multicolumn-${ver}-checksums.txt" -o "$tmp/checksums.txt"; then
        echo "fzf-multicolumn: download failed: $base_url/$asset" >&2
        rm -rf "$tmp"
        return 1
    fi
    local expected actual
    expected=$(grep " $asset\$" "$tmp/checksums.txt" | awk '{print $1}')
    actual=$(setup_sha256_string < "$tmp/$asset")
    if [[ -z "$expected" || "$expected" != "$actual" ]]; then
        echo "fzf-multicolumn: checksum mismatch for $asset (expected ${expected:-none}, got $actual)" >&2
        rm -rf "$tmp"
        return 1
    fi
    if ! tar -xzf "$tmp/$asset" -C "$tmp" fzf-multicolumn || [[ ! -f "$tmp/fzf-multicolumn" ]]; then
        echo "fzf-multicolumn: extraction of $asset failed" >&2
        rm -rf "$tmp"
        return 1
    fi
    mkdir -p "$(dirname "$BIN")"
    # Stage next to the target first so the working binary is only removed
    # once the new one is safely on the same filesystem.
    if ! mv "$tmp/fzf-multicolumn" "$BIN.new"; then
        echo "fzf-multicolumn: failed to stage binary at $BIN.new" >&2
        rm -rf "$tmp"
        return 1
    fi
    chmod +x "$BIN.new"
    # rm before replacing (not mv-over): on macOS, overwriting a signed
    # binary in place invalidates the kernel's per-vnode code-signature
    # cache and the next launch is SIGKILLed with no error message.
    rm -f "$BIN"
    mv "$BIN.new" "$BIN"
    rm -rf "$tmp"
    echo "fzf-multicolumn $ver installed to $BIN"
}

_record_state() {
    if command -v fzf-multicolumn >/dev/null 2>&1; then
        local ver
        ver=$(fzf-multicolumn --version 2>/dev/null | awk 'NR==1{print $1}')
        record_script_state "$MODULE" "version" "${ver:-unknown}" "${ver:-unknown}"
    fi
}
