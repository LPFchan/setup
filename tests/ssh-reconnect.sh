#!/usr/bin/env zsh
# The ssh-reconnect block is owned by the tmux module: tmux mouse mode is what
# dirties the local terminal when a link dies, and the reattach is only lossless
# because the same module autostarts the shared "main" session.
set -euo pipefail

ROOT=${0:A:h:h}
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

export HOME="$TEST_TMP/home"
export XDG_STATE_HOME="$TEST_TMP/state"
export STATE_DIR="$XDG_STATE_HOME/setup"
mkdir -p "$HOME" "$STATE_DIR"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# shellcheck disable=SC1091
source "$ROOT/lib/script-helpers.sh"
# shellcheck disable=SC1091
source "$ROOT/files/tmux.sh"

[[ -n "${RECONNECT_BLOCK_CONTENT:-}" ]] \
    || fail "the tmux module does not carry the reconnect block"

# The block ships as shell source, so a syntax error would break every
# interactive login on every machine at once.
zsh -n -c "$RECONNECT_BLOCK_CONTENT" || fail "reconnect block is not valid zsh"

# Mouse reporting is the mode that must be undone: while it is on, a dead link
# leaves every mouse movement typing an escape sequence at the local prompt.
[[ "$RECONNECT_BLOCK_CONTENT" == *'?1006l'* && "$RECONNECT_BLOCK_CONTENT" == *'?1000l'* ]] \
    || fail "the terminal restore does not disable mouse reporting"

# Drop the interactive/TTY guard so the helpers can be exercised from a
# non-interactive test shell, which the guard deliberately excludes.
eval "${${RECONNECT_BLOCK_CONTENT#*then}%fi}"
(( ${+functions[_ssh_login_target]} && ${+functions[_ssh_wake_watcher]} )) \
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

echo "ssh reconnect tests passed"
