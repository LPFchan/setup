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
mac_block=$(printf '%s\n' "$block" | awk '
    /^Host yeowoolmac mac.lost.plus$/ { found=1 }
    found && /^Host / && $2 != "yeowoolmac" { exit }
    found { print }
')
[[ "$mac_block" == *'UserKnownHostsFile none'* \
   && "$mac_block" == *'StrictHostKeyChecking no'* ]] \
    || fail "Mac mini partition host keys are not ignored"
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
[[ "$grimoire_block" != *'UserKnownHostsFile '* \
   && "$grimoire_block" != *'StrictHostKeyChecking '* ]] \
    || fail "Mac mini host-key policy leaked to other hosts"

self_block=$(SSH_ALIASES_SELF=bingus _build_block)
[[ "$self_block" != *'Host bingus'* ]] \
    || fail "current host was not omitted"

[[ "$grimoire_block" == *'ServerAliveInterval 15'* \
   && "$grimoire_block" == *'ServerAliveCountMax 3'* ]] \
    || fail "keepalives are missing, so a suspended laptop hangs until the TCP timeout"
[[ "$grimoire_block" == *'ConnectTimeout 5'* ]] \
    || fail "an unbounded connect stalls reconnects made before Wi-Fi returns"

echo "ssh aliases tests passed"
