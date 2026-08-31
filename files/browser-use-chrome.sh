#!/usr/bin/env zsh
# setup-module: browser-use-chrome
# setup-type: script

(( ${+functions[fetch_source_url]} )) || source "${${(%):-%x}:A:h}/../lib/script-helpers.sh"

MODULE="browser-use-chrome"
UNIT_DIR="${BROWSER_USE_SYSTEMD_DIR:-$HOME/.config/systemd/user}"
UNIT="$UNIT_DIR/browser-use-chrome.service"
CDP_PORT="${BROWSER_USE_CDP_PORT:-9223}"

_chrome_binary() {
    local candidate
    if [[ -n "${BROWSER_USE_CHROMIUM_BIN:-}" && -x "$BROWSER_USE_CHROMIUM_BIN" ]]; then
        printf '%s\n' "$BROWSER_USE_CHROMIUM_BIN"
        return 0
    fi
    for candidate in /snap/bin/chromium /usr/bin/chromium /usr/bin/chromium-browser \
        /usr/bin/google-chrome /usr/bin/google-chrome-stable; do
        if [[ -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    echo "browser-use-chrome: no Chromium-family browser found" >&2
    return 1
}

_profile_dir() {
    if [[ -n "${BROWSER_USE_PROFILE_DIR:-}" ]]; then
        printf '%s\n' "$BROWSER_USE_PROFILE_DIR"
        return 0
    fi
    local chrome
    chrome=$(_chrome_binary) || return 1
    if [[ "$chrome" == /snap/* ]]; then
        printf '%s\n' "$HOME/snap/chromium/common/browser-use-profile"
    else
        printf '%s\n' "$HOME/.local/state/browser-use/chromium"
    fi
}

_render_unit() {
    local chrome profile
    chrome=$(_chrome_binary) || return 1
    profile=$(_profile_dir) || return 1
    cat <<EOF
# setup-module: browser-use-chrome
[Unit]
Description=Headless Chromium for Browser Use
After=network.target

[Service]
ExecStart=$chrome --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage --no-first-run --no-default-browser-check --remote-debugging-address=127.0.0.1 --remote-debugging-port=$CDP_PORT --remote-allow-origins=* --user-data-dir=$profile about:blank
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
EOF
}

_desired_hash() {
    _render_unit | setup_sha256_string
}

_apply() {
    local action="$1" staged hash profile
    staged=$(mktemp)
    _render_unit > "$staged" || { rm -f "$staged"; return 1; }
    hash=$(setup_sha256_string < "$staged")
    profile=$(_profile_dir) || { rm -f "$staged"; return 1; }
    mkdir -p "$UNIT_DIR" "$profile" || { rm -f "$staged"; return 1; }
    command install -m 0644 "$staged" "$UNIT" || { rm -f "$staged"; return 1; }
    rm -f "$staged"
    systemctl --user daemon-reload || return 1
    systemctl --user enable browser-use-chrome.service || return 1
    systemctl --user restart browser-use-chrome.service || return 1
    record_script_state "$MODULE" "systemd-user" "$hash" "$hash"
    echo "browser-use-chrome: $action -> $UNIT"
}

install() {
    _apply installed
}

update() {
    _apply updated
}

status() {
    if [[ ! -f "$UNIT" ]]; then
        printf '%-25s %-12s target=%s\n' "$MODULE" "uninstalled" "$UNIT"
        return 2
    fi

    local staged desired current state
    staged=$(mktemp)
    _render_unit > "$staged" || { rm -f "$staged"; return 1; }
    desired=$(setup_sha256_string < "$staged")
    current=$(setup_sha256_string < "$UNIT")
    rm -f "$staged"

    state="current"
    [[ "$current" == "$desired" ]] || state="outdated"
    systemctl --user is-enabled --quiet browser-use-chrome.service || state="outdated"
    systemctl --user is-active --quiet browser-use-chrome.service || state="outdated"
    curl -fsS --max-time 2 "http://127.0.0.1:$CDP_PORT/json/version" >/dev/null \
        || state="outdated"

    printf '%-25s %-12s local=%s remote=%s target=%s\n' \
        "$MODULE" "$state" "${current:0:7}" "${desired:0:7}" "$UNIT"
    [[ "$state" == "current" ]]
}

uninstall() {
    systemctl --user disable --now browser-use-chrome.service 2>/dev/null || true
    rm -f "$UNIT"
    systemctl --user daemon-reload
    remove_script_state "$MODULE"
    echo "browser-use-chrome: removed -> $UNIT"
}
