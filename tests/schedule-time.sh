#!/usr/bin/env zsh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" SETUP_SOURCE_ONLY=1
mkdir -p "$HOME/.local/bin" "$XDG_STATE_HOME/setup"
# shellcheck disable=SC1091
source "$ROOT/bin/setup"

fail() { echo "FAIL: $*" >&2; exit 1; }

SYSTEMCTL_CALLS="$TMP/systemctl-calls"
: > "$SYSTEMCTL_CALLS"
uname() { echo Linux; }
systemctl() { printf '%s\n' "$*" >> "$SYSTEMCTL_CALLS"; }

cmd_schedule > "$TMP/linux-out"
timer="$HOME/.config/systemd/user/setup-update.timer"
grep -Fqx 'OnCalendar=*-*-* 06:00:00' "$timer" \
    || fail "Linux timer is not scheduled for 06:00"
grep -q 'scheduled daily at 06:00 (systemd)' "$TMP/linux-out" \
    || fail "Linux schedule output has the wrong time"
grep -qx -- '--user daemon-reload' "$SYSTEMCTL_CALLS" \
    || fail "Linux timer did not reload systemd"
grep -qx -- '--user enable --now setup-update.timer' "$SYSTEMCTL_CALLS" \
    || fail "Linux timer was not enabled"

LAUNCHCTL_CALLS="$TMP/launchctl-calls"
: > "$LAUNCHCTL_CALLS"
uname() { echo Darwin; }
id() { echo 501; }
launchctl() { printf '%s\n' "$*" >> "$LAUNCHCTL_CALLS"; }

cmd_schedule > "$TMP/macos-out"
plist="$HOME/Library/LaunchAgents/com.lost.plus.setup-update.plist"
grep -q '<key>Hour</key><integer>6</integer>' "$plist" \
    || fail "macOS timer is not scheduled for 06:00"
grep -q 'scheduled daily at 06:00 (launchd)' "$TMP/macos-out" \
    || fail "macOS schedule output has the wrong time"
grep -q 'bootstrap gui/501' "$LAUNCHCTL_CALLS" \
    || fail "macOS timer was not loaded"

echo "schedule time tests passed"
