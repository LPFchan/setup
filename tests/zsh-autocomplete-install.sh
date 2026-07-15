#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

export HOME="$TEST_TMP/home"
export ZSH_PLUGINS_DIR="$HOME/.zsh"
mkdir -p "$HOME"

clone_count=0
upsert_count=0
record_count=0
git_clone_if_missing() {
    clone_count=$((clone_count + 1))
    [[ "${FAIL_FIRST_CLONE:-0}" != "1" || "$clone_count" -ne 1 ]]
}
manage_block() { :; }
git_local_ref() { echo abcdef0; }
record_script_state() { record_count=$((record_count + 1)); }
remove_script_state() { :; }

# shellcheck disable=SC1091
source "$ROOT/files/zsh-autocomplete.sh"
_upsert_block() { upsert_count=$((upsert_count + 1)); }

FAIL_FIRST_CLONE=1
if install; then
    echo "install unexpectedly succeeded after the first clone failed" >&2
    exit 1
fi
[[ "$clone_count" -eq 1 ]] || { echo "install continued cloning after failure" >&2; exit 1; }
[[ "$upsert_count" -eq 0 ]] || { echo "install wrote .zshrc after clone failure" >&2; exit 1; }
[[ "$record_count" -eq 0 ]] || { echo "install recorded state after clone failure" >&2; exit 1; }

FAIL_FIRST_CLONE=0
clone_count=0
install
[[ "$clone_count" -eq 2 ]] || { echo "install did not clone both repositories" >&2; exit 1; }
[[ "$upsert_count" -eq 1 ]] || { echo "install did not write .zshrc" >&2; exit 1; }
[[ "$record_count" -eq 1 ]] || { echo "install did not record state" >&2; exit 1; }

echo "zsh-autocomplete install tests passed"
