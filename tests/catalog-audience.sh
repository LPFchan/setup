#!/usr/bin/env zsh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

export HOME="$TEST_TMP/home"
export XDG_STATE_HOME="$TEST_TMP/state"
export STATE_DIR="$XDG_STATE_HOME/setup"
export SETUP_SOURCE_ONLY=1
export LINUX_SETUP_SOURCE_URL="file://$ROOT"
export SETUP_OWNER_KEYS_URL="file://$TEST_TMP/owner.keys"
mkdir -p "$HOME/.ssh" "$STATE_DIR"

owner_key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOwnerCatalogKey owner'
other_key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOtherCatalogKey other'
printf '%s\n' "$owner_key" > "$TEST_TMP/owner.keys"
printf '%s\n' "$owner_key" > "$HOME/.ssh/id_ed25519.pub"

# shellcheck disable=SC1091
source "$ROOT/bin/setup"

trusted=$(cmd_list)
[[ "$trusted" == *ssh-aliases* && "$trusted" == *kernel-simmer* ]] || {
    echo "trusted catalog omitted fleet entries" >&2
    exit 1
}

printf '%s\n' "$other_key" > "$HOME/.ssh/id_ed25519.pub"
public=$(cmd_list)
[[ "$public" != *ssh-aliases* && "$public" != *kernel-simmer* ]] || {
    echo "public catalog exposed fleet entries" >&2
    exit 1
}
[[ "$public" == *setup* && "$public" == *refresh-models* ]] || {
    echo "public catalog omitted public entries" >&2
    exit 1
}

echo "catalog audience tests passed"
