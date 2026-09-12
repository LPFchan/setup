#!/usr/bin/env zsh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" SETUP_SOURCE_ONLY=1
mkdir -p "$HOME/.config/systemd/user" "$HOME/Library/LaunchAgents" "$XDG_STATE_HOME/setup"
# shellcheck disable=SC1091
source "$ROOT/bin/setup"

linux_service="$HOME/.config/systemd/user/setup-update.service"
linux_timer="$HOME/.config/systemd/user/setup-update.timer"
uname() { echo Linux; }
# cmd_unschedule delegates to bin/schedule, a subprocess that cannot see
# shell functions. Stub systemctl as a PATH executable honoring the same
# env knobs, and point the helper at the test units dir.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/systemctl" <<'STUB'
#!/usr/bin/env zsh
if [[ "$*" == *'disable --now'* ]]; then exit "${SYSTEMCTL_DISABLE_RC:-0}"; fi
if [[ "$*" == *'is-active'* ]]; then
    printf '%s\n' "${SYSTEMCTL_ACTIVE_STATE:-inactive}"
    exit "${SYSTEMCTL_ACTIVE_RC:-0}"
fi
if [[ "$*" == *'is-enabled'* ]]; then
    printf '%s\n' "${SYSTEMCTL_ENABLED_STATE:-disabled}"
    exit "${SYSTEMCTL_ENABLED_RC:-0}"
fi
exit 0
STUB
chmod +x "$TMP/bin/systemctl"
ln -sf "$ROOT/bin/schedule" "$TMP/bin/schedule"
export PATH="$TMP/bin:$PATH"
export SCHEDULE_USER_DIR="$HOME/.config/systemd/user"
export SYSTEMCTL_DISABLE_RC SYSTEMCTL_ACTIVE_RC SYSTEMCTL_ENABLED_RC SYSTEMCTL_ACTIVE_STATE SYSTEMCTL_ENABLED_STATE
touch "$linux_service" "$linux_timer"
# All three systemctl operations failing is indeterminate: retain recovery files.
SYSTEMCTL_DISABLE_RC=1 SYSTEMCTL_ACTIVE_RC=1 SYSTEMCTL_ENABLED_RC=1
SYSTEMCTL_ACTIVE_STATE='Failed to connect to bus' SYSTEMCTL_ENABLED_STATE='Failed to connect to bus'
if cmd_unschedule >/dev/null 2>&1; then echo "Linux indeterminate failure succeeded" >&2; exit 1; fi
[[ -e "$linux_service" && -e "$linux_timer" ]] || { echo "Linux indeterminate failure removed recovery config" >&2; exit 1; }
# Failed disable is acceptable only when successful textual queries explicitly
# report the desired inactive + disabled terminal state.
SYSTEMCTL_DISABLE_RC=1 SYSTEMCTL_ACTIVE_RC=3 SYSTEMCTL_ENABLED_RC=1
SYSTEMCTL_ACTIVE_STATE=inactive SYSTEMCTL_ENABLED_STATE=disabled
cmd_unschedule >/dev/null
[[ ! -e "$linux_service" && ! -e "$linux_timer" ]] || { echo "Linux known inactive/disabled retained units" >&2; exit 1; }
# Error text is never accepted, even if commands reuse documented state codes.
touch "$linux_service" "$linux_timer"
SYSTEMCTL_DISABLE_RC=1 SYSTEMCTL_ACTIVE_RC=3 SYSTEMCTL_ENABLED_RC=1
SYSTEMCTL_ACTIVE_STATE='Failed to connect to bus' SYSTEMCTL_ENABLED_STATE='Failed to connect to bus'
if cmd_unschedule >/dev/null 2>&1; then echo "Linux D-Bus text with state codes succeeded" >&2; exit 1; fi
[[ -e "$linux_service" && -e "$linux_timer" ]] || { echo "Linux D-Bus text removed recovery config" >&2; exit 1; }
# Recognized text with transport/nonmatching codes is also indeterminate.
SYSTEMCTL_ACTIVE_RC=1 SYSTEMCTL_ENABLED_RC=4
SYSTEMCTL_ACTIVE_STATE=inactive SYSTEMCTL_ENABLED_STATE=disabled
if cmd_unschedule >/dev/null 2>&1; then echo "Linux states with transport codes succeeded" >&2; exit 1; fi
[[ -e "$linux_service" && -e "$linux_timer" ]] || { echo "Linux transport-code failure removed recovery config" >&2; exit 1; }
# The second documented inactive text is accepted with is-active rc=3.
SYSTEMCTL_ACTIVE_RC=3 SYSTEMCTL_ENABLED_RC=1
SYSTEMCTL_ACTIVE_STATE=failed SYSTEMCTL_ENABLED_STATE=disabled
cmd_unschedule >/dev/null
[[ ! -e "$linux_service" && ! -e "$linux_timer" ]] || { echo "Linux known failed/disabled retained units" >&2; exit 1; }
touch "$linux_service" "$linux_timer"
SYSTEMCTL_DISABLE_RC=0
cmd_unschedule >/dev/null
[[ ! -e "$linux_service" && ! -e "$linux_timer" ]] || { echo "Linux success retained units" >&2; exit 1; }

uname() { echo Darwin; }
id() { [[ "$1" == -u ]] && echo 501; }
plist="$HOME/Library/LaunchAgents/com.lost.plus.setup-update.plist"
launchctl() { printf '%s' "${LAUNCHCTL_OUTPUT:-}"; return "${LAUNCHCTL_RC:-0}"; }
touch "$plist"
LAUNCHCTL_RC=5 LAUNCHCTL_OUTPUT='permission denied'
if cmd_unschedule >/dev/null 2>&1; then echo "macOS unload failure succeeded" >&2; exit 1; fi
[[ -e "$plist" ]] || { echo "macOS unload failure removed recovery plist" >&2; exit 1; }
LAUNCHCTL_RC=3 LAUNCHCTL_OUTPUT='Could not find service'
cmd_unschedule >/dev/null
[[ ! -e "$plist" ]] || { echo "macOS already-unloaded status retained plist" >&2; exit 1; }
touch "$plist"
LAUNCHCTL_RC=0 LAUNCHCTL_OUTPUT=''
cmd_unschedule >/dev/null
[[ ! -e "$plist" ]] || { echo "macOS success retained plist" >&2; exit 1; }

echo "unschedule path tests passed"
