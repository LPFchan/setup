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
mangchi_block=$(printf '%s\n' "$block" | awk '
    /^Host mangchi mangchi.lost.plus$/ { found=1 }
    found && /^Host / && $2 != "mangchi" { exit }
    found { print }
')
[[ "$mangchi_block" == *'HostName mangchi.lost.plus'* \
   && "$mangchi_block" == *'User yeowool'* ]] \
    || fail "mangchi private DNS alias is missing"
mac_block=$(printf '%s\n' "$block" | awk '
    /^Host yeowoolmac mac.lost.plus$/ { found=1 }
    found && /^Host / && $2 != "yeowoolmac" { exit }
    found { print }
')
[[ "$mac_block" != *'UserKnownHostsFile '* \
   && "$mac_block" != *'StrictHostKeyChecking '* ]] \
    || fail "Mac mini still bypasses host-key verification"
bingus_block=$(printf '%s\n' "$block" | awk '
    /^Host bingus bingus.lost.plus$/ { found=1 }
    found && /^Host / && $2 != "bingus" { exit }
    found { print }
')

[[ "$bingus_block" == *'HostName bingus.lost.plus'* ]] \
    || fail "bingus hostname is missing"
[[ "$bingus_block" == *'SetEnv TERM=xterm-256color'* ]] \
    || fail "bingus does not fall back to DSM-supported terminfo"

grimoire_block=$(printf '%s\n' "$block" | awk '
    /^Host grimoire grimoire.lost.plus$/ { found=1 }
    found && /^Host / && $2 != "grimoire" { exit }
    found { print }
')
[[ "$grimoire_block" != *'SetEnv TERM='* ]] \
    || fail "TERM fallback leaked to hosts that support tmux-256color"
[[ "$grimoire_block" != *'UserKnownHostsFile '* \
   && "$grimoire_block" != *'StrictHostKeyChecking '* ]] \
    || fail "host-specific host-key policy overrides the fleet default"

[[ "$block" == *$'Host *\n    StrictHostKeyChecking accept-new' ]] \
    || fail "global first-use policy is missing or scoped to the last alias"
[[ "$block" != *'UserKnownHostsFile '* ]] \
    || fail "managed config replaces the user's known-hosts storage"

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

# Preserve user policy and key history while replacing the old Mac exception.
cat > "$SSH_CONFIG" <<'EOF'
Host strict.example
    StrictHostKeyChecking yes
Host ask.example
    StrictHostKeyChecking ask
Host user-override.example
    StrictHostKeyChecking no
Host *
    ServerAliveInterval 42
EOF
unmanaged_config=$(cat "$SSH_CONFIG")
printf '%s\n' 'existing.example ssh-ed25519 existing-key-do-not-delete' > "$HOME/.ssh/known_hosts"
known_hosts_before=$(cat "$HOME/.ssh/known_hosts")
legacy_block=$'Host yeowoolmac mac.lost.plus\n    UserKnownHostsFile /dev/null\n    StrictHostKeyChecking no'
manage_block "$SSH_CONFIG" "$MODULE" "$legacy_block" "upsert" "append" >/dev/null
# Existing installations can have stricter user stanzas after the old block.
later_config=$'Host later-strict.example\n    StrictHostKeyChecking yes'
printf '%s\n' "$later_config" >> "$SSH_CONFIG"
unmanaged_config+=$'\n'"$later_config"
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
# GNU stat first: it fails cleanly on macOS with nothing on stdout, whereas BSD
# stat -f prints filesystem info to STDOUT before failing on Linux, so the old
# order captured that blob followed by the real mode and never equalled 600.
key_mode=$(stat -c '%a' "$HOME/.ssh/authorized_keys" 2>/dev/null \
    || stat -f '%Lp' "$HOME/.ssh/authorized_keys")
[[ "$key_mode" == "600" ]] \
    || fail "authorized_keys permissions are not 600 (got: $key_mode)"

status >/dev/null || fail "freshly installed GitHub owner keys are not current"
[[ "$(cat "$HOME/.ssh/known_hosts")" == "$known_hosts_before" ]] \
    || fail "install changed known_hosts"
! grep -q '/dev/null' "$SSH_CONFIG" || fail "legacy Mac bypass survived migration"

# Ask the real OpenSSH parser, not just a text matcher. -G does not connect.
effective_option() {
    ssh -G -F "$SSH_CONFIG" "$1" 2>/dev/null | awk -v key="$2" '$1 == key { print $2 }'
}
for target in dumpling mac.lost.plus yeowoolmac arbitrary.example 192.0.2.1; do
    [[ "$(effective_option "$target" stricthostkeychecking)" == "accept-new" ]] \
        || fail "first-use policy does not apply to $target"
    [[ "$(effective_option "$target" userknownhostsfile)" != "/dev/null" ]] \
        || fail "$target discards known host keys"
done
[[ "$(effective_option strict.example stricthostkeychecking)" == "true" ]] \
    || fail "explicit strict user policy was weakened"
[[ "$(effective_option later-strict.example stricthostkeychecking)" == "true" ]] \
    || fail "migration weakened a strict stanza after the old managed block"
[[ "$(effective_option ask.example stricthostkeychecking)" == "ask" ]] \
    || fail "explicit interactive user policy was overridden"
[[ "$(effective_option user-override.example stricthostkeychecking)" == "false" ]] \
    || fail "explicit user override was rewritten"
# Detect and repair placement drift even when the managed content is unchanged.
added_config=$'Host added-strict.example\n    StrictHostKeyChecking yes'
printf '%s\n' "$added_config" >> "$SSH_CONFIG"
unmanaged_config+=$'\n'"$added_config"
status_output=$(status 2>&1) && fail "later user stanza did not cause placement drift"
[[ "$status_output" == *'outdated'* ]] || fail "placement drift did not report outdated"
update >/dev/null
[[ "$(effective_option added-strict.example stricthostkeychecking)" == "true" ]] \
    || fail "update did not preserve a newly added strict user policy"
status >/dev/null || fail "relocated managed block did not report current"
config_before=$(cat "$SSH_CONFIG")
update >/dev/null
[[ "$(cat "$SSH_CONFIG")" == "$config_before" ]] || fail "update is not idempotent"
# Policy drift participates in the normal module status/update lifecycle.
sed 's/StrictHostKeyChecking accept-new/StrictHostKeyChecking ask/' "$SSH_CONFIG" > "$TEST_TMP/drift"
mv "$TEST_TMP/drift" "$SSH_CONFIG"
status_output=$(status 2>&1) && fail "host-key policy drift was not detected"
[[ "$status_output" == *'outdated'* ]] || fail "policy drift did not report outdated"
update >/dev/null
status >/dev/null || fail "update did not repair host-key policy drift"
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

! grep -q 'setup:ssh-aliases' "$SSH_CONFIG" || fail "uninstall left the SSH block behind"
[[ "$(cat "$SSH_CONFIG" | sed '/^$/d')" == "$unmanaged_config" ]] \
    || fail "uninstall changed unmanaged SSH config"
[[ "$(cat "$HOME/.ssh/known_hosts")" == "$known_hosts_before" ]] \
    || fail "update/uninstall changed known_hosts"
status_output=$(status 2>&1) && fail "uninstalled module reported current"
[[ "$status_output" == *'uninstalled'* ]] || fail "uninstall status is incorrect"

echo "ssh aliases tests passed"
