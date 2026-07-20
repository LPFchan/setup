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

# Force a known kernel for platform filtering independent of the host OS.
uname() {
    case "${1:-}" in
        -s) printf '%s\n' "${SETUP_TEST_UNAME_S:-Linux}" ;;
        -m) printf '%s\n' x86_64 ;;
        *) command uname "$@" ;;
    esac
}

list_for() {
    SETUP_TEST_UNAME_S="$1" cmd_list
}

# Trusted Linux: fleet + linux-only modules are visible.
trusted_linux=$(list_for Linux)
[[ "$trusted_linux" == *ssh-aliases* && "$trusted_linux" == *kernel-simmer* && "$trusted_linux" == *backup* ]] || {
    echo "trusted Linux catalog omitted fleet/linux entries" >&2
    exit 1
}

# Trusted Darwin: fleet cross-platform stays; linux-only is hidden.
trusted_darwin=$(list_for Darwin)
[[ "$trusted_darwin" == *ssh-aliases* ]] || {
    echo "trusted Darwin catalog omitted cross-platform fleet entry" >&2
    exit 1
}
[[ "$trusted_darwin" != *kernel-simmer* && "$trusted_darwin" != *backup* \
    && "$trusted_darwin" != *monitoring* && "$trusted_darwin" != *service-ctl* \
    && "$trusted_darwin" != *gpu-fancontrol* ]] || {
    echo "trusted Darwin catalog exposed linux-only entries" >&2
    exit 1
}

# Public catalog: fleet hidden on both platforms; public modules remain.
printf '%s\n' "$other_key" > "$HOME/.ssh/id_ed25519.pub"
public_linux=$(list_for Linux)
public_darwin=$(list_for Darwin)
for public in "$public_linux" "$public_darwin"; do
    [[ "$public" != *ssh-aliases* && "$public" != *kernel-simmer* && "$public" != *backup* ]] || {
        echo "public catalog exposed fleet entries" >&2
        exit 1
    }
    [[ "$public" == *setup* && "$public" == *refresh-models* ]] || {
        echo "public catalog omitted public entries" >&2
        exit 1
    }
done

echo "catalog audience tests passed"
