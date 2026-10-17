#!/usr/bin/env zsh
set -euo pipefail

ROOT=${0:A:h:h}
export SETUP_SOURCE_ONLY=1
source "$ROOT/bin/setup"

test_platform=Darwin
test_loaded=yes
test_systemd=inactive
test_gui=yes
uname() { print -r -- "$test_platform"; }
id() { print 501; }
launchctl() {
    [[ "$1" == print && "$test_gui" == yes ]] || return 1
    [[ "$2" == gui/501 ]] && return 0
    [[ "$2" == gui/501/com.lost.plus.fleet-sync && "$test_loaded" == yes ]]
}
systemctl() {
    [[ "$test_platform" == Linux ]] || { print 'systemctl called on macOS' >&2; return 1; }
    print -r -- "$test_systemd"
}
fail() { print -u2 -- "FAIL: $*"; exit 1; }

module_is_active fleet || fail 'loaded macOS fleet agent reported inactive'
test_loaded=no
if module_is_active fleet; then
    fail 'missing macOS fleet agent reported active'
fi
# Over SSH there is no GUI domain; an installed plist waiting for the next
# login counts as enabled.
test_gui=no
HOME=$(mktemp -d)
trap 'rm -rf "$HOME"' EXIT
if module_is_active fleet; then
    fail 'fleet with no plist and no GUI session reported active'
fi
mkdir -p "$HOME/Library/LaunchAgents"
touch "$HOME/Library/LaunchAgents/com.lost.plus.fleet-sync.plist"
module_is_active fleet || fail 'fleet plist waiting for a GUI login reported inactive'
test_gui=yes
if module_is_active fleet; then
    fail 'unloaded fleet agent in a GUI session reported active'
fi
test_platform=Linux
test_systemd=active
module_is_active fleet || fail 'active Linux fleet timer reported inactive'
test_systemd=inactive
if module_is_active fleet; then
    fail 'inactive Linux fleet timer reported active'
fi
print 'macOS/Linux fleet service checks passed'
