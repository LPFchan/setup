#!/usr/bin/env zsh
set -euo pipefail

ROOT=${0:A:h:h}
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

export HOME="$TEST_TMP/home"
export XDG_STATE_HOME="$TEST_TMP/state"
export STATE_DIR="$XDG_STATE_HOME/setup"
mkdir -p "$HOME/.ssh" "$STATE_DIR"

OWNER_KEYS_FILE="$TEST_TMP/github.keys"
cat > "$OWNER_KEYS_FILE" <<'EOF'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestOwnerKeyOne owner-one
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCTestOwnerKeyTwo owner-two
EOF
export SETUP_OWNER_KEYS_URL="file://$OWNER_KEYS_FILE"

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
[[ "$mac_block" == *'UserKnownHostsFile /dev/null'* \
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

# Exercise the real managed-block lifecycle without executing setup's command
# dispatcher.
export SETUP_SOURCE_ONLY=1
export LINUX_SETUP_SOURCE_URL="file://$ROOT"
source "$ROOT/bin/setup"
source "$ROOT/files/ssh-aliases.sh"

manage_block "$SSH_CONFIG" "$MODULE" "$(_build_block)" "upsert" "append" >/dev/null
status_output=$(status 2>&1) && fail "missing authorized_keys did not make the module outdated"
[[ "$status_output" == *'outdated'* ]] \
    || fail "missing authorized_keys did not report outdated"

printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIUnmanagedKey keep-me' > "$HOME/.ssh/authorized_keys"
install >/dev/null

grep -q '^# >>> setup:ssh-aliases-github-keys >>>$' "$HOME/.ssh/authorized_keys" \
    || fail "authorized_keys managed block was not installed"
grep -q 'TestOwnerKeyOne' "$HOME/.ssh/authorized_keys" \
    || fail "first GitHub owner key was not installed"
grep -q 'UnmanagedKey' "$HOME/.ssh/authorized_keys" \
    || fail "an unmanaged authorized key was overwritten"
[[ "$(stat -f '%Lp' "$HOME/.ssh/authorized_keys" 2>/dev/null || stat -c '%a' "$HOME/.ssh/authorized_keys")" == "600" ]] \
    || fail "authorized_keys permissions are not 600"

status >/dev/null || fail "freshly installed GitHub owner keys are not current"
printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestOwnerKeyThree owner-three' >> "$OWNER_KEYS_FILE"
status_output=$(status 2>&1) && fail "a new GitHub owner key did not make the module outdated"
[[ "$status_output" == *'outdated'* ]] \
    || fail "changed GitHub owner keys did not report outdated"

update >/dev/null
grep -q 'TestOwnerKeyThree' "$HOME/.ssh/authorized_keys" \
    || fail "update did not enroll the new GitHub owner key"
status >/dev/null || fail "updated GitHub owner keys are not current"

uninstall >/dev/null
grep -q 'UnmanagedKey' "$HOME/.ssh/authorized_keys" \
    || fail "uninstall removed an unmanaged authorized key"
! grep -q 'setup:ssh-aliases-github-keys' "$HOME/.ssh/authorized_keys" \
    || fail "uninstall left the GitHub owner-key block behind"

echo "ssh aliases tests passed"
