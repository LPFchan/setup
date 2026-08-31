#!/usr/bin/env zsh
# setup-module: browser-use-chrome
# setup-type: script

(( ${+functions[fetch_source_url]} )) || source "${${(%):-%x}:A:h}/../lib/script-helpers.sh"

MODULE="browser-use-chrome"
UNIT_DIR="${BROWSER_USE_SYSTEMD_DIR:-$HOME/.config/systemd/user}"
UNIT="$UNIT_DIR/browser-use-chrome.service"
PROFILE_DIR="${BROWSER_USE_PROFILE_DIR:-$HOME/.local/state/browser-use/chromium}"

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

_render_unit() {
    local chrome
    chrome=$(_chrome_binary) || return 1
    cat <<EOF
# setup-module: browser-use-chrome
[Unit]
Description=Headless Chromium for Browser Use
After=network.target

[Service]
ExecStart=$chrome --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage --no-first-run --no-default-browser-check --remote-debugging-address=127.0.0.1 --remote-debugging-port=9222 --remote-allow-origins=* --user-data-dir=%h/.local/state/browser-use/chromium about:blank
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
    local action="$1" staged hash
    staged=$(mktemp)
    _render_unit > "$staged" || { rm -f "$staged"; return 1; }
    hash=$(setup_sha256_string < "$staged")
    mkdir -p "$UNIT_DIR" "$PROFILE_DIR" || { rm -f "$staged"; return 1; }
    command install -m 0644 "$staged" "$UNIT" || { rm -f "$staged"; return 1; }
    rm -f "$staged"
    systemctl --user daemon-reload || return 1
    systemctl --user enable --now browser-use-chrome.service || return 1
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

    state="up-to-date"
    [[ "$current" == "$desired" ]] || state="outdated"
    systemctl --user is-enabled --quiet browser-use-chrome.service || state="disabled"
    systemctl --user is-active --quiet browser-use-chrome.service || state="stopped"

    printf '%-25s %-12s local=%s remote=%s target=%s\n' \
        "$MODULE" "$state" "${current:0:7}" "${desired:0:7}" "$UNIT"
    [[ "$state" == "up-to-date" ]]
}

uninstall() {
    systemctl --user disable --now browser-use-chrome.service 2>/dev/null || true
    rm -f "$UNIT"
    systemctl --user daemon-reload
    remove_script_state "$MODULE"
    echo "browser-use-chrome: removed -> $UNIT"
}
