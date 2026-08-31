#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

export HOME="$TEST_TMP/home"
export XDG_STATE_HOME="$TEST_TMP/state"
export BROWSER_USE_SYSTEMD_DIR="$HOME/.config/systemd/user"
export BROWSER_USE_PROFILE_DIR="$HOME/.local/state/browser-use/chromium"
export BROWSER_USE_CHROMIUM_BIN="$TEST_TMP/chromium"
export SYSTEMCTL_LOG="$TEST_TMP/systemctl.log"
mkdir -p "$HOME" "$TEST_TMP/bin"
touch "$BROWSER_USE_CHROMIUM_BIN"
chmod +x "$BROWSER_USE_CHROMIUM_BIN"

cat > "$TEST_TMP/bin/systemctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
case "$*" in
  *is-enabled*|*is-active*) exit 0 ;;
esac
SH
chmod +x "$TEST_TMP/bin/systemctl"
cat > "$TEST_TMP/bin/curl" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$TEST_TMP/bin/curl"
export PATH="$TEST_TMP/bin:$PATH"

zsh -c "source '$ROOT/lib/script-helpers.sh'; source '$ROOT/files/browser-use-chrome.sh'; install; status; cp '$BROWSER_USE_SYSTEMD_DIR/browser-use-chrome.service' '$TEST_TMP/unit.snapshot'; uninstall"

UNIT="$BROWSER_USE_SYSTEMD_DIR/browser-use-chrome.service"
[[ ! -e "$UNIT" ]] || { echo "unit survived uninstall" >&2; exit 1; }
grep -Fq "ExecStart=$BROWSER_USE_CHROMIUM_BIN" "$TEST_TMP/unit.snapshot"
grep -Fq -- "--user-data-dir=$BROWSER_USE_PROFILE_DIR" "$TEST_TMP/unit.snapshot"
grep -Fq -- '--remote-debugging-address=127.0.0.1' "$TEST_TMP/unit.snapshot"
grep -Fq -- '--remote-debugging-port=9223' "$TEST_TMP/unit.snapshot"
grep -Fq -- 'WantedBy=default.target' "$TEST_TMP/unit.snapshot"
grep -Fq -- '--user enable --now browser-use-chrome.service' "$SYSTEMCTL_LOG"
grep -Fq -- '--user disable --now browser-use-chrome.service' "$SYSTEMCTL_LOG"

if [[ -x /snap/bin/chromium ]]; then
    snap_profile=$(BROWSER_USE_CHROMIUM_BIN=/snap/bin/chromium BROWSER_USE_PROFILE_DIR= \
        zsh -c "source '$ROOT/lib/script-helpers.sh'; source '$ROOT/files/browser-use-chrome.sh'; _profile_dir")
    [[ "$snap_profile" == "$HOME/snap/chromium/common/browser-use-profile" ]]
fi

echo "browser-use-chrome tests passed"
