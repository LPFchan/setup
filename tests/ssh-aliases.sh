#!/usr/bin/env zsh
set -euo pipefail

ROOT=${0:A:h:h}
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

export HOME="$TEST_TMP/home"
export XDG_STATE_HOME="$TEST_TMP/state"
export STATE_DIR="$XDG_STATE_HOME/setup"
mkdir -p "$HOME/.ssh" "$STATE_DIR"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# shellcheck disable=SC1091
source "$ROOT/lib/script-helpers.sh"
# shellcheck disable=SC1091
source "$ROOT/files/ssh-aliases.sh"

block=$(SSH_ALIASES_SELF=not-a-fleet-host _build_block)
bingus_block=$(printf '%s\n' "$block" | awk '
    /^Host bingus$/ { found=1 }
    found && /^Host / && $2 != "bingus" { exit }
    found { print }
')

[[ "$bingus_block" == *'HostName bingus.lost.plus'* ]] \
    || fail "bingus hostname is missing"
[[ "$bingus_block" == *'SetEnv TERM=xterm-256color'* ]] \
    || fail "bingus does not fall back to DSM-supported terminfo"

grimoire_block=$(printf '%s\n' "$block" | awk '
    /^Host grimoire$/ { found=1 }
    found && /^Host / && $2 != "grimoire" { exit }
    found { print }
')
[[ "$grimoire_block" != *'SetEnv TERM='* ]] \
    || fail "TERM fallback leaked to hosts that support tmux-256color"

self_block=$(SSH_ALIASES_SELF=bingus _build_block)
[[ "$self_block" != *'Host bingus'* ]] \
    || fail "current host was not omitted"

[[ "$grimoire_block" == *'ServerAliveInterval 15'* \
   && "$grimoire_block" == *'ServerAliveCountMax 3'* ]] \
    || fail "keepalives are missing, so a suspended laptop hangs until the TCP timeout"
[[ "$grimoire_block" == *'ConnectTimeout 5'* ]] \
    || fail "an unbounded connect stalls reconnects made before Wi-Fi returns"

# The reconnect wrapper ships as shell source; a syntax error would break every
# interactive login on every machine at once.
zsh -n -c "$RECONNECT_BLOCK" || fail "reconnect block is not valid zsh"

# Drop the interactive/TTY guard so the helpers can be exercised from a
# non-interactive test shell, which the guard deliberately excludes.
body=${${RECONNECT_BLOCK#*then}%fi}
eval "$body"
(( ${+functions[_ssh_login_target]} )) \
    || fail "reconnect block did not define its helpers"

[[ $(_ssh_login_target grimoire) == grimoire ]] \
    || fail "a plain login was not recognized"
[[ $(_ssh_login_target -t -p 2222 grimoire) == grimoire ]] \
    || fail "option values were counted as operands"
[[ -z $(_ssh_login_target grimoire uptime) ]] \
    || fail "a remote command was wrapped in the reconnect loop"
[[ -z $(_ssh_login_target) ]] \
    || fail "an argument-less invocation was wrapped"

# Wake detection, driven by a fake clock. Unloading zsh/datetime turns
# EPOCHSECONDS back into an ordinary variable the test can advance, and the
# shadowed sleep stops after a fixed number of ticks so the loop body runs.
zmodload -u zsh/datetime 2>/dev/null
typeset -g EPOCHSECONDS=1000 TICK=2 KILLED=0 TICKS=0
sleep() { (( EPOCHSECONDS += TICK )); (( ++TICKS >= 3 )) && return 1; return 0; }
pkill() { KILLED=1; return 0; }
kill()  { return 0; }   # keep the parent-shell-alive probe true

TICK=2 _ssh_wake_watcher 1
(( KILLED == 0 )) \
    || fail "the watcher hung up a healthy session while merely ticking"

EPOCHSECONDS=1000 KILLED=0 TICKS=0
TICK=40 _ssh_wake_watcher 1
(( KILLED == 1 )) \
    || fail "a wake left the stale client to wait out ServerAlive"

echo "ssh aliases tests passed"
